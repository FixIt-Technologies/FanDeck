# GenesisFanControl

A SwiftUI macOS clone of [Macs Fan Control](https://crystalidea.com/macs-fan-control)
with a modern dark UI, a working IOKit/AppleSMC backend on Apple Silicon,
a privileged helper daemon for fan writes, and a global `fans` CLI that
shares the same backend as the GUI.

Tested on MacBookPro21,5 (M4 Pro, macOS 15). The read path also works on
Intel Macs; the write path's Apple-Silicon `Ftst` dance is a no-op there.

---

## Quick start

```bash
cd GenesisFanControl
bun install         # nothing actually pulled — only scripts/ has TS
bun run start       # build release + install /Applications/.app + launch
```

The first run pops one macOS admin prompt to drop a symlink at
`/usr/local/bin/fans`. Subsequent `bun run start` invocations need no
password — the install layout uses symlinks so every rebuild is
instantly reflected.

To control fans, click **Install Helper** in the amber banner that
appears when you drag a fan; a second admin prompt installs a launchd
daemon at `/usr/local/sbin/genesis-fan-control-helper`. From then on,
the GUI's drag-to-set drives real fans without `sudo`.

```bash
fans list                       # globally available
fans get F0
sudo fans set F0 const 3500     # write directly without the helper
sudo fans set F0 auto
fans watch                      # 1Hz tail of RPMs + headline sensor
```

---

## Project layout

```
GenesisFanControl/
├── Package.swift                  # SPM manifest — 3 executables + library + tests
├── package.json                   # Bun-driven build / install / dev scripts
├── README.md                      # this file
├── scripts/
│   ├── install.ts                 # build → /Applications/.app + /usr/local/bin
│   ├── uninstall.ts               # remove .app, CLI symlink, helper daemon
│   ├── dev.ts                     # watch mode — fs.watch + debounced rebuild
│   ├── build-icon.swift           # render fanblades.fill → AppIcon.icns
│   └── AppIcon.icns               # generated, ignored .iconset stays out of git
├── Sources/
│   ├── GenesisFanControlCore/     # shared library
│   │   ├── AppState/AppState.swift
│   │   ├── Logging/{Log,GFCLogger,LogStore}.swift
│   │   ├── Privileged/{HelperProtocol,HelperClient,HelperInstaller,UnixSocket}.swift
│   │   ├── SMC/{AppleSMCService,MockSMCService,SMCService,SMCModels}.swift
│   │   └── Settings/SettingsStore.swift
│   ├── GenesisFanControl/         # the SwiftUI app
│   │   ├── App/{GenesisFanControlApp,AppDelegate}.swift
│   │   ├── FanControl/FanControlSheet.swift
│   │   ├── MainWindow/{MainView,FanGaugeCard,SensorPanel}.swift
│   │   ├── Settings/{SettingsRootView,GeneralSettingsTab,TemperatureSensorsTab,MenuBarIconTab}.swift
│   │   └── Theme/{Theme,Components}.swift
│   ├── GenesisFanControlHelper/main.swift   # root daemon
│   └── fans/main.swift                       # CLI
└── Tests/GenesisFanControlTests/             # 329 XCTest cases (14 files)
```

Four targets, one library:

| Target | Kind | Purpose |
|---|---|---|
| `GenesisFanControlCore` | library | SMC bridge, AppState, settings, logging, helper protocol — shared by everything below |
| `GenesisFanControl` | executable | SwiftUI app, menu-bar icon, settings window |
| `GenesisFanControlHelper` | executable | privileged daemon launched by launchd; owns SMC writes |
| `fans` | executable | command-line client; runs against the same `AppleSMCService` directly |

---

## The SMC backend

`Sources/GenesisFanControlCore/SMC/AppleSMCService.swift` is the real IOKit
bridge. It speaks the standard private-AppleSMC ioctl that every Swift /
Objective-C SMC wrapper in the wild uses (smcFanControl, SMCKit, stats,
AlDente, BatFi, fastfetch, btop, …).

### The wire protocol

Open the service:

```swift
IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
IOServiceOpen(service, mach_task_self_, 0, &connection)
```

Then `IOConnectCallStructMethod(connection, selector=2, input80B, 80, output80B, &80)`,
where the 80-byte buffer is **the** `SMCParamStruct`:

```text
offset  size  field
   0     4    key (FourCC, e.g. 'F0Ac')
   4     6    vers (SMCVersion)
  10     2    (padding)
  12    16    pLimitData (SMCPLimitData)
  28    12    keyInfo (SMCKeyInfoData — dataSize, dataType, dataAttributes + 3B pad)
  40     1    result (0 = ok; SMC firmware error otherwise)
  41     1    status
  42     1    data8 (call type: 5=read, 6=write, 9=getKeyInfo)
  43     1    (padding)
  44     4    data32
  48    32    bytes (payload)
                                                    total = 80
```

Swift's default struct layout packs `SMCKeyInfoData` to 9 bytes (no
trailing padding). The kernel expects the struct to be 80 bytes total,
so we add three explicit `UInt8` pad fields to `SMCKeyInfoData` to round
it to 12. A `precondition(MemoryLayout<SMCParamStruct>.stride == 80)`
crashes startup if anyone ever re-packs it; without it, the kernel
returns garbage values silently.

### Data type tags

`keyInfo.dataType` is itself a FourCC. Decoders we support:

| Type tag | Bytes | Semantics |
|---|---|---|
| `"ui8 "` | 1 | unsigned 8-bit |
| `"ui16"` | 2 | unsigned 16-bit big-endian |
| `"ui32"` | 4 | unsigned 32-bit big-endian |
| `"si8 "` | 1 | signed 8-bit |
| `"si16"` | 2 | signed 16-bit big-endian |
| `"fpe2"` | 2 | 14-bit unsigned int, 2-bit fraction (raw / 4) — most common fan target on Intel |
| `"sp78"` | 2 | signed 8.8 fixed-point (raw / 256) — common temperature |
| `"flt "` | 4 | IEEE 754 32-bit float — **the** Apple Silicon fan/temp encoding |

Encoders only need to be exact for the keys we WRITE — that's fan mode
(ui8) and fan target (fpe2 or flt, machine-dependent — see below).

### Apple Silicon write path — the `Ftst` unlock dance

This is the single most important Apple Silicon finding. On Intel,
forcing manual mode is one write: `F{i}Md = 1`. On M1 / M2 / M3 / M4,
the SMC kernel accepts that write (`result == 0`) but `thermalmonitord`
silently undoes it within milliseconds, leaving the fan in OS-managed
mode. The fix, cribbed from
[exelban/stats SMC/smc.swift:566-602](https://github.com/exelban/stats/blob/master/SMC/smc.swift):

1. **Fast path** — try `writeUInt8("F0Md", 1)` directly. If the fan is
   already unlocked (from a previous `setMode`), this succeeds and we're
   done in microseconds.
2. **Read `Ftst`**. If it doesn't exist, give up — we're on a machine
   where this lock doesn't apply.
3. If `Ftst != 1`, **write `Ftst = 1`**, retry up to 100× at 50 ms each
   until the SMC accepts it. (This is the firmware "unlock fan control"
   permission.)
4. **Sleep 3 s.** thermalmonitord polls; we have to wait for it to see
   the unlock and yield.
5. **Retry `F0Md = 1` up to 300×** at 100 ms. The first ~5 usually fail
   ("still busy"); somewhere in the middle the write lands.

Worst-case wall clock on the first write: ~3.5 s. Subsequent writes hit
the fast path (~1 ms).

**Release direction matters.** To return to auto, you must write the
mode key FIRST while `Ftst` is still unlocked, THEN drop `Ftst`:

```swift
writeUInt8("F0Md", 0)   // mode back to auto WHILE Ftst is still 1
writeUInt8("Ftst", 0)   // re-lock; firmware reclaims fan control
```

Doing it the other way around (`Ftst=0` first, `F0Md=0` second) silently
fails: the firmware re-locks the moment `Ftst` goes 1→0 and ignores the
subsequent `F0Md` write. Symptom was the "click Auto → UI blinks to
auto → snaps back to the previous constant" bug.

**Per-tick re-assertion.** thermalmonitord can claw back `F0Tg` (and
the physical `F0Ac`) under thermal governance — set a fan to 5500 RPM
and the firmware may drop it to ~4100 within seconds, even while
`F0Md=1`. Our defense is `primeSnapshot()`'s host loop: every poll
tick re-pushes the user's intended target via `writeRPM`, with a
fall-back to `helperClient.setMode(.constant(rpm:))` when the GUI's
direct (non-root) write is rejected. This makes the re-assertion the
*mechanism* for both `.constant` and `.sensorBased` modes, not just
maintenance. Cost is ~1 ms / fan / tick.

**Cold-start safe-reset.** On every `AppleSMCService.init`, we drop
every fan we discover in `F0Md=1` back to `F0Md=0` (auto) before the
first snapshot. Reason: if a previous run crashed mid-constant,
thermalmonitord left `F0Tg` at whatever it last clamped, and a fresh
init would otherwise adopt that value as "user intent" and re-assert
it forever via the host loop.

**Absolute RPM safety floor.** `writeRPM(fanIdx:rpm:)` clamps to
`max(800, rawRPM)` BEFORE encoding so no path (CLI, helper, host
re-assertion, future programmatic) can write 0 — which on most Mac
fans stalls the bearing.

We run this whole sequence on a dedicated `DispatchQueue` so it never
freezes the SwiftUI main thread — see *Concurrency model* below.

### `F0Tg` is `flt`, not `fpe2`

A subtle bug we hit early: on Apple Silicon, the fan target key
`F\(i)Tg` is encoded as a 4-byte IEEE 754 float (`"flt "`), not the
2-byte `fpe2` used on Intel. Writing `fpe2` bytes `(hi, lo, 0, 0)` into
a 4-byte float slot produces an IEEE 754 denormal ≈ 1e-43 RPM, which
the firmware floors or fail-safes to maximum. (Hence: "I set the fan to
2500 RPM and it ramped to max instead.")

`writeRPM(fanIdx:rpm:)` first calls `getKeyInfo` to read the actual
type tag, then branches:

```swift
switch typeStr {
case "fpe2":
    let raw = UInt16(rpm) << 2     // 14.2 fixed
    bytes[0] = hi; bytes[1] = lo
case "flt ":
    let bits = Float(rpm).bitPattern    // little-endian on disk
    bytes[0..<4] = bits.littleEndianBytes
case "ui16":
    bytes[0..<2] = UInt16(rpm).bigEndian
}
```

The same dispatch is used for `Ftst` (`ui8`), mode keys (`ui8`), and
anything else we ever write.

### `F0Md` case quirk

Different Macs expose the mode key as `F0Md` (uppercase) or `F0md`
(lowercase). `modeKey(forFan:)` probes both at first call and caches
the one that answers in `modeKeyCache`, then reuses it. Without this,
machines that only expose lowercase silently fail every fan write.

### Sensor discovery

`FNum` returns the fan count (`ui8`). We probe `F0` … `F{n-1}` for
each fan's `Ac` / `Mn` / `Mx` / `Tg` / `Md` keys.

Temperatures are discovered by probing a hand-curated list of ~30
candidate keys (`AppleSMCService.candidateSensors`) — only the ones
the chip actually answers are kept. The list covers M-series CPU
performance/efficiency cores (`Tp09 / Tp0T / Tp0b / Tp0d / Tp0f / Tp0n`),
GPU clusters (`Tg0D / Tg0V` etc.), battery (`TB0T / TB1T / TB2T`),
NVMe SSDs (`TH0a / TH0b / TH0x`), airport (`TW0P`), thunderbolt
(`TTLD / TTRD`), and power-supply proximity (`TPSP`).

The catalog isn't exhaustive — research notes in
`~/Tresors/Projects/GenesisBrain/GenesisTools/Fans/Research-2026-06-29.md`
identify another ~20 M3 / M4-specific keys (`Te0?`, `Tf??` prefixes)
that we don't probe yet.

---

## Privileged helper daemon

Fan writes need root. The GUI doesn't run as root, so we ship a tiny
helper daemon that does.

### Installation flow

`HelperInstaller.install()` is invoked from the GUI's "Install Helper"
button (in the elevation banner). It runs **one** `osascript` "with
administrator privileges" call to:

1. Wipe any legacy MacsFanControl-era helper (`launchctl bootout` +
   `rm -f` of its plist, binary, socket).
2. Copy the freshly built helper binary to
   `/usr/local/sbin/genesis-fan-control-helper` (root:wheel, 0755).
3. Write `/Library/LaunchDaemons/dev.foltyn.genesis-fan-control.helper.plist`
   with `RunAtLoad=true`, `KeepAlive=true`, log paths under `/var/log/`.
4. `launchctl bootout system <plist>` (in case of upgrade), then
   `launchctl bootstrap system <plist>` to load it, then
   `launchctl kickstart -k system/<label>` to force-start it.
5. Wait up to 3 s for the daemon's Unix socket to come up. If `ping()`
   succeeds we're done; otherwise throw `.timeout`.

### IPC — JSON over a Unix domain socket

`HelperProtocol.swift` defines a tiny Codable enum:

```swift
public enum HelperRequest: Codable {
    case ping
    case setAuto(fanID: String)
    case setConstant(fanID: String, rpm: Int)
}

public struct HelperResponse: Codable {
    public let ok: Bool
    public let error: String?
    public let backendName: String?
    public let protocolVersion: Int?
}
```

Wire format: one JSON object per line, `\n`-delimited, one request →
one response → close. `UnixSocket.swift` wraps the BSD socket calls
directly (`socket(AF_UNIX, SOCK_STREAM, 0)` → `bind` → `chmod 0666` →
`listen` → `accept`). One connection per RPC keeps the helper trivially
stateless.

### Protocol version + auto-update banner

`HelperConstants.protocolVersion` is bumped on **every** helper-side
behavior fix (even bug-fix-only). Each ping response carries the
helper's compiled version. `HelperClient.health()` returns one of:

- `.healthy(version)` — helper alive AND version matches
- `.outdated(installed, current)` — helper alive but stale
- `.down` — socket unreachable

`AppState.tick` reads `health()` every second. On `.outdated`,
`needsElevation` is raised immediately and persistently so the user
sees a banner with explicit copy ("Helper is out of date — installed
v1, GUI expects v2") and an "Update Helper" button that re-runs the
same admin-privileged install flow. This catches the case where the
GUI binary has fix X but the installed helper at `/usr/local/sbin/`
is still the binary from before X — without this, the user wouldn't
know they need to re-install and would just see broken behavior.

Socket path: `/var/run/genesis-fan-control.sock` (0666, world-writable).
**Known security smell** — any local process can crank fans. Review
flagged this HIGH. Mitigation in progress: `getpeereid(2)` in helper
accept loop + `chmod 0660`. Migration path to `SMAppService.daemon` +
XPC for codesigning-anchored identity check is documented in
*Future work*.

### Why not `NSXPCConnection`?

Because for an unsigned dev binary built by SwiftPM, the path of least
resistance is a Unix socket. `NSXPCConnection` + machService is the
canonical Apple choice and would gain us the codesigning-anchored
identity check for free, but it requires the helper to be inside an
`.app` bundle at `Contents/Library/LaunchDaemons/`, signed with the
same team ID, and registered via `SMAppService.daemon(plistName:)`.
That's incompatible with `swift build -c release` standalone binaries.
The migration path is documented in *Future work*.

---

## SwiftUI app

### Window layout

The main window uses `.windowStyle(.hiddenTitleBar)` — content extends
all the way to the top of the window for a seamless dark surface. The
custom top "status bar" overlay pads 70 px on the left to clear the
traffic-light buttons and shows: app name, backend pill (`AppleSMC`
green, `MockSMC · SIM` amber). The gear button + Updated timestamp
live in the SensorPanel header on the right (same y row).

**Hit-testing gotcha** (HARD-WON): the ZStack must declare the
interactive `HStack { fansColumn; SensorPanel }` AFTER `topStatusBar`
so the interactive side wins SwiftUI's last-declared-first hit-test
order. An HStack with a trailing `Spacer()` claims hit-testing for
its *whole* frame width — so if topStatusBar is on top of SensorPanel
at y=0..28, every click in the SensorPanel header's territory (gear
included) gets eaten by topStatusBar's Spacer and dropped. Belt-and-
braces: `.allowsHitTesting(false)` on topStatusBar (purely decorative,
no buttons). This was diagnosed via the SwiftUI expert skill after
three failed action-dispatch fixes that all addressed the wrong layer.

Below that is a two-column layout:
- **Center** — a `ScrollView` of `FanGaugeCard` per fan (stacked).
- **Right** — a fixed-width 280 px `SensorPanel` listing every
  temperature, grouped by kind, color-coded by reading (green < 45,
  amber < 65, orange < 80, red ≥ 80 °C).

### `FanGaugeCard`

Each card has:
- Fan name + ID label + a mode pill ("AUTOMATIC", "CONSTANT SPEED",
  "SENSOR-BASED")
- The interactive `DraggableRPMGauge` (described below)
- min / max RPM labels under the gauge
- Three `MetricChip` tiles (CURRENT / TARGET / LOAD)
- An "Auto" button (only when mode ≠ .auto) + the "Configure…" modal trigger

### `DraggableRPMGauge`

The bar is BOTH a live indicator AND a setter:

- The colored fill is always the current RPM, animated with a 1.0 s
  ease-out — except during a drag, where it tracks the cursor 1:1
  with no animation (the rapid-restart on every `onChanged` was
  freezing the animation at its slow-start).
- A vertical "wall" marker shows the active setpoint, with the RPM
  label rendered below the bar so the user can always read it:
  - **Amber** when the user is dragging or the fan is in `.constant`
    mode. Label: `"3500 RPM"`.
  - **Cyan** when the fan is in `.sensorBased` mode. Label:
    `"→ 3500 RPM"` (`→` indicates the value is dynamic — the SMC layer
    re-computes the target from the live sensor reading every tick).

`DragGesture(minimumDistance: 0)` is attached to the entire gauge
including a `contentShape(Rectangle())` so a tap anywhere along the bar
commits a constant-RPM write immediately. The deduped onChanged commits
on every cursor move so the fan tracks live as you drag.

### Per-fan modal (`FanControlSheet`)

Three modes:

1. **Automatic** — `.auto`. Writes `F\(i)Md = 0` (still under unlock)
   then `Ftst = 0`. Order matters — see *Apple Silicon write path*
   above.
2. **Constant speed** — `.constant(rpm: Int)`. Goes through the full
   `unlockFanControl` dance, then `writeRPM(fanIdx:rpm:)`. The per-tick
   re-assertion in `primeSnapshot()` keeps the firmware from clawing
   the setpoint back under thermal governance.
3. **Sensor-based** — `.sensorBased(sensorId: String, points: [RampPoint])`.
   Host-driven N-point piecewise-linear curve. `RampPoint = { tempC,
   rpm }`. Every polling tick reads the named sensor and interpolates
   between the sorted points: clamps to `first.rpm` below
   `first.tempC`, clamps to `last.rpm` above `last.tempC`, lerps
   between consecutive points otherwise. Result is clamped into
   `[fan.minRPM, fan.maxRPM]` and pushed to `F\(i)Tg`.

The sensor picker lists every sensor with its **live temperature** on
the right side of each menu row, so the user can pick the right one
without leaving the modal. Rendered as `Menu { Button { Label(...,
systemImage:) } }` (NSMenuItem only takes the first Text of a Button
label — embed the temperature into the title string).

The LIVE PREVIEW card has a Swift Chart of the ramp curve:
- Cyan piecewise-linear line through all `RampPoint`s with clamps on
  either end, with a gradient AreaMark underneath for visual mass.
- One **draggable** dot per point. First point is green, last is red,
  intermediates are cyan. Drag horizontally to change temp, vertically
  to change RPM. Drag is clamped per-axis AND prevented from crossing
  neighbor temps so the curve stays monotonically left-to-right (no
  visual kinks).
- **Double-click** anywhere in the empty plot area adds a new point
  at that `(tempC, rpm)`.
- **Right-click** a point → "Delete point" (when N > 2).
- Compact per-point editor above the chart for keyboard / steppers
  with delete buttons (disabled when N ≤ 2) and an "Add point" link
  that inserts a vertex halfway between the last two.
- Amber dashed `RuleMark` at the current sensor reading, with a glowing
  PointMark on the curve at the projected RPM, annotated with both
  `"X.X °C"` and `"→ N RPM"`.

**Sensor-based config persistence.** `SettingsStore.sensorRampConfigs:
[String: SensorRampConfig]` (per-fan, JSON-persisted to UserDefaults).
The sheet hydrates from `settings.sensorRampConfig(for: fanID)` which
first tries this fan's own config, then ANY sibling fan's (so the
second fan inherits from the first — "copy from sibling" on the first
sensor-based pick). On Apply, the chosen config is saved REGARDLESS
of which mode the user is committing — so switching to constant or
auto and back later restores the exact ramp.

---

## Concurrency model

`AppState` is `@MainActor`. SMC reads + writes can sleep for several
seconds (the `Ftst` dance, helper socket round-trips), so doing them
synchronously would freeze the cursor.

The fix: a dedicated serial `DispatchQueue`:

```swift
private nonisolated let smcQueue = DispatchQueue(
    label: "dev.foltyn.genesis-fan-control.smc",
    qos: .userInitiated
)
```

Both `tick()` (the 1 Hz polling timer) and `setMode(...)` dispatch their
SMC work onto this queue, then hop back to MainActor to publish the
result. `setMode` is fire-and-forget:

1. **Optimistic UI** (MainActor) — update `fan.mode`, `fan.targetRPM`,
   `fan.currentRPM` immediately so the gauge tracks the user's intent
   while the write is in flight. Capture the intent into
   `pendingIntent[fanID]` so any polling tick that lands between the
   optimistic update and the write completion can MERGE the intent
   over the snapshot (otherwise the UI flickers back to whatever the
   firmware reports — typically the previous setpoint).
   `writeInFlight = true`.
2. **Queue** — `smcQueue.async { smc.setMode(...) → smc.refresh() →
   smc.snapshot() }`.
3. **Reconcile** (MainActor) — clear `pendingIntent[fanID]`, then
   publish the real snapshot. If the kernel rejected (`ok == false`),
   set `needsElevation = true` so the banner re-appears.
   `writeInFlight = false`.

`AppState.publish(snapshot:)` is the single funnel that publishes
fans/sensors — both `tick()` and `setMode()` go through it. It merges
`pendingIntent` over `snap.fans` so optimistic state survives any
in-flight snapshot.

`SMCService` is marked `Sendable`; concrete classes use `@unchecked
Sendable` because their mutable cache is guarded by the queue.

---

## Build system

### Three layers

1. **`swift build`** — produces three binaries in `.build/<config>/`:
   `GenesisFanControl`, `genesis-fan-control-helper`, `fans`.
2. **`bun run scripts/install.ts`** — builds in release mode, then sets
   up a proper `.app` bundle at `/Applications/GenesisFanControl.app/`
   with `Contents/MacOS/{GenesisFanControl, genesis-fan-control-helper}`
   as **symlinks** into `.build/release/` and a proper Info.plist with
   `CFBundleIconFile=AppIcon`. Also symlinks
   `/usr/local/bin/fans → .build/release/fans` (one-time sudo prompt).
3. **`bun run dev`** — watches `Sources/` for `*.swift` changes via
   `fs.watch` and triggers the install pipeline on each save (debounced
   200 ms). Equivalent to `vite dev`.

Because the .app's binaries are symlinks, every `swift build` is
**instantly** reflected in `/Applications/`. No copies needed. macOS
honors symlinks inside `.app` bundles fine (LaunchServices follows them
for the main executable).

### ⚠ install:app DOES NOT update the installed helper at /usr/local/sbin/

The launchd helper lives at `/usr/local/sbin/genesis-fan-control-helper`
(root:wheel, copied by the *one-time* `HelperInstaller` admin prompt).
`install:app` only handles the **unprivileged** GUI + CLI — it can't
overwrite the root-owned helper without re-prompting. So after a
helper-side code change (anything inside `AppleSMCService` that the
helper compiles into its binary), the GUI runs the new code but the
installed helper is still the old one.

**Mitigation (automatic):** `HelperConstants.protocolVersion` is
bumped on every helper-side fix. `HelperClient.health()` compares the
running helper's reported version against the GUI's compiled version
each tick. On mismatch, `AppState` raises a persistent elevation
banner with copy "Helper is out of date — installed v1, GUI expects
v2" and an **"Update Helper"** button that re-runs the admin install
flow. User clicks once, helper updates, banner clears.

**Bump-on-every-helper-change rule:** when you edit any code that the
helper picks up (anything in `AppleSMCService`, `HelperProtocol`, the
helper's `main.swift`), increment `protocolVersion`. Otherwise the
GUI won't know the installed copy is stale.

### Why a release `.app` instead of running `.build/debug/` directly?

Three reasons:
- A proper `.app` shows up in Spotlight, the Dock when launched, and
  the ⌘-Tab switcher with the right name and icon.
- `cmd+Tab` activation requires `.regular` activation policy, which our
  `AppDelegate` already promotes on `windowDidBecomeKey` — but the OS
  also has to recognize the binary as a "real" app, which it doesn't
  for a bare `swift run` output. The `.app` wrapper fixes that.
- The AppIcon (`scripts/build-icon.swift` → SF Symbol `fanblades.fill`
  → 10-resolution `.iconset` → `iconutil` → `.icns`) only renders when
  bundled in `Contents/Resources/`.

### Scripts

| Script | Effect |
|---|---|
| `bun run build` | `swift build -c release` |
| `bun run build:debug` | `swift build` |
| `bun run start` | Build release + install .app + restart |
| `bun run start:debug` | Build debug + install .app + restart |
| `bun run dev` | Watch mode; rebuilds + restarts on save |
| `bun run icon` | Regenerate `scripts/AppIcon.icns` |
| `bun run test` | `swift test` (329 cases, ~6 s) |
| `bun run clean` | `swift package clean` |
| `bun run uninstall:app` | Remove .app + CLI symlink + helper daemon |

---

## CLI

`fans` is a tiny wrapper around `AppleSMCService` directly — it doesn't
go through the helper at all. Reads are unprivileged; writes need
`sudo`. (Or, run it through the helper by piping JSON into
`/var/run/genesis-fan-control.sock` — see `HelperProtocol.swift`.)

```
fans <command>

  list                                          fans + sensors
  get <fanID>                                   detail
  sensors                                       all sensors
  sensor <sensorID>                             detail
  set <fanID> auto                              release
  set <fanID> const <rpm>                       constant
  set <fanID> sensor <sensorID> <lo> <hi>       sensor-based
  watch [intervalSec]                           tail readings
```

The binary lives at `.build/release/fans`; `/usr/local/bin/fans` is a
symlink to it, so once installed it's globally available — and every
`bun run start` updates it transparently because the symlink target's
content changes.

---

## Logging

Mirrors TimeTravel's double-sink design:

- `Log.app.info(...)`, `.smc.debug(...)`, `.fans.error(...)`,
  `.sensors.*`, `.ui.*`, `.settings.*`, `.lifecycle.*` — seven
  categories under one subsystem.
- Every call writes to **both** `os.Logger` (subsystem
  `dev.foltyn.genesis-fan-control`, visible via `log stream`) AND an
  in-memory `LogStore.shared` ring buffer (1000 entries) backing an
  in-app Logs panel.
- `.public` privacy is explicit on every interpolation so unified-log
  output is legible without enabling Apple's private-logging entitlement.

To tail in a terminal:

```bash
log stream --predicate 'subsystem == "dev.foltyn.genesis-fan-control"' --level debug
```

---

## Testing

`swift test` runs **329 XCTest cases** in ~6 s across 14 files. Two layers:
pure model/store tests against `GenesisFanControlCore`, plus process-logic +
SwiftUI view-structure tests added with the macOS-14 window-fix work.

**Core models & stores** (the original 6 files, 97 cases):

- **SMCModelsTests** (24) — `Fan.loadFraction` boundaries, `loadColor`
  thresholds, fahrenheit conversion, formatted() across all
  fahrenheit×precise combos, `SensorKind.sfSymbol` non-empty, full
  Codable round-trip for `SensorKind`, `FanMode`, `Fan`, `TempSensor`.
- **MockSMCServiceTests** (13) — inventory shape, RPM convergence,
  clamping, unknown-fan no-op, sensor drift bounded, mode flips land
  in snapshot.
- **LogStoreTests** (21) — ring buffer caps at 1000 + evicts oldest,
  per-category filtering, `LogFilter` AND composition, exportText /
  exportJSON shape, `LogLevel.Comparable`.
- **LogProxyTests** (6) — `Log.*` routes hit `LogStore.shared` after a
  50 ms tick.
- **SettingsStoreTests** (19) — fresh-suite defaults, per-property
  round-trip via UUID-named UserDefaults suites (per test), raw-key
  shapes, JSON-encoded menu-bar sensor IDs.
- **AppStateTests** (14) — initial population, `lastUpdated` distantPast
  until first tick, `setMode` round-trip in published `fans`,
  `headlineSensor` is the hottest CPU, `stopPolling()` idempotent.

**Process logic + UI** (8 files, 232 cases). Each executable's pure decision
logic was extracted into `Core` and the executable rewired to *call* the seam,
so these tests guard the real code path — not a parallel copy:

- **ActivationPolicyTests** (27) — `ActivationPolicyDecider`: dock-icon→policy,
  key-window promote, and demote-gating (never demote while the main OR Settings
  window is still visible).
- **SettingsDispatchTests** (45) — `SettingsWindowDispatch`: `isSettingsWindow`
  matching + the `openSettings()` → poll → bounded-legacy-fallback → give-up
  state machine behind the gear button.
- **MenuBarRenderTests** (37) — `MenuBarContent`: SF-symbol per icon style, title
  composition (temp / RPM / percent / sensors), and the byte-identical cache-skip.
- **WatchdogLifecycleTests** (24) — `MaxHoldDecider`: max-hold revert set and the
  non-auto filters that drive sleep/wake re-assert and the terminate-revert.
- **HelperHoldStateTests** (32) — `HelperHoldState` hold/release/re-assert
  targets + idle-revert, and `HelperPeerAuth` root/console-user gate.
- **FansCLITests** (48) — `CLIParser`: command + set-spec parsing, every error
  case, un-clamped const RPM, bare `fans` → usage/exit 0.
- **ViewStructureTests** + **ViewInspectorProbeTests** (19) — ViewInspector:
  MainView hit-testing + gear reachability, SensorPanel rows, FanGaugeCard
  Auto/Configure, FanControlSheet ramp points + apply-to-all.

The test target `@testable import`s the `GenesisFanControl` executable directly
(its `@main` App struct allows it — no separate UI library needed); ViewInspector
is a test-only dependency.

Singletons are reset / avoided per-test: `LogStore.shared.clear()` in
setUp/tearDown; `SettingsStore(defaults:)` over UUID-named UserDefaults
suites; `AppState(smc:autoStartPolling:false)` for AppState tests.

The real `AppleSMCService` is **not** unit-tested — it talks to the
kernel, so the test fixture would have to mock IOKit. A CLI smoke test
in `bun run test:smoke` (planned) would do `fans list` and assert the
RPM count > 0.

**Not covered by `swift test`:** real on-screen window-surfacing — does the gear
actually bring the Settings window to the front, does the menu-bar click raise
the main window. That's AppKit/WindowServer behavior needing XCUITest or a manual
click; the decision logic *behind* those flows is covered above.

---

## Known limitations

The 3-lens review at `.claude/plans/2026-06-30-GenesisFanControlReview.md`
audited the project and surfaced **41 findings** (25 HIGH+MED, 25/25
adversarially confirmed). The table below tracks what shipped vs.
what's still open.

### ✅ Shipped since the review

- **Multi-point ramp curve.** `FanMode.sensorBased(sensorId, points:
  [RampPoint])` replaces the old two-anchor form. Draggable handles in
  the chart, per-point editor with steppers, double-click to add,
  right-click to delete. CLI adds `fans set <id> ramp <sensor>
  <c1:rpm1> ...`.
- **Helper protocol versioning + auto-update banner.** Bumped to v2;
  GUI's `HelperClient.health()` returns `.healthy / .outdated / .down`;
  AppState raises a persistent banner on `.outdated` with explicit
  "installed v1, GUI expects v2 — click Update Helper to re-install".
- **Per-tick re-assertion** (constant + sensor-based modes). Defeats
  thermalmonitord claw-back. Direct write → fall back to
  `helperClient.setMode(.constant)` when GUI is non-root.
- **AUTO release direction fixed.** F0Md=0 BEFORE Ftst=0 (was inverted,
  caused the "click Auto → blinks → reverts to old setting" bug).
- **`writeRPM` absolute safety floor** (800 RPM) on every path —
  closes the "CLI / helper / programmatic can write 0 and stall the
  bearing" hole.
- **Cold-start safe-reset.** On `AppleSMCService.init`, every fan
  found in F0Md=1 is dropped back to auto before the first snapshot —
  so a crashed previous run can't strand a fan pinned at the
  firmware-clamped value.
- **`pendingIntent` merge.** Polling tick that fires between optimistic
  UI update and `setMode` completion no longer overrides the user's
  intent ("set 2052, gauge flickers between 2052 and the old value").
- **Sensor-based config persistence + cross-fan inheritance.** Switch
  to constant/auto and back restores the exact sensor + curve. Second
  fan's first sensor-based pick inherits from the first.
- **Gear-button hit-testing** (3 wrong diagnoses before the
  SwiftUI-skill-assisted root cause): ZStack order + topStatusBar
  `.allowsHitTesting(false)`.
- **Sensor picker shows live temps per row** (Menu+Button+Label,
  embed temp in the title string — NSMenuItem only takes the first
  Text).
- **Gauge gap at high RPM**: tightened fill shadow radius 6→2 so the
  glow doesn't bleed past the cyan SetpointWall.
- **`includeEGPU` + `includeExternalDrives` (Tt-prefix) wired** — were
  no-op toggles.

### 🟥 Still open (from the review)

1. **Socket has no peer-cred check.** Any local process can drive
   fans via `/var/run/genesis-fan-control.sock`. Fix: `getpeereid(2)`
   in helper accept + `chmod 0660`. Ideal endgame:
   `SMAppService.daemon` + XPC with codesigning anchor.
2. **No crash-recovery in the helper.** If the GUI dies, the per-tick
   re-assertion stops; firmware clawback wins; Ftst stays open. Fix:
   helper-side deadline timer + SIGTERM handler that reverts every
   locked fan to F0Md=0 / Ftst=0 before unlink/exit.
3. **No max-hold watchdog.** Constant mode persists forever. Fix:
   30 min default → auto-revert + notification.
   `applicationWillTerminate` drops manual fans to auto.
4. **No sleep/wake handler.** Battery → AC transition and S3/S4 wake
   currently don't re-assert. Observe `NSWorkspace.willSleep/didWake`.
5. **`Ftst` is global, treated per-fan.** Releasing fan 0 while fan 1
   is still in constant clears the unlock for fan 1 too. Fix: count
   locked fans; only zero Ftst when count drops to 0.
6. **CLI `fans set` leaves fan degraded after exit** — re-assertion
   never runs from the CLI process. Either move the loop into the
   helper (cleanest) or warn loudly that the GUI must stay running.
7. **`FanControlSheet` captures `let fan: Fan`** — value type frozen
   at sheet construction. Refactor to `let fanID: String` + computed
   live lookup so the live preview's "Currently reported" updates.
8. **6 settings toggles still dead.** `openAtLogin` (wire via
   SMAppService.mainApp), `checkUpdatesOnLaunch`, `languageCode`,
   `menuBarIconStyle`, `menuBarFan`, `menuBarSensorIDs`. Wire each or
   remove the control — current UI promises actions that never happen.

### 🟨 Smaller stuff (full list in the review file)

- Multi-click setMode race wipes pendingIntent (per-fan version
  tokens).
- No socket timeouts; slow unlock pins smcQueue ~33 s.
- Per-tick `helperClient.setMode` is a fresh socket + 3 SMC
  round-trips — sticky session would amortize.
- HelperInstaller bash uses `'` quotes with no escaping of
  `helperBinary` path.
- Drag gesture fires SMC write per pixel — should commit only
  onEnded.
- MenuBarIconTab Picker rows use HStack{Image,Text} — same
  collapse-to-first-Text bug as the sensor picker had; fix with
  Label(...).tag(...).
- Activation-policy demote 300 ms `asyncAfter` has no cancel.
- Sensor disappears → fan stays pinned in unlocked constant state
  with no fallback.
- Missing M3/M4 sensor keys (`Te??` / `Tf??`).
- Mock fallback is silent (banner would be kinder).
- No in-app log viewer.

---

## Future work

- **Multi-point ramp curve.** Most-requested feature next.
- **Privileged helper via SMAppService.** Needs an `.app` bundle layout
  (probably an Xcode workspace that wraps the SPM package) + a paid
  developer ID for signing.
- **Code-signature peer-identity check on the socket.** Tear out the
  Unix socket, replace with `NSXPCConnection` machService, validate
  `auditToken` against an expected signing identity. Needs SMAppService
  anyway, so couple it with the previous point.
- **Sparkle for OTA updates.**
- **Localization.** The UI is English-only; the original Macs Fan
  Control screenshots were Czech. The settings strings should move into
  a String Catalog.
- **Hardware-specific sensor catalog.** Detect chip
  (`sysctl machdep.cpu.brand_string`) and pick the right candidate
  sensor list per family.
- **Per-fan profile presets.** "Silent / Balanced / Performance" with
  one-click switching, stored in `SettingsStore`.
- **Headless mode for the CLI.** `fans daemon` mode that runs a
  user-level loop applying a curve from a YAML config file — useful for
  servers / setups where the GUI shouldn't be loaded.
- **Sensor history graph.** A 10-minute sparkline per sensor in the
  right rail, replacing the current point reading.

---

## Troubleshooting & dev gotchas

Hard-won lessons. These have all been mis-diagnosed at least once.

**Gear button doesn't open Settings.** It's a hit-testing bug, not an
action-dispatch bug. SwiftUI ZStack hit-tests last-declared-first; if
a decorative overlay sits above the SensorPanel header, its HStack +
trailing Spacer claims the whole 28pt strip width and swallows clicks.
Fix: declare the interactive HStack AFTER decorative overlays in the
ZStack, AND put `.allowsHitTesting(false)` on the decorative side.
Don't reach for SettingsLink / NSApp.sendAction / NSViewRepresentable
wrappers until you've confirmed the click is actually reaching the
Button.

**App crashes with EXC_CRASH / SIGABRT during layout.** Look for
`NSHostingView.SizeConstraints.update(from:)` in the backtrace — that's
the `NSViewRepresentable` bridge throwing an autolayout exception.
Usually caused by an `NSHostingView` with `translatesAutoresizingMask
IntoConstraints = false` + explicit edge constraints whose SwiftUI
content wants to renegotiate its intrinsic size on a later render
pass. Drop the constraints and let the hosting view drive its own
size, OR avoid the bridge entirely (SwiftUI Button already handles
`mouseDownCanMoveWindow = false`).

**Fan setpoint reverts to firmware-clamped value after a few seconds.**
thermalmonitord claws back `F0Tg` under thermal governance. The host
loop in `primeSnapshot()` MUST re-assert every poll tick — that's the
mechanism, not maintenance. Any new mode (or future helper RPC) that
sets a target without also re-asserting will drift back. If a new
write succeeds initially but drifts within ~5s, suspect this.

**Click "Auto" → UI blinks to auto → snaps back to constant.**
`setMode(.auto)` is writing `Ftst=0` BEFORE `F0Md=0`. Firmware re-locks
the moment Ftst goes 1→0 and ignores subsequent F0Md writes. Reverse
the order.

**Helper write failed, banner didn't pop.** The installed helper at
`/usr/local/sbin/` is older than the protocol version. Bump
`HelperConstants.protocolVersion` to force the GUI's `health()` check
to flag it `.outdated` → banner pops with "Update Helper".

**`fans set F0 sensor ...` from the CLI works briefly then drifts.**
CLI sets the mode but the CLI process exits immediately; the per-tick
re-assertion only runs from the GUI. Either keep the GUI open or use
`fans watch` (which has its own RunLoop).

**Tests `testTickAdvancesLastUpdated` / `testTickRefreshesSensors`
fail.** They make a synchronous assertion right after calling
`state.tick()` — but `tick()` dispatches onto `smcQueue` and hops the
publish back to `@MainActor`. Use `drainTicks()` (in
`AppStateTests.swift`) to spin the runloop briefly between
`tick()` and the assertion.

**App relaunches but new binary doesn't seem to load.** macOS may
cache the app launch services entry. Confirm via `ls -la
/Applications/GenesisFanControl.app/Contents/MacOS/GenesisFanControl`
that it's a symlink into `.build/release/`. If it points somewhere
old, `bun run uninstall:app` + `bun run install:app` to rebuild from
scratch.

---

## Changelog (recent work)

In rough order shipped, newest at top. Full commit messages tell the
"why" — git log is the source of truth.

- **146d2db** — AppKit/UI + logic test suite: each process's decision logic
  extracted into `Core` and the executables rewired to call it, so 102→329
  `swift test` cases now guard the real paths (activation policy, Settings
  dispatch, menu bar, watchdogs, helper, fans CLI) plus ViewInspector
  view-structure tests.
- **9a93ebf** — Window/Settings opening hardened for macOS 14+: gear uses the
  real `openSettings()` env action (the `showSettingsWindow:` selector was
  removed in macOS 14), menu-bar click promotes `.regular` +
  `orderFrontRegardless`, and the policy demote no longer strands a still-open
  Settings window.
- **6911ae6** — README rewrite (this section + the others).
- **11b6a0c** — Gear button finally clickable (ZStack reorder + 
  `.allowsHitTesting(false)` on topStatusBar). Helper protocol
  versioning + auto-pop "Helper is out of date" banner.
- **7b244ed** — First (incomplete) gear-button fix and continuation
  of the safety-floor pass (writeRPM clamps to 800; cold-start
  `safeResetAllFansToAuto`).
- **ba6fe96** — Crash fix: remove NoDragArea — was throwing an
  autolayout exception out of `NSHostingView.SizeConstraints.update`
  and aborting the process.
- **3a3d3a8** — URGENT: AUTO release direction fix (F0Md=0 BEFORE
  Ftst=0) + 3-way fallback gear button (which still didn't work, see
  11b6a0c).
- **725405f** — N-point ramp curve UI + data model: RampPoint,
  piecewise-linear interpolation, draggable chart handles + per-point
  editor.
- **3b58d8e** — Persist sensor-based config per fan; second fan
  inherits from the first on first sensor-based pick.
- **e328321** — Sensor picker dropdown shows live temps per row
  (Menu+Button+Label trick).
- **c2a99bf** — Per-tick re-assertion via helper for both constant
  AND sensor-based modes; sensor-based mode actually unlocks fan
  control; gear button (first attempt — SettingsLink, didn't work).
- **80a2688** — Three regression fixes: pendingIntent merge stops
  in-flight setMode flicker; NoDragArea added (later caused crash,
  see ba6fe96); sensor picker temp-per-row first attempt.
- **fea184f** — Gauge gap at high RPM (tightened fill shadow);
  wired `includeExternalDrives` (Tt-prefix).
- **ecdc10d** — Constant-fan claw-back fix: preserve cached
  `.constant` mode through snapshots + re-assert every tick.

---

## Sources & research

The wire-protocol details, the Ftst dance, and the M-series key tables
all came from a parallel research pass over open-source projects:

- [exelban/stats](https://github.com/exelban/stats) — canonical Swift
  SMC bridge with Apple Silicon support; we copied the `unlockFanControl`
  sequence almost verbatim. `SMC/smc.swift:566-602`.
- [beltex/SMCKit](https://github.com/beltex/SMCKit) — the original 2014
  Swift SMC wrapper; everyone since starts from this struct layout.
- [hholtmann/smcFanControl](https://github.com/hholtmann/smcFanControl)
  — Objective-C predecessor; canonical install/uninstall pattern.
- [AlDente](https://github.com/davidwernhart/AlDente),
  [BatFi](https://github.com/rurza/BatFi),
  [bclm](https://github.com/zackelia/bclm) — Swift battery tools using
  the same SMC struct, useful as cross-checks on the type-tag set.

The full research write-up with line numbers + commit SHAs lives in the
Obsidian vault at
`~/Tresors/Projects/GenesisBrain/GenesisTools/Fans/Research-2026-06-29.md`.

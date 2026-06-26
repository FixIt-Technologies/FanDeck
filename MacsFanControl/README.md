# MacsFanControl

A SwiftUI macOS clone of [Macs Fan Control](https://crystalidea.com/macs-fan-control) with a modern dark UI.

## Status

Bootstrap. The UI shell, settings window, per-fan control sheet, theme, and logging are all in place. The SMC backend currently uses a **mock** implementation that returns three fake fans + a representative sensor list so the app builds and runs end-to-end without root or SMC entitlements.

## Run

### In Xcode (recommended)

Open `apps/MacsFanControl/Package.swift` in Xcode (or drag the `apps/MacsFanControl` folder onto the Xcode dock icon). Xcode treats SwiftPM executable targets as runnable apps:

1. Xcode finishes "resolving dependencies" (instant — no deps).
2. Select the `MacsFanControl` scheme in the toolbar.
3. ⌘R.

The app launches as a normal SwiftUI macOS window plus a menu-bar item. Press ⌘, to open Settings.

### From the terminal

```bash
cd apps/MacsFanControl
swift run                # build + launch the menu-bar app
swift build              # build only
```

## Layout

- `Sources/MacsFanControl/App/` — `@main` entry point, app delegate, app state
- `Sources/MacsFanControl/Logging/` — `Log` proxy, `MFCLogger` (os.Logger backend), `LogStore` (in-memory ring buffer for the in-app log browser)
- `Sources/MacsFanControl/Theme/` — colors, typography, spacing, radii, animations, `SettingsCard`, `NeonToggleStyle`, `SidebarNavItem`, `VisualEffectBlur`, …
- `Sources/MacsFanControl/SMC/` — `SMCService` protocol + `MockSMCService` (real `AppleSMC` impl is a TODO)
- `Sources/MacsFanControl/Settings/` — 3-tab Settings window: General, Temperature Sensors, Menu Bar Icon
- `Sources/MacsFanControl/FanControl/` — Per-fan control sheet (Constant RPM vs Sensor-controlled with thresholds)
- `Sources/MacsFanControl/MainWindow/` — Dashboard sidebar + detail
- `Sources/MacsFanControl/Shared/` — `ConstraintSafeWindow` and other AppKit glue

## Theme

Ported and consolidated from [TimeTravel](../../../Rewind/apps/timetravel-app/TimeTravel) — same neon/cyberpunk dark palette (`Color.settingsBackground`, `Color.neonAmber`, …), same `SettingsCard` / `SidebarNavItem` / `NeonToggleStyle` primitives. One palette (the `settings*` / `neon*` side) — the `tt*` palette wasn't ported because it was specific to TimeTravel's overlay HUD.

## Logging

Verbatim port of TimeTravel's `Log` + `MFCLogger` (renamed from `TTLogger`) + `LogStore`:
- `Log.app.info("…")`, `Log.smc.debug("…")`, etc. — categories are `app / ui / settings / smc / fans / sensors / lifecycle`.
- All logs go to `os.Logger` (visible via `log stream --predicate 'subsystem == "dev.foltyn.macsfancontrol"'`) AND to an in-memory ring buffer that the in-app Logs panel renders.
- Crash debugging: enable the `os_log` subsystem in Console.app, filter on `dev.foltyn.macsfancontrol`.

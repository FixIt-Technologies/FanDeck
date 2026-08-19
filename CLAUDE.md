# FanDeck — agent notes

@README.md carries the overview, commands and repo map — this file is only the bites.

## Non-obvious

- Two manifests describe the same targets: `GenesisFanControl/Package.swift` (SPM)
  and `GenesisFanControl/Project.swift` (Tuist). They are twins — change one, change
  the other, or `swift build` and the Xcode workspace drift apart.
- The Xcode workspace is generated. `tuist install && tuist generate --no-open`
  before anything Xcode-shaped; never commit `GenesisFans.xcworkspace/`, `Derived/`,
  `.build/` or `dist/`.
- `bun run start` cannot replace the root-owned helper at `/usr/local/sbin/`. Bump
  `HelperConstants.protocolVersion` whenever you touch code the helper compiles in
  (`AppleSMCService`, `HelperProtocol`, `GenesisFanControlHelper/main.swift`),
  otherwise the GUI silently drives a stale daemon instead of showing the
  "Update Helper" banner.
- Bun only — the `package.json` scripts are Bun scripts. No npm/pnpm/yarn.
- The `fans help` text still claims a MOCK backend. It is stale; the CLI has used
  `AppleSMCService` since `fans/main.swift:33`. Don't propagate the claim.

## Fan writes are real hardware

`GenesisFanControl/Sources/GenesisFanControlCore/SMC/` and `.../Privileged/` drive a physical machine.
Read `GenesisFanControl/README.md` (SMC backend + helper sections) before editing
there — the `Ftst` unlock sequence, its release *order*, and the per-tick
re-assertion against `thermalmonitord` are load-bearing and counter-intuitive.
Preserve the 800 RPM floor in `writeRPM`, the cold-start safe reset, the
SIGTERM/idle-watchdog revert of locked fans, and the `getpeereid` peer check.

## Testing

`swift test` from `GenesisFanControl/` — 329 XCTest cases, ~6 s, and there is no CI, so
it is the only gate. Exercise logic through `MockSMCService`; never pin a real fan in a test.

## Etiquette

Branch `work/<slug>`, Conventional Commits scoped by app (`feat(fandeck):`,
`fix(genesis-fan-control):`), PR to `master`. The owner (@LEFTEQ) reviews and merges —
never self-merge, never enable auto-merge.

# FanDeck — Decisions [!date](2026-07-18)

## Summary
**FanDeck**: a new condensed-UI macOS fan-control app built on top of `apps/GenesisFanControl`. SwiftUI + Tuist, full feature parity (auto / constant / sensor-ramp modes, drag-to-set, ramp curve editor, sensors, helper daemon), menu-bar-first with a rich control panel, and a compact mini-gauge window.

Board: internal brainstorm board (vitrinka)

## Decisions

:::table
| # | Decision | Call | Status |
|---|----------|------|--------|
| D1 | Code architecture | Tuist-ify everything — one workspace, Core + old app + FanDeck as Tuist projects (SPM `Package.swift` kept alongside for `swift build`/`swift test` compat) | [!status green](Decided) |
| D2 | App shape & lifecycle | Menu-bar-first agent (LSUIElement accessory; compact window on demand; dock icon optional in settings) | [!status green](Decided) |
| D3 | Menu-bar surface | Rich `MenuBarExtra(.window)` panel: per-fan sliders, Auto all / Full blast, hottest temps, helper status | [!status green](Decided) |
| D4 | Condensed window layout | Take B — mini-gauge grid: stat strip, circular arc gauges (drag to set), sensor chips | [!status green](Decided) |
| D5 | Ramp editor | Full draggable chart editor ported from `FanControlSheet` — **with a performance audit/refactor** (throttle drag re-renders, avoid Chart rebuild storms) | [!status green](Decided) |
| D6 | App identity | FanDeck · bundle `dev.foltyn.fandeck` | [!status green](Decided) |
| D7 | Visual language | Hybrid — native macOS materials + semantic colors for chrome (onyx-style), amber/cyan reserved for fan state | [!status green](Decided) |
:::

## Assumptions
- FanDeck **shares** the installed helper daemon (`/usr/local/sbin/genesis-fan-control-helper`) and the `fans` CLI — both app-agnostic.
- Only one app manages fans at a runtime (both re-assert setpoints every tick); running both simultaneously is unsupported.
- Tuist workspace conventions copied from `~/Documents/Work/onyx` (Workspace.swift + per-target Project.swift, `Tuist/Package.swift` for external deps, ad-hoc local signing `CODE_SIGN_IDENTITY: -`).
- macOS 14+ deployment target like the original.

## Architecture notes
- Workspace root `apps/` (Workspace.swift + Tuist/): projects `apps/GenesisFanControl` (Core framework + legacy app + helper + fans CLI + tests, sources unchanged) and `apps/FanDeck` (new app).
- FanDeck reuses `GenesisFanControlCore` wholesale: AppleSMC bridge (Ftst dance, per-tick re-assertion, 800 RPM floor), HelperClient/Installer, SettingsStore, AppState 1 Hz polling with optimistic writes, MockSMC.
- New code is UI-only: MenuBarExtra panel, mini-gauge compact window, hybrid theme layer, refactored ramp editor.

## Open questions
None.

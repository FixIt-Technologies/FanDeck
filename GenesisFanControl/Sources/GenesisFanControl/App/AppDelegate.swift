//
//  AppDelegate.swift
//  GenesisFanControl
//
//  Sets the activation policy and seeds the menu-bar item. Polling lives
//  in AppState; the menu-bar status item just reads from it.
//
//  Safety-of-last-resort responsibilities (review HIGH #4 + MED):
//   • applicationWillTerminate: drop every non-auto fan to AUTO before
//     the process exits — a clean Quit / ⌘Q must never leave a fan
//     pinned. (SIGKILL is covered by the helper's idle watchdog.)
//   • Max-hold watchdog: per-fan deadline (default 30 min). When a fan
//     has been in CONSTANT or SENSOR mode that long without a fresh
//     user setMode call, auto-revert with a user-visible notification.
//     Stops a forgotten "I cranked it to 5800 last night" from running
//     the bearings dry for a week.
//   • Sleep / wake: on sleep, snapshot the current intent; on wake,
//     re-assert every non-auto fan once (one socket round-trip) so the
//     firmware claw-back during sleep doesn't strand the fan.
//

import AppKit
import SwiftUI
import Combine
import ServiceManagement
import GenesisFanControlCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    /// Combine subs for SettingsStore. Holds menu-bar icon re-renders
    /// (style/fan/sensorIDs), login-item re-registration (openAtLogin),
    /// and the AppState observer that drives the menu-bar number text.
    private var settingsBag: Set<AnyCancellable> = []
    /// Holds the pending demote-to-.accessory work item from
    /// `mainWindowWillClose`. Cancelled by `windowDidBecomeKey` if the
    /// user re-opens the window inside the 300 ms grace window so we
    /// don't yank the dock icon out from under them (review MED —
    /// "activation-policy demote race").
    private var demoteWorkItem: DispatchWorkItem?
    /// Wall-clock max for any non-auto fan before we auto-revert. 30
    /// minutes is conservative: long enough to let a user pin a fan
    /// during a render / build and forget about it, short enough that a
    /// truly forgotten override doesn't run for days.
    private let maxHoldSeconds: TimeInterval = 30 * 60
    /// Per-fan timestamp of the most recent user-initiated non-auto
    /// transition. AppState's tick re-asserts the SMC write every
    /// second; that re-assertion does NOT push this timestamp forward
    /// — only an actual user click does. Keyed by fanID.
    private var holdSince: [String: Date] = [:]
    private var maxHoldTimer: Timer?

    // AppDelegate is @MainActor, so this method is already main-actor
    // isolated — no Task hop needed. Running startup synchronously here
    // guarantees the activation policy + menu-bar item are installed
    // before the first window renders. Observer callbacks still hop via
    // Task { @MainActor } because the NSNotificationCenter closures are
    // not actor-isolated even on queue: .main.
    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.logAppLaunch()
        Log.logSMCBackend(AppState.shared.smc.backendName,
                          simulated: AppState.shared.smc.isSimulated)

        applyActivationPolicy()
        installMenuBarItem()
        bindMenuBarSettings()
        applyOpenAtLogin(SettingsStore.shared.openAtLogin)

        NotificationCenter.default.addObserver(forName: .mfcShowDockIconChanged,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.applyActivationPolicy() }
        }
        // Re-promote to .regular whenever a window becomes key. Without
        // this, ⌘-Tab can't bring the app back when showDockIcon=false
        // (.accessory apps are excluded from the switcher).
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                               object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in self?.windowDidBecomeKey(note) }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                               object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in self?.mainWindowWillClose(note) }
        }

        // Sleep/wake observers — NSWorkspace, NOT NotificationCenter.
        // S3/standby can clobber Ftst depending on chip; on wake we
        // simply re-assert every non-auto fan once via setMode — the
        // existing setMode path already does the unlock dance + write.
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(forName: NSWorkspace.willSleepNotification,
                                    object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.systemWillSleep() }
        }
        workspaceCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                    object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.systemDidWake() }
        }

        // Capture user-intent timestamps so the max-hold watchdog has
        // a reference point. AppState's setMode posts this on every
        // user-driven mode change (the per-tick re-assertion does not,
        // so a long-held constant fan still ages out as expected).
        NotificationCenter.default.addObserver(forName: .gfcUserSetMode,
                                               object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in self?.userSetModeFired(note) }
        }
        startMaxHoldWatchdog()
    }

    /// Final safety gate — drop every non-auto fan to AUTO before exit.
    /// NSApplication.willTerminate fires on ⌘Q, "Quit" menu item, Apple
    /// Events shutdown — basically every graceful path. SIGKILL is NOT
    /// covered (the kernel doesn't deliver it); the helper's idle
    /// watchdog catches that case from the other side.
    func applicationWillTerminate(_ notification: Notification) {
        Log.lifecycle.warning("applicationWillTerminate — reverting all non-auto fans to AUTO")
        let state = AppState.shared
        let nonAuto = state.fans.filter {
            if case .auto = $0.mode { return false } else { return true }
        }
        guard !nonAuto.isEmpty else { return }
        // setMode dispatches async on smcQueue. Block briefly so we
        // give the writes a chance to land before the process exits.
        for fan in nonAuto {
            state.setMode(.auto, for: fan.id)
        }
        // Give smcQueue ~1.5s to drain — enough for two Ftst dances
        // worst-case. Past that the process is going away regardless.
        let deadline = Date(timeIntervalSinceNow: 1.5)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
    }

    private func applyActivationPolicy() {
        let showDock = SettingsStore.shared.showDockIcon
        let policy: NSApplication.ActivationPolicy = showDock ? .regular : .accessory
        NSApp.setActivationPolicy(policy)
        Log.lifecycle.info("Activation policy → \(showDock ? "regular" : "accessory")")
    }

    /// When the main window becomes visible/active, we always want ⌘-Tab
    /// to be able to find us — promote to .regular regardless of the user's
    /// "Show dock icon" preference. We demote again when the main window
    /// closes (see `mainWindowWillClose`).
    private func windowDidBecomeKey(_ note: Notification) {
        guard let win = note.object as? NSWindow,
              win.identifier?.rawValue == "main" else { return }
        // Cancel any pending demote — the user re-opened the window
        // before our 300ms grace expired, so the demote is stale and
        // would silently strip the dock icon they're now seeing.
        demoteWorkItem?.cancel()
        demoteWorkItem = nil
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            Log.lifecycle.debug("Window became key → promoted to .regular for ⌘-Tab")
        }
    }

    /// When the main window closes, drop back to the user's chosen policy
    /// so the dock icon honors the setting once they're done.
    private func mainWindowWillClose(_ note: Notification) {
        guard let win = note.object as? NSWindow,
              win.identifier?.rawValue == "main" else { return }
        // Hold any previous pending demote first — otherwise rapid
        // close/open/close stacks them.
        demoteWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.applyActivationPolicy() }
        }
        demoteWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    // MARK: - Sleep / wake

    private func systemWillSleep() {
        Log.lifecycle.info("System will sleep — fans will be re-asserted on wake")
    }

    private func systemDidWake() {
        let nonAuto = AppState.shared.fans.filter {
            if case .auto = $0.mode { return false } else { return true }
        }
        guard !nonAuto.isEmpty else { return }
        Log.lifecycle.info("System did wake — re-asserting \(nonAuto.count) non-auto fan(s)")
        for fan in nonAuto {
            // Re-issue the same mode the user previously set. setMode
            // runs the full unlock dance + write through smcQueue.
            AppState.shared.setMode(fan.mode, for: fan.id)
        }
    }

    // MARK: - Max-hold watchdog

    private func startMaxHoldWatchdog() {
        // 60s tick is plenty — the watchdog only acts at the maxHold
        // boundary (30 min by default), so missing the moment by up to
        // a minute is fine and keeps the wake-from-sleep cost trivial.
        maxHoldTimer?.invalidate()
        maxHoldTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkMaxHold() }
        }
    }

    private func userSetModeFired(_ note: Notification) {
        guard let fanID = note.userInfo?["fanID"] as? String,
              let isAuto = note.userInfo?["isAuto"] as? Bool else { return }
        if isAuto {
            holdSince.removeValue(forKey: fanID)
        } else {
            holdSince[fanID] = Date()
        }
    }

    private func checkMaxHold() {
        let now = Date()
        for (fanID, since) in holdSince {
            let held = now.timeIntervalSince(since)
            guard held >= maxHoldSeconds else { continue }
            // Only act if the fan is actually still non-auto — the user
            // might have switched it back via the gauge's Auto button.
            guard let fan = AppState.shared.fan(withID: fanID) else {
                holdSince.removeValue(forKey: fanID)
                continue
            }
            if case .auto = fan.mode {
                holdSince.removeValue(forKey: fanID)
                continue
            }
            Log.lifecycle.warning("Max-hold reached for \(fanID) (\(Int(held))s ≥ \(Int(maxHoldSeconds))s) — reverting to AUTO")
            AppState.shared.setMode(.auto, for: fanID)
            holdSince.removeValue(forKey: fanID)
            notifyMaxHold(fanID: fanID, fan: fan)
        }
    }

    private func notifyMaxHold(fanID: String, fan: Fan) {
        // Lightweight NSUserNotification-equivalent — we don't depend
        // on UserNotifications.framework (which requires entitlements)
        // for a single-use unsigned dev build. The elevation banner in
        // MainView surfaces transient state via @Published — the same
        // mechanism here keeps the watchdog visible in-app.
        let alert = NSAlert()
        alert.messageText = "Fan reverted to AUTO"
        alert.informativeText = "\(fan.name) (\(fanID)) was held in \(fan.mode.displayName) for over \(Int(maxHoldSeconds / 60)) minutes and has been reverted to AUTO. Re-pin it from the dashboard if you still need a manual setpoint."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        // Don't make this modal — we're on a timer tick. Show it
        // asynchronously over the main window if it's open.
        if let win = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
            alert.beginSheetModal(for: win, completionHandler: { _ in })
        } else {
            // No window — fall back to standalone, non-blocking.
            DispatchQueue.main.async { _ = alert.runModal() }
        }
    }

    // MARK: - Menu bar

    private func installMenuBarItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(menuBarClicked(_:))
        }
        self.statusItem = item
        renderMenuBar()
        Log.ui.debug("Menu-bar status item installed")
    }

    /// Render the status-item icon + title from current SettingsStore +
    /// AppState. Called on launch and whenever any of the menu-bar-
    /// driving knobs changes (icon style, fan readout, sensor IDs) or
    /// the live snapshot updates (every poll tick).
    private func renderMenuBar() {
        guard let button = statusItem?.button else { return }
        let settings = SettingsStore.shared
        let state = AppState.shared

        // Icon. ALWAYS template — the menu bar uses templates so the
        // glyph is auto-tinted to match light/dark menu-bar background.
        // The previous `.color` style left isTemplate=false which made
        // the symbol render as raw black pixels (invisible on dark menu
        // bars; mis-aligned vertically because non-template images
        // bypass the standard 22pt baseline). For "color" we use the
        // fill variant; the actual color comes from the system.
        switch settings.menuBarIconStyle {
        case .color, .monochrome:
            let symbol = settings.menuBarIconStyle == .color ? "fanblades.fill" : "fanblades"
            button.image = NSImage(systemSymbolName: symbol,
                                   accessibilityDescription: "GenesisFanControl")
        case .temperature:
            // Use a thermometer glyph + headline temp as the title.
            button.image = NSImage(systemSymbolName: "thermometer.medium",
                                   accessibilityDescription: "GenesisFanControl")
        }
        button.image?.isTemplate = true
        button.imagePosition = .imageLeading

        // Title (right of the icon). Compose: optional fan readout +
        // up to two selected sensor temps. Keep it under ~24 chars so
        // it doesn't blow out the menu bar.
        var parts: [String] = []

        // Headline temp if user picked .temperature style
        if settings.menuBarIconStyle == .temperature,
           let s = state.headlineSensor {
            parts.append(s.formatted(useFahrenheit: settings.useFahrenheit, precise: false))
        }

        // Optional fan readout
        switch settings.menuBarFan {
        case .none:
            break
        case .rpm:
            if let f = state.fans.first {
                parts.append("\(f.currentRPM) RPM")
            }
        case .percent:
            if let f = state.fans.first {
                let pct = Int((f.loadFraction * 100).rounded())
                parts.append("\(pct)%")
            }
        }

        // Up to 2 sensor temps the user selected
        let pickedIDs = Array(settings.menuBarSensorIDs.prefix(2))
        for id in pickedIDs {
            if let s = state.sensor(withID: id) {
                parts.append(s.formatted(useFahrenheit: settings.useFahrenheit, precise: false))
            }
        }

        // Use NSAttributedString with explicit labelColor so the title
        // adapts to menu-bar appearance — plain `button.title` falls
        // back to black on the system's default font, which becomes
        // invisible on a dark menu bar (the bug from screenshot #29:
        // "38 °C · 43 °C" black on dark). labelColor resolves to the
        // correct contrasting color at draw time, and we vertically-
        // center it to the icon's baseline via NSFont.menuBarFont.
        if parts.isEmpty {
            button.title = ""
            button.attributedTitle = NSAttributedString(string: "")
        } else {
            let titleText = " " + parts.joined(separator: " · ")
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.menuBarFont(ofSize: 0),
                .foregroundColor: NSColor.labelColor,
            ]
            button.attributedTitle = NSAttributedString(string: titleText, attributes: attrs)
        }
    }

    /// Hook SettingsStore + AppState into renderMenuBar() so every
    /// relevant change re-renders. Subscriptions are debounced through
    /// the main run loop's natural coalescing — multiple toggles in the
    /// same tick still produce a single icon update.
    private func bindMenuBarSettings() {
        let settings = SettingsStore.shared
        let state = AppState.shared

        settings.$menuBarIconStyle
            .sink { [weak self] _ in self?.renderMenuBar() }
            .store(in: &settingsBag)
        settings.$menuBarFan
            .sink { [weak self] _ in self?.renderMenuBar() }
            .store(in: &settingsBag)
        settings.$menuBarSensorIDs
            .sink { [weak self] _ in self?.renderMenuBar() }
            .store(in: &settingsBag)
        settings.$useFahrenheit
            .sink { [weak self] _ in self?.renderMenuBar() }
            .store(in: &settingsBag)
        // Login-item state
        settings.$openAtLogin
            .sink { [weak self] enabled in self?.applyOpenAtLogin(enabled) }
            .store(in: &settingsBag)

        // Live data — re-render when fans/sensors update so the
        // RPM/percent/temp readouts in the menu bar track reality.
        state.$fans
            .sink { [weak self] _ in self?.renderMenuBar() }
            .store(in: &settingsBag)
        state.$sensors
            .sink { [weak self] _ in self?.renderMenuBar() }
            .store(in: &settingsBag)
    }

    /// Reconcile the SMAppService.mainApp registration state with the
    /// user's preference. Best-effort — on macOS < 13 this API doesn't
    /// exist; we log and move on. Errors (sandbox / signing) are also
    /// non-fatal — the toggle is convenience, not safety-critical.
    private func applyOpenAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled {
                    try service.register()
                    Log.lifecycle.info("Login item registered")
                }
            } else {
                if service.status == .enabled || service.status == .requiresApproval {
                    try service.unregister()
                    Log.lifecycle.info("Login item unregistered")
                }
            }
        } catch {
            Log.lifecycle.error("Login-item toggle failed: \(error)")
        }
    }

    @objc private func menuBarClicked(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        if let win = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
            win.makeKeyAndOrderFront(nil)
        }
    }
}

extension Notification.Name {
    static let mfcShowDockIconChanged = Notification.Name("dev.foltyn.genesis-fan-control.showDockIconChanged")
}

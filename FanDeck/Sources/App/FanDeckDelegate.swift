//
//  FanDeckDelegate.swift
//  FanDeck
//
//  Port of the original AppDelegate's safety + lifecycle duties, minus
//  the NSStatusItem (the MenuBarExtra scene owns the menu bar here):
//    • applicationWillTerminate → revert every non-auto fan to AUTO.
//    • Max-hold watchdog → auto-revert fans pinned non-auto > 30 min.
//    • Sleep/wake → re-assert non-auto fans once on wake.
//    • Activation policy → accessory by default (LSUIElement), promote
//      to .regular while the compact window is open, honor the
//      "Show dock icon" setting.
//    • Open-at-login registration via SMAppService.
//

import AppKit
import SwiftUI
import Combine
import ServiceManagement
import GenesisFanControlCore

@MainActor
final class FanDeckDelegate: NSObject, NSApplicationDelegate {
    private var settingsBag: Set<AnyCancellable> = []
    private var demoteWorkItem: DispatchWorkItem?
    private let maxHoldSeconds: TimeInterval = 30 * 60
    private var holdSince: [String: Date] = [:]
    private var maxHoldTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.logAppLaunch()
        Log.logSMCBackend(AppState.shared.smc.backendName,
                          simulated: AppState.shared.smc.isSimulated)

        applyActivationPolicy()
        applyOpenAtLogin(SettingsStore.shared.openAtLogin)

        SettingsStore.shared.$openAtLogin
            .sink { [weak self] enabled in self?.applyOpenAtLogin(enabled) }
            .store(in: &settingsBag)
        SettingsStore.shared.$showDockIcon
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in self?.applyActivationPolicy() }
            }
            .store(in: &settingsBag)

        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                               object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in self?.windowDidBecomeKey(note) }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                               object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in self?.managedWindowWillClose(note) }
        }

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                    object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.systemDidWake() }
        }

        NotificationCenter.default.addObserver(forName: .gfcUserSetMode,
                                               object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in self?.userSetModeFired(note) }
        }
        startMaxHoldWatchdog()
    }

    /// Drop every non-auto fan to AUTO before exit (⌘Q / Quit). SIGKILL
    /// is covered from the other side by the helper's idle watchdog.
    func applicationWillTerminate(_ notification: Notification) {
        Log.lifecycle.warning("applicationWillTerminate — reverting all non-auto fans to AUTO")
        let state = AppState.shared
        let nonAutoIDs = MaxHoldDecider.nonAutoFanIDs(fans: state.fans)
        guard !nonAutoIDs.isEmpty else { return }
        for id in nonAutoIDs {
            state.setMode(.auto, for: id)
        }
        let deadline = Date(timeIntervalSinceNow: 1.5)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
    }

    // MARK: - Activation policy

    private func applyActivationPolicy() {
        let showDock = SettingsStore.shared.showDockIcon
        let intent = ActivationPolicyDecider.targetPolicy(showDockIcon: showDock)
        NSApp.setActivationPolicy(intent == .regular ? .regular : .accessory)
        Log.lifecycle.info("Activation policy → \(showDock ? "regular" : "accessory")")
    }

    private func windowDidBecomeKey(_ note: Notification) {
        guard let win = note.object as? NSWindow,
              ActivationPolicyDecider.shouldPromoteOnKeyWindow(
                  identifier: win.identifier?.rawValue ?? "") else { return }
        demoteWorkItem?.cancel()
        demoteWorkItem = nil
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
    }

    private func managedWindowWillClose(_ note: Notification) {
        guard let win = note.object as? NSWindow else { return }
        let id = win.identifier?.rawValue ?? ""
        guard ActivationPolicyDecider.shouldDemote(closingID: id, visibleWindowIDs: []) else { return }
        demoteWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let visibleWindowIDs = NSApp.windows
                    .filter(\.isVisible)
                    .compactMap { $0.identifier?.rawValue }
                if ActivationPolicyDecider.shouldDemote(closingID: id,
                                                        visibleWindowIDs: visibleWindowIDs) {
                    self.applyActivationPolicy()
                }
            }
        }
        demoteWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    // MARK: - Sleep / wake

    private func systemDidWake() {
        let allFans = AppState.shared.fans
        let nonAutoIDs = MaxHoldDecider.nonAutoFanIDs(fans: allFans)
        guard !nonAutoIDs.isEmpty else { return }
        Log.lifecycle.info("System did wake — re-asserting \(nonAutoIDs.count) non-auto fan(s)")
        for fan in allFans where nonAutoIDs.contains(fan.id) {
            AppState.shared.setMode(fan.mode, for: fan.id)
        }
    }

    // MARK: - Max-hold watchdog

    private func startMaxHoldWatchdog() {
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
        let fans = AppState.shared.fans
        let currentModes = Dictionary(uniqueKeysWithValues: fans.map { ($0.id, $0.mode) })
        let toRevert = MaxHoldDecider.fansToRevert(
            holdSince: holdSince, now: now,
            maxHold: maxHoldSeconds, currentModes: currentModes
        )
        for fanID in toRevert {
            guard let fan = AppState.shared.fan(withID: fanID) else {
                holdSince.removeValue(forKey: fanID)
                continue
            }
            Log.lifecycle.warning("Max-hold reached for \(fanID) — reverting to AUTO")
            AppState.shared.setMode(.auto, for: fanID)
            holdSince.removeValue(forKey: fanID)
            notifyMaxHold(fan: fan)
        }
        let toClean = holdSince.keys.filter { fanID in
            guard now.timeIntervalSince(holdSince[fanID]!) >= maxHoldSeconds else { return false }
            guard let mode = currentModes[fanID] else { return true }
            if case .auto = mode { return true }
            return false
        }
        for fanID in toClean { holdSince.removeValue(forKey: fanID) }
    }

    private func notifyMaxHold(fan: Fan) {
        let alert = NSAlert()
        alert.messageText = "Fan reverted to AUTO"
        alert.informativeText = "\(fan.name) (\(fan.id)) was held in \(fan.mode.displayName) for over \(Int(maxHoldSeconds / 60)) minutes and has been reverted to AUTO."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        if let win = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }), win.isVisible {
            alert.beginSheetModal(for: win, completionHandler: { _ in })
        } else {
            DispatchQueue.main.async { _ = alert.runModal() }
        }
    }

    // MARK: - Login item

    private func applyOpenAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled {
                    try service.register()
                }
            } else {
                if service.status == .enabled || service.status == .requiresApproval {
                    try service.unregister()
                }
            }
        } catch {
            Log.lifecycle.error("Login-item toggle failed: \(error)")
        }
    }
}

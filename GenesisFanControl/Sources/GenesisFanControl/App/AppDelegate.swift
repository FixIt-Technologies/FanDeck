//
//  AppDelegate.swift
//  GenesisFanControl
//
//  Sets the activation policy and seeds the menu-bar item. Polling lives
//  in AppState; the menu-bar status item just reads from it.
//

import AppKit
import SwiftUI
import GenesisFanControlCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            Log.logAppLaunch()
            Log.logSMCBackend(AppState.shared.smc.backendName,
                              simulated: AppState.shared.smc.isSimulated)

            self.applyActivationPolicy()
            self.installMenuBarItem()

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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            Task { @MainActor in self?.applyActivationPolicy() }
        }
    }

    // MARK: - Menu bar

    private func installMenuBarItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "fanblades.fill",
                                   accessibilityDescription: "GenesisFanControl")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.title = ""
            button.target = self
            button.action = #selector(menuBarClicked(_:))
        }
        self.statusItem = item
        Log.ui.debug("Menu-bar status item installed")
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

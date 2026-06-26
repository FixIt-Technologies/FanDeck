//
//  AppDelegate.swift
//  MacsFanControl
//
//  Sets the activation policy and seeds the menu-bar item. Polling lives
//  in AppState; the menu-bar status item just reads from it.
//

import AppKit
import SwiftUI
import MacsFanControlCore

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
        }
    }

    private func applyActivationPolicy() {
        let showDock = SettingsStore.shared.showDockIcon
        let policy: NSApplication.ActivationPolicy = showDock ? .regular : .accessory
        NSApp.setActivationPolicy(policy)
        Log.lifecycle.info("Activation policy → \(showDock ? "regular" : "accessory")")
    }

    // MARK: - Menu bar

    private func installMenuBarItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "fanblades.fill",
                                   accessibilityDescription: "MacsFanControl")
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
    static let mfcShowDockIconChanged = Notification.Name("dev.foltyn.macsfancontrol.showDockIconChanged")
}

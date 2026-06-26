//
//  MacsFanControlApp.swift
//  MacsFanControl
//
//  Entry point. Two SwiftUI scenes:
//    1. Main window  — fan + sensor dashboard
//    2. Settings     — the standard ⌘, scene; three "tabs" via a
//                      toolbar-style picker, like macOS System Settings
//                      pre-Ventura redesigns.
//

import SwiftUI
import MacsFanControlCore

@main
struct MacsFanControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState.shared
    @StateObject private var settings = SettingsStore.shared

    var body: some Scene {
        // Main dashboard
        Window("MacsFanControl", id: "main") {
            MainView()
                .environmentObject(appState)
                .environmentObject(settings)
                .frame(minWidth: 880, minHeight: 560)
                .background(Color.mfcBackground.ignoresSafeArea())
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 960, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) { /* no New */ }
        }

        // Preferences window (⌘,)
        Settings {
            SettingsRootView()
                .environmentObject(appState)
                .environmentObject(settings)
                .preferredColorScheme(.dark)
        }
    }
}

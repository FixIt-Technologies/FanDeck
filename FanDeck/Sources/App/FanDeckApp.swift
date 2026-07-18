//
//  FanDeckApp.swift
//  FanDeck
//
//  Menu-bar-first entry point (decision D2). Three scenes:
//    1. MenuBarExtra (.window) — the rich control panel, the primary
//       daily surface (D3).
//    2. Window "main" — the compact mini-gauge dashboard (D4), opened
//       on demand from the panel or ⌘O.
//    3. Settings — ⌘, preferences.
//
//  The app ships LSUIElement=true; FanDeckDelegate promotes the
//  activation policy to .regular while the compact window is open so
//  it appears in ⌘-Tab, then demotes back to accessory.
//

import SwiftUI
import GenesisFanControlCore

@main
struct FanDeckApp: App {
    @NSApplicationDelegateAdaptor(FanDeckDelegate.self) private var delegate
    @StateObject private var appState = AppState.shared
    @StateObject private var settings = SettingsStore.shared

    var body: some Scene {
        MenuBarExtra {
            MenuPanelView()
                .environmentObject(appState)
                .environmentObject(settings)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)

        Window("FanDeck", id: "main") {
            CompactMainView()
                .environmentObject(appState)
                .environmentObject(settings)
        }
        .defaultSize(width: 416, height: 520)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { /* no New */ }
        }

        Settings {
            FanDeckSettingsView()
                .environmentObject(appState)
                .environmentObject(settings)
        }
    }
}

/// Live menu-bar label: fan glyph + optional readout (RPM / % / picked
/// sensor temps) composed by the shared MenuBarContent seam, so the
/// FanDeck menu bar honors the same settings as the original app.
private struct MenuBarLabel: View {
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        let symbol = MenuBarContent.symbol(for: settings.menuBarIconStyle)
        let picked = Array(settings.menuBarSensorIDs.prefix(2))
            .compactMap { appState.sensor(withID: $0) }
        let title = MenuBarContent.title(
            style: settings.menuBarIconStyle,
            menuBarFan: settings.menuBarFan,
            firstFan: appState.fans.first,
            headlineSensor: appState.headlineSensor,
            pickedSensors: picked,
            useFahrenheit: settings.useFahrenheit
        )
        if title.isEmpty {
            Image(systemName: symbol)
        } else {
            // MenuBarExtra renders Image+Text labels natively in the bar.
            Label {
                Text(title.trimmingCharacters(in: .whitespaces))
                    .monospacedDigit()
            } icon: {
                Image(systemName: symbol)
            }
            .labelStyle(.titleAndIcon)
        }
    }
}

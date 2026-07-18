//
//  FanDeckSettingsView.swift
//  FanDeck
//
//  ⌘, preferences — native Form/TabView styling (hybrid language).
//  Backed by the shared SettingsStore, so FanDeck and the original app
//  read the same preferences.
//

import SwiftUI
import GenesisFanControlCore

struct FanDeckSettingsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            menuBarTab
                .tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
        }
        .frame(width: 420, height: 300)
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Toggle("Open at login", isOn: $settings.openAtLogin)
            Toggle("Show Dock icon", isOn: $settings.showDockIcon)
            Divider()
            Toggle("Use Fahrenheit", isOn: $settings.useFahrenheit)
            Toggle("Precise temperatures (0.1°)", isOn: $settings.precise)
        }
        .padding(20)
    }

    // MARK: - Menu bar

    private var menuBarTab: some View {
        Form {
            Picker("Icon", selection: $settings.menuBarIconStyle) {
                ForEach(MenuBarIconStyle.allCases) { style in
                    Text(style.label).tag(style)
                }
            }
            Picker("Fan readout", selection: $settings.menuBarFan) {
                ForEach(MenuBarFanDisplay.allCases) { d in
                    Text(d.label).tag(d)
                }
            }
            Divider()
            Text("Sensors in the menu bar (max 2)")
                .font(.system(size: 11, weight: .semibold))
            List {
                ForEach(appState.sensors) { s in
                    Toggle(isOn: sensorBinding(s.id)) {
                        HStack {
                            Image(systemName: s.kind.sfSymbol)
                                .foregroundStyle(FD.secondaryText)
                            Text(s.name)
                            Spacer()
                            Text(s.formatted(useFahrenheit: settings.useFahrenheit, precise: false))
                                .monospacedDigit()
                                .foregroundStyle(FD.tempColor(s.celsius))
                        }
                    }
                    .disabled(!settings.menuBarSensorIDs.contains(s.id)
                              && settings.menuBarSensorIDs.count >= 2)
                }
            }
            .frame(height: 130)
        }
        .padding(20)
    }

    private func sensorBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { settings.menuBarSensorIDs.contains(id) },
            set: { on in
                if on {
                    guard settings.menuBarSensorIDs.count < 2,
                          !settings.menuBarSensorIDs.contains(id) else { return }
                    settings.menuBarSensorIDs.append(id)
                } else {
                    settings.menuBarSensorIDs.removeAll { $0 == id }
                }
            }
        )
    }
}

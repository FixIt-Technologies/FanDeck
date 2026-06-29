//
//  SettingsRootView.swift
//  GenesisFanControl
//
//  Single-pane Settings window — General + Temperature Sensors + Menu
//  Bar Icon sections stacked vertically. There isn't enough content to
//  justify three separate tabs.
//

import SwiftUI
import GenesisFanControlCore

struct SettingsRootView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GeneralSettingsTab()
                TemperatureSensorsTab()
                MenuBarIconTab()
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(width: 560, height: 560)
        .background(Color.gfcBackground)
    }
}

#Preview {
    SettingsRootView()
        .environmentObject(AppState.shared)
        .environmentObject(SettingsStore.shared)
        .preferredColorScheme(.dark)
}

//
//  TemperatureSensorsTab.swift
//  GenesisFanControl
//
//  Mirrors screenshot 2: which drive families to enumerate, unit, precision.
//

import SwiftUI
import GenesisFanControlCore

struct TemperatureSensorsTab: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(icon: "internaldrive", title: "READ TEMPERATURES FROM", accentColor: .gfcRed) {
                VStack(spacing: 2) {
                    SettingsToggleRow(
                        title: "Connected NVMe/SATA drives",
                        isOn: $settings.includeSATANVMe,
                        accent: .gfcRed
                    )
                    HStack(spacing: 0) {
                        Spacer().frame(width: 24)
                        SettingsToggleRow(
                            title: "Including external drives (Thunderbolt)",
                            isOn: $settings.includeExternalDrives,
                            accent: .gfcRed,
                            isDisabled: !settings.includeSATANVMe
                        )
                    }
                    Divider().opacity(0.1)
                    SettingsToggleRow(
                        title: "eGPU connected via Thunderbolt",
                        isOn: $settings.includeEGPU,
                        accent: .gfcRed
                    )
                }
            }

            SettingsCard(icon: "thermometer.sun.fill", title: "DISPLAY UNITS", accentColor: .gfcAmber) {
                VStack(spacing: 2) {
                    SettingsToggleRow(
                        title: "Use Fahrenheit scale",
                        isOn: $settings.useFahrenheit
                    )
                    Divider().opacity(0.1)
                    SettingsToggleRow(
                        title: "Show precise temperature when possible (e.g. 45.4)",
                        isOn: $settings.precise
                    )
                }
            }

            Spacer(minLength: 0)
        }
    }
}

#Preview {
    TemperatureSensorsTab()
        .environmentObject(SettingsStore.shared)
        .padding(20)
        .frame(width: 540, height: 380)
        .background(Color.gfcBackground)
        .preferredColorScheme(.dark)
}

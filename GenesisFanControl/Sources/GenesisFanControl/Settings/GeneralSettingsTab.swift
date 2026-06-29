//
//  GeneralSettingsTab.swift
//  GenesisFanControl
//
//  Mirrors screenshot 1: auto-start, check updates, dock icon, language.
//

import SwiftUI
import GenesisFanControlCore

/// General preferences. Two toggles only — both wired end-to-end:
/// `openAtLogin` reconciles with SMAppService.mainApp on every change,
/// `showDockIcon` swaps NSApp activation policy on the fly.
///
/// Earlier drafts had "Check for updates at launch" and a language
/// picker, but no updater shipped and no localization shipped, so the
/// controls were lying to the user. Removed rather than left as dead
/// toggles (review HIGH — "Six Settings toggles never read at runtime").
struct GeneralSettingsTab: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(icon: "power", title: "STARTUP & BEHAVIOR", accentColor: .gfcAmber) {
                VStack(spacing: 2) {
                    SettingsToggleRow(
                        title: "Auto-start at system login",
                        subtitle: "Register with macOS so GenesisFanControl launches when you log in",
                        isOn: $settings.openAtLogin
                    )
                    Divider().opacity(0.1)
                    SettingsToggleRow(
                        title: "Show icon in Dock",
                        subtitle: "Off keeps the app menu-bar only",
                        isOn: $settings.showDockIcon
                    )
                    .onChange(of: settings.showDockIcon) { _, _ in
                        NotificationCenter.default.post(name: .mfcShowDockIconChanged, object: nil)
                    }
                }
            }

            Spacer(minLength: 0)
        }
    }
}

#Preview {
    GeneralSettingsTab()
        .environmentObject(SettingsStore.shared)
        .padding(20)
        .frame(width: 540, height: 380)
        .background(Color.gfcBackground)
        .preferredColorScheme(.dark)
}

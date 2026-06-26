//
//  GeneralSettingsTab.swift
//  MacsFanControl
//
//  Mirrors screenshot 1: auto-start, check updates, dock icon, language.
//

import SwiftUI
import MacsFanControlCore

struct GeneralSettingsTab: View {
    @EnvironmentObject var settings: SettingsStore

    private let languages: [(code: String, name: String)] = [
        ("en", "English"),
        ("cs", "Czech (Čeština)"),
        ("de", "German (Deutsch)"),
        ("es", "Spanish (Español)"),
        ("fr", "French (Français)"),
        ("ja", "Japanese (日本語)"),
        ("zh", "Chinese (中文)"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(icon: "power", title: "STARTUP & BEHAVIOR", accentColor: .mfcAmber) {
                VStack(spacing: 2) {
                    SettingsToggleRow(
                        title: "Auto-start at system login (recommended)",
                        isOn: $settings.openAtLogin
                    )
                    Divider().opacity(0.1)
                    SettingsToggleRow(
                        title: "Check for updates at launch",
                        isOn: $settings.checkUpdatesOnLaunch
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

            SettingsCard(icon: "globe", title: "LANGUAGE", accentColor: .mfcCyan) {
                HStack(spacing: 10) {
                    Text("Language:")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.mfcText)
                    Picker("", selection: $settings.languageCode) {
                        ForEach(languages, id: \.code) { l in
                            Text(l.name).tag(l.code)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 260)

                    Spacer()

                    Button("Translate…") {
                        if let url = URL(string: "https://crowdin.com/") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.link)
                    .foregroundColor(.mfcCyan)
                }
                .padding(.vertical, 4)
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
        .background(Color.mfcBackground)
        .preferredColorScheme(.dark)
}

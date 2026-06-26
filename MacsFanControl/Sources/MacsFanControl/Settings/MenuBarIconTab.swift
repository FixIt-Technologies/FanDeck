//
//  MenuBarIconTab.swift
//  MacsFanControl
//
//  Mirrors screenshot 3: pick icon style, fan readout style, and up to
//  two sensors to surface next to the menubar icon.
//

import SwiftUI
import MacsFanControlCore

struct MenuBarIconTab: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(icon: "menubar.dock.rectangle.badge.record", title: "MENU-BAR APPEARANCE", accentColor: .mfcCyan) {
                VStack(spacing: 12) {
                    LabeledRow("Icon:") {
                        Picker("", selection: $settings.menuBarIconStyle) {
                            ForEach(MenuBarIconStyle.allCases) { style in
                                HStack {
                                    Image(systemName: iconName(for: style))
                                        .foregroundColor(.mfcCyan)
                                    Text(style.label)
                                }.tag(style)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 280)
                    }
                    LabeledRow("Fan:") {
                        Picker("", selection: $settings.menuBarFan) {
                            ForEach(MenuBarFanDisplay.allCases) { d in
                                Text(d.label).tag(d)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 200)
                    }
                }
            }

            SettingsCard(icon: "list.bullet.rectangle.portrait", title: "SENSORS IN MENU BAR", accentColor: .mfcAmber) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Pick up to two sensors to surface next to the icon.")
                        .font(.system(size: 11))
                        .foregroundColor(.mfcTextMuted)

                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(appState.sensors) { s in
                                MenuBarSensorRow(
                                    sensor: s,
                                    isOn: settings.menuBarSensorIDs.contains(s.id),
                                    toggle: { toggle(s.id) }
                                )
                            }
                        }
                    }
                    .frame(maxHeight: 140)
                }
            }

            Spacer(minLength: 0)
        }
    }

    private func toggle(_ id: String) {
        if let idx = settings.menuBarSensorIDs.firstIndex(of: id) {
            settings.menuBarSensorIDs.remove(at: idx)
        } else if settings.menuBarSensorIDs.count < 2 {
            settings.menuBarSensorIDs.append(id)
        } else {
            // Replace the older one
            settings.menuBarSensorIDs.removeFirst()
            settings.menuBarSensorIDs.append(id)
        }
    }

    private func iconName(for style: MenuBarIconStyle) -> String {
        switch style {
        case .color: return "fanblades.fill"
        case .monochrome: return "fanblades"
        case .temperature: return "thermometer.medium"
        }
    }
}

private struct LabeledRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.mfcText)
                .frame(width: 70, alignment: .trailing)
            content
            Spacer()
        }
    }
}

private struct MenuBarSensorRow: View {
    let sensor: TempSensor
    let isOn: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                Image(systemName: sensor.kind.sfSymbol)
                    .foregroundColor(sensor.kind.accent)
                    .frame(width: 18)
                Text(sensor.name)
                    .font(.system(size: 12))
                    .foregroundColor(.mfcText)
                Spacer()
                if isOn {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.mfcAmber)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isOn ? Color.mfcAmber.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    MenuBarIconTab()
        .environmentObject(SettingsStore.shared)
        .environmentObject(AppState.shared)
        .padding(20)
        .frame(width: 540, height: 380)
        .background(Color.mfcBackground)
        .preferredColorScheme(.dark)
}

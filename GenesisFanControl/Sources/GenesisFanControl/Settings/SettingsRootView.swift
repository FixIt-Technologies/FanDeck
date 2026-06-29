//
//  SettingsRootView.swift
//  GenesisFanControl
//
//  Three-tab Settings window: General / Temperature Sensors / Menu Bar Icon.
//  Toolbar-style picker (top icon row) mirrors screenshots 1-3.
//

import SwiftUI
import GenesisFanControlCore

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case sensors
    case menuBar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .sensors: return "Temperature Sensors"
        case .menuBar: return "Menu Bar Icon"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape.fill"
        case .sensors: return "thermometer.medium"
        case .menuBar: return "menubar.rectangle"
        }
    }

    var accent: Color {
        switch self {
        case .general: return .gfcAmber
        case .sensors: return .gfcRed
        case .menuBar: return .gfcCyan
        }
    }
}

struct SettingsRootView: View {
    @State private var tab: SettingsTab = .general

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider().overlay(Color.white.opacity(0.06))
            content
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 560, height: 420)
        .background(Color.gfcBackground)
    }

    private var tabBar: some View {
        HStack(spacing: 28) {
            ForEach(SettingsTab.allCases) { t in
                SettingsTabButton(tab: t, isSelected: tab == t) {
                    withAnimation(GFCAnimation.standard) { tab = t }
                }
            }
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [Color.gfcSidebar, Color.gfcBackground],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .general: GeneralSettingsTab()
        case .sensors: TemperatureSensorsTab()
        case .menuBar: MenuBarIconTab()
        }
    }
}

private struct SettingsTabButton: View {
    let tab: SettingsTab
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(tab.accent.opacity(0.18))
                            .frame(width: 52, height: 42)
                            .shadow(color: tab.accent.opacity(0.5), radius: 8)
                    } else if isHovered {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.05))
                            .frame(width: 52, height: 42)
                    }
                    Image(systemName: tab.icon)
                        .font(.system(size: 22, weight: isSelected ? .semibold : .regular))
                        .foregroundColor(isSelected ? tab.accent : .gfcTextSecondary)
                }
                .frame(width: 52, height: 42)
                Text(tab.title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(isSelected ? .gfcText : .gfcTextSecondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
    }
}

#Preview {
    SettingsRootView()
        .environmentObject(AppState.shared)
        .environmentObject(SettingsStore.shared)
        .preferredColorScheme(.dark)
}

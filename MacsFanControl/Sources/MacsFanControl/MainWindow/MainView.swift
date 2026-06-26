//
//  MainView.swift
//  MacsFanControl
//
//  Dashboard: sidebar (fans + sensors), detail panel.
//

import SwiftUI
import MacsFanControlCore

enum MainSelection: Hashable {
    case fan(String)
    case sensor(String)
}

struct MainView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: SettingsStore
    @State private var selection: MainSelection?
    @State private var configuringFanID: String?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 320)
        } detail: {
            detail
                .background(Color.mfcBackground.ignoresSafeArea())
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(item: Binding(
            get: { configuringFanID.flatMap { id in appState.fan(withID: id).map { ConfiguringFan(fan: $0) } } },
            set: { newValue in configuringFanID = newValue?.fan.id }
        )) { wrapper in
            FanControlSheet(fan: wrapper.fan)
                .environmentObject(appState)
                .environmentObject(settings)
        }
        .onAppear {
            if selection == nil {
                selection = appState.fans.first.map { .fan($0.id) }
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        ZStack {
            Color.mfcSidebar.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider().overlay(Color.white.opacity(0.06))
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        section(title: "FANS", icon: "fanblades.fill", accent: .mfcAmber) {
                            VStack(spacing: 4) {
                                ForEach(appState.fans) { fan in
                                    SidebarNavItem(
                                        icon: "fanblades.fill",
                                        title: fan.name,
                                        isSelected: selection == .fan(fan.id),
                                        accent: fan.loadColor,
                                        action: { selection = .fan(fan.id) }
                                    )
                                }
                            }
                        }
                        section(title: "SENSORS", icon: "thermometer.medium", accent: .mfcCyan) {
                            VStack(spacing: 4) {
                                ForEach(filteredSensors) { sensor in
                                    SidebarNavItem(
                                        icon: sensor.kind.sfSymbol,
                                        title: sensor.name,
                                        isSelected: selection == .sensor(sensor.id),
                                        accent: sensor.kind.accent,
                                        action: { selection = .sensor(sensor.id) }
                                    )
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 12)
                }
                footer
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "fanblades.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.mfcAmber)
                .pulseGlow(color: .mfcAmber)
            VStack(alignment: .leading, spacing: 1) {
                Text("MacsFanControl")
                    .font(MFCFont.headline(13))
                    .foregroundColor(.mfcText)
                Text(appState.smc.backendName + (appState.smc.isSimulated ? " · simulated" : ""))
                    .font(.system(size: 10))
                    .foregroundColor(.mfcTextMuted)
            }
            Spacer()
            TagPill(text: settings.useFahrenheit ? "°F" : "°C", color: .mfcCyan)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func section<Content: View>(title: String, icon: String, accent: Color,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(accent)
                Text(title)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.mfcTextMuted)
                    .tracking(0.8)
                Spacer()
            }
            .padding(.horizontal, 6)
            content()
        }
    }

    private var footer: some View {
        HStack {
            Image(systemName: "clock")
                .font(.system(size: 10))
                .foregroundColor(.mfcTextMuted)
            Text("Updated \(timeAgo(appState.lastUpdated))")
                .font(.system(size: 10))
                .foregroundColor(.mfcTextMuted)
            Spacer()
            Button {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundColor(.mfcTextSecondary)
            .help("Open Settings (⌘,)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.25))
    }

    private var filteredSensors: [TempSensor] {
        appState.sensors.filter { s in
            switch s.kind {
            case .storage: return settings.includeSATANVMe
            case .gpu: return true  // we'd filter eGPU by name in a real impl
            default: return true
            }
        }
    }

    private func timeAgo(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 0 || date == .distantPast { return "—" }
        if s < 2 { return "just now" }
        return "\(s)s ago"
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .fan(let id):
            if let fan = appState.fan(withID: id) {
                FanDetailView(fan: fan, onConfigure: { configuringFanID = id })
            } else { emptyState }
        case .sensor(let id):
            if let sensor = appState.sensor(withID: id) {
                SensorDetailView(sensor: sensor)
            } else { emptyState }
        case .none:
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "fanblades")
                .font(.system(size: 64, weight: .light))
                .foregroundColor(.mfcTextMuted)
            Text("Pick a fan or sensor in the sidebar")
                .font(MFCFont.body(14))
                .foregroundColor(.mfcTextSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Identifiable sheet payload

private struct ConfiguringFan: Identifiable {
    let fan: Fan
    var id: String { fan.id }
}

#Preview {
    MainView()
        .environmentObject(AppState.shared)
        .environmentObject(SettingsStore.shared)
        .frame(width: 960, height: 640)
        .preferredColorScheme(.dark)
}

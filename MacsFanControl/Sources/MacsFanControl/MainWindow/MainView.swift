//
//  MainView.swift
//  MacsFanControl
//
//  Two columns:
//   - center  : every fan stacked as a draggable FanGaugeCard
//   - right   : compact SensorPanel listing all temperatures at once
//
//  No fan-selection navigation — everything is visible at all times.
//

import SwiftUI
import MacsFanControlCore

struct MainView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: SettingsStore
    @State private var configuringFanID: String?

    private let sensorPanelWidth: CGFloat = 280

    var body: some View {
        ZStack {
            Color.mfcBackground.ignoresSafeArea()
            HStack(spacing: 0) {
                fansColumn
                SensorPanel()
                    .frame(width: sensorPanelWidth)
            }
            topStatusBar
        }
        .sheet(item: Binding(
            get: { configuringFanID.flatMap { id in appState.fan(withID: id).map { FanWrap(fan: $0) } } },
            set: { newValue in configuringFanID = newValue?.fan.id }
        )) { wrapper in
            FanControlSheet(fan: wrapper.fan)
                .environmentObject(appState)
                .environmentObject(settings)
        }
    }

    // MARK: - Status bar (overlay)

    private var topStatusBar: some View {
        VStack {
            HStack(spacing: 10) {
                Image(systemName: "fanblades.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.mfcAmber)
                    .pulseGlow(color: .mfcAmber)
                Text("MacsFanControl")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.mfcText)
                TagPill(text: appState.smc.backendName + (appState.smc.isSimulated ? " · SIM" : ""),
                        color: appState.smc.isSimulated ? .mfcAmber : .mfcGreen)
                Spacer()
                Text("Updated \(timeAgo(appState.lastUpdated))")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.mfcTextMuted)
                Button {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.mfcTextSecondary)
                }
                .buttonStyle(.plain)
                .help("Open Settings (⌘,)")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                Rectangle()
                    .fill(Color.mfcSidebar.opacity(0.7))
                    .background(VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow))
                    .ignoresSafeArea(.container, edges: .top)
            )
            Spacer()
        }
    }

    // MARK: - Fans column

    private var fansColumn: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 18) {
                Color.clear.frame(height: 30) // padding under status bar
                if appState.fans.isEmpty {
                    emptyFans
                } else {
                    ForEach(appState.fans) { fan in
                        FanGaugeCard(
                            fan: fan,
                            onConfigure: { configuringFanID = fan.id },
                            onSetManual: { rpm in
                                appState.setMode(.constant(rpm: rpm), for: fan.id)
                            },
                            onResetAuto: {
                                appState.setMode(.auto, for: fan.id)
                            }
                        )
                    }
                }
                helpFooter
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyFans: some View {
        VStack(spacing: 12) {
            Image(systemName: "fanblades")
                .font(.system(size: 48, weight: .light))
                .foregroundColor(.mfcTextMuted)
            Text("No fans detected.")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.mfcTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private var helpFooter: some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.tap.fill")
                .font(.system(size: 10))
                .foregroundColor(.mfcAmber)
            Text("Tap or drag the green bar to pin a constant RPM. Click ‘Auto’ to release.")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.mfcTextMuted)
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func timeAgo(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 0 || date == .distantPast { return "—" }
        if s < 2 { return "just now" }
        return "\(s)s ago"
    }
}

// MARK: - Sheet payload

private struct FanWrap: Identifiable {
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

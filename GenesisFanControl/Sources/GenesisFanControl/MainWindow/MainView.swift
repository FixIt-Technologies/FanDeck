//
//  MainView.swift
//  GenesisFanControl
//
//  Two columns:
//   - center  : every fan stacked as a draggable FanGaugeCard
//   - right   : compact SensorPanel listing all temperatures at once
//
//  No fan-selection navigation — everything is visible at all times.
//

import SwiftUI
import GenesisFanControlCore

struct MainView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: SettingsStore
    @State private var configuringFanID: String?

    private let sensorPanelWidth: CGFloat = 280

    var body: some View {
        ZStack {
            Color.gfcBackground.ignoresSafeArea()
            HStack(spacing: 0) {
                fansColumn
                SensorPanel()
                    .frame(width: sensorPanelWidth)
            }
            topStatusBar
            if appState.needsElevation {
                elevationBanner
            }
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
                // Pad past the traffic lights — content now extends behind
                // them since the title bar is hidden.
                Color.clear.frame(width: 64, height: 1)
                Image(systemName: "fanblades.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.gfcAmber)
                    .pulseGlow(color: .gfcAmber)
                Text("GenesisFanControl")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.gfcText)
                TagPill(text: appState.smc.backendName + (appState.smc.isSimulated ? " · SIM" : ""),
                        color: appState.smc.isSimulated ? .gfcAmber : .gfcGreen)
                Spacer()
                Text("Updated \(timeAgo(appState.lastUpdated))")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.gfcTextMuted)
                Button {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.gfcTextSecondary)
                }
                .buttonStyle(.plain)
                .help("Open Settings (⌘,)")
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 10)
            // No background fill — window background bleeds through so the
            // title-bar area merges visually with content below.
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
                .foregroundColor(.gfcTextMuted)
            Text("No fans detected.")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.gfcTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private var helpFooter: some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.tap.fill")
                .font(.system(size: 10))
                .foregroundColor(.gfcAmber)
            Text("Tap or drag the green bar to pin a constant RPM. Click ‘Auto’ to release.")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.gfcTextMuted)
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var elevationBanner: some View {
        VStack {
            Spacer()
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: appState.helperInstalling ? "hourglass" : "lock.shield.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.gfcAmber)
                VStack(alignment: .leading, spacing: 4) {
                    Text(appState.helperInstalling
                         ? "Installing privileged helper…"
                         : "Fan control needs an elevated helper")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.gfcText)
                    Text(appState.helperInstallError
                         ?? "Click Install to add a tiny root daemon (you'll be asked for your admin password). After that the app drives fans without sudo.")
                        .font(.system(size: 11))
                        .foregroundColor(appState.helperInstallError == nil ? .gfcTextSecondary : .gfcRed)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if !appState.helperInstalling {
                    Button("Install Helper") { appState.installHelper() }
                        .buttonStyle(PrimaryButtonStyle())
                    Button("Dismiss") { appState.needsElevation = false }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: 720)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.gfcSidebar.opacity(0.95))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.gfcAmber.opacity(0.6), lineWidth: 1)
                    )
                    .shadow(color: .gfcAmber.opacity(0.3), radius: 14)
            )
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
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

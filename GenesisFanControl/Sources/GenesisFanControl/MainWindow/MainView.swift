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
    @Environment(\.openSettings) private var openSettings
    @State private var configuringFanID: String?

    private let sensorPanelWidth: CGFloat = 280

    var body: some View {
        // ZStack order matters for hit-testing — last-declared wins. We
        // want the interactive HStack on top so SensorPanel's gear (and
        // any future buttons in the header strip) reliably receive
        // clicks. topStatusBar sits BELOW the HStack now, with
        // allowsHitTesting(false) as belt-and-braces — its decorative
        // pill / icon would never need clicks anyway.
        ZStack {
            Color.gfcBackground.ignoresSafeArea()
            topStatusBar
            HStack(spacing: 0) {
                fansColumn
                SensorPanel()
                    .frame(width: sensorPanelWidth)
            }
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
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                // Pad past the traffic lights — content extends behind
                // them since the title bar is hidden.
                Color.clear.frame(width: 70, height: 1)
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
                // The right-hand controls (Updated, gear) live in the
                // SensorPanel header so they stay on the same row as
                // "TEMPERATURES" instead of one row above it.
            }
            .padding(.horizontal, 12)
            // Match the macOS title-bar height (28 pt) so the app name +
            // pill sit on the same baseline as the traffic lights.
            .frame(height: 28)
            Spacer()
        }
        // Without this the SwiftUI safe-area inset for the (hidden) title
        // bar pushes the VStack down ~28 pt — landing the row BELOW the
        // traffic lights instead of beside them.
        .ignoresSafeArea(.container, edges: .top)
        // CRITICAL: this overlay is purely decorative (Image + Text + pill
        // + Spacer; zero interactive controls). It sits on top of the
        // SensorPanel header in the ZStack — and SwiftUI's HStack claims
        // hit-testing for its WHOLE frame width, even where there's just
        // a Spacer. Without this modifier the gear button in SensorPanel
        // (also at y=0..28) never receives clicks — they're consumed by
        // this strip and dropped. Diagnosed via SwiftUI expert skill.
        .allowsHitTesting(false)
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
        // Three states the banner can communicate:
        //   • installing  — spinner, hourglass, just wait
        //   • outdated    — helper IS running but is an older build than
        //                   the GUI; needs a re-install to pick up fixes
        //   • down        — helper isn't running at all (first-time
        //                   install OR uninstalled)
        let installing = appState.helperInstalling
        let outdated: (installed: Int, current: Int)? = {
            if case .outdated(let inst, let cur) = appState.helperHealth { return (inst, cur) }
            return nil
        }()
        let titleText: String = installing
            ? "Installing privileged helper…"
            : (outdated != nil
                ? "Helper is out of date"
                : "Fan control needs an elevated helper")
        let detailText: String = appState.helperInstallError
            ?? (outdated.map { "The helper running as root is build v\($0.installed); this GUI expects v\($0.current). Click Update to re-install with the latest fixes (you'll be asked for your admin password)." }
                ?? "Click Install to add a tiny root daemon (you'll be asked for your admin password). After that the app drives fans without sudo.")
        let buttonLabel = outdated != nil ? "Update Helper" : "Install Helper"
        VStack {
            Spacer()
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: installing ? "hourglass" : (outdated != nil ? "arrow.triangle.2.circlepath.circle.fill" : "lock.shield.fill"))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.gfcAmber)
                VStack(alignment: .leading, spacing: 4) {
                    Text(titleText)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.gfcText)
                    Text(detailText)
                        .font(.system(size: 11))
                        .foregroundColor(appState.helperInstallError == nil ? .gfcTextSecondary : .gfcRed)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if !installing {
                    Button(buttonLabel) { appState.installHelper() }
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

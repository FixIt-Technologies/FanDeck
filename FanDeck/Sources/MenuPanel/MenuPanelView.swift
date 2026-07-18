//
//  MenuPanelView.swift
//  FanDeck
//
//  The rich MenuBarExtra(.window) panel — FanDeck's primary daily
//  surface (decision D3). Live per-fan sliders, one-click Auto all /
//  Full blast, hottest temperatures, helper status, and jump-offs to
//  the compact window and Settings.
//

import SwiftUI
import GenesisFanControlCore

struct MenuPanelView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            FDElevationBanner()
            hottestHero
            ForEach(appState.fans) { fan in
                PanelFanRow(fan: fan)
            }
            quickActions
            sensorStrip
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 316)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Text("FANDECK")
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.8)
            Spacer()
            FDStatusDot(healthy: appState.helperAvailable)
            Text(helperLabel)
                .font(.system(size: 9.5))
                .foregroundStyle(FD.secondaryText)
        }
    }

    private var helperLabel: String {
        switch appState.helperHealth {
        case .healthy(let v): return "helper v\(v) · \(appState.smc.backendName)"
        case .outdated(let installed, _): return "helper v\(installed) stale · \(appState.smc.backendName)"
        case .down: return "helper off · \(appState.smc.backendName)"
        }
    }

    // MARK: - Hottest hero

    private var hottestHero: some View {
        FDCard {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let s = appState.headlineSensor {
                    Text(s.formatted(useFahrenheit: settings.useFahrenheit, precise: false))
                        .font(.system(size: 23, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(FD.tempColor(s.celsius))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(s.name)
                            .font(.system(size: 9.5))
                            .foregroundStyle(FD.secondaryText)
                            .lineLimit(1)
                        Text("hottest")
                            .font(.system(size: 9))
                            .foregroundStyle(FD.tertiaryText)
                    }
                } else {
                    Text("No sensors")
                        .font(.system(size: 12))
                        .foregroundStyle(FD.secondaryText)
                }
                Spacer(minLength: 0)
                Text(secondaryTemps)
                    .font(.system(size: 9.5))
                    .monospacedDigit()
                    .foregroundStyle(FD.tertiaryText)
            }
        }
    }

    private var secondaryTemps: String {
        let interesting: [SensorKind] = [.gpu, .storage]
        let parts = interesting.compactMap { kind -> String? in
            guard let s = appState.sensors.filter({ $0.kind == kind })
                .max(by: { $0.celsius < $1.celsius }) else { return nil }
            let label = kind == .gpu ? "GPU" : "SSD"
            return "\(label) \(s.formatted(useFahrenheit: settings.useFahrenheit, precise: false))"
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Quick actions

    private var quickActions: some View {
        HStack(spacing: 7) {
            Button("Auto all") {
                for fan in appState.fans { appState.setMode(.auto, for: fan.id) }
            }
            .controlSize(.small)
            Button("Full blast") {
                for fan in appState.fans { appState.setMode(.constant(rpm: fan.maxRPM), for: fan.id) }
            }
            .controlSize(.small)
            .tint(FD.amber)
            Spacer()
            if appState.writeInFlight {
                ProgressView().controlSize(.mini)
            }
        }
    }

    // MARK: - Sensors

    private var sensorStrip: some View {
        let top = Array(appState.sensors.sorted(by: { $0.celsius > $1.celsius }).prefix(4))
        return HStack(spacing: 5) {
            ForEach(top) { s in
                FDSensorChip(name: shortName(s),
                             celsius: s.celsius,
                             label: s.formatted(useFahrenheit: settings.useFahrenheit, precise: false))
                    .equatable()
            }
        }
    }

    private func shortName(_ s: TempSensor) -> String {
        switch s.kind {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .storage: return "SSD"
        case .battery: return "Batt"
        case .airport: return "WiFi"
        case .thunderbolt: return "TB"
        default: return String(s.name.prefix(6))
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Dashboard", systemImage: "rectangle.grid.2x2")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .keyboardShortcut("o")
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(FD.secondaryText)
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(FD.secondaryText)
            .keyboardShortcut("q")
        }
    }
}

// MARK: - Panel fan row

/// One fan: name · mode pill · RPM readout on top, a thin drag-to-set
/// slider underneath. Dragging commits `.constant` mode live (deduped
/// to 50 RPM steps so the SMC isn't hammered per pixel); the wall
/// marker shows the active setpoint.
struct PanelFanRow: View {
    let fan: Fan
    @EnvironmentObject var appState: AppState

    @State private var isDragging = false
    @State private var dragRPM: Int = 0
    @State private var lastCommittedRPM: Int = -1

    var body: some View {
        FDCard {
            VStack(spacing: 7) {
                HStack(spacing: 7) {
                    Text(fan.name)
                        .font(.system(size: 11, weight: .semibold))
                    FDModePill(mode: fan.mode)
                    Spacer()
                    Text("\(isDragging ? dragRPM : fan.currentRPM)")
                        .font(.system(size: 13, weight: .bold))
                        .monospacedDigit()
                    Text("RPM")
                        .font(.system(size: 8.5))
                        .foregroundStyle(FD.tertiaryText)
                }
                FanTrackSlider(fan: fan, isDragging: $isDragging, dragRPM: $dragRPM) { rpm in
                    // Dedupe: only commit when the rounded step moved.
                    guard rpm != lastCommittedRPM else { return }
                    lastCommittedRPM = rpm
                    appState.setMode(.constant(rpm: rpm), for: fan.id)
                }
                HStack {
                    Text("\(fan.minRPM)")
                    Spacer()
                    if case .auto = fan.mode {
                        Text("OS-managed")
                    } else {
                        Button("Auto") { appState.setMode(.auto, for: fan.id) }
                            .buttonStyle(.plain)
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(FD.green)
                    }
                    Spacer()
                    Text("\(fan.maxRPM)")
                }
                .font(.system(size: 8.5))
                .foregroundStyle(FD.tertiaryText)
            }
        }
    }
}

/// Thin capsule track: fill = current RPM, wall marker = setpoint.
/// Tap or drag anywhere sets a constant RPM (50-step quantized).
struct FanTrackSlider: View {
    let fan: Fan
    @Binding var isDragging: Bool
    @Binding var dragRPM: Int
    let commit: (Int) -> Void

    private func rpm(atFraction f: Double) -> Int {
        let raw = Double(fan.minRPM) + f * Double(fan.maxRPM - fan.minRPM)
        return min(fan.maxRPM, max(fan.minRPM, Int((raw / 50).rounded()) * 50))
    }

    private func fraction(of rpm: Int) -> Double {
        guard fan.maxRPM > fan.minRPM else { return 0 }
        return Double(rpm - fan.minRPM) / Double(fan.maxRPM - fan.minRPM)
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let fillFrac = isDragging ? fraction(of: dragRPM) : fan.loadFraction
            let accent = isDragging ? FD.amber : FD.modeAccent(fan.mode)
            ZStack(alignment: .leading) {
                Capsule().fill(FD.separator.opacity(0.5))
                Capsule()
                    .fill(LinearGradient(colors: [accent.opacity(0.35), accent.opacity(0.85)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(6, fillFrac * w))
                    .animation(isDragging ? nil : .easeOut(duration: 0.6), value: fillFrac)
                setpointWall(width: w)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        isDragging = true
                        let f = min(1, max(0, drag.location.x / w))
                        let r = rpm(atFraction: f)
                        dragRPM = r
                        commit(r)
                    }
                    .onEnded { _ in isDragging = false }
            )
        }
        .frame(height: 13)
    }

    @ViewBuilder
    private func setpointWall(width: CGFloat) -> some View {
        let wallRPM: Int? = {
            if isDragging { return dragRPM }
            switch fan.mode {
            case .auto: return nil
            case .constant, .sensorBased: return fan.targetRPM
            }
        }()
        if let rpm = wallRPM {
            let color: Color = {
                if isDragging { return FD.amber }
                if case .sensorBased = fan.mode { return FD.cyan }
                return FD.amber
            }()
            RoundedRectangle(cornerRadius: 1.5)
                .fill(color)
                .frame(width: 3, height: 19)
                .shadow(color: color.opacity(0.8), radius: 3)
                .offset(x: fraction(of: rpm) * width - 1.5)
        }
    }
}

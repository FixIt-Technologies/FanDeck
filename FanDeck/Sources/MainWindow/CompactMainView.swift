//
//  CompactMainView.swift
//  FanDeck
//
//  The compact dashboard window (decision D4, Take B — mini-gauge grid):
//  stat strip on top, one arc gauge per fan side by side, sensor chips
//  in a wrap grid below, footer with helper status + updated stamp.
//

import SwiftUI
import GenesisFanControlCore

struct CompactMainView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: SettingsStore

    /// Which fan's ramp/config sheet is open (nil = none).
    @State private var configuringFan: Fan?
    @State private var sensorsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FDElevationBanner()
            statStrip
            gaugeRow
            sensorHeader
            sensorGrid
            Spacer(minLength: 0)
            footer
        }
        .padding(12)
        .frame(minWidth: 392, minHeight: 470)
        .background(.regularMaterial)
        .sheet(item: $configuringFan) { fan in
            RampEditorSheet(fan: fan)
                .environmentObject(appState)
                .environmentObject(settings)
        }
    }

    // MARK: - Stat strip

    private var statStrip: some View {
        HStack(spacing: 7) {
            if let hot = appState.headlineSensor {
                statTile(label: "HOTTEST",
                         value: hot.formatted(useFahrenheit: settings.useFahrenheit, precise: false),
                         color: FD.tempColor(hot.celsius))
            }
            if let avg = cpuAverage {
                statTile(label: "CPU AVG",
                         value: TempSensor(id: "_", name: "_", kind: .cpu, celsius: avg)
                             .formatted(useFahrenheit: settings.useFahrenheit, precise: false),
                         color: FD.tempColor(avg))
            }
            ForEach(appState.fans) { fan in
                statTile(label: fan.name.uppercased(),
                         value: "\(fan.currentRPM)",
                         color: FD.modeAccent(fan.mode))
            }
        }
    }

    private var cpuAverage: Double? {
        let cpus = appState.sensors.filter { $0.kind == .cpu }
        guard !cpus.isEmpty else { return nil }
        return cpus.map(\.celsius).reduce(0, +) / Double(cpus.count)
    }

    private func statTile(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 8, weight: .semibold))
                .kerning(0.7)
                .foregroundStyle(FD.tertiaryText)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 14, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(FD.card)
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(FD.cardStroke, lineWidth: 1)
                )
        )
    }

    // MARK: - Gauges

    private var gaugeRow: some View {
        HStack(spacing: 10) {
            ForEach(appState.fans) { fan in
                gaugeCard(fan)
            }
        }
    }

    private func gaugeCard(_ fan: Fan) -> some View {
        FDCard {
            VStack(spacing: 5) {
                FanArcGauge(fan: fan) { rpm in
                    appState.setMode(.constant(rpm: rpm), for: fan.id)
                }
                .frame(maxWidth: 130)
                Text(fan.name)
                    .font(.system(size: 11, weight: .semibold))
                HStack(spacing: 6) {
                    FDModePill(mode: fan.mode)
                    if case .auto = fan.mode {} else {
                        Button("Auto") { appState.setMode(.auto, for: fan.id) }
                            .buttonStyle(.plain)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(FD.green)
                    }
                    Button {
                        configuringFan = fan
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 9))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(FD.secondaryText)
                    .help("Configure mode & sensor curve…")
                }
                HStack {
                    Text("\(fan.minRPM)")
                    Spacer()
                    Text("\(fan.maxRPM)")
                }
                .font(.system(size: 8))
                .foregroundStyle(FD.tertiaryText)
                .padding(.horizontal, 8)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Sensors

    private var sensorHeader: some View {
        HStack(spacing: 6) {
            Text("SENSORS")
                .font(.system(size: 9, weight: .bold))
                .kerning(1)
                .foregroundStyle(FD.secondaryText)
            Text("\(appState.sensors.count)")
                .font(.system(size: 8.5, weight: .semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(FD.card))
                .foregroundStyle(FD.secondaryText)
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { sensorsExpanded.toggle() }
            } label: {
                Image(systemName: sensorsExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(FD.secondaryText)
        }
    }

    private var sensorGrid: some View {
        let sorted = appState.sensors.sorted(by: { $0.celsius > $1.celsius })
        let shown = sensorsExpanded ? sorted : Array(sorted.prefix(8))
        return ScrollView(showsIndicators: false) {
            FlowLayout(spacing: 5) {
                ForEach(shown) { s in
                    FDSensorChip(name: s.name,
                                 celsius: s.celsius,
                                 label: s.formatted(useFahrenheit: settings.useFahrenheit,
                                                    precise: settings.precise))
                        .equatable()
                }
            }
        }
        .frame(maxHeight: sensorsExpanded ? 220 : 84)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            FDStatusDot(healthy: appState.helperAvailable)
            Text(footerText)
                .font(.system(size: 9.5))
                .foregroundStyle(FD.tertiaryText)
            Spacer()
            Text("drag a gauge to set RPM")
                .font(.system(size: 9))
                .foregroundStyle(FD.tertiaryText)
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(FD.secondaryText)
        }
    }

    private var footerText: String {
        let helper: String
        switch appState.helperHealth {
        case .healthy(let v): helper = "helper v\(v)"
        case .outdated(let installed, _): helper = "helper v\(installed) stale"
        case .down: helper = "helper off"
        }
        let stamp = appState.lastUpdated == .distantPast
            ? "—"
            : appState.lastUpdated.formatted(date: .omitted, time: .standard)
        return "\(helper) · \(appState.smc.backendName) · updated \(stamp)"
    }
}

// MARK: - Simple flow layout for sensor chips

/// Minimal left-to-right wrap layout (macOS 14's `Layout` protocol).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 {
                x = 0
                y += rowH + spacing
                rowH = 0
            }
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
        return CGSize(width: width, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = bounds.width
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 {
                x = 0
                y += rowH + spacing
                rowH = 0
            }
            sub.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                      proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}

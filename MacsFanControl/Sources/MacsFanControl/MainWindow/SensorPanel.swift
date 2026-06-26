//
//  SensorPanel.swift
//  MacsFanControl
//
//  Always-visible right rail listing every sensor at a glance.
//  Grouped by kind, monospaced temperatures, color-coded by reading.
//

import SwiftUI
import MacsFanControlCore

struct SensorPanel: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.06))
            ScrollView(showsIndicators: true) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(groupedSensors, id: \.kind) { group in
                        SensorGroupView(
                            kind: group.kind,
                            sensors: group.sensors,
                            useFahrenheit: settings.useFahrenheit,
                            precise: settings.precise
                        )
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 12)
            }
        }
        .background(Color.mfcSidebar.opacity(0.55))
        .overlay(
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(width: 1),
            alignment: .leading
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "thermometer.medium")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.mfcCyan)
            Text("TEMPERATURES")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundColor(.mfcTextSecondary)
            Spacer()
            Text("\(filteredSensors.count)")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.mfcTextMuted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var filteredSensors: [TempSensor] {
        appState.sensors.filter { s in
            if s.kind == .storage && !settings.includeSATANVMe { return false }
            return true
        }
    }

    private var groupedSensors: [(kind: SensorKind, sensors: [TempSensor])] {
        let buckets = Dictionary(grouping: filteredSensors, by: { $0.kind })
        return SensorKind.allCases.compactMap { k in
            guard let xs = buckets[k], !xs.isEmpty else { return nil }
            return (kind: k, sensors: xs)
        }
    }
}

// MARK: - SensorGroupView

private struct SensorGroupView: View {
    let kind: SensorKind
    let sensors: [TempSensor]
    let useFahrenheit: Bool
    let precise: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: kind.sfSymbol)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(kind.accent)
                Text(kind.label.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.7)
                    .foregroundColor(.mfcTextMuted)
                Spacer()
                Text("avg \(formatted(avgC))")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(.mfcTextMuted)
            }
            .padding(.horizontal, 4)

            VStack(spacing: 1) {
                ForEach(sensors) { s in
                    SensorRow(sensor: s,
                              useFahrenheit: useFahrenheit,
                              precise: precise)
                }
            }
        }
    }

    private var avgC: Double {
        guard !sensors.isEmpty else { return 0 }
        return sensors.map { $0.celsius }.reduce(0, +) / Double(sensors.count)
    }

    private func formatted(_ c: Double) -> String {
        let v = useFahrenheit ? (c * 9.0 / 5.0 + 32.0) : c
        let unit = useFahrenheit ? "°F" : "°C"
        return precise ? String(format: "%.1f %@", v, unit)
                       : String(format: "%.0f %@", v, unit)
    }
}

private struct SensorRow: View {
    let sensor: TempSensor
    let useFahrenheit: Bool
    let precise: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(sensor.name)
                .font(.system(size: 10))
                .foregroundColor(.mfcText)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text(sensor.formatted(useFahrenheit: useFahrenheit, precise: precise))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(colorForTemp(sensor.celsius))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.white.opacity(0.02))
        )
    }

    private func colorForTemp(_ c: Double) -> Color {
        switch c {
        case ..<45: return .mfcGreen
        case ..<65: return .mfcAmber
        case ..<80: return Color(red: 1.0, green: 0.5, blue: 0.2)
        default:    return .mfcRed
        }
    }
}

// MARK: - SensorKind labels

private extension SensorKind {
    var label: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .battery: return "Battery"
        case .storage: return "Storage"
        case .airport: return "AirPort / Wi-Fi"
        case .thunderbolt: return "Thunderbolt"
        case .proximity: return "Proximity"
        case .power: return "Power"
        case .trackpad: return "Trackpad"
        case .other: return "Other"
        }
    }
}

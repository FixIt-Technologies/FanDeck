//
//  FanDetailView.swift
//  MacsFanControl
//

import SwiftUI
import MacsFanControlCore

struct FanDetailView: View {
    let fan: Fan
    var onConfigure: () -> Void

    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                heroCard
                modeCard
                rangesCard
            }
            .padding(24)
        }
    }

    private var heroCard: some View {
        VStack(spacing: 18) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(fan.name)
                        .font(MFCFont.display(28))
                        .foregroundColor(.mfcText)
                    Text("Fan \(fan.id)")
                        .font(MFCFont.caption())
                        .foregroundColor(.mfcTextMuted)
                }
                Spacer()
                TagPill(text: fan.mode.displayName.uppercased(),
                        color: tagColor(for: fan.mode))
            }

            RPMGauge(fan: fan)

            HStack(spacing: 18) {
                MetricChip(label: "CURRENT", value: "\(fan.currentRPM)", suffix: "RPM",
                           color: fan.loadColor)
                MetricChip(label: "TARGET", value: "\(fan.targetRPM)", suffix: "RPM",
                           color: .mfcCyan)
                MetricChip(label: "LOAD",
                           value: String(format: "%.0f", fan.loadFraction * 100),
                           suffix: "%", color: .mfcAmber)
                Spacer()
                Button("Configure…", action: onConfigure)
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(24)
        .neonCard(accentColor: fan.loadColor)
    }

    private var modeCard: some View {
        SettingsCard(icon: "slider.horizontal.3", title: "ACTIVE MODE", accentColor: .mfcCyan) {
            switch fan.mode {
            case .auto:
                VStack(alignment: .leading, spacing: 4) {
                    SettingsInfoRow(label: "Mode", value: "Automatic (OS-managed)")
                    Text("macOS' built-in thermal policy is in charge. Configure to override.")
                        .font(MFCFont.caption())
                        .foregroundColor(.mfcTextMuted)
                        .padding(.top, 4)
                }
            case .constant(let rpm):
                SettingsInfoRow(label: "Mode", value: "Constant speed")
                SettingsInfoRow(label: "Target RPM", value: "\(rpm)")
            case .sensorBased(let sensorId, let low, let high):
                SettingsInfoRow(label: "Mode", value: "Sensor-based")
                SettingsInfoRow(label: "Sensor", value: appState.sensor(withID: sensorId)?.name ?? sensorId)
                SettingsInfoRow(label: "Start ramping at", value: String(format: "%.0f °C", low))
                SettingsInfoRow(label: "Full speed at", value: String(format: "%.0f °C", high))
            }
        }
    }

    private var rangesCard: some View {
        SettingsCard(icon: "ruler", title: "HARDWARE LIMITS", accentColor: .mfcPurple) {
            VStack(spacing: 4) {
                SettingsInfoRow(label: "Minimum RPM", value: "\(fan.minRPM)")
                SettingsInfoRow(label: "Maximum RPM", value: "\(fan.maxRPM)")
                SettingsInfoRow(label: "Throttle range",
                                value: "\(fan.maxRPM - fan.minRPM) RPM")
            }
        }
    }

    private func tagColor(for mode: FanMode) -> Color {
        switch mode {
        case .auto: return .mfcGreen
        case .constant: return .mfcAmber
        case .sensorBased: return .mfcCyan
        }
    }
}

// MARK: - RPM gauge

private struct RPMGauge: View {
    let fan: Fan

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.07))
                        .frame(height: 14)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    fan.loadColor.opacity(0.6),
                                    fan.loadColor,
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(8, geo.size.width * fan.loadFraction), height: 14)
                        .shadow(color: fan.loadColor.opacity(0.5), radius: 8)
                }
            }
            .frame(height: 14)
            HStack {
                Text("\(fan.minRPM) RPM")
                Spacer()
                Text("\(fan.maxRPM) RPM")
            }
            .font(MFCFont.caption())
            .foregroundColor(.mfcTextMuted)
        }
    }
}

// MARK: - Metric chip

struct MetricChip: View {
    let label: String
    let value: String
    let suffix: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.mfcTextMuted)
                .tracking(0.8)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .foregroundColor(color)
                Text(suffix)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.mfcTextSecondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.25))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(color.opacity(0.25), lineWidth: 1)
        )
    }
}

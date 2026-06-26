//
//  SensorDetailView.swift
//  MacsFanControl
//

import SwiftUI
import MacsFanControlCore

struct SensorDetailView: View {
    let sensor: TempSensor
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var appState: AppState

    @State private var history: [Double] = []
    private let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                heroCard
                propertiesCard
                fansLinkedCard
            }
            .padding(24)
        }
        .onAppear { history = [sensor.celsius] }
        .onReceive(timer) { _ in
            history.append(sensor.celsius)
            if history.count > 60 { history.removeFirst(history.count - 60) }
        }
    }

    private var heroCard: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: sensor.kind.sfSymbol)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(sensor.kind.accent)
                    .frame(width: 48, height: 48)
                    .background(sensor.kind.accent.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(sensor.name)
                        .font(MFCFont.headline(20))
                        .foregroundColor(.mfcText)
                    Text("Key \(sensor.id) · \(sensor.kind.rawValue.uppercased())")
                        .font(MFCFont.caption())
                        .foregroundColor(.mfcTextMuted)
                }
                Spacer()
                Text(sensor.formatted(useFahrenheit: settings.useFahrenheit,
                                      precise: settings.precise))
                    .font(.system(size: 32, weight: .semibold, design: .monospaced))
                    .foregroundColor(.mfcText)
            }
            SparklineView(values: history, color: sensor.kind.accent)
                .frame(height: 80)
        }
        .padding(20)
        .neonCard(accentColor: sensor.kind.accent)
    }

    private var propertiesCard: some View {
        SettingsCard(icon: "info.circle.fill", title: "PROPERTIES",
                     accentColor: sensor.kind.accent) {
            VStack(spacing: 2) {
                SettingsInfoRow(label: "SMC key", value: sensor.id)
                SettingsInfoRow(label: "Category", value: sensor.kind.rawValue.capitalized)
                SettingsInfoRow(
                    label: "Reading (°C)",
                    value: String(format: "%.2f °C", sensor.celsius)
                )
                SettingsInfoRow(
                    label: "Reading (°F)",
                    value: String(format: "%.2f °F", sensor.fahrenheit)
                )
            }
        }
    }

    private var fansLinkedCard: some View {
        let linked = appState.fans.filter {
            if case .sensorBased(let sid, _, _) = $0.mode { return sid == sensor.id }
            return false
        }
        return SettingsCard(icon: "fanblades.fill", title: "FANS DRIVEN BY THIS SENSOR",
                            accentColor: .mfcAmber) {
            if linked.isEmpty {
                Text("No fan is currently driven by this sensor.")
                    .font(MFCFont.caption(12))
                    .foregroundColor(.mfcTextMuted)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 2) {
                    ForEach(linked) { fan in
                        SettingsInfoRow(label: fan.name, value: "\(fan.currentRPM) RPM")
                    }
                }
            }
        }
    }
}

// MARK: - Sparkline

struct SparklineView: View {
    let values: [Double]
    var color: Color = .mfcAmber

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                guard values.count >= 2 else { return }
                let (minV, maxV) = bounds()
                let range = max(0.1, maxV - minV)
                let dx = size.width / CGFloat(max(1, values.count - 1))

                var path = Path()
                for (i, v) in values.enumerated() {
                    let x = CGFloat(i) * dx
                    let y = size.height - (CGFloat((v - minV) / range)) * size.height
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
                context.stroke(path, with: .color(color), lineWidth: 2)

                // Filled area below the line
                var fill = path
                fill.addLine(to: CGPoint(x: size.width, y: size.height))
                fill.addLine(to: CGPoint(x: 0, y: size.height))
                fill.closeSubpath()
                context.fill(fill, with: .linearGradient(
                    Gradient(colors: [color.opacity(0.35), color.opacity(0.0)]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: 0, y: size.height)
                ))
            }
            .overlay(alignment: .topLeading) {
                if let last = values.last {
                    Text(String(format: "%.1f °C", last))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.mfcTextSecondary)
                        .padding(6)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.black.opacity(0.4))
                        )
                        .padding(4)
                }
            }
        }
    }

    private func bounds() -> (Double, Double) {
        guard let lo = values.min(), let hi = values.max() else { return (0, 1) }
        let pad = max(0.5, (hi - lo) * 0.1)
        return (lo - pad, hi + pad)
    }
}

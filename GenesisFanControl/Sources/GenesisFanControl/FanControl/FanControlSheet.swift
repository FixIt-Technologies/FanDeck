//
//  FanControlSheet.swift
//  GenesisFanControl
//
//  Configure a single fan: Automatic / Constant RPM / Sensor-controlled.
//  Mirrors functionality from screenshots 4-5 (Czech: "Konstantní otáčky"
//  vs "Hodnoty ovládá senzor" with low + high temperature thresholds)
//  with a modernized layout.
//

import SwiftUI
import Charts
import GenesisFanControlCore

struct FanControlSheet: View {
    let fan: Fan
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var mode: ModeChoice
    @State private var constantRPM: Double
    @State private var sensorID: String
    @State private var lowTempC: Double
    @State private var highTempC: Double

    enum ModeChoice: String, CaseIterable, Identifiable {
        case auto, constant, sensor
        var id: String { rawValue }
        var label: String {
            switch self {
            case .auto: return "Automatic (OS-managed)"
            case .constant: return "Constant speed"
            case .sensor: return "Sensor-based"
            }
        }
        var subtitle: String {
            switch self {
            case .auto: return "Let macOS manage RPM via its built-in thermal policy"
            case .constant: return "Hold a fixed RPM regardless of temperature"
            case .sensor: return "Ramp linearly from min → max RPM between two temperatures"
            }
        }
    }

    init(fan: Fan) {
        self.fan = fan
        // Defaults for sensor-based mode when the fan is in auto/constant.
        // Lookup order: this fan's saved config → any sibling fan's saved
        // config (so the second fan inherits from the first) → hard-coded
        // 45/85 fallback. The picked sensor falls back to the first
        // available aggregate / CPU sensor at the call site if "TC0E"
        // (Intel) isn't present on Apple Silicon.
        let saved = SettingsStore.shared.sensorRampConfig(for: fan.id)
        let defaultSensor = saved?.sensorId ?? "__cpu_all_max"
        let defaultLow = saved?.lowTempC ?? 45
        let defaultHigh = saved?.highTempC ?? 85
        switch fan.mode {
        case .auto:
            self._mode = State(initialValue: .auto)
            self._constantRPM = State(initialValue: Double(fan.minRPM))
            self._sensorID = State(initialValue: defaultSensor)
            self._lowTempC = State(initialValue: defaultLow)
            self._highTempC = State(initialValue: defaultHigh)
        case .constant(let rpm):
            self._mode = State(initialValue: .constant)
            self._constantRPM = State(initialValue: Double(rpm))
            self._sensorID = State(initialValue: defaultSensor)
            self._lowTempC = State(initialValue: defaultLow)
            self._highTempC = State(initialValue: defaultHigh)
        case .sensorBased(let sid, let low, let high):
            self._mode = State(initialValue: .sensor)
            self._constantRPM = State(initialValue: Double(fan.minRPM))
            self._sensorID = State(initialValue: sid)
            self._lowTempC = State(initialValue: low)
            self._highTempC = State(initialValue: high)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.08))
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    modeChoiceCard
                    if mode == .constant { constantCard }
                    if mode == .sensor { sensorCard }
                    livePreviewCard
                }
                .padding(20)
            }
            Divider().overlay(Color.white.opacity(0.08))
            footer
        }
        .frame(width: 560, height: 540)
        .background(
            ZStack {
                Color.gfcBackground
                CyberpunkGrid().opacity(0.3)
            }
            .ignoresSafeArea()
        )
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(fan.loadColor.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: "fanblades.fill")
                    .font(.system(size: 22))
                    .foregroundColor(fan.loadColor)
                    .pulseGlow(color: fan.loadColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Configure fan: \(fan.name)")
                    .font(GFCFont.headline(15))
                    .foregroundColor(.gfcText)
                Text("\(fan.id) · range \(fan.minRPM)–\(fan.maxRPM) RPM")
                    .font(GFCFont.caption())
                    .foregroundColor(.gfcTextMuted)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.gfcSidebar.opacity(0.6))
    }

    // MARK: - Mode picker

    private var modeChoiceCard: some View {
        SettingsCard(icon: "slider.horizontal.3", title: "FAN CONTROL MODE", accentColor: .gfcAmber) {
            VStack(spacing: 8) {
                ForEach(ModeChoice.allCases) { choice in
                    ModeRadioRow(
                        choice: choice,
                        isSelected: mode == choice,
                        action: { withAnimation(GFCAnimation.standard) { mode = choice } }
                    )
                }
            }
        }
    }

    // MARK: - Constant RPM card

    private var constantCard: some View {
        SettingsCard(icon: "gauge.with.dots.needle.bottom.50percent",
                     title: "TARGET RPM", accentColor: .gfcAmber) {
            VStack(alignment: .leading, spacing: 10) {
                NeonSlider(
                    value: $constantRPM,
                    range: Double(fan.minRPM)...Double(fan.maxRPM),
                    accent: .gfcAmber,
                    trailing: { "\(Int($0)) RPM" }
                )
                HStack {
                    Text("Min: \(fan.minRPM)")
                    Spacer()
                    Text("Max: \(fan.maxRPM)")
                }
                .font(GFCFont.caption())
                .foregroundColor(.gfcTextMuted)
            }
        }
    }

    // MARK: - Sensor card

    private var sensorCard: some View {
        SettingsCard(icon: "thermometer.medium", title: "SENSOR & THRESHOLDS",
                     accentColor: .gfcCyan) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Text("Sensor:")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.gfcText)
                    // Menu (not Picker) — macOS Picker's pop-up renders each
                    // entry through NSMenuItem.title (plain text), so any
                    // HStack/Spacer/secondary Text inside the ForEach gets
                    // collapsed to the leading label only. Menu+Button keeps
                    // the SwiftUI hierarchy intact so we can show the live
                    // temperature on the right of each row.
                    Menu {
                        ForEach(appState.sensors) { s in
                            Button {
                                sensorID = s.id
                            } label: {
                                let temp = s.formatted(useFahrenheit: settings.useFahrenheit, precise: false)
                                HStack(spacing: 8) {
                                    Image(systemName: s.kind.sfSymbol)
                                    Text(s.name)
                                    Spacer(minLength: 12)
                                    Text(temp)
                                        .monospacedDigit()
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if let cur = appState.sensor(withID: sensorID) {
                                Image(systemName: cur.kind.sfSymbol)
                                Text(cur.name)
                                Spacer(minLength: 12)
                                Text(cur.formatted(useFahrenheit: settings.useFahrenheit, precise: false))
                                    .monospacedDigit()
                                    .foregroundColor(.secondary)
                            } else {
                                Text("Choose sensor…").foregroundColor(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .menuStyle(.borderlessButton)
                    .frame(maxWidth: 360)
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Start ramping at:")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.gfcText)
                        Spacer()
                        StepperRow(value: $lowTempC, range: 0...120, step: 1, suffix: "°C")
                    }
                    NeonSlider(
                        value: $lowTempC,
                        range: 20...100,
                        accent: .gfcGreen,
                        trailing: { String(format: "%.0f °C", $0) }
                    )
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Reach full speed at:")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.gfcText)
                        Spacer()
                        StepperRow(value: $highTempC, range: 0...120, step: 1, suffix: "°C")
                    }
                    NeonSlider(
                        value: $highTempC,
                        range: 20...110,
                        accent: .gfcRed,
                        trailing: { String(format: "%.0f °C", $0) }
                    )
                }
            }
        }
    }

    // MARK: - Live preview

    private var livePreviewCard: some View {
        let preview = computedTargetRPM()
        return SettingsCard(icon: "waveform.path.ecg", title: "LIVE PREVIEW",
                            accentColor: .gfcGreen) {
            VStack(alignment: .leading, spacing: 12) {
                SettingsInfoRow(label: "Current sensor reading",
                                value: currentSensorReading())
                SettingsInfoRow(label: "Projected target RPM",
                                value: "\(preview) RPM",
                                valueColor: .gfcAmber)
                SettingsInfoRow(label: "Currently reported",
                                value: "\(fan.currentRPM) RPM")
                // Sensor-mode ramp curve. The dot marks the live sensor
                // reading + the RPM the curve maps it to.
                if mode == .sensor {
                    rampGraph
                        .padding(.top, 6)
                }
            }
        }
    }

    private var rampGraph: some View {
        let live = appState.sensor(withID: sensorID)
        let currentTemp = live?.celsius ?? lowTempC
        let projected = computedTargetRPM()
        let xMin = max(0.0, min(lowTempC - 10, 20))
        let xMax = max(highTempC + 10, 110)

        // Anchor points of the piecewise-linear ramp: clamp before low,
        // ramp between low and high, clamp after high.
        let curve: [(temp: Double, rpm: Int)] = [
            (xMin,        fan.minRPM),
            (lowTempC,    fan.minRPM),
            (highTempC,   fan.maxRPM),
            (xMax,        fan.maxRPM),
        ]

        return Chart {
            // Filled area under the ramp for visual mass
            ForEach(curve.indices, id: \.self) { i in
                AreaMark(
                    x: .value("Temp", curve[i].temp),
                    y: .value("RPM", curve[i].rpm)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.gfcCyan.opacity(0.45), Color.gfcCyan.opacity(0.05)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .interpolationMethod(.linear)
            }
            // The ramp line itself
            ForEach(curve.indices, id: \.self) { i in
                LineMark(
                    x: .value("Temp", curve[i].temp),
                    y: .value("RPM", curve[i].rpm)
                )
                .foregroundStyle(Color.gfcCyan)
                .lineStyle(StrokeStyle(lineWidth: 2))
                .interpolationMethod(.linear)
            }
            // Anchor handles — the two user-controllable thresholds
            PointMark(
                x: .value("Temp", lowTempC),
                y: .value("RPM", fan.minRPM)
            )
            .foregroundStyle(Color.gfcGreen)
            .symbolSize(80)
            .annotation(position: .top, alignment: .center) {
                Text("\(Int(lowTempC))°")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.gfcGreen)
            }
            PointMark(
                x: .value("Temp", highTempC),
                y: .value("RPM", fan.maxRPM)
            )
            .foregroundStyle(Color.gfcRed)
            .symbolSize(80)
            .annotation(position: .top, alignment: .center) {
                Text("\(Int(highTempC))°")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.gfcRed)
            }
            // Live cursor — current temp on the curve.
            RuleMark(x: .value("Now", currentTemp))
                .foregroundStyle(Color.gfcAmber.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            PointMark(
                x: .value("Temp", currentTemp),
                y: .value("RPM", projected)
            )
            .foregroundStyle(Color.gfcAmber)
            .symbolSize(140)
            .annotation(position: .topTrailing, alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(String(format: "%.1f °C", currentTemp))
                    Text("→ \(projected) RPM")
                }
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(.gfcAmber)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.black.opacity(0.55))
                )
            }
        }
        .chartXScale(domain: xMin...xMax)
        .chartYScale(domain: 0...fan.maxRPM)
        .chartXAxis {
            AxisMarks(values: .stride(by: 20)) { value in
                AxisGridLine().foregroundStyle(Color.white.opacity(0.06))
                AxisTick().foregroundStyle(Color.white.opacity(0.15))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text("\(Int(v))°")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.gfcTextMuted)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(Color.white.opacity(0.06))
                AxisValueLabel {
                    if let v = value.as(Int.self) {
                        Text("\(v)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.gfcTextMuted)
                    }
                }
            }
        }
        .frame(height: 160)
    }

    // MARK: - Footer (Cancel / Apply)

    private var footer: some View {
        HStack {
            if case .sensorBased = applyMode() {
                Label("Sensor mode bypasses macOS thermal policy — verify cooling.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(GFCFont.caption())
                    .foregroundColor(.gfcAmber)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button("Apply") {
                // Persist the sensor-based config whenever the user has
                // touched it — even if the active mode they're applying is
                // constant or auto. That way switching back to sensor-based
                // later restores exactly what they had configured.
                settings.saveSensorRampConfig(
                    SensorRampConfig(sensorId: sensorID,
                                     lowTempC: lowTempC,
                                     highTempC: highTempC),
                    for: fan.id)
                appState.setMode(applyMode(), for: fan.id)
                dismiss()
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.gfcSidebar.opacity(0.6))
    }

    // MARK: - Helpers

    private func applyMode() -> FanMode {
        switch mode {
        case .auto: return .auto
        case .constant: return .constant(rpm: Int(constantRPM.rounded()))
        case .sensor:
            return .sensorBased(
                sensorId: sensorID,
                lowTempC: lowTempC,
                highTempC: max(highTempC, lowTempC + 1)
            )
        }
    }

    private func currentSensorReading() -> String {
        guard let s = appState.sensor(withID: sensorID) else { return "—" }
        return s.formatted(useFahrenheit: settings.useFahrenheit, precise: settings.precise)
    }

    private func computedTargetRPM() -> Int {
        switch applyMode() {
        case .auto:
            return fan.currentRPM
        case .constant(let rpm):
            return rpm
        case .sensorBased(let sid, let low, let high):
            let temp = appState.sensor(withID: sid)?.celsius ?? 0
            guard high > low else { return fan.minRPM }
            let t = max(0, min(1, (temp - low) / (high - low)))
            return fan.minRPM + Int(t * Double(fan.maxRPM - fan.minRPM))
        }
    }
}

// MARK: - Mode radio row

private struct ModeRadioRow: View {
    let choice: FanControlSheet.ModeChoice
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .stroke(isSelected ? Color.gfcAmber : Color.white.opacity(0.3), lineWidth: 1.5)
                        .frame(width: 18, height: 18)
                    if isSelected {
                        Circle()
                            .fill(Color.gfcAmber)
                            .frame(width: 10, height: 10)
                            .shadow(color: .gfcAmber, radius: 5)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(choice.label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.gfcText)
                    Text(choice.subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.gfcTextMuted)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.gfcAmber.opacity(0.10) :
                          (isHovered ? Color.white.opacity(0.04) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.gfcAmber.opacity(0.3) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering }
        }
    }
}

// MARK: - Numeric stepper

private struct StepperRow: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let suffix: String

    var body: some View {
        HStack(spacing: 4) {
            Text(String(format: "%.0f", value))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(.gfcText)
                .frame(minWidth: 36, alignment: .trailing)
            Text(suffix)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.gfcTextMuted)
            Stepper("", value: $value, in: range, step: step)
                .labelsHidden()
        }
    }
}

#Preview {
    FanControlSheet(fan: Fan(id: "F0", name: "Left side", minRPM: 1200, maxRPM: 5800,
                             currentRPM: 2400, targetRPM: 2400,
                             mode: .sensorBased(sensorId: "TC0E", lowTempC: 45, highTempC: 80)))
        .environmentObject(AppState.shared)
        .environmentObject(SettingsStore.shared)
}

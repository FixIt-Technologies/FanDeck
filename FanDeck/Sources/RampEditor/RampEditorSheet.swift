//
//  RampEditorSheet.swift
//  FanDeck
//
//  Per-fan configuration sheet — full parity with the original
//  FanControlSheet (decision D5): Automatic / Constant / Sensor-based
//  with the draggable N-point ramp curve (drag points, double-click to
//  add, right-click to delete, live sensor cursor), sensor picker with
//  live temperatures, per-fan config persistence, Apply to all.
//
//  PERFORMANCE REFACTOR (the D5 audit) — what changed vs. the original:
//   1. The Swift Charts curve is extracted into `RampChartView`, an
//      Equatable view receiving only VALUE inputs (points, domain,
//      liveTemp quantized to 0.5 °C, projected RPM). The original
//      rebuilt the whole Chart — marks, axes, overlay — on every 1 Hz
//      AppState tick because the sheet observed appState directly in
//      the chart builder. Now a tick that moves the sensor < 0.5 °C
//      re-renders NOTHING, and a moving sensor re-renders only the
//      chart, not the whole sheet's card stack.
//   2. Drag updates are quantized (0.5 °C / 25 RPM) before mutating
//      `points`, collapsing ~60 Hz cursor noise into a handful of real
//      state changes per second (the original wrote unquantized Doubles
//      on every pixel of cursor travel — each one a full Chart rebuild).
//   3. Handle positions are computed from the chart proxy once per
//      points-change, not per drag event, because the quantized points
//      array is the single source of truth.
//

import SwiftUI
import Charts
import GenesisFanControlCore

struct RampEditorSheet: View {
    let fanID: String
    let initialFan: Fan

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var mode: ModeChoice
    @State private var constantRPM: Double
    @State private var sensorID: String
    @State private var points: [RampPoint]

    private var fan: Fan { appState.fan(withID: fanID) ?? initialFan }

    enum ModeChoice: String, CaseIterable, Identifiable {
        case auto, constant, sensor
        var id: String { rawValue }
        var label: String {
            switch self {
            case .auto: return "Automatic"
            case .constant: return "Constant"
            case .sensor: return "Sensor curve"
            }
        }
    }

    init(fan: Fan) {
        self.fanID = fan.id
        self.initialFan = fan
        let saved = SettingsStore.shared.sensorRampConfig(for: fan.id)
        let defaultSensor = saved?.sensorId ?? "__cpu_all_max"
        let defaultPoints: [RampPoint] = saved?.points ?? [
            RampPoint(tempC: 45, rpm: fan.minRPM),
            RampPoint(tempC: 85, rpm: fan.maxRPM),
        ]
        switch fan.mode {
        case .auto:
            _mode = State(initialValue: .auto)
            _constantRPM = State(initialValue: Double(fan.minRPM))
            _sensorID = State(initialValue: defaultSensor)
            _points = State(initialValue: defaultPoints)
        case .constant(let rpm):
            _mode = State(initialValue: .constant)
            _constantRPM = State(initialValue: Double(rpm))
            _sensorID = State(initialValue: defaultSensor)
            _points = State(initialValue: defaultPoints)
        case .sensorBased(let sid, let pts):
            _mode = State(initialValue: .sensor)
            _constantRPM = State(initialValue: Double(fan.minRPM))
            _sensorID = State(initialValue: sid)
            _points = State(initialValue: pts.sorted(by: { $0.tempC < $1.tempC }))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    modePicker
                    if mode == .constant { constantCard }
                    if mode == .sensor { sensorCard }
                    livePreviewCard
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 540, height: mode == .sensor ? 560 : 380)
        .background(.regularMaterial)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "fanblades.fill")
                .font(.system(size: 20))
                .foregroundStyle(FD.modeAccent(fan.mode))
            VStack(alignment: .leading, spacing: 1) {
                Text("Configure \(fan.name)")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(fan.id) · range \(fan.minRPM)–\(fan.maxRPM) RPM")
                    .font(.system(size: 10))
                    .foregroundStyle(FD.secondaryText)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Mode picker

    private var modePicker: some View {
        Picker("Mode", selection: $mode.animation(.easeInOut(duration: 0.2))) {
            ForEach(ModeChoice.allCases) { c in
                Text(c.label).tag(c)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    // MARK: - Constant

    private var constantCard: some View {
        FDCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Target")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Text("\(Int(constantRPM)) RPM")
                        .font(.system(size: 12, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(FD.amber)
                }
                Slider(value: $constantRPM,
                       in: Double(fan.minRPM)...Double(fan.maxRPM),
                       step: 50)
                    .tint(FD.amber)
                HStack {
                    Text("Min \(fan.minRPM)")
                    Spacer()
                    Text("Max \(fan.maxRPM)")
                }
                .font(.system(size: 9.5))
                .foregroundStyle(FD.tertiaryText)
            }
        }
    }

    // MARK: - Sensor mode

    private var sensorCard: some View {
        FDCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Sensor")
                        .font(.system(size: 11, weight: .semibold))
                    // Menu, not Picker — NSMenuItem collapses a multi-Text
                    // label to its first Text, so the live temperature is
                    // concatenated into the title string.
                    Menu {
                        ForEach(appState.sensors) { s in
                            Button {
                                sensorID = s.id
                            } label: {
                                let temp = s.formatted(useFahrenheit: settings.useFahrenheit, precise: false)
                                Label("\(s.name)   ·   \(temp)", systemImage: s.kind.sfSymbol)
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if let cur = appState.sensor(withID: sensorID) {
                                Image(systemName: cur.kind.sfSymbol)
                                Text(cur.name)
                                Spacer(minLength: 10)
                                Text(cur.formatted(useFahrenheit: settings.useFahrenheit, precise: false))
                                    .monospacedDigit()
                                    .foregroundStyle(FD.secondaryText)
                            } else {
                                Text("Choose sensor…").foregroundStyle(FD.secondaryText)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .menuStyle(.borderlessButton)
                }

                RampPointRows(points: $points, minRPM: fan.minRPM, maxRPM: fan.maxRPM)

                RampChartContainer(points: $points,
                                   minRPM: fan.minRPM, maxRPM: fan.maxRPM,
                                   liveTemp: quantizedLiveTemp,
                                   projected: computedTargetRPM())
                    .frame(height: 190)
            }
        }
    }

    /// Live sensor reading quantized to 0.5 °C — the chart's equality key.
    /// Sub-half-degree jitter therefore re-renders nothing (perf refactor #1).
    private var quantizedLiveTemp: Double {
        let t = appState.sensor(withID: sensorID)?.celsius ?? points.first?.tempC ?? 45
        return (t * 2).rounded() / 2
    }

    // MARK: - Live preview

    private var livePreviewCard: some View {
        FDCard {
            VStack(alignment: .leading, spacing: 6) {
                previewRow("Current sensor",
                           value: appState.sensor(withID: sensorID)?
                               .formatted(useFahrenheit: settings.useFahrenheit,
                                          precise: settings.precise) ?? "—")
                previewRow("Projected target", value: "\(computedTargetRPM()) RPM", accent: FD.amber)
                previewRow("Currently reported", value: "\(fan.currentRPM) RPM")
            }
        }
    }

    private func previewRow(_ label: String, value: String, accent: Color = .primary) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(FD.secondaryText)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(accent)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if mode == .sensor {
                Label("Sensor mode bypasses macOS thermal policy.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(FD.amber)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            if appState.fans.count > 1 {
                Button("Apply to all") { apply(toAll: true) }
                    .help("Apply this mode to every fan")
            }
            Button("Apply") { apply(toAll: false) }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(FD.amber)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func apply(toAll: Bool) {
        let sortedPts = points.sorted(by: { $0.tempC < $1.tempC })
        let targets: [Fan] = toAll ? appState.fans : [fan]
        for f in targets {
            settings.saveSensorRampConfig(
                SensorRampConfig(sensorId: sensorID, points: sortedPts),
                for: f.id)
            appState.setMode(applyMode(for: f), for: f.id)
        }
        dismiss()
    }

    private func applyMode(for target: Fan) -> FanMode {
        switch mode {
        case .auto:
            return .auto
        case .constant:
            let rpm = max(target.minRPM, min(target.maxRPM, Int(constantRPM.rounded())))
            return .constant(rpm: rpm)
        case .sensor:
            let pts = points
                .sorted(by: { $0.tempC < $1.tempC })
                .map { RampPoint(tempC: $0.tempC,
                                 rpm: max(target.minRPM, min(target.maxRPM, $0.rpm))) }
            return .sensorBased(sensorId: sensorID, points: pts)
        }
    }

    private func computedTargetRPM() -> Int {
        switch mode {
        case .auto:
            return fan.currentRPM
        case .constant:
            return Int(constantRPM.rounded())
        case .sensor:
            return RampMath.interpolate(tempC: quantizedLiveTemp, points: points,
                                        minRPM: fan.minRPM, maxRPM: fan.maxRPM)
        }
    }
}

// MARK: - Ramp math (shared by preview + chart)

enum RampMath {
    /// Piecewise-linear interpolation, mirroring
    /// AppleSMCService.rpmForTemp: clamp outside the endpoints, lerp
    /// between consecutive points, clamp into [minRPM, maxRPM].
    static func interpolate(tempC c: Double, points: [RampPoint],
                            minRPM: Int, maxRPM: Int) -> Int {
        func clamp(_ r: Int) -> Int { max(minRPM, min(maxRPM, r)) }
        let sorted = points.sorted(by: { $0.tempC < $1.tempC })
        guard let first = sorted.first else { return minRPM }
        guard sorted.count >= 2 else { return clamp(first.rpm) }
        if c <= first.tempC { return clamp(first.rpm) }
        if c >= sorted.last!.tempC { return clamp(sorted.last!.rpm) }
        for i in 0..<(sorted.count - 1) {
            let a = sorted[i], b = sorted[i + 1]
            if c >= a.tempC && c <= b.tempC {
                let span = b.tempC - a.tempC
                guard span > 0 else { return clamp(a.rpm) }
                let t = (c - a.tempC) / span
                return clamp(Int((Double(a.rpm) + t * Double(b.rpm - a.rpm)).rounded()))
            }
        }
        return clamp(sorted.last!.rpm)
    }
}

// MARK: - Point rows (numeric editing)

struct RampPointRows: View {
    @Binding var points: [RampPoint]
    let minRPM: Int
    let maxRPM: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Ramp points")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Button {
                    addPoint()
                } label: {
                    Label("Add point", systemImage: "plus.circle.fill")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(FD.cyan)
            }
            ForEach(points.indices, id: \.self) { i in
                row(index: i)
            }
            Text("Drag the dots on the curve, double-click to add, right-click to delete.")
                .font(.system(size: 9))
                .foregroundStyle(FD.tertiaryText)
        }
    }

    @ViewBuilder
    private func row(index i: Int) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(RampChartContainer.pointColor(index: i, count: points.count))
                .frame(width: 8, height: 8)
            Text("at")
                .font(.system(size: 10))
                .foregroundStyle(FD.tertiaryText)
            Text("\(Int(points[i].tempC)) °C")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .frame(minWidth: 46, alignment: .trailing)
            Stepper("", value: tempBinding(i), in: 0...120, step: 1)
                .labelsHidden()
            Text("→")
                .font(.system(size: 10))
                .foregroundStyle(FD.tertiaryText)
            Text("\(points[i].rpm) RPM")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .frame(minWidth: 64, alignment: .trailing)
            Stepper("", value: rpmBinding(i), in: minRPM...maxRPM, step: 50)
                .labelsHidden()
            Spacer()
            Button {
                guard points.count > 2, i < points.count else { return }
                points.remove(at: i)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                    .foregroundStyle(points.count > 2 ? Color(nsColor: .systemRed) : FD.tertiaryText)
            }
            .buttonStyle(.plain)
            .disabled(points.count <= 2)
        }
    }

    private func tempBinding(_ i: Int) -> Binding<Double> {
        Binding(
            get: { points.indices.contains(i) ? points[i].tempC : 0 },
            set: { v in
                guard points.indices.contains(i) else { return }
                points[i].tempC = v
                points.sort(by: { $0.tempC < $1.tempC })
            }
        )
    }

    private func rpmBinding(_ i: Int) -> Binding<Int> {
        Binding(
            get: { points.indices.contains(i) ? points[i].rpm : minRPM },
            set: { v in
                guard points.indices.contains(i) else { return }
                points[i].rpm = max(minRPM, min(maxRPM, v))
            }
        )
    }

    private func addPoint() {
        let last = points.last ?? RampPoint(tempC: 85, rpm: maxRPM)
        let prev = points.dropLast().last ?? RampPoint(tempC: 45, rpm: minRPM)
        points.append(RampPoint(tempC: (prev.tempC + last.tempC) / 2,
                                rpm: (prev.rpm + last.rpm) / 2))
        points.sort(by: { $0.tempC < $1.tempC })
    }
}

// MARK: - Chart container (interaction) + Equatable chart (rendering)

/// Owns the drag / double-click-add / right-click-delete interaction and
/// feeds the pure `RampChartView` underneath. Handles quantize their drag
/// to 0.5 °C / 25 RPM BEFORE touching `points` (perf refactor #2).
struct RampChartContainer: View {
    @Binding var points: [RampPoint]
    let minRPM: Int
    let maxRPM: Int
    let liveTemp: Double
    let projected: Int

    private static let plotSpace = "fdRampPlot"

    static func pointColor(index: Int, count: Int) -> Color {
        if index == 0 { return FD.green }
        if index == count - 1 { return Color(nsColor: .systemRed) }
        return FD.cyan
    }

    private var xMin: Double {
        let lo = points.first?.tempC ?? 45
        return max(0.0, min(lo - 10, 20))
    }
    private var xMax: Double {
        let hi = points.last?.tempC ?? 85
        return max(hi + 10, 110)
    }

    var body: some View {
        RampChartView(points: points, xMin: xMin, xMax: xMax, yMax: maxRPM,
                      liveTemp: liveTemp, projected: projected)
            .equatable()
            .chartOverlay { proxy in
                GeometryReader { geo in
                    if let plot = proxy.plotFrame {
                        let frame = geo[plot]
                        ZStack {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { loc in
                                    addPoint(at: loc, proxy: proxy, frame: frame)
                                }
                            ForEach(points.indices, id: \.self) { i in
                                handle(at: i, proxy: proxy, frame: frame)
                            }
                        }
                        .coordinateSpace(name: Self.plotSpace)
                    }
                }
            }
    }

    @ViewBuilder
    private func handle(at i: Int, proxy: ChartProxy, frame: CGRect) -> some View {
        if points.indices.contains(i),
           let posX = proxy.position(forX: points[i].tempC),
           let posY = proxy.position(forY: points[i].rpm) {
            let color = Self.pointColor(index: i, count: points.count)
            ZStack {
                Circle().fill(color.opacity(0.22)).frame(width: 24, height: 24)
                Circle().fill(color).frame(width: 12, height: 12)
                    .shadow(color: color.opacity(0.8), radius: 3)
            }
            .frame(width: 40, height: 40)
            .contentShape(Circle())
            .gesture(dragGesture(forPointAt: i, proxy: proxy, frame: frame))
            .position(x: posX + frame.minX, y: posY + frame.minY)
            .contextMenu {
                if points.count > 2 {
                    Button(role: .destructive) {
                        points.remove(at: i)
                    } label: {
                        Label("Delete point", systemImage: "trash")
                    }
                }
            }
        }
    }

    private func dragGesture(forPointAt i: Int, proxy: ChartProxy, frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.plotSpace))
            .onChanged { drag in
                guard points.indices.contains(i) else { return }
                let inChartX = drag.location.x - frame.minX
                let inChartY = drag.location.y - frame.minY
                guard let tempC: Double = proxy.value(atX: inChartX, as: Double.self),
                      let rpm: Int = proxy.value(atY: inChartY, as: Int.self) else { return }
                // Quantize BEFORE mutating state — sub-step cursor travel
                // produces zero state changes and zero chart rebuilds.
                var newT = ((max(0, min(120, tempC))) * 2).rounded() / 2
                if i > 0 { newT = max(newT, points[i - 1].tempC + 1) }
                if i < points.count - 1 { newT = min(newT, points[i + 1].tempC - 1) }
                let newR = max(minRPM, min(maxRPM, Int((Double(rpm) / 25).rounded()) * 25))
                if points[i].tempC != newT || points[i].rpm != newR {
                    points[i].tempC = newT
                    points[i].rpm = newR
                }
            }
    }

    private func addPoint(at location: CGPoint, proxy: ChartProxy, frame: CGRect) {
        let inChartX = location.x - frame.minX
        let inChartY = location.y - frame.minY
        guard let tempC: Double = proxy.value(atX: inChartX, as: Double.self),
              let rpm: Int = proxy.value(atY: inChartY, as: Int.self) else { return }
        points.append(RampPoint(
            tempC: (max(0, min(120, tempC)) * 2).rounded() / 2,
            rpm: max(minRPM, min(maxRPM, Int((Double(rpm) / 25).rounded()) * 25))
        ))
        points.sort(by: { $0.tempC < $1.tempC })
    }
}

/// Pure rendering of the ramp curve — Equatable so identical inputs skip
/// the (expensive) Chart rebuild entirely (perf refactor #1).
struct RampChartView: View, Equatable {
    let points: [RampPoint]
    let xMin: Double
    let xMax: Double
    let yMax: Int
    let liveTemp: Double
    let projected: Int

    var body: some View {
        // Clamped curve: hold first.rpm before first.tempC, lerp between,
        // hold last.rpm after last.tempC.
        var curve: [(temp: Double, rpm: Int)] = []
        if let first = points.first { curve.append((xMin, first.rpm)) }
        for p in points { curve.append((p.tempC, p.rpm)) }
        if let last = points.last { curve.append((xMax, last.rpm)) }

        return Chart {
            ForEach(curve.indices, id: \.self) { i in
                AreaMark(x: .value("Temp", curve[i].temp),
                         y: .value("RPM", curve[i].rpm))
                    .foregroundStyle(
                        LinearGradient(colors: [FD.cyan.opacity(0.35), FD.cyan.opacity(0.03)],
                                       startPoint: .top, endPoint: .bottom)
                    )
                    .interpolationMethod(.linear)
            }
            ForEach(curve.indices, id: \.self) { i in
                LineMark(x: .value("Temp", curve[i].temp),
                         y: .value("RPM", curve[i].rpm))
                    .foregroundStyle(FD.cyan)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.linear)
            }
            RuleMark(x: .value("Now", liveTemp))
                .foregroundStyle(FD.amber.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            PointMark(x: .value("Temp", liveTemp), y: .value("RPM", projected))
                .foregroundStyle(FD.amber)
                .symbolSize(100)
                .annotation(position: .topTrailing, alignment: .leading, spacing: 4) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(String(format: "%.1f °C", liveTemp))
                        Text("→ \(projected) RPM")
                    }
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(FD.amber)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 3).fill(FD.card))
                }
        }
        .chartXScale(domain: xMin...xMax)
        .chartYScale(domain: 0...yMax)
        .chartXAxis {
            AxisMarks(values: .stride(by: 20)) { value in
                AxisGridLine().foregroundStyle(FD.separator.opacity(0.4))
                AxisTick().foregroundStyle(FD.separator)
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text("\(Int(v))°")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(FD.tertiaryText)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(FD.separator.opacity(0.4))
                AxisValueLabel {
                    if let v = value.as(Int.self) {
                        Text("\(v)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(FD.tertiaryText)
                    }
                }
            }
        }
    }
}

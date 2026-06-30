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
    /// Captured at sheet construction so the editor can survive a fan
    /// being momentarily absent from `appState.fans`. The LIVE fan
    /// data (currentRPM, mode after this user's apply, sensor readings)
    /// is resolved by ID every body pass via `liveFan`. Capturing the
    /// struct here would freeze it — the gauge's "Currently reported"
    /// line and the live-cursor on the chart would never move.
    let fanID: String
    /// Snapshot of the fan at open time — used ONLY for static metadata
    /// (name, minRPM, maxRPM, initial mode for state seeding) and as a
    /// fallback if the fan disappears mid-edit.
    let initialFan: Fan

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var mode: ModeChoice
    @State private var constantRPM: Double
    @State private var sensorID: String
    /// N-point ramp curve (N >= 2). Kept sorted-by-tempC at all times so
    /// the chart + interpolation don't have to re-sort on every read.
    @State private var points: [RampPoint]

    /// Live fan data, refreshed every body pass. Falls back to the
    /// snapshot captured at open time if the polling tick momentarily
    /// drops the fan out of the published list (rare — sensor probe
    /// failure etc.). All read-only — user edits stay in @State above.
    private var fan: Fan { appState.fan(withID: fanID) ?? initialFan }

    /// Name for the ramp-chart overlay coordinate space so draggable
    /// handles report a location independent of their .position offset.
    private let rampPlotSpace = "gfcRampPlot"

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
        self.fanID = fan.id
        self.initialFan = fan
        // Defaults for sensor-based mode when the fan is in auto/constant.
        // Lookup order: this fan's saved config → any sibling fan's saved
        // config (so the second fan inherits from the first) → 2-point
        // 45/85 fallback mapped to the fan's actual min/max RPM.
        let saved = SettingsStore.shared.sensorRampConfig(for: fan.id)
        let defaultSensor = saved?.sensorId ?? "__cpu_all_max"
        let defaultPoints: [RampPoint] = saved?.points ?? [
            RampPoint(tempC: 45, rpm: fan.minRPM),
            RampPoint(tempC: 85, rpm: fan.maxRPM),
        ]
        switch fan.mode {
        case .auto:
            self._mode = State(initialValue: .auto)
            self._constantRPM = State(initialValue: Double(fan.minRPM))
            self._sensorID = State(initialValue: defaultSensor)
            self._points = State(initialValue: defaultPoints)
        case .constant(let rpm):
            self._mode = State(initialValue: .constant)
            self._constantRPM = State(initialValue: Double(rpm))
            self._sensorID = State(initialValue: defaultSensor)
            self._points = State(initialValue: defaultPoints)
        case .sensorBased(let sid, let pts):
            self._mode = State(initialValue: .sensor)
            self._constantRPM = State(initialValue: Double(fan.minRPM))
            self._sensorID = State(initialValue: sid)
            self._points = State(initialValue: pts.sorted(by: { $0.tempC < $1.tempC }))
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
                    // entry through NSMenuItem.title which is a single
                    // string. Even a Menu+Button label collapses to the
                    // first Text it finds, so any "name [Spacer] temp"
                    // HStack drops the trailing temp. Concatenate the temp
                    // into the Label's title string instead — that's what
                    // actually lands in the menu item.
                    Menu {
                        ForEach(appState.sensors) { s in
                            Button {
                                sensorID = s.id
                            } label: {
                                let temp = s.formatted(useFahrenheit: settings.useFahrenheit, precise: false)
                                Label("\(s.name)   ·   \(temp)",
                                      systemImage: s.kind.sfSymbol)
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

                pointsEditor
            }
        }
    }

    /// Compact list of ramp vertices — one row per point with both
    /// temp (°C) and rpm steppers + delete button (disabled when N <= 2).
    /// "Add point" appends a new vertex halfway between the last two and
    /// re-sorts. The Chart in livePreviewCard renders the same array
    /// with draggable handles, so the user can edit either way.
    private var pointsEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Ramp points")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.gfcText)
                Spacer()
                Button {
                    addPoint()
                } label: {
                    Label("Add point", systemImage: "plus.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderless)
                .foregroundColor(.gfcCyan)
            }
            ForEach(points.indices, id: \.self) { i in
                pointRow(index: i)
            }
            Text("Drag the dots on the graph below to reshape the curve, or edit values here.")
                .font(.system(size: 10))
                .foregroundColor(.gfcTextMuted)
        }
    }

    @ViewBuilder
    private func pointRow(index i: Int) -> some View {
        let binding = pointBinding(at: i)
        HStack(spacing: 8) {
            Circle()
                .fill(pointColor(at: i))
                .frame(width: 10, height: 10)
                .shadow(color: pointColor(at: i).opacity(0.7), radius: 3)
            // Temp: explicit value Text + a labels-hidden Stepper. The
            // value MUST live outside the Stepper — `.labelsHidden()`
            // hides the Stepper's label, which is exactly where the old
            // code put the "45 °C" text, so it rendered blank.
            Text("at")
                .font(.system(size: 11))
                .foregroundColor(.gfcTextMuted)
            Text("\(Int(points[i].tempC)) °C")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(.gfcText)
                .frame(minWidth: 52, alignment: .trailing)
            Stepper("", value: binding.tempC, in: 0...120, step: 1)
                .labelsHidden()
            Text("→")
                .font(.system(size: 11))
                .foregroundColor(.gfcTextMuted)
            // RPM: same pattern.
            Text("\(points[i].rpm) RPM")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(.gfcText)
                .frame(minWidth: 74, alignment: .trailing)
            Stepper("", value: binding.rpm, in: fan.minRPM...fan.maxRPM, step: 50)
                .labelsHidden()
            Spacer()
            Button {
                deletePoint(at: i)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundColor(points.count > 2 ? .gfcRed : .gfcTextMuted.opacity(0.3))
            }
            .buttonStyle(.plain)
            .disabled(points.count <= 2)
            .help(points.count > 2 ? "Delete this point" : "Need at least 2 points")
        }
        .padding(.vertical, 2)
    }

    private func pointBinding(at i: Int) -> (tempC: Binding<Double>, rpm: Binding<Int>) {
        let temp = Binding<Double>(
            get: { points[safe: i]?.tempC ?? 0 },
            set: { newVal in
                guard i < points.count else { return }
                points[i].tempC = newVal
                points.sort(by: { $0.tempC < $1.tempC })
            }
        )
        let rpm = Binding<Int>(
            get: { points[safe: i]?.rpm ?? fan.minRPM },
            set: { newVal in
                guard i < points.count else { return }
                points[i].rpm = max(fan.minRPM, min(fan.maxRPM, newVal))
            }
        )
        return (temp, rpm)
    }

    private func pointColor(at i: Int) -> Color {
        if i == 0 { return .gfcGreen }
        if i == points.count - 1 { return .gfcRed }
        return .gfcCyan
    }

    private func addPoint() {
        let last = points.last ?? RampPoint(tempC: 85, rpm: fan.maxRPM)
        let prev = points.dropLast().last ?? RampPoint(tempC: 45, rpm: fan.minRPM)
        let mid = RampPoint(
            tempC: (prev.tempC + last.tempC) / 2,
            rpm: (prev.rpm + last.rpm) / 2
        )
        points.append(mid)
        points.sort(by: { $0.tempC < $1.tempC })
    }

    private func deletePoint(at i: Int) {
        guard points.count > 2, i < points.count else { return }
        points.remove(at: i)
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
        let currentTemp = live?.celsius ?? points.first?.tempC ?? 45
        let projected = computedTargetRPM()
        // X-axis: pad 10° on each side of the extreme points, but never
        // narrower than 20…110 so the chart breathes.
        let lo = points.first?.tempC ?? 45
        let hi = points.last?.tempC ?? 85
        let xMin = max(0.0, min(lo - 10, 20))
        let xMax = max(hi + 10, 110)
        // Build a clamped curve: hold first.rpm before first.tempC,
        // interpolate between points, hold last.rpm after last.tempC.
        var curve: [(temp: Double, rpm: Int)] = []
        if let first = points.first { curve.append((xMin, first.rpm)) }
        for p in points { curve.append((p.tempC, p.rpm)) }
        if let last = points.last { curve.append((xMax, last.rpm)) }

        return Chart {
            // Filled area under the ramp
            ForEach(curve.indices, id: \.self) { i in
                AreaMark(
                    x: .value("Temp", curve[i].temp),
                    y: .value("RPM", curve[i].rpm)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.gfcCyan.opacity(0.40), Color.gfcCyan.opacity(0.04)],
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
            // Live cursor — current temp on the curve
            RuleMark(x: .value("Now", currentTemp))
                .foregroundStyle(Color.gfcAmber.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            PointMark(
                x: .value("Temp", currentTemp),
                y: .value("RPM", projected)
            )
            .foregroundStyle(Color.gfcAmber)
            .symbolSize(110)
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
        .chartOverlay { proxy in
            GeometryReader { geo in
                if let plot = proxy.plotFrame {
                    let frame = geo[plot]
                    ZStack {
                        // Background tap-area: double-click on empty space
                        // anywhere in the plot adds a new ramp point at
                        // that (tempC, rpm).
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { loc in
                                addPointAt(location: loc, proxy: proxy, frame: frame, xMin: xMin, xMax: xMax)
                            }
                        ForEach(points.indices, id: \.self) { i in
                            handle(at: i, proxy: proxy, frame: frame, xMin: xMin, xMax: xMax)
                        }
                    }
                    // Named space so each handle's DragGesture reports a
                    // location in THIS overlay's coordinates regardless of
                    // where .position places the handle — matches `frame`
                    // (geo[plot], same space) for the proxy conversion.
                    .coordinateSpace(name: rampPlotSpace)
                }
            }
        }
        .frame(height: 180)
    }

    @ViewBuilder
    private func handle(at i: Int, proxy: ChartProxy, frame: CGRect,
                        xMin: Double, xMax: Double) -> some View {
        let p = points[safe: i] ?? RampPoint(tempC: 0, rpm: 0)
        if let posX = proxy.position(forX: p.tempC),
           let posY = proxy.position(forY: p.rpm) {
            let cx = posX + frame.minX
            let cy = posY + frame.minY
            let isFirst = (i == 0)
            let isLast = (i == points.count - 1)
            let color: Color = isFirst ? .gfcGreen : (isLast ? .gfcRed : .gfcCyan)

            ZStack {
                Circle()
                    .fill(color.opacity(0.25))
                    .frame(width: 26, height: 26)
                Circle()
                    .fill(color)
                    .frame(width: 14, height: 14)
                    .shadow(color: color.opacity(0.85), radius: 4)
            }
            // Generous 40pt hit target + contentShape + gesture applied
            // BEFORE .position so the draggable region sits ON the dot
            // (the old code applied contentShape AFTER .position, which
            // put a 32pt hit circle at the plot's corner — nowhere near
            // the handle — so nothing was draggable).
            .frame(width: 40, height: 40)
            .contentShape(Circle())
            .gesture(dragGesture(forPointAt: i, proxy: proxy, frame: frame, xMin: xMin, xMax: xMax))
            .position(x: cx, y: cy)
            .contextMenu {
                if points.count > 2 {
                    Button(role: .destructive) {
                        deletePoint(at: i)
                    } label: {
                        Label("Delete point", systemImage: "trash")
                    }
                }
            }
        }
    }

    private func dragGesture(forPointAt i: Int, proxy: ChartProxy, frame: CGRect,
                             xMin: Double, xMax: Double) -> some Gesture {
        // coordinateSpace: .named(rampPlotSpace) → drag.location is in the
        // overlay's coordinate space (same as `frame`), so subtracting
        // frame.minX/minY gives a plot-relative point the ChartProxy can
        // invert. Without the named space the location would be relative
        // to the .position'd handle and the math would be garbage.
        DragGesture(minimumDistance: 0, coordinateSpace: .named(rampPlotSpace))
            .onChanged { drag in
                guard i < points.count else { return }
                let inChartX = drag.location.x - frame.minX
                let inChartY = drag.location.y - frame.minY
                if let tempC: Double = proxy.value(atX: inChartX, as: Double.self),
                   let rpm: Int = proxy.value(atY: inChartY, as: Int.self) {
                    var newT = max(0, min(120, tempC))
                    // Prevent dragging past neighbors — keeps the curve
                    // monotonically progressing left-to-right so the line
                    // doesn't kink visually.
                    if i > 0 {
                        newT = max(newT, points[i - 1].tempC + 1)
                    }
                    if i < points.count - 1 {
                        newT = min(newT, points[i + 1].tempC - 1)
                    }
                    points[i].tempC = newT
                    points[i].rpm = max(fan.minRPM, min(fan.maxRPM, rpm))
                }
            }
    }

    private func addPointAt(location: CGPoint, proxy: ChartProxy, frame: CGRect,
                            xMin: Double, xMax: Double) {
        let inChartX = location.x - frame.minX
        let inChartY = location.y - frame.minY
        guard let tempC: Double = proxy.value(atX: inChartX, as: Double.self),
              let rpm: Int = proxy.value(atY: inChartY, as: Int.self) else { return }
        let newPoint = RampPoint(
            tempC: max(0, min(120, tempC)),
            rpm: max(fan.minRPM, min(fan.maxRPM, rpm))
        )
        points.append(newPoint)
        points.sort(by: { $0.tempC < $1.tempC })
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
            // Only show "Apply to all" when there's more than one fan —
            // on a single-fan Mac it's redundant.
            if appState.fans.count > 1 {
                Button("Apply to all") { apply(toAll: true) }
                    .buttonStyle(SecondaryButtonStyle())
                    .help("Apply this mode to every fan")
            }
            Button("Apply") { apply(toAll: false) }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.gfcSidebar.opacity(0.6))
    }

    /// Apply the configured mode to this fan, or to every fan when
    /// `toAll` is true. Persists the sensor-based config per fan so a
    /// later re-open restores exactly what was set.
    private func apply(toAll: Bool) {
        let sortedPts = points.sorted(by: { $0.tempC < $1.tempC })
        let targets: [Fan] = toAll ? appState.fans : [fan]
        for f in targets {
            // Re-clamp the mode's RPMs into each fan's own envelope —
            // fans can have different min/max, so the same target/ramp
            // must be range-fit per fan.
            settings.saveSensorRampConfig(
                SensorRampConfig(sensorId: sensorID, points: sortedPts),
                for: f.id)
            appState.setMode(applyMode(for: f), for: f.id)
        }
        dismiss()
    }

    // MARK: - Helpers

    private func applyMode() -> FanMode { applyMode(for: fan) }

    /// Build the mode to apply, clamped into `target`'s RPM envelope so
    /// the same setting fits fans with different min/max ranges.
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
        case .sensorBased(let sid, let pts):
            let temp = appState.sensor(withID: sid)?.celsius ?? 0
            return interpolate(tempC: temp, points: pts)
        }
    }

    /// Mirror of AppleSMCService.rpmForTemp(_:fan:points:) — duplicated
    /// here so the live preview doesn't depend on the SMC service. Same
    /// piecewise-linear semantics: clamp outside the endpoints, lerp
    /// between consecutive points, clamp into [fan.minRPM, fan.maxRPM].
    private func interpolate(tempC c: Double, points: [RampPoint]) -> Int {
        let sorted = points.sorted(by: { $0.tempC < $1.tempC })
        guard let first = sorted.first else { return fan.minRPM }
        guard sorted.count >= 2 else { return clamped(first.rpm) }
        if c <= first.tempC { return clamped(first.rpm) }
        if c >= sorted.last!.tempC { return clamped(sorted.last!.rpm) }
        for i in 0..<(sorted.count - 1) {
            let a = sorted[i], b = sorted[i + 1]
            if c >= a.tempC && c <= b.tempC {
                let span = b.tempC - a.tempC
                guard span > 0 else { return clamped(a.rpm) }
                let t = (c - a.tempC) / span
                return clamped(Int((Double(a.rpm) + t * Double(b.rpm - a.rpm)).rounded()))
            }
        }
        return clamped(sorted.last!.rpm)
    }

    private func clamped(_ rpm: Int) -> Int {
        max(fan.minRPM, min(fan.maxRPM, rpm))
    }
}

// MARK: - Array safe subscript

private extension Array {
    subscript(safe i: Int) -> Element? {
        return indices.contains(i) ? self[i] : nil
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
                             mode: .sensorBased(sensorId: "TC0E", points: [
                                 RampPoint(tempC: 45, rpm: 1200),
                                 RampPoint(tempC: 65, rpm: 3000),
                                 RampPoint(tempC: 80, rpm: 5800),
                             ])))
        .environmentObject(AppState.shared)
        .environmentObject(SettingsStore.shared)
}

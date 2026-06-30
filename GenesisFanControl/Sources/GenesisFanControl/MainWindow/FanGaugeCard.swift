//
//  FanGaugeCard.swift
//  GenesisFanControl
//
//  One card per fan, shown stacked in the main window. Exact layout
//  matches the screenshot the user reviewed: title + mode pill, gauge
//  (now click/drag-to-set), three metric chips, Configure… on the right.
//

import SwiftUI
import GenesisFanControlCore

struct FanGaugeCard: View {
    let fan: Fan
    var onConfigure: () -> Void
    var onSetManual: (Int) -> Void
    var onResetAuto: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Title + mode pill
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(fan.name)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundColor(.gfcText)
                    Text("Fan \(fan.id)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.gfcTextMuted)
                }
                Spacer()
                TagPill(text: fan.mode.displayName.uppercased(),
                        color: tagColor(for: fan.mode))
            }

            // Draggable gauge — green fill = live RPM, amber wall = manual setpoint
            DraggableRPMGauge(fan: fan, onSetManual: onSetManual)

            // Min / Max labels
            HStack {
                Text("\(formatted(fan.minRPM)) RPM")
                Spacer()
                Text("\(formatted(fan.maxRPM)) RPM")
            }
            .font(.system(size: 11))
            .foregroundColor(.gfcTextMuted)

            // Metric chips + Configure
            HStack(spacing: 12) {
                MetricChip(label: "CURRENT", value: "\(fan.currentRPM)", suffix: "RPM",
                           color: fan.loadColor)
                MetricChip(label: "TARGET", value: "\(fan.targetRPM)", suffix: "RPM",
                           color: .gfcCyan)
                MetricChip(label: "LOAD",
                           value: String(format: "%.0f", fan.loadFraction * 100),
                           suffix: "%", color: .gfcAmber)
                Spacer()
                if isManualOrSensor(fan.mode) {
                    Button("Auto", action: onResetAuto)
                        .buttonStyle(SecondaryButtonStyle())
                }
                Button("Configure…", action: onConfigure)
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(22)
        .neonCard(accentColor: fan.loadColor)
    }

    private func tagColor(for mode: FanMode) -> Color {
        switch mode {
        case .auto: return .gfcGreen
        case .constant: return .gfcAmber
        case .sensorBased: return .gfcCyan
        }
    }

    private func isManualOrSensor(_ m: FanMode) -> Bool {
        if case .auto = m { return false }
        return true
    }

    private func formatted(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = " "
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}

// MARK: - DraggableRPMGauge

/// The gauge is BOTH a live indicator AND a setter.
/// - The colored fill always shows current RPM (animated).
/// - When the user clicks or drags inside it, an amber "wall" appears
///   at the cursor position. On release we commit `.constant(rpm:)`
///   to the fan. While the fan stays in constant mode, the wall stays
///   pinned at the chosen RPM and the fill continues to approach it.
struct DraggableRPMGauge: View {
    let fan: Fan
    var onSetManual: (Int) -> Void

    @State private var dragRPM: Int? = nil
    @State private var isDragging = false

    private let height: CGFloat = 18

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Track
                Capsule()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: height)

                // Live RPM fill — ALWAYS the real, physical current RPM.
                // It does NOT snap to the tap/drag position; the amber
                // SetpointWall shows where you're pinning to, and the
                // green fill ramps up to meet it over the next few
                // seconds as the fan physically spins up. (User report:
                // tapping 70% used to jump the fill straight to 70%
                // instead of climbing — the fill followed dragRPM. Now
                // only the wall moves on tap; the fill stays honest.)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [fan.loadColor.opacity(0.55), fan.loadColor],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(8, geo.size.width * CGFloat(displayedFraction)),
                           height: height)
                    .shadow(color: fan.loadColor.opacity(0.3), radius: 2)
                    .animation(.easeOut(duration: 1.0), value: displayedFraction)

                // Sensor-based: faint ticks at each ramp vertex's RPM so
                // the user sees the whole curve's "stops" (the RPM range
                // the fan will sweep across temperature), not just the one
                // live target. Drawn BELOW the live wall so the active
                // target stays the prominent marker.
                ForEach(rampWallRPMs(), id: \.self) { rpm in
                    let x = positionFor(rpm: rpm, totalWidth: geo.size.width)
                    RampTick(x: x, height: height, color: .gfcCyan.opacity(0.45))
                }

                // Setpoint wall — amber for manual constant, cyan for the
                // live sensor-based target. Always shows the RPM label so
                // the user can read exactly where the fan is being pinned.
                if let marker = activeMarker() {
                    let x = positionFor(rpm: marker.rpm, totalWidth: geo.size.width)
                    SetpointWall(x: x, totalWidth: geo.size.width, height: height,
                                 rpm: marker.rpm, color: marker.color, label: marker.label,
                                 emphasised: isDragging)
                }
            }
            .frame(height: height)
            .contentShape(Rectangle())
            .gesture(
                // Drag updates LOCAL `dragRPM` on every onChanged (gives
                // 1:1 visual tracking under the cursor) but DOES NOT call
                // onSetManual until onEnded. A slow drag across the gauge
                // used to fire dozens of SMC writes per second — a single
                // commit on release is what every other fan-control app
                // does, and the SetpointWall keeps the visual feedback
                // honest in between (review MED — "drag gesture fires
                // SMC write per pixel"). Click-to-pin still works because
                // a tap is a 0-length drag that ends immediately.
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        isDragging = true
                        let rpm = rpmFor(x: g.location.x, totalWidth: geo.size.width)
                        if dragRPM != rpm { dragRPM = rpm }
                    }
                    .onEnded { g in
                        let rpm = rpmFor(x: g.location.x, totalWidth: geo.size.width)
                        // Commit ONCE on release — the SMC write + Apple
                        // Silicon Ftst dance takes ~3s in the worst case,
                        // so per-pixel writes were genuinely wasteful and
                        // would back up smcQueue with stale targets.
                        onSetManual(rpm)
                        // Clear dragRPM right away — fan.mode is .constant(rpm:) now,
                        // so `activeManualRPM()` already returns the right value.
                        dragRPM = nil
                        isDragging = false
                    }
            )
            .help(helpText)
        }
        // Frame leaves room for the RPM tag rendered BELOW the wall.
        .frame(height: height + 24)
    }

    // MARK: helpers

    private var helpText: String {
        "Click or drag to set a constant RPM. The bar fills with the live reading; the amber wall is your manual target."
    }

    private func activeManualRPM() -> Int? {
        if let dragRPM { return dragRPM }
        if case .constant(let rpm) = fan.mode { return rpm }
        return nil
    }

    /// RPM of each ramp vertex for sensor-based mode (clamped into the
    /// fan envelope, de-duplicated). Empty for auto/constant — only the
    /// sensor curve has multiple "stops" worth showing on the bar.
    private func rampWallRPMs() -> [Int] {
        guard case .sensorBased(_, let points) = fan.mode else { return [] }
        let clamped = points.map { max(fan.minRPM, min(fan.maxRPM, $0.rpm)) }
        return Array(Set(clamped)).sorted()
    }

    /// One marker describes the wall: where it is on the bar, what RPM
    /// it represents, what color, and the text under it. Manual (drag or
    /// constant) is amber; the sensor-based dynamic target is cyan.
    private struct Marker {
        let rpm: Int
        let color: Color
        let label: String
    }

    private func activeMarker() -> Marker? {
        if let dragRPM {
            return Marker(rpm: dragRPM, color: .gfcAmber, label: "\(dragRPM) RPM")
        }
        if case .constant(let rpm) = fan.mode {
            return Marker(rpm: rpm, color: .gfcAmber, label: "\(rpm) RPM")
        }
        if case .sensorBased = fan.mode {
            return Marker(rpm: fan.targetRPM, color: .gfcCyan,
                          label: "→ \(fan.targetRPM) RPM")
        }
        return nil
    }

    /// 0…1 width fraction for the green fill — ALWAYS the live physical
    /// fan reading, never the drag position. The amber SetpointWall is
    /// what tracks the finger/target; the fill ramps up to meet it as
    /// the fan actually spins up.
    private var displayedFraction: Double {
        let range = max(1, fan.maxRPM - fan.minRPM)
        return max(0, min(1, Double(fan.currentRPM - fan.minRPM) / Double(range)))
    }

    private func rpmFor(x: CGFloat, totalWidth: CGFloat) -> Int {
        let pct = max(0, min(1, x / max(1, totalWidth)))
        return fan.minRPM + Int(pct * CGFloat(fan.maxRPM - fan.minRPM))
    }

    private func positionFor(rpm: Int, totalWidth: CGFloat) -> CGFloat {
        guard fan.maxRPM > fan.minRPM else { return 0 }
        let pct = CGFloat(max(0, min(1, Double(rpm - fan.minRPM) / Double(fan.maxRPM - fan.minRPM))))
        return pct * totalWidth
    }
}

// MARK: - Ramp tick (faint vertex marker for sensor-based mode)

/// A thin static tick at a ramp vertex's RPM. Several of these show the
/// sweep range of a sensor curve on the 1-D RPM bar; the live target is
/// still drawn as the prominent SetpointWall on top.
private struct RampTick: View {
    let x: CGFloat
    let height: CGFloat
    let color: Color

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: 2, height: height + 4)
            .offset(x: x - 1, y: -2)
            .allowsHitTesting(false)
    }
}

// MARK: - Setpoint wall marker

private struct SetpointWall: View {
    let x: CGFloat
    let totalWidth: CGFloat
    let height: CGFloat
    let rpm: Int
    let color: Color
    let label: String
    let emphasised: Bool

    var body: some View {
        // .topLeading + explicit width so child offsets are measured from
        // x = 0 (the gauge's leading edge). With the default `.top`
        // alignment (horizontal=center) the wall rectangle would start at
        // (innerZStackWidth - rectWidth)/2 and the `.offset(x:)` would
        // shift it from that centered base — leaving a visible gap between
        // the fill's right edge and the wall.
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [color.opacity(0.85), color],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: emphasised ? 4 : 3, height: height + 8)
                .shadow(color: color.opacity(0.85), radius: emphasised ? 8 : 5)
                .offset(x: x - (emphasised ? 2 : 1.5), y: -4)
                .animation(.easeOut(duration: 0.1), value: emphasised)

            let estimatedWidth: CGFloat = CGFloat(label.count) * 6 + 12
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.black)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color)
                )
                .shadow(color: color.opacity(0.5), radius: 3)
                .offset(x: clamp(x - estimatedWidth / 2,
                                 lower: 0,
                                 upper: max(0, totalWidth - estimatedWidth)),
                        y: height + 4)
        }
        .frame(width: totalWidth, height: height + 24, alignment: .topLeading)
    }

    private func clamp(_ v: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        max(lower, min(upper, v))
    }
}

// MARK: - MetricChip (small read-only KPI tile)

struct MetricChip: View {
    let label: String
    let value: String
    let suffix: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.gfcTextMuted)
                .tracking(0.8)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .foregroundColor(color)
                Text(suffix)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.gfcTextSecondary)
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

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

                // Live RPM fill — during drag we drive it directly from the
                // cursor so it tracks 1:1; otherwise we animate to fan.currentRPM.
                // Shadow is kept tight (radius 2) so at high RPM the soft
                // colored glow doesn't extend past the SetpointWall and
                // make the bar look like it overshoots the manual target.
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
                    .animation(isDragging ? nil : .easeOut(duration: 1.0),
                               value: displayedFraction)

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
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        isDragging = true
                        let rpm = rpmFor(x: g.location.x, totalWidth: geo.size.width)
                        // Only commit if it actually changed — avoids redundant
                        // republishes during fine sub-pixel drags.
                        if dragRPM != rpm {
                            dragRPM = rpm
                            onSetManual(rpm)
                        }
                    }
                    .onEnded { g in
                        let rpm = rpmFor(x: g.location.x, totalWidth: geo.size.width)
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

    /// 0…1 width fraction for the fill. While dragging we pin it to the
    /// cursor so the bar tracks the finger; otherwise we follow the live
    /// fan reading.
    private var displayedFraction: Double {
        let rpm: Int
        if let dragRPM { rpm = dragRPM }
        else { rpm = fan.currentRPM }
        let range = max(1, fan.maxRPM - fan.minRPM)
        return max(0, min(1, Double(rpm - fan.minRPM) / Double(range)))
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

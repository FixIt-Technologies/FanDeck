//
//  FanGaugeCard.swift
//  MacsFanControl
//
//  One card per fan, shown stacked in the main window. Exact layout
//  matches the screenshot the user reviewed: title + mode pill, gauge
//  (now click/drag-to-set), three metric chips, Configure… on the right.
//

import SwiftUI
import MacsFanControlCore

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
                        .foregroundColor(.mfcText)
                    Text("Fan \(fan.id)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.mfcTextMuted)
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
            .foregroundColor(.mfcTextMuted)

            // Metric chips + Configure
            HStack(spacing: 12) {
                MetricChip(label: "CURRENT", value: "\(fan.currentRPM)", suffix: "RPM",
                           color: fan.loadColor)
                MetricChip(label: "TARGET", value: "\(fan.targetRPM)", suffix: "RPM",
                           color: .mfcCyan)
                MetricChip(label: "LOAD",
                           value: String(format: "%.0f", fan.loadFraction * 100),
                           suffix: "%", color: .mfcAmber)
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
        case .auto: return .mfcGreen
        case .constant: return .mfcAmber
        case .sensorBased: return .mfcCyan
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

                // Live RPM fill
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [fan.loadColor.opacity(0.55), fan.loadColor],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(8, geo.size.width * CGFloat(fan.loadFraction)),
                           height: height)
                    .shadow(color: fan.loadColor.opacity(0.45), radius: 6)
                    .animation(.easeOut(duration: 0.25), value: fan.currentRPM)

                // Manual setpoint wall (during drag OR while fan is in constant mode)
                if let target = activeManualRPM() {
                    let x = positionFor(rpm: target, totalWidth: geo.size.width)
                    ManualWall(x: x, totalWidth: geo.size.width, height: height,
                               rpm: target, isDragging: isDragging)
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
        .frame(height: height + 6)
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

// MARK: - Manual wall marker

private struct ManualWall: View {
    let x: CGFloat
    let totalWidth: CGFloat
    let height: CGFloat
    let rpm: Int
    let isDragging: Bool

    var body: some View {
        ZStack(alignment: .top) {
            // The wall — a vertical bar through the gauge
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [Color.mfcAmber.opacity(0.85), Color.mfcAmber],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: isDragging ? 4 : 3, height: height + 8)
                .shadow(color: .mfcAmber.opacity(0.85), radius: isDragging ? 8 : 5)
                .offset(x: x - (isDragging ? 2 : 1.5), y: -4)
                .animation(.easeOut(duration: 0.1), value: isDragging)

            // Floating RPM tag (only while dragging — keeps the gauge calm at rest)
            if isDragging {
                Text("\(rpm)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.black)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.mfcAmber)
                    )
                    .shadow(color: .mfcAmber.opacity(0.6), radius: 4)
                    .offset(x: clamp(x - 18, lower: 0, upper: max(0, totalWidth - 36)),
                            y: -22)
                    .transition(.opacity)
            }
        }
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

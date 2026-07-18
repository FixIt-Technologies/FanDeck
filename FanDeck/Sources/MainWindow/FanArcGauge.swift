//
//  FanArcGauge.swift
//  FanDeck
//
//  The mini circular gauge (decision D4, Take B). A 240° arc whose fill
//  tracks the live RPM and whose knob marks the active setpoint. The
//  whole face is a control: tap or drag around the arc to set a
//  constant RPM (50-step quantized, deduped before committing).
//

import SwiftUI
import GenesisFanControlCore

struct FanArcGauge: View {
    let fan: Fan
    /// Called with a quantized RPM whenever the user's drag moves a step.
    let commit: (Int) -> Void

    @State private var isDragging = false
    @State private var dragRPM: Int = 0
    @State private var lastCommittedRPM: Int = -1

    // 240° sweep, opening at the bottom: start at 150° (bottom-left),
    // sweep clockwise to 30° (bottom-right). SwiftUI's y axis points
    // down, so increasing angles run clockwise on screen.
    private let sweep: Double = 240
    private let startAngle: Double = 150
    private let stroke: CGFloat = 9

    private var displayRPM: Int { isDragging ? dragRPM : fan.currentRPM }

    private func fraction(of rpm: Int) -> Double {
        guard fan.maxRPM > fan.minRPM else { return 0 }
        return min(1, max(0, Double(rpm - fan.minRPM) / Double(fan.maxRPM - fan.minRPM)))
    }

    private var setpointRPM: Int? {
        if isDragging { return dragRPM }
        switch fan.mode {
        case .auto: return nil
        case .constant, .sensorBased: return fan.targetRPM
        }
    }

    private var accent: Color {
        if isDragging { return FD.amber }
        return FD.modeAccent(fan.mode)
    }

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let radius = size / 2 - stroke
            ZStack {
                arcPath(center: center, radius: radius, fraction: 1)
                    .stroke(FD.separator.opacity(0.55),
                            style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                arcPath(center: center, radius: radius, fraction: fraction(of: displayRPM))
                    .stroke(accent.opacity(0.9),
                            style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                    .shadow(color: accent.opacity(0.35), radius: 3)
                    .animation(isDragging ? nil : .easeOut(duration: 0.6),
                               value: fraction(of: displayRPM))
                if let sp = setpointRPM {
                    knob(fraction: fraction(of: sp), center: center, radius: radius)
                }
                VStack(spacing: 0) {
                    Text("\(displayRPM)")
                        .font(.system(size: size * 0.16, weight: .bold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("RPM")
                        .font(.system(size: size * 0.07))
                        .foregroundStyle(FD.tertiaryText)
                }
            }
            .contentShape(Circle())
            .gesture(dragGesture(center: center))
        }
        .aspectRatio(1, contentMode: .fit)
    }

    // MARK: - Drawing

    private func arcPath(center: CGPoint, radius: CGFloat, fraction: Double) -> Path {
        Path { p in
            p.addArc(center: center,
                     radius: radius,
                     startAngle: .degrees(startAngle),
                     endAngle: .degrees(startAngle + sweep * fraction),
                     clockwise: false)
        }
    }

    private func knob(fraction: Double, center: CGPoint, radius: CGFloat) -> some View {
        let angle = (startAngle + sweep * fraction) * .pi / 180
        let x = center.x + cos(angle) * radius
        let y = center.y + sin(angle) * radius
        let color: Color = {
            if isDragging { return FD.amber }
            if case .sensorBased = fan.mode { return FD.cyan }
            return FD.amber
        }()
        return Circle()
            .fill(color)
            .frame(width: 11, height: 11)
            .shadow(color: color.opacity(0.85), radius: 3)
            .position(x: x, y: y)
    }

    // MARK: - Interaction

    private func dragGesture(center: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                let dx = drag.location.x - center.x
                let dy = drag.location.y - center.y
                var deg = atan2(dy, dx) * 180 / .pi   // -180…180, 0 = right, CW-positive
                if deg < 0 { deg += 360 }              // 0…360
                // Rebase onto the gauge sweep: 0 at startAngle, growing CW.
                var rel = deg - startAngle
                if rel < 0 { rel += 360 }
                // Clamp the 120° dead zone at the bottom to the nearer end
                // so a drag can't jump from max to min across the gap.
                if rel > sweep {
                    rel = rel - sweep < (360 - sweep) / 2 ? sweep : 0
                }
                let f = rel / sweep
                let raw = Double(fan.minRPM) + f * Double(fan.maxRPM - fan.minRPM)
                let rpm = min(fan.maxRPM, max(fan.minRPM, Int((raw / 50).rounded()) * 50))
                isDragging = true
                dragRPM = rpm
                guard rpm != lastCommittedRPM else { return }
                lastCommittedRPM = rpm
                commit(rpm)
            }
            .onEnded { _ in isDragging = false }
    }
}

//
//  Theme.swift
//  MacsFanControl
//
//  Design system tokens. Consolidated from TimeTravel's Theme.swift —
//  only the "Cyberpunk Settings" palette (settings* / neon*) was kept;
//  the warm-amber `tt*` palette was overlay-HUD specific and not relevant
//  here. One palette, one mode (dark).
//

import SwiftUI
import MacsFanControlCore
import AppKit

// MARK: - Colors

extension Color {
    // Deep backgrounds
    static let mfcBackground = Color(red: 0.012, green: 0.012, blue: 0.031)
    static let mfcSidebar = Color(red: 0.024, green: 0.024, blue: 0.047)
    static let mfcCard = Color(red: 0.039, green: 0.039, blue: 0.078)
    static let mfcCardHover = Color(red: 0.055, green: 0.055, blue: 0.098)

    // Neon accents
    static let mfcAmber = Color(red: 1.0, green: 0.63, blue: 0.20)
    static let mfcAmberGlow = Color(red: 1.0, green: 0.72, blue: 0.35)
    static let mfcCyan = Color(red: 0.0, green: 0.94, blue: 1.0)
    static let mfcCyanGlow = Color(red: 0.35, green: 0.96, blue: 1.0)
    static let mfcPurple = Color(red: 0.66, green: 0.33, blue: 0.97)
    static let mfcGreen = Color(red: 0.35, green: 0.85, blue: 0.55)
    static let mfcRed = Color(red: 1.0, green: 0.35, blue: 0.35)

    // Strokes, dividers, text
    static let mfcBorder = Color.white.opacity(0.06)
    static let mfcBorderActive = Color.mfcAmber.opacity(0.4)
    static let mfcText = Color.white.opacity(0.92)
    static let mfcTextSecondary = Color.white.opacity(0.55)
    static let mfcTextMuted = Color.white.opacity(0.35)
}

// MARK: - Typography

enum MFCFont {
    static func display(_ size: CGFloat = 32, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
    static func headline(_ size: CGFloat = 15, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
    static func body(_ size: CGFloat = 13, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
    static func caption(_ size: CGFloat = 11, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
    static func mono(_ size: CGFloat = 12, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Spacing

enum MFCSpacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

// MARK: - Radii

enum MFCRadius {
    static let sm: CGFloat = 6
    static let md: CGFloat = 10
    static let lg: CGFloat = 14
    static let xl: CGFloat = 20
    static let full: CGFloat = 999
}

// MARK: - Animation

enum MFCAnimation {
    static let quick = Animation.easeOut(duration: 0.15)
    static let standard = Animation.easeInOut(duration: 0.25)
    static let smooth = Animation.easeInOut(duration: 0.35)
    static let springy = Animation.spring(response: 0.35, dampingFraction: 0.7)
    static let gentle = Animation.spring(response: 0.5, dampingFraction: 0.85)
}

// MARK: - VisualEffectBlur

struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = state
        v.wantsLayer = true
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

// MARK: - Modifiers

struct GlowEffect: ViewModifier {
    var color: Color = .mfcAmber
    var radius: CGFloat = 12
    var isActive: Bool = true

    func body(content: Content) -> some View {
        content
            .shadow(color: isActive ? color.opacity(0.5) : .clear, radius: radius)
            .shadow(color: isActive ? color.opacity(0.3) : .clear, radius: radius * 2)
    }
}

extension View {
    func glowEffect(color: Color = .mfcAmber, radius: CGFloat = 12, isActive: Bool = true) -> some View {
        modifier(GlowEffect(color: color, radius: radius, isActive: isActive))
    }
}

struct PulseGlow: ViewModifier {
    @State private var isAnimating = false
    var color: Color = .mfcAmber

    func body(content: Content) -> some View {
        content
            .shadow(color: color.opacity(isAnimating ? 0.4 : 0.2),
                    radius: isAnimating ? 12 : 8)
            .onAppear {
                withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                    isAnimating = true
                }
            }
    }
}

extension View {
    func pulseGlow(color: Color = .mfcAmber) -> some View {
        modifier(PulseGlow(color: color))
    }
}

struct NeonCardStyle: ViewModifier {
    var isHovered: Bool = false
    var accentColor: Color = .mfcAmber

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.mfcCard.opacity(isHovered ? 1.0 : 0.9),
                                    Color.mfcCard.opacity(isHovered ? 0.95 : 0.85),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    if isHovered {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(accentColor.opacity(0.03))
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                isHovered ? accentColor.opacity(0.4) : Color.white.opacity(0.08),
                                isHovered ? accentColor.opacity(0.2) : Color.white.opacity(0.03),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: isHovered ? accentColor.opacity(0.15) : .clear, radius: 20, x: 0, y: 4)
    }
}

extension View {
    func neonCard(isHovered: Bool = false, accentColor: Color = .mfcAmber) -> some View {
        modifier(NeonCardStyle(isHovered: isHovered, accentColor: accentColor))
    }
}

// MARK: - Cyberpunk Grid Background

struct CyberpunkGrid: View {
    var body: some View {
        GeometryReader { _ in
            Canvas { context, size in
                let gridSize: CGFloat = 40
                let lineWidth: CGFloat = 0.5
                for y in stride(from: 0, through: size.height, by: gridSize) {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(path, with: .color(.mfcAmber.opacity(0.04)), lineWidth: lineWidth)
                }
                for x in stride(from: 0, through: size.width, by: gridSize) {
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(path, with: .color(.mfcAmber.opacity(0.04)), lineWidth: lineWidth)
                }
            }
        }
    }
}

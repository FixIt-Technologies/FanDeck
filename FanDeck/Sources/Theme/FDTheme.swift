//
//  FDTheme.swift
//  FanDeck
//
//  The hybrid design language (decision D7): native macOS materials and
//  semantic colors for all chrome — windows, panels, text, separators —
//  with the GenesisFanControl electric accents (amber / cyan) reserved
//  exclusively for FAN STATE:
//    • amber  = manual intent (constant mode, drag-in-progress, setpoint)
//    • cyan   = sensor-driven intent (ramp mode, dynamic target)
//    • green  = healthy / auto / helper alive
//  Everything else uses adaptive system colors so FanDeck feels
//  first-party in both light and dark appearance (onyx-style).
//

import SwiftUI
import AppKit
import GenesisFanControlCore

enum FD {
    // MARK: Fan-state accents (the only brand colors)
    static let amber = Color(red: 1.0, green: 0.63, blue: 0.20)
    static let cyan = Color(red: 0.0, green: 0.80, blue: 0.90)
    static let green = Color(red: 0.24, green: 0.78, blue: 0.46)

    // MARK: Adaptive chrome
    static let secondaryText = Color(nsColor: .secondaryLabelColor)
    static let tertiaryText = Color(nsColor: .tertiaryLabelColor)
    static let separator = Color(nsColor: .separatorColor)
    /// Card fill on top of window material — a whisper of contrast that
    /// works in both appearances.
    static let card = Color(nsColor: .textBackgroundColor).opacity(0.55)
    static let cardStroke = Color(nsColor: .separatorColor).opacity(0.6)

    /// Temperature severity — system palette so it adapts.
    static func tempColor(_ celsius: Double) -> Color {
        switch celsius {
        case ..<45: return Color(nsColor: .systemGreen)
        case ..<65: return Color(nsColor: .systemYellow)
        case ..<80: return Color(nsColor: .systemOrange)
        default: return Color(nsColor: .systemRed)
        }
    }

    /// Accent for a fan's current mode.
    static func modeAccent(_ mode: FanMode) -> Color {
        switch mode {
        case .auto: return green
        case .constant: return amber
        case .sensorBased: return cyan
        }
    }

    static func modeShortLabel(_ mode: FanMode) -> String {
        switch mode {
        case .auto: return "AUTO"
        case .constant: return "CONSTANT"
        case .sensorBased: return "SENSOR"
        }
    }
}

// MARK: - Shared atoms

/// Small colored capsule naming the fan's mode.
struct FDModePill: View {
    let mode: FanMode

    var body: some View {
        Text(FD.modeShortLabel(mode))
            .font(.system(size: 8.5, weight: .bold))
            .kerning(0.8)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(FD.modeAccent(mode).opacity(0.16)))
            .foregroundStyle(FD.modeAccent(mode))
    }
}

/// Liveness dot — helper / backend status.
struct FDStatusDot: View {
    let healthy: Bool

    var body: some View {
        Circle()
            .fill(healthy ? FD.green : Color(nsColor: .systemRed))
            .frame(width: 7, height: 7)
            .shadow(color: (healthy ? FD.green : .red).opacity(0.7), radius: 3)
    }
}

/// Rounded card container over the window material.
struct FDCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(FD.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(FD.cardStroke, lineWidth: 1)
                    )
            )
    }
}

/// One compact sensor chip: name + colored temperature.
struct FDSensorChip: View, Equatable {
    let name: String
    let celsius: Double
    let label: String

    static func == (a: FDSensorChip, b: FDSensorChip) -> Bool {
        a.name == b.name && a.label == b.label && abs(a.celsius - b.celsius) < 0.05
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(name)
                .font(.system(size: 10))
                .foregroundStyle(FD.secondaryText)
                .lineLimit(1)
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(FD.tempColor(celsius))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(FD.card))
        .overlay(Capsule().strokeBorder(FD.cardStroke, lineWidth: 1))
    }
}

/// The shared "helper needed" banner. Compact enough for both surfaces.
struct FDElevationBanner: View {
    @EnvironmentObject var appState: AppState

    private var copy: String {
        if case .outdated(let installed, let current) = appState.helperHealth {
            return "Helper is out of date — installed v\(installed), app expects v\(current)."
        }
        if let err = appState.helperInstallError {
            return "Helper install failed: \(err)"
        }
        return "Fan control needs the elevated helper."
    }

    private var buttonTitle: String {
        if case .outdated = appState.helperHealth { return "Update Helper" }
        return "Install Helper"
    }

    var body: some View {
        if appState.needsElevation || appState.helperInstallError != nil {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(FD.amber)
                Text(copy)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Spacer(minLength: 6)
                if appState.helperInstalling {
                    ProgressView().controlSize(.small)
                } else {
                    Button(buttonTitle) { appState.installHelper() }
                        .controlSize(.small)
                        .tint(FD.amber)
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(FD.amber.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(FD.amber.opacity(0.35), lineWidth: 1)
                    )
            )
        }
    }
}

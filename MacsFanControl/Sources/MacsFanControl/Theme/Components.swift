//
//  Components.swift
//  MacsFanControl
//
//  Reusable building blocks: SettingsSectionHeader, SettingsCard,
//  SettingsToggleRow, SettingsInfoRow, NeonToggleStyle, SidebarNavItem,
//  NeonSlider. Adapted from TimeTravel's SettingsView.swift primitives.
//

import SwiftUI
import MacsFanControlCore

// MARK: - SettingsSectionHeader

struct SettingsSectionHeader: View {
    let icon: String
    let title: String
    var accentColor: Color = .mfcAmber

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(accentColor)
                .frame(width: 26, height: 26)
                .background(accentColor.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .shadow(color: accentColor.opacity(0.3), radius: 4)

            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.mfcText)
                .tracking(0.5)

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [accentColor.opacity(0.3), accentColor.opacity(0.0)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 1)
        }
        .padding(.bottom, 6)
    }
}

// MARK: - SettingsCard

struct SettingsCard<Content: View>: View {
    let icon: String
    let title: String
    var accentColor: Color = .mfcAmber
    @ViewBuilder let content: Content

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(icon: icon, title: title, accentColor: accentColor)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 6)
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .neonCard(isHovered: isHovered, accentColor: accentColor)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering }
        }
    }
}

// MARK: - NeonToggleStyle

struct NeonToggleStyle: ToggleStyle {
    var accent: Color = .mfcAmber

    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.mfcText)
            Spacer()
            ZStack {
                Capsule()
                    .fill(configuration.isOn ? accent.opacity(0.2) : Color.white.opacity(0.08))
                    .frame(width: 44, height: 24)
                    .overlay(
                        Capsule()
                            .stroke(
                                configuration.isOn ? accent.opacity(0.5) : Color.white.opacity(0.1),
                                lineWidth: 1
                            )
                    )
                Circle()
                    .fill(configuration.isOn ? accent : Color.white.opacity(0.7))
                    .frame(width: 18, height: 18)
                    .shadow(color: configuration.isOn ? accent.opacity(0.5) : .clear, radius: 6)
                    .offset(x: configuration.isOn ? 10 : -10)
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isOn)
            .onTapGesture { configuration.isOn.toggle() }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { configuration.isOn.toggle() }
    }
}

// MARK: - SettingsToggleRow

struct SettingsToggleRow: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool
    var accent: Color = .mfcAmber
    var isDisabled: Bool = false

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.mfcTextMuted)
                }
            }
        }
        .toggleStyle(NeonToggleStyle(accent: accent))
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1.0)
    }
}

// MARK: - SettingsInfoRow

struct SettingsInfoRow: View {
    let label: String
    let value: String
    var valueColor: Color = .mfcTextSecondary

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.mfcText)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(valueColor)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - SidebarNavItem

struct SidebarNavItem: View {
    let icon: String
    let title: String
    let isSelected: Bool
    var accent: Color = .mfcAmber
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    if isSelected {
                        Circle()
                            .fill(accent.opacity(0.2))
                            .frame(width: 30, height: 30)
                            .blur(radius: 8)
                    }
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: isSelected ? .semibold : .medium))
                        .foregroundColor(isSelected ? accent : .mfcTextSecondary)
                        .frame(width: 22, height: 22)
                }
                .frame(width: 30, height: 30)
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(isSelected ? .mfcText : .mfcTextSecondary)
                    .lineLimit(1)
                Spacer()
                if isSelected {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(accent)
                        .frame(width: 3, height: 18)
                        .shadow(color: accent.opacity(0.6), radius: 4)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? accent.opacity(0.1) :
                          (isHovered ? Color.white.opacity(0.04) : .clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? accent.opacity(0.3) : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering }
        }
    }
}

// MARK: - NeonSlider

struct NeonSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var accent: Color = .mfcAmber
    var trailing: (Double) -> String = { String(format: "%.0f", $0) }

    @State private var isDragging = false

    var body: some View {
        HStack(spacing: 12) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 6)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [accent.opacity(0.7), accent],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(0, fillWidth(in: geo.size.width)), height: 6)
                        .shadow(color: accent.opacity(0.6), radius: 6)
                    Circle()
                        .fill(accent)
                        .frame(width: 16, height: 16)
                        .shadow(color: accent.opacity(0.7), radius: isDragging ? 10 : 6)
                        .scaleEffect(isDragging ? 1.2 : 1.0)
                        .offset(x: max(0, fillWidth(in: geo.size.width) - 8))
                        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isDragging)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            isDragging = true
                            updateValue(at: g.location.x, width: geo.size.width)
                        }
                        .onEnded { _ in isDragging = false }
                )
            }
            .frame(height: 20)

            Text(trailing(value))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(.mfcText)
                .frame(minWidth: 56, alignment: .trailing)
        }
    }

    private func fillWidth(in totalWidth: CGFloat) -> CGFloat {
        let progress = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
        return CGFloat(max(0, min(1, progress))) * totalWidth
    }

    private func updateValue(at x: CGFloat, width: CGFloat) {
        let p = max(0, min(1, x / max(1, width)))
        value = range.lowerBound + Double(p) * (range.upperBound - range.lowerBound)
    }
}

// MARK: - PrimaryButtonStyle / SecondaryButtonStyle

struct PrimaryButtonStyle: ButtonStyle {
    var accent: Color = .mfcAmber

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.black)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [accent, accent.opacity(0.85)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .shadow(color: accent.opacity(configuration.isPressed ? 0.2 : 0.5), radius: 8)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.mfcText)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.12 : 0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Tag Pill

struct TagPill: View {
    let text: String
    var color: Color = .mfcAmber

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(color.opacity(0.15))
            )
            .overlay(
                Capsule()
                    .stroke(color.opacity(0.4), lineWidth: 1)
            )
    }
}

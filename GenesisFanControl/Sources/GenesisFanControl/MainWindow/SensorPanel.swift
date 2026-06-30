//
//  SensorPanel.swift
//  GenesisFanControl
//
//  Always-visible right rail listing every sensor at a glance.
//  Grouped by kind, monospaced temperatures, color-coded by reading.
//

import SwiftUI
import AppKit  // NSApp.sendAction for the gear button
import GenesisFanControlCore

struct SensorPanel: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Push the header BELOW the 28pt title-bar drag region. AppKit
            // claims everything in the top 28pt of a .hiddenTitleBar
            // window as a window-drag area, eating clicks on any SwiftUI
            // Button that lives there — that's why every prior fix to
            // openSettings dispatch failed: the click never arrived. The
            // earlier NoDragArea NSHostingView shim worked for hit-testing
            // but its NSViewRepresentable sizing dropped the gear into the
            // wrong row visually. Pushing the header down is dumber, has
            // no sizing surprises, and is what other similar apps do.
            Color.clear.frame(height: 30)
            header
            Divider().overlay(Color.white.opacity(0.06))
            ScrollView(showsIndicators: true) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(groupedSensors, id: \.kind) { group in
                        SensorGroupView(
                            kind: group.kind,
                            sensors: group.sensors,
                            useFahrenheit: settings.useFahrenheit,
                            precise: settings.precise
                        )
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 12)
            }
        }
        .background(Color.gfcSidebar.opacity(0.55))
        .overlay(
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(width: 1),
            alignment: .leading
        )
        // Without this the right rail leaves a black gap above
        // TEMPERATURES (safe-area inset reserved for the hidden title bar).
        .ignoresSafeArea(.container, edges: .top)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "thermometer.medium")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.gfcCyan)
            // No tracking — at 10 pt that adds enough width to wrap
            // "TEMPERATURES" on a 280-pt-wide panel. Tight is fine.
            Text("TEMPERATURES")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.gfcTextSecondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 8)
            Text(timeAgo(appState.lastUpdated))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(.gfcTextMuted)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            // Bare NSApp.sendAction("showSettingsWindow:") was returning
            // false on macOS 26 — the responder chain lookup wasn't
            // landing on the Settings scene's installed handler. The
            // GearButton wrapper activates the app first, then tries
            // the modern selector, the legacy "showPreferencesWindow:"
            // selector, and finally walks the application menu for any
            // item whose title contains "Settings" or "Preferences" —
            // one of those always fires.
            //
            // The header is now pushed below the 28pt drag region by
            // the leading Color.clear spacer in `body`, so plain Button
            // works — no need for the NoDragArea NSHostingView shim that
            // was breaking layout (gear was rendering in the wrong row).
            GearButton()
        }
        .padding(.horizontal, 12)
        // Same height as the topStatusBar — TEMPERATURES sits on the
        // same row as the GenesisFanControl pill on the left.
        .frame(height: 28)
    }

    private var filteredSensors: [TempSensor] {
        appState.sensors.filter { s in
            switch s.kind {
            case .storage:
                if !settings.includeSATANVMe { return false }
                // Thunderbolt-attached external storage exposes via Tt-
                // prefix SMC keys; internal NVMe is TH0* on Apple Silicon
                // and TM* / TR* / SSD* on Intel. When the user turns off
                // "include external drives" we drop anything that looks
                // Thunderbolt-attached. On a machine with no externals
                // connected this filter is a no-op — that's expected.
                if !settings.includeExternalDrives && s.id.hasPrefix("Tt") {
                    return false
                }
                return true
            case .gpu:
                return settings.includeEGPU
            default:
                return true
            }
        }
    }

    private var groupedSensors: [(kind: SensorKind, sensors: [TempSensor])] {
        let buckets = Dictionary(grouping: filteredSensors, by: { $0.kind })
        return SensorKind.allCases.compactMap { k in
            guard let xs = buckets[k], !xs.isEmpty else { return nil }
            // Order so virtuals sit IMMEDIATELY AFTER the real sensors
            // they aggregate (Perf cores → Perf avg/max → Eff cores →
            // Eff avg/max → … → All-cores avg/max at the bottom).
            return (kind: k, sensors: xs.sorted { sortKey($0) < sortKey($1) })
        }
    }

    private func timeAgo(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 0 || date == .distantPast { return "—" }
        if s < 2 { return "just now" }
        return "\(s)s ago"
    }

    /// Sort key used inside a single-kind group so aggregate sensors
    /// land next to their source group, not lumped at the end.
    private func sortKey(_ s: TempSensor) -> Int {
        switch s.id {
        case "__cpu_perf_avg": return 90
        case "__cpu_perf_max": return 91
        case "__cpu_eff_avg":  return 190
        case "__cpu_eff_max":  return 191
        case "__gpu_avg":      return 90
        case "__gpu_max":      return 91
        case "__cpu_all_avg":  return 990
        case "__cpu_all_max":  return 991
        default:
            // Real Tp0X performance cores get 1..8; efficiency get 100..105.
            if s.id.hasPrefix("Tp0"), s.id.count == 4 {
                let last = String(s.id.suffix(1))
                let perf = ["9","T","b","d","1","5","D","X"]
                if let i = perf.firstIndex(of: last) { return 1 + i }
                let eff = ["f","n","r","t","v","z"]
                if let i = eff.firstIndex(of: last) { return 100 + i }
            }
            if s.id.hasPrefix("Tg0"), s.id.count == 4 { return 1 }
            return 500 // everything else (TC0E etc) drops below the cores
        }
    }
}

// MARK: - SensorGroupView

private struct SensorGroupView: View {
    let kind: SensorKind
    let sensors: [TempSensor]
    let useFahrenheit: Bool
    let precise: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: kind.sfSymbol)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(kind.accent)
                Text(kind.label.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.7)
                    .foregroundColor(.gfcTextMuted)
                Spacer()
                Text("avg \(formatted(avgC))")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(.gfcTextMuted)
            }
            .padding(.horizontal, 4)

            VStack(spacing: 1) {
                ForEach(sensors) { s in
                    SensorRow(sensor: s,
                              useFahrenheit: useFahrenheit,
                              precise: precise)
                        .equatable()
                }
            }
        }
    }

    private var avgC: Double {
        guard !sensors.isEmpty else { return 0 }
        return sensors.map { $0.celsius }.reduce(0, +) / Double(sensors.count)
    }

    private func formatted(_ c: Double) -> String {
        let v = useFahrenheit ? (c * 9.0 / 5.0 + 32.0) : c
        let unit = useFahrenheit ? "°F" : "°C"
        return precise ? String(format: "%.1f %@", v, unit)
                       : String(format: "%.0f %@", v, unit)
    }
}

// Equatable so SwiftUI skips re-rendering a row whose (sensor, unit,
// precision) is byte-identical — when one sensor crosses a 0.1 °C bucket
// and forces a panel re-eval, the other ~39 unchanged rows are pruned.
// All stored properties are Equatable, so `==` is auto-synthesized.
private struct SensorRow: View, Equatable {
    let sensor: TempSensor
    let useFahrenheit: Bool
    let precise: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(sensor.name)
                    .font(.system(size: 10))
                    .foregroundColor(.gfcText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(sensor.formatted(useFahrenheit: useFahrenheit, precise: precise))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(colorForTemp(sensor.celsius))
            }
            .padding(.horizontal, 6)
            .padding(.top, 3)
            tempBar
                .padding(.horizontal, 6)
                .padding(.bottom, 3)
        }
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.white.opacity(0.02))
        )
    }

    /// Temperature meter — 2 px tall bar under each row, filled to
    /// (celsius / 100). Animates the width whenever the reading changes
    /// so the panel pulses in real time as the polling tick updates.
    /// Kept low-opacity / no glow so it reads as ambient context, not as
    /// a focal element competing with the sensor name + temperature label.
    private var tempBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.04))
                    .frame(height: 2)
                Capsule()
                    .fill(colorForTemp(sensor.celsius).opacity(0.35))
                    .frame(width: max(1, geo.size.width * fractionOfHundred),
                           height: 2)
                    // No implicit animation. Sensor temps jitter every 1 Hz
                    // tick (≥0.1 °C diode noise / mock sine drift), so an
                    // `.animation(value: sensor.celsius)` here kicked a 0.6 s
                    // width ease on ALL ~40 rows EVERY tick — a sustained
                    // per-frame render loop (Focus C co-primary). The bar
                    // still snaps to the correct width each tick; a 2 px
                    // capsule step is imperceptible without the ease.
            }
        }
        .frame(height: 2)
    }

    private var fractionOfHundred: CGFloat {
        CGFloat(max(0, min(1, sensor.celsius / 100)))
    }

    private func colorForTemp(_ c: Double) -> Color {
        switch c {
        case ..<45: return .gfcGreen
        case ..<65: return .gfcAmber
        case ..<80: return Color(red: 1.0, green: 0.5, blue: 0.2)
        default:    return .gfcRed
        }
    }
}

// MARK: - SensorKind labels

private extension SensorKind {
    var label: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .battery: return "Battery"
        case .storage: return "Storage"
        case .airport: return "AirPort / Wi-Fi"
        case .thunderbolt: return "Thunderbolt"
        case .proximity: return "Proximity"
        case .power: return "Power"
        case .trackpad: return "Trackpad"
        case .other: return "Other"
        }
    }
}

// MARK: - Settings gear button

/// Opens the Settings scene from a header button.
///
/// macOS 14 ships `SettingsLink` as the canonical way to invoke the
/// Settings scene from inside a view, but it's BROKEN when the app's
/// activation policy is `.accessory` (no dock icon) — clicking the
/// link silently does nothing because there's no foreground regular
/// app to host the Settings window. Verified empirically: the
/// `GearButton tapped` log fires; no Settings window appears.
///
/// Workaround: a plain `Button` that (a) promotes the app to
/// `.regular` momentarily and (b) dispatches `showSettingsWindow:` to
/// the responder chain. This works regardless of starting policy.
private struct GearButton: View {
    var body: some View {
        Button {
            openSettingsRobustly()
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.gfcTextSecondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open Settings (⌘,)")
    }

    private func openSettingsRobustly() {
        Log.ui.warning("GearButton tapped — entering openSettingsRobustly()")

        // The Settings scene won't COME FORWARD unless the app is .regular
        // and active. .accessory apps can dispatch showSettingsWindow:
        // successfully (the selector returns true) yet the window-server
        // never brings the window to front — which is exactly the bug:
        // the log said "opened via showSettingsWindow:" but nothing
        // appeared. Promote, activate, dispatch, THEN explicitly hunt the
        // Settings window and raise it (it's created asynchronously, so we
        // poll for it on the next few run-loop turns).
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)

        let dispatched =
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) ||
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil) ||
            openSettingsViaMenu()
        Log.ui.warning("Settings dispatch result=\(dispatched) — now raising the window")

        // The SwiftUI Settings window materialises a beat after the action
        // fires. Poll up to ~1s for it and force it key+front+centered.
        raiseSettingsWindow(attempt: 0)
    }

    private func openSettingsViaMenu() -> Bool {
        guard let mainMenu = NSApp.mainMenu else { return false }
        for menuItem in mainMenu.items {
            guard let submenu = menuItem.submenu else { continue }
            for sub in submenu.items where
                sub.title.localizedCaseInsensitiveContains("settings") ||
                sub.title.localizedCaseInsensitiveContains("preferences") {
                if let action = sub.action,
                   NSApp.sendAction(action, to: sub.target, from: nil) {
                    return true
                }
            }
        }
        return false
    }

    /// Find the SwiftUI Settings window and force it to the front. SwiftUI
    /// names it "com_apple_SwiftUI_Settings_window"; we also match by title
    /// as a fallback. Retries a few times because the window is created
    /// asynchronously after showSettingsWindow: dispatches.
    private func raiseSettingsWindow(attempt: Int) {
        let win = NSApp.windows.first { w in
            (w.identifier?.rawValue.contains("Settings") ?? false) ||
            w.title.localizedCaseInsensitiveContains("settings") ||
            w.title.localizedCaseInsensitiveContains("preferences")
        }
        if let win {
            NSApp.activate(ignoringOtherApps: true)
            win.center()
            win.makeKeyAndOrderFront(nil)
            win.orderFrontRegardless()
            Log.ui.warning("Settings window raised: '\(win.title)' id=\(win.identifier?.rawValue ?? "—")")
            return
        }
        guard attempt < 10 else {
            Log.ui.error("Settings window never appeared after dispatch (policy=\(NSApp.activationPolicy().rawValue))")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            raiseSettingsWindow(attempt: attempt + 1)
        }
    }
}

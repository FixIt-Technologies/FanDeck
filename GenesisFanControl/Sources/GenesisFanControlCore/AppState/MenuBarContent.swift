//
//  MenuBarContent.swift
//  GenesisFanControlCore
//
//  Pure menu-bar rendering decisions extracted from AppDelegate.renderMenuBar().
//  No AppKit import in Core — NSImage/NSAttributedString allocation stays in
//  AppDelegate. AppDelegate calls symbol()+title() and wraps them for the
//  NSStatusItem button. The shouldSkip() cache check replaces the
//  lastMenuBarSymbol/lastMenuBarTitle early-return guard.
//

import Foundation

public struct MenuBarContent {

    // MARK: - symbol

    /// SF Symbol name for the given icon style. AppDelegate wraps this with
    /// NSImage(systemSymbolName:) and sets isTemplate = true.
    public static func symbol(for style: MenuBarIconStyle) -> String {
        switch style {
        case .color:       return "fanblades.fill"
        case .monochrome:  return "fanblades"
        case .temperature: return "thermometer.medium"
        }
    }

    // MARK: - title

    /// Composed title string (right of the icon). Empty string when nothing
    /// is configured. Non-empty strings are prefixed with a leading space
    /// so the text doesn't collide with the icon glyph.
    ///
    /// Logic mirrors AppDelegate.renderMenuBar() exactly:
    ///  1. If style == .temperature and headlineSensor != nil → format it.
    ///  2. If menuBarFan == .rpm/.percent and firstFan != nil → append reading.
    ///  3. For each id in pickedSensors (up to 2) whose sensor is present →
    ///     append formatted temp.
    /// Parts are joined with " · ".
    public static func title(style: MenuBarIconStyle,
                             menuBarFan: MenuBarFanDisplay,
                             firstFan: Fan?,
                             headlineSensor: TempSensor?,
                             pickedSensors: [TempSensor],
                             useFahrenheit: Bool) -> String {
        var parts: [String] = []

        // Headline temp for the .temperature icon style
        if style == .temperature, let s = headlineSensor {
            parts.append(s.formatted(useFahrenheit: useFahrenheit, precise: false))
        }

        // Optional fan readout
        switch menuBarFan {
        case .none:
            break
        case .rpm:
            if let f = firstFan {
                parts.append("\(f.currentRPM) RPM")
            }
        case .percent:
            if let f = firstFan {
                let pct = Int((f.loadFraction * 100).rounded())
                parts.append("\(pct)%")
            }
        }

        // Up to 2 sensor temps picked by the user (callers pass at most 2)
        for s in pickedSensors.prefix(2) {
            parts.append(s.formatted(useFahrenheit: useFahrenheit, precise: false))
        }

        return parts.isEmpty ? "" : " " + parts.joined(separator: " · ")
    }

    // MARK: - shouldSkip

    /// True when the symbol + title are byte-identical to the last-rendered
    /// values, meaning there is nothing new to show and the NSImage /
    /// NSAttributedString rebuild can be skipped (Focus B2 cache).
    /// Returns false on first render (nil cache values).
    public static func shouldSkip(symbol: String, title: String,
                                  lastSymbol: String?, lastTitle: String?) -> Bool {
        guard let lastSymbol, let lastTitle else { return false }
        return symbol == lastSymbol && title == lastTitle
    }
}

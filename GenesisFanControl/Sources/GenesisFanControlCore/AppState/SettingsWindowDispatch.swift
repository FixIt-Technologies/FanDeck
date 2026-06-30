//
//  SettingsWindowDispatch.swift
//  GenesisFanControlCore
//
//  Pure Settings-window detection and retry-state machine extracted from
//  SensorPanel.swift (GearButton.raiseSettingsWindow + isSettingsWindow).
//  No AppKit import in Core — NSApp queries stay in GearButton.
//

import Foundation

// MARK: - SettingsWindowAction

public enum SettingsWindowAction: Equatable, Sendable {
    /// Window found: raise it immediately.
    case raise
    /// Keep polling — schedule another attempt in ~100 ms.
    case retry
    /// First pass exhausted (attempt == 10, no fallback tried yet): fire
    /// the legacy selector + menu-scrape fallback once.
    case tryFallback
    /// Second pass also exhausted (didFallback true, attempt == 10):
    /// give up, log the failure.
    case giveUp
}

// MARK: - SettingsWindowDispatch

public struct SettingsWindowDispatch {

    // MARK: - isSettingsWindow

    /// Returns true when a window should be treated as the SwiftUI Settings
    /// window. Matches:
    ///   • SwiftUI's canonical identifier "com_apple_SwiftUI_Settings_window"
    ///     (which also satisfies `.contains("Settings")`)
    ///   • Any identifier containing "Settings" (case-sensitive, as used by
    ///     SwiftUI on macOS 14)
    ///   • Any title case-insensitively containing "settings" or "preferences"
    ///
    /// Mirrors the NSApp.windows.first { ... } predicate in
    /// GearButton.raiseSettingsWindow.
    public static func isSettingsWindow(identifier: String?, title: String) -> Bool {
        if let id = identifier {
            if id.contains("Settings") { return true }
        }
        let t = title.lowercased()
        return t.contains("settings") || t.contains("preferences")
    }

    // MARK: - nextAction

    /// Determine what the polling loop should do next.
    ///
    /// Maps exactly to the `raiseSettingsWindow(attempt:didFallback:)` control
    /// flow in GearButton:
    ///   • `found == true` → .raise (regardless of attempt count)
    ///   • `found == false, attempt < 10` → .retry (keep polling)
    ///   • `found == false, attempt >= 10, !didFallback` → .tryFallback
    ///   • `found == false, attempt >= 10, didFallback` → .giveUp
    ///
    /// When `didFallback` is true the second pass starts with attempt == 0
    /// again (the caller resets it after firing the fallback), so
    /// `nextAction(attempt: 0, didFallback: true, found: false)` → .retry.
    public static func nextAction(attempt: Int, didFallback: Bool, found: Bool) -> SettingsWindowAction {
        if found { return .raise }
        if attempt < 10 { return .retry }
        if !didFallback { return .tryFallback }
        return .giveUp
    }
}

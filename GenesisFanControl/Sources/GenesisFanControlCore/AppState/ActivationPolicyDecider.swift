//
//  ActivationPolicyDecider.swift
//  GenesisFanControlCore
//
//  Pure activation-policy decisions extracted from AppDelegate.
//  No AppKit import — the enum values are deliberately app-kit-free.
//  AppDelegate maps ActivationPolicyIntent → NSApplication.ActivationPolicy.
//

import Foundation

// MARK: - ActivationPolicyIntent

public enum ActivationPolicyIntent: Equatable, Sendable {
    case regular
    case accessory
}

// MARK: - ActivationPolicyDecider

public struct ActivationPolicyDecider {

    /// The policy the app should apply based on the user's "Show Dock Icon"
    /// preference. When true → .regular (app visible in Dock + ⌘-Tab);
    /// when false → .accessory (menu-bar-only).
    public static func targetPolicy(showDockIcon: Bool) -> ActivationPolicyIntent {
        showDockIcon ? .regular : .accessory
    }

    /// Whether a window-became-key event for `identifier` should promote
    /// the app to .regular so it is reachable via ⌘-Tab. Only the "main"
    /// window triggers promotion; other auxiliary windows (about, etc.) do not.
    /// Mirrors the `win.identifier?.rawValue == "main"` guard in
    /// AppDelegate.windowDidBecomeKey(_:).
    public static func shouldPromoteOnKeyWindow(identifier: String) -> Bool {
        identifier == "main"
    }

    /// Whether closing `closingID` (given the set of currently-visible window
    /// IDs) should trigger a demote back to the user's chosen policy.
    /// Demote fires only when no app-managed window (main or Settings) remains
    /// visible. Mirrors the `stillVisible` logic in AppDelegate.mainWindowWillClose.
    public static func shouldDemote(closingID: String, visibleWindowIDs: [String]) -> Bool {
        // Only act on main or Settings windows
        guard closingID == "main" || closingID.contains("Settings") else {
            return false
        }
        // Demote only when no managed window stays visible after this one closes.
        let managedVisible = visibleWindowIDs.contains { id in
            id == "main" || id.contains("Settings")
        }
        return !managedVisible
    }
}

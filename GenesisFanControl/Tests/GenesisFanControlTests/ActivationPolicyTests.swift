//
//  ActivationPolicyTests.swift
//  GenesisFanControlTests
//
//  Tests for ActivationPolicyDecider — the pure activation-policy
//  decision layer extracted from AppDelegate.
//
//  Covers three surfaces:
//    • targetPolicy(showDockIcon:)         — .regular vs .accessory mapping
//    • shouldPromoteOnKeyWindow(identifier:) — only "main" triggers promotion
//    • shouldDemote(closingID:visibleWindowIDs:) — demote-gating: only when no
//      managed (main or Settings) window remains visible; non-managed closes ignored
//

import XCTest
@testable import GenesisFanControlCore

final class ActivationPolicyTests: XCTestCase {

    // MARK: - ActivationPolicyIntent Equatable

    func testIntentEquatable() {
        XCTAssertEqual(ActivationPolicyIntent.regular, .regular)
        XCTAssertEqual(ActivationPolicyIntent.accessory, .accessory)
        XCTAssertNotEqual(ActivationPolicyIntent.regular, .accessory)
    }

    // MARK: - targetPolicy(showDockIcon:)

    func testTargetPolicyShowDockIconTrue_returnsRegular() {
        XCTAssertEqual(
            ActivationPolicyDecider.targetPolicy(showDockIcon: true),
            .regular
        )
    }

    func testTargetPolicyShowDockIconFalse_returnsAccessory() {
        XCTAssertEqual(
            ActivationPolicyDecider.targetPolicy(showDockIcon: false),
            .accessory
        )
    }

    // MARK: - shouldPromoteOnKeyWindow(identifier:)

    func testPromoteOnMain_true() {
        // The main window becoming key should trigger a promotion to .regular
        // so the app is reachable via ⌘-Tab.
        XCTAssertTrue(
            ActivationPolicyDecider.shouldPromoteOnKeyWindow(identifier: "main")
        )
    }

    func testPromoteOnSettingsWindow_false() {
        // The SwiftUI Settings window has a long reverse-DNS identifier.
        // It must NOT trigger a promotion (bug fix: previously promoted on Settings).
        XCTAssertFalse(
            ActivationPolicyDecider.shouldPromoteOnKeyWindow(
                identifier: "com_apple_SwiftUI_Settings_window"
            )
        )
    }

    func testPromoteOnAboutWindow_false() {
        // Auxiliary windows should not cause a policy change.
        XCTAssertFalse(
            ActivationPolicyDecider.shouldPromoteOnKeyWindow(identifier: "about")
        )
    }

    func testPromoteOnEmptyIdentifier_false() {
        XCTAssertFalse(
            ActivationPolicyDecider.shouldPromoteOnKeyWindow(identifier: "")
        )
    }

    func testPromoteOnMainUppercase_false() {
        // Identifier matching is exact and case-sensitive; "MAIN" ≠ "main".
        XCTAssertFalse(
            ActivationPolicyDecider.shouldPromoteOnKeyWindow(identifier: "MAIN")
        )
    }

    func testPromoteOnArbitraryAuxiliaryWindow_false() {
        XCTAssertFalse(
            ActivationPolicyDecider.shouldPromoteOnKeyWindow(identifier: "fanDetails")
        )
    }

    // MARK: - shouldDemote: non-managed window closes (always false)

    func testDemote_nonManagedWindowClosing_noOtherVisible_false() {
        // "about" is neither "main" nor contains "Settings" — guard fails immediately.
        XCTAssertFalse(
            ActivationPolicyDecider.shouldDemote(closingID: "about", visibleWindowIDs: [])
        )
    }

    func testDemote_emptyClosingID_false() {
        XCTAssertFalse(
            ActivationPolicyDecider.shouldDemote(closingID: "", visibleWindowIDs: [])
        )
    }

    func testDemote_fanDetailsWindowClosing_false() {
        XCTAssertFalse(
            ActivationPolicyDecider.shouldDemote(closingID: "fanDetails", visibleWindowIDs: [])
        )
    }

    func testDemote_nonManagedWindowClosing_managedWindowsPresent_false() {
        // Even though main is visible, closing a non-managed window must be a no-op.
        XCTAssertFalse(
            ActivationPolicyDecider.shouldDemote(
                closingID: "about",
                visibleWindowIDs: ["main", "com_apple_SwiftUI_Settings_window"]
            )
        )
    }

    // MARK: - shouldDemote: main window closes

    func testDemote_mainClosing_noOtherVisible_true() {
        // Nothing managed remains → demote.
        XCTAssertTrue(
            ActivationPolicyDecider.shouldDemote(closingID: "main", visibleWindowIDs: [])
        )
    }

    func testDemote_mainClosing_onlyAuxiliaryWindowsVisible_true() {
        // "about" and "changelog" are not managed → demote still fires.
        XCTAssertTrue(
            ActivationPolicyDecider.shouldDemote(
                closingID: "main",
                visibleWindowIDs: ["about", "changelog"]
            )
        )
    }

    func testDemote_mainClosing_settingsStillVisible_false() {
        // Bug fixed: used to demote even while Settings was open.
        // Settings window (contains "Settings") keeps us from demoting.
        XCTAssertFalse(
            ActivationPolicyDecider.shouldDemote(
                closingID: "main",
                visibleWindowIDs: ["com_apple_SwiftUI_Settings_window"]
            )
        )
    }

    func testDemote_mainClosing_mainStillInVisibleList_false() {
        // Defensive: if caller mistakenly includes the closing window in the
        // visible set (race / multi-window), we should not demote.
        XCTAssertFalse(
            ActivationPolicyDecider.shouldDemote(
                closingID: "main",
                visibleWindowIDs: ["main"]
            )
        )
    }

    func testDemote_mainClosing_bothManagedWindowsVisible_false() {
        XCTAssertFalse(
            ActivationPolicyDecider.shouldDemote(
                closingID: "main",
                visibleWindowIDs: ["main", "com_apple_SwiftUI_Settings_window"]
            )
        )
    }

    // MARK: - shouldDemote: Settings window closes

    func testDemote_settingsWindowClosing_noOtherVisible_true() {
        // Settings closes, main is also gone → demote.
        XCTAssertTrue(
            ActivationPolicyDecider.shouldDemote(
                closingID: "com_apple_SwiftUI_Settings_window",
                visibleWindowIDs: []
            )
        )
    }

    func testDemote_settingsWindowClosing_mainStillVisible_false() {
        // Bug fixed: closing Settings while main is still visible must NOT demote.
        XCTAssertFalse(
            ActivationPolicyDecider.shouldDemote(
                closingID: "com_apple_SwiftUI_Settings_window",
                visibleWindowIDs: ["main"]
            )
        )
    }

    func testDemote_settingsWindowClosing_settingsStillInVisibleList_false() {
        // Caller still lists the closing window as visible (defensive check).
        XCTAssertFalse(
            ActivationPolicyDecider.shouldDemote(
                closingID: "com_apple_SwiftUI_Settings_window",
                visibleWindowIDs: ["com_apple_SwiftUI_Settings_window"]
            )
        )
    }

    func testDemote_settingsWindowClosing_onlyAuxiliaryWindowsVisible_true() {
        // Aux windows don't count as managed — should demote.
        XCTAssertTrue(
            ActivationPolicyDecider.shouldDemote(
                closingID: "com_apple_SwiftUI_Settings_window",
                visibleWindowIDs: ["about"]
            )
        )
    }

    func testDemote_settingsWindowClosing_mainAndAuxVisible_false() {
        // main is managed → do NOT demote.
        XCTAssertFalse(
            ActivationPolicyDecider.shouldDemote(
                closingID: "com_apple_SwiftUI_Settings_window",
                visibleWindowIDs: ["main", "about"]
            )
        )
    }

    // MARK: - shouldDemote: Settings identifier matching (contains "Settings")

    func testDemote_recognizesCustomSettingsIdentifier_true() {
        // Any window whose ID contains "Settings" is treated as managed.
        // Verify contains-match fires for alternate identifier forms.
        XCTAssertTrue(
            ActivationPolicyDecider.shouldDemote(
                closingID: "AppSettings",
                visibleWindowIDs: []
            )
        )
    }

    func testDemote_containsCheckIsCaseSensitive_false() {
        // "settings" (lowercase) does not contain "Settings" (capital S) →
        // treated as non-managed → guard fails → false.
        XCTAssertFalse(
            ActivationPolicyDecider.shouldDemote(
                closingID: "com_apple_swiftui_settings_window",   // all lowercase
                visibleWindowIDs: []
            )
        )
    }

    // MARK: - Integration: full showDockIcon=false lifecycle

    /// Reproduces the exact sequence that had a premature-demote bug:
    ///   1. App launches → .accessory (no dock icon)
    ///   2. Main window appears & becomes key → promote to .regular
    ///   3. User opens Settings alongside main
    ///   4. User closes Settings → main still visible → must NOT demote
    ///   5. User closes main → nothing managed-visible → must demote
    func testFullLifecycle_showDockIconFalse() {
        // Step 1: idle policy
        XCTAssertEqual(ActivationPolicyDecider.targetPolicy(showDockIcon: false), .accessory)

        // Step 2: main window becomes key → promote
        XCTAssertTrue(ActivationPolicyDecider.shouldPromoteOnKeyWindow(identifier: "main"))

        // Step 3: Settings opens (both windows now visible — tested separately; no state here)

        // Step 4: Settings closes while main is still visible
        XCTAssertFalse(
            ActivationPolicyDecider.shouldDemote(
                closingID: "com_apple_SwiftUI_Settings_window",
                visibleWindowIDs: ["main"]
            ),
            "Must NOT demote when main is still visible after Settings closes"
        )

        // Step 5: Main closes, nothing managed remains
        XCTAssertTrue(
            ActivationPolicyDecider.shouldDemote(
                closingID: "main",
                visibleWindowIDs: []
            ),
            "Must demote when the last managed window closes"
        )
    }

    /// showDockIcon=true: targetPolicy is .regular; demote-gating still applies
    /// correctly (the caller decides whether to honour a demote under showDockIcon=true,
    /// but the decider itself is honest about whether managed windows remain).
    func testFullLifecycle_showDockIconTrue() {
        XCTAssertEqual(ActivationPolicyDecider.targetPolicy(showDockIcon: true), .regular)

        // Settings window key → does NOT promote (already .regular; guard in caller)
        XCTAssertFalse(
            ActivationPolicyDecider.shouldPromoteOnKeyWindow(
                identifier: "com_apple_SwiftUI_Settings_window"
            )
        )

        // Closing main with nothing remaining → decider says demote
        // (caller then checks showDockIcon=true and may stay .regular regardless)
        XCTAssertTrue(
            ActivationPolicyDecider.shouldDemote(
                closingID: "main",
                visibleWindowIDs: []
            )
        )
    }
}

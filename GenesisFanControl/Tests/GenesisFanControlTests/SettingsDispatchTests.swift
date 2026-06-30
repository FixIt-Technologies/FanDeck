//
//  SettingsDispatchTests.swift
//  GenesisFanControlTests
//
//  Tests for SettingsWindowDispatch — the pure Settings-window detection and
//  retry-state machine extracted from GearButton.raiseSettingsWindow.
//  Targets Seam 2 from the extraction summary.
//

import XCTest
@testable import GenesisFanControlCore

final class SettingsDispatchTests: XCTestCase {

    // MARK: - isSettingsWindow — identifier path

    func testIdentifierContainsSettingsReturnsTrue() {
        // SwiftUI's canonical identifier on macOS 14
        XCTAssertTrue(
            SettingsWindowDispatch.isSettingsWindow(
                identifier: "com_apple_SwiftUI_Settings_window",
                title: "Some Title"
            )
        )
    }

    func testIdentifierEqualsSettingsReturnsTrue() {
        XCTAssertTrue(
            SettingsWindowDispatch.isSettingsWindow(
                identifier: "Settings",
                title: ""
            )
        )
    }

    func testIdentifierHasSettingsAsSubstringReturnsTrue() {
        XCTAssertTrue(
            SettingsWindowDispatch.isSettingsWindow(
                identifier: "AppSettings_Panel",
                title: "Unrelated"
            )
        )
    }

    func testIdentifierContainsSettingsCaseSensitiveOnly() {
        // "settings" (lowercase) does NOT satisfy id.contains("Settings"),
        // but the title fallback fires; here title is also unrelated → false.
        XCTAssertFalse(
            SettingsWindowDispatch.isSettingsWindow(
                identifier: "appsettings",
                title: "About"
            )
        )
    }

    func testIdentifierWithLowercaseSettingsFallsBackToTitle() {
        // identifier has lowercase "settings", title saves it
        XCTAssertTrue(
            SettingsWindowDispatch.isSettingsWindow(
                identifier: "appsettings",
                title: "Settings"
            )
        )
    }

    // MARK: - isSettingsWindow — nil identifier, title path

    func testNilIdentifierTitleContainsSettingsLowercaseReturnsTrue() {
        XCTAssertTrue(
            SettingsWindowDispatch.isSettingsWindow(
                identifier: nil,
                title: "settings"
            )
        )
    }

    func testNilIdentifierTitleContainsSettingsMixedCaseReturnsTrue() {
        XCTAssertTrue(
            SettingsWindowDispatch.isSettingsWindow(
                identifier: nil,
                title: "Settings"
            )
        )
    }

    func testNilIdentifierTitleContainsSettingsAllCapsReturnsTrue() {
        XCTAssertTrue(
            SettingsWindowDispatch.isSettingsWindow(
                identifier: nil,
                title: "SETTINGS"
            )
        )
    }

    func testNilIdentifierTitleContainsPreferencesLowercaseReturnsTrue() {
        XCTAssertTrue(
            SettingsWindowDispatch.isSettingsWindow(
                identifier: nil,
                title: "preferences"
            )
        )
    }

    func testNilIdentifierTitleContainsPreferencesMixedCaseReturnsTrue() {
        XCTAssertTrue(
            SettingsWindowDispatch.isSettingsWindow(
                identifier: nil,
                title: "Preferences"
            )
        )
    }

    func testNilIdentifierTitleContainsPreferencesAllCapsReturnsTrue() {
        XCTAssertTrue(
            SettingsWindowDispatch.isSettingsWindow(
                identifier: nil,
                title: "PREFERENCES"
            )
        )
    }

    func testNilIdentifierTitleContainsSettingsAsSubstringReturnsTrue() {
        XCTAssertTrue(
            SettingsWindowDispatch.isSettingsWindow(
                identifier: nil,
                title: "App Settings & Privacy"
            )
        )
    }

    func testNilIdentifierUnrelatedTitleReturnsFalse() {
        XCTAssertFalse(
            SettingsWindowDispatch.isSettingsWindow(
                identifier: nil,
                title: "Main Window"
            )
        )
    }

    func testNilIdentifierEmptyTitleReturnsFalse() {
        XCTAssertFalse(
            SettingsWindowDispatch.isSettingsWindow(
                identifier: nil,
                title: ""
            )
        )
    }

    // MARK: - isSettingsWindow — non-nil identifier that does NOT match, title saves it

    func testUnrelatedIdentifierTitleSettingsReturnsTrue() {
        XCTAssertTrue(
            SettingsWindowDispatch.isSettingsWindow(
                identifier: "MainWindow",
                title: "Settings"
            )
        )
    }

    func testUnrelatedIdentifierTitlePreferencesReturnsTrue() {
        XCTAssertTrue(
            SettingsWindowDispatch.isSettingsWindow(
                identifier: "MainWindow",
                title: "Preferences"
            )
        )
    }

    func testUnrelatedIdentifierUnrelatedTitleReturnsFalse() {
        XCTAssertFalse(
            SettingsWindowDispatch.isSettingsWindow(
                identifier: "MainWindow",
                title: "About"
            )
        )
    }

    func testEmptyIdentifierUnrelatedTitleReturnsFalse() {
        XCTAssertFalse(
            SettingsWindowDispatch.isSettingsWindow(
                identifier: "",
                title: "About"
            )
        )
    }

    // MARK: - nextAction — found == true always raises (highest priority)

    func testFoundAtAttemptZeroRaises() {
        XCTAssertEqual(
            SettingsWindowDispatch.nextAction(attempt: 0, didFallback: false, found: true),
            .raise
        )
    }

    func testFoundAtAttemptNineRaises() {
        XCTAssertEqual(
            SettingsWindowDispatch.nextAction(attempt: 9, didFallback: false, found: true),
            .raise
        )
    }

    func testFoundAtAttemptTenRaises() {
        // found takes priority over exhaustion thresholds
        XCTAssertEqual(
            SettingsWindowDispatch.nextAction(attempt: 10, didFallback: false, found: true),
            .raise
        )
    }

    func testFoundWithDidFallbackTrueAttemptZeroRaises() {
        XCTAssertEqual(
            SettingsWindowDispatch.nextAction(attempt: 0, didFallback: true, found: true),
            .raise
        )
    }

    func testFoundWithDidFallbackTrueAttemptTenRaises() {
        XCTAssertEqual(
            SettingsWindowDispatch.nextAction(attempt: 10, didFallback: true, found: true),
            .raise
        )
    }

    // MARK: - nextAction — first pass (didFallback == false), not found

    func testFirstPassAttemptZeroNotFoundRetries() {
        XCTAssertEqual(
            SettingsWindowDispatch.nextAction(attempt: 0, didFallback: false, found: false),
            .retry
        )
    }

    func testFirstPassAttemptOneNotFoundRetries() {
        XCTAssertEqual(
            SettingsWindowDispatch.nextAction(attempt: 1, didFallback: false, found: false),
            .retry
        )
    }

    func testFirstPassAttemptNineNotFoundRetries() {
        // 9 < 10 → still retry
        XCTAssertEqual(
            SettingsWindowDispatch.nextAction(attempt: 9, didFallback: false, found: false),
            .retry
        )
    }

    func testFirstPassAttemptTenNotFoundTriggersFallback() {
        // Boundary: attempt == 10, no fallback yet → tryFallback
        XCTAssertEqual(
            SettingsWindowDispatch.nextAction(attempt: 10, didFallback: false, found: false),
            .tryFallback
        )
    }

    func testFirstPassAttemptElevenNotFoundTriggersFallback() {
        // attempt > 10, no fallback yet → still tryFallback
        XCTAssertEqual(
            SettingsWindowDispatch.nextAction(attempt: 11, didFallback: false, found: false),
            .tryFallback
        )
    }

    func testFirstPassAttemptHundredNotFoundTriggersFallback() {
        XCTAssertEqual(
            SettingsWindowDispatch.nextAction(attempt: 100, didFallback: false, found: false),
            .tryFallback
        )
    }

    // MARK: - nextAction — second pass (didFallback == true), not found

    func testSecondPassAttemptZeroNotFoundRetries() {
        // Caller reset attempt to 0 after firing fallback → second pass starts fresh
        XCTAssertEqual(
            SettingsWindowDispatch.nextAction(attempt: 0, didFallback: true, found: false),
            .retry
        )
    }

    func testSecondPassAttemptOneNotFoundRetries() {
        XCTAssertEqual(
            SettingsWindowDispatch.nextAction(attempt: 1, didFallback: true, found: false),
            .retry
        )
    }

    func testSecondPassAttemptNineNotFoundRetries() {
        // Still below threshold on second pass
        XCTAssertEqual(
            SettingsWindowDispatch.nextAction(attempt: 9, didFallback: true, found: false),
            .retry
        )
    }

    func testSecondPassAttemptTenNotFoundGivesUp() {
        // Boundary: attempt == 10, fallback already tried → give up
        XCTAssertEqual(
            SettingsWindowDispatch.nextAction(attempt: 10, didFallback: true, found: false),
            .giveUp
        )
    }

    func testSecondPassAttemptElevenNotFoundGivesUp() {
        XCTAssertEqual(
            SettingsWindowDispatch.nextAction(attempt: 11, didFallback: true, found: false),
            .giveUp
        )
    }

    func testSecondPassAttemptHundredNotFoundGivesUp() {
        XCTAssertEqual(
            SettingsWindowDispatch.nextAction(attempt: 100, didFallback: true, found: false),
            .giveUp
        )
    }

    // MARK: - nextAction — boundary 9 vs 10 is critical

    func testBoundaryAttemptNineIsRetry() {
        XCTAssertEqual(
            SettingsWindowDispatch.nextAction(attempt: 9, didFallback: false, found: false),
            .retry
        )
    }

    func testBoundaryAttemptTenIsTryFallback() {
        XCTAssertEqual(
            SettingsWindowDispatch.nextAction(attempt: 10, didFallback: false, found: false),
            .tryFallback
        )
    }

    func testBoundarySecondPassAttemptNineIsRetry() {
        XCTAssertEqual(
            SettingsWindowDispatch.nextAction(attempt: 9, didFallback: true, found: false),
            .retry
        )
    }

    func testBoundarySecondPassAttemptTenIsGiveUp() {
        XCTAssertEqual(
            SettingsWindowDispatch.nextAction(attempt: 10, didFallback: true, found: false),
            .giveUp
        )
    }

    // MARK: - Full lifecycle sequence (state-machine walk)

    func testFirstPassSequenceLeadsToTryFallback() {
        // Simulate 10 failed polls then check the transition
        var action: SettingsWindowAction = .retry
        for attempt in 0..<10 {
            action = SettingsWindowDispatch.nextAction(
                attempt: attempt, didFallback: false, found: false
            )
            XCTAssertEqual(action, .retry, "attempt \(attempt) should still retry")
        }
        // attempt == 10 → triggers fallback
        action = SettingsWindowDispatch.nextAction(attempt: 10, didFallback: false, found: false)
        XCTAssertEqual(action, .tryFallback)
    }

    func testSecondPassSequenceLeadsToGiveUp() {
        // After fallback fired, caller resets attempt to 0 and didFallback = true
        var action: SettingsWindowAction = .retry
        for attempt in 0..<10 {
            action = SettingsWindowDispatch.nextAction(
                attempt: attempt, didFallback: true, found: false
            )
            XCTAssertEqual(action, .retry, "second-pass attempt \(attempt) should still retry")
        }
        action = SettingsWindowDispatch.nextAction(attempt: 10, didFallback: true, found: false)
        XCTAssertEqual(action, .giveUp)
    }

    func testWindowFoundMidFirstPassRaisesImmediately() {
        // Window appears on attempt 5 of the first pass
        let action = SettingsWindowDispatch.nextAction(attempt: 5, didFallback: false, found: true)
        XCTAssertEqual(action, .raise)
    }

    func testWindowFoundMidSecondPassRaisesImmediately() {
        // Window appears on attempt 3 of the second pass
        let action = SettingsWindowDispatch.nextAction(attempt: 3, didFallback: true, found: true)
        XCTAssertEqual(action, .raise)
    }

    func testWindowFoundExactlyAtExhaustionBoundaryStillRaises() {
        // Even at the exhaustion boundary, found wins
        let action = SettingsWindowDispatch.nextAction(attempt: 10, didFallback: true, found: true)
        XCTAssertEqual(action, .raise)
    }

    // MARK: - SettingsWindowAction Equatable sanity

    func testActionEquatableDistinct() {
        let all: [SettingsWindowAction] = [.raise, .retry, .tryFallback, .giveUp]
        for (i, a) in all.enumerated() {
            for (j, b) in all.enumerated() {
                if i == j {
                    XCTAssertEqual(a, b)
                } else {
                    XCTAssertNotEqual(a, b)
                }
            }
        }
    }
}

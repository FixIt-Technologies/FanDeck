//
//  HelperHoldStateTests.swift
//  GenesisFanControlTests
//
//  Tests for Seam 5 — HelperHoldState (hold/release/reassert) and
//  HelperPeerAuth (peer authorization). Both types are pure value/enum
//  types with no async surface, so no MainActor or runloop draining is
//  needed.
//

import XCTest
@testable import GenesisFanControlCore

final class HelperHoldStateTests: XCTestCase {

    // MARK: - Initial state

    func testInitStartsEmpty() {
        let state = HelperHoldState()
        XCTAssertTrue(state.reassertTargets.isEmpty,
                      "Fresh HelperHoldState should have no held fans")
    }

    // MARK: - hold(_:rpm:)

    func testHoldAddsEntry() {
        var state = HelperHoldState()
        state.hold("fan0", rpm: 3000)
        XCTAssertEqual(state.reassertTargets["fan0"], 3000)
        XCTAssertEqual(state.reassertTargets.count, 1)
    }

    func testHoldOverwritesExistingRPM() {
        var state = HelperHoldState()
        state.hold("fan0", rpm: 3000)
        state.hold("fan0", rpm: 4500)
        XCTAssertEqual(state.reassertTargets["fan0"], 4500,
                       "Second hold on same fan should overwrite the RPM")
        XCTAssertEqual(state.reassertTargets.count, 1,
                       "Overwrite should not create a duplicate entry")
    }

    func testHoldMultipleFansAreTrackedIndependently() {
        var state = HelperHoldState()
        state.hold("fan0", rpm: 2000)
        state.hold("fan1", rpm: 5800)
        XCTAssertEqual(state.reassertTargets["fan0"], 2000)
        XCTAssertEqual(state.reassertTargets["fan1"], 5800)
        XCTAssertEqual(state.reassertTargets.count, 2)
    }

    func testHoldMinimumRPM() {
        var state = HelperHoldState()
        state.hold("fan0", rpm: 0)
        XCTAssertEqual(state.reassertTargets["fan0"], 0,
                       "hold stores whatever RPM the caller supplies — clamping is the caller's job")
    }

    func testHoldNegativeRPMStoredAsIs() {
        // HelperHoldState is a pure dictionary; validation is the helper's job.
        var state = HelperHoldState()
        state.hold("fan0", rpm: -1)
        XCTAssertEqual(state.reassertTargets["fan0"], -1)
    }

    // MARK: - release(_:)

    func testReleaseRemovesEntry() {
        var state = HelperHoldState()
        state.hold("fan0", rpm: 3000)
        state.release("fan0")
        XCTAssertNil(state.reassertTargets["fan0"])
        XCTAssertTrue(state.reassertTargets.isEmpty)
    }

    func testReleaseNonExistentFanIsNoop() {
        var state = HelperHoldState()
        state.hold("fan0", rpm: 3000)
        state.release("fan99")  // not held
        // fan0 must be untouched
        XCTAssertEqual(state.reassertTargets["fan0"], 3000,
                       "Releasing an unknown fan should leave existing holds intact")
        XCTAssertEqual(state.reassertTargets.count, 1)
    }

    func testReleaseOnEmptyStateIsNoop() {
        var state = HelperHoldState()
        state.release("fan0")  // nothing held at all
        XCTAssertTrue(state.reassertTargets.isEmpty)
    }

    func testReleaseLeavesOtherFansIntact() {
        var state = HelperHoldState()
        state.hold("fan0", rpm: 2000)
        state.hold("fan1", rpm: 5000)
        state.release("fan0")
        XCTAssertNil(state.reassertTargets["fan0"])
        XCTAssertEqual(state.reassertTargets["fan1"], 5000,
                       "Releasing one fan must not affect other held fans")
        XCTAssertEqual(state.reassertTargets.count, 1)
    }

    func testHoldThenReleaseAllLeavesEmpty() {
        var state = HelperHoldState()
        state.hold("fan0", rpm: 1200)
        state.hold("fan1", rpm: 3600)
        state.hold("fan2", rpm: 5800)
        state.release("fan0")
        state.release("fan1")
        state.release("fan2")
        XCTAssertTrue(state.reassertTargets.isEmpty,
                      "Releasing all fans should yield an empty reassertTargets")
    }

    func testReleaseTwiceIsIdempotent() {
        var state = HelperHoldState()
        state.hold("fan0", rpm: 3000)
        state.release("fan0")
        state.release("fan0")  // second call — must not crash or add phantom entry
        XCTAssertTrue(state.reassertTargets.isEmpty)
    }

    func testHoldAfterReleasRestoresEntry() {
        var state = HelperHoldState()
        state.hold("fan0", rpm: 3000)
        state.release("fan0")
        state.hold("fan0", rpm: 4200)
        XCTAssertEqual(state.reassertTargets["fan0"], 4200,
                       "Re-holding a previously released fan should work normally")
    }

    // MARK: - shouldRevertIdle(lastActivity:now:threshold:)

    func testIdleExactlyAtThresholdReturnsTrue() {
        let state = HelperHoldState()
        let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let threshold: TimeInterval = 30
        // now - lastActivity == threshold exactly → true (>= not >)
        XCTAssertTrue(state.shouldRevertIdle(lastActivity: base,
                                              now: base.addingTimeInterval(threshold),
                                              threshold: threshold),
                      "Interval equal to threshold should trigger idle revert")
    }

    func testIdleJustBelowThresholdReturnsFalse() {
        let state = HelperHoldState()
        let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let threshold: TimeInterval = 30
        let epsilon = 0.001
        XCTAssertFalse(state.shouldRevertIdle(lastActivity: base,
                                               now: base.addingTimeInterval(threshold - epsilon),
                                               threshold: threshold),
                       "Interval strictly below threshold should NOT trigger idle revert")
    }

    func testIdleWellAboveThresholdReturnsTrue() {
        let state = HelperHoldState()
        let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
        XCTAssertTrue(state.shouldRevertIdle(lastActivity: base,
                                              now: base.addingTimeInterval(120),
                                              threshold: 30))
    }

    func testIdleWhenNowEqualsLastActivityReturnsFalse() {
        let state = HelperHoldState()
        let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
        XCTAssertFalse(state.shouldRevertIdle(lastActivity: base,
                                               now: base,
                                               threshold: 30),
                       "Zero elapsed time should never trigger idle revert (positive threshold)")
    }

    func testIdleWithZeroThresholdReturnsTrueWhenNowEqualsLastActivity() {
        // threshold == 0: any now >= lastActivity satisfies the >= condition.
        let state = HelperHoldState()
        let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
        XCTAssertTrue(state.shouldRevertIdle(lastActivity: base,
                                              now: base,
                                              threshold: 0),
                      "Zero threshold: now == lastActivity should be treated as idle")
    }

    func testIdleWithZeroThresholdReturnsTrueWhenNowIsLater() {
        let state = HelperHoldState()
        let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
        XCTAssertTrue(state.shouldRevertIdle(lastActivity: base,
                                              now: base.addingTimeInterval(1),
                                              threshold: 0))
    }

    func testIdleWhenNowBeforeLastActivityReturnsFalse() {
        // Clocks can go backwards (NTP slew, mock). Interval is negative → false.
        let state = HelperHoldState()
        let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
        XCTAssertFalse(state.shouldRevertIdle(lastActivity: base,
                                               now: base.addingTimeInterval(-5),
                                               threshold: 30))
    }

    func testIdleWithVeryLargeThresholdReturnsFalse() {
        let state = HelperHoldState()
        let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
        XCTAssertFalse(state.shouldRevertIdle(lastActivity: base,
                                               now: base.addingTimeInterval(3600),
                                               threshold: TimeInterval(Int.max)),
                       "Unreachably large threshold should never trigger idle revert")
    }

    func testIdleIsPureAndDoesNotMutateTargets() {
        // shouldRevertIdle is a non-mutating func — verify reassertTargets unaffected.
        var state = HelperHoldState()
        state.hold("fan0", rpm: 3000)
        let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
        _ = state.shouldRevertIdle(lastActivity: base,
                                    now: base.addingTimeInterval(60),
                                    threshold: 30)
        XCTAssertEqual(state.reassertTargets["fan0"], 3000,
                       "shouldRevertIdle must not modify reassertTargets")
    }

    // MARK: - HelperPeerAuth.isAuthorized

    func testRootUIDWithNilConsoleIsAuthorized() {
        XCTAssertTrue(HelperPeerAuth.isAuthorized(uid: 0, consoleUID: nil),
                      "Root (uid 0) is always authorized, even when no console user is logged in")
    }

    func testRootUIDWithConsoleUserIsAuthorized() {
        XCTAssertTrue(HelperPeerAuth.isAuthorized(uid: 0, consoleUID: 501),
                      "Root (uid 0) is authorized regardless of console user")
    }

    func testRootUIDWhenConsoleUIDIsAlsoZero() {
        XCTAssertTrue(HelperPeerAuth.isAuthorized(uid: 0, consoleUID: 0))
    }

    func testConsoleUserIsAuthorized() {
        XCTAssertTrue(HelperPeerAuth.isAuthorized(uid: 501, consoleUID: 501),
                      "Active console user should be authorized")
    }

    func testDifferentNonRootUserIsNotAuthorized() {
        XCTAssertFalse(HelperPeerAuth.isAuthorized(uid: 502, consoleUID: 501),
                       "Non-root user whose uid != consoleUID must be denied")
    }

    func testNonRootWithNilConsoleIsNotAuthorized() {
        XCTAssertFalse(HelperPeerAuth.isAuthorized(uid: 501, consoleUID: nil),
                       "Non-root with no logged-in console user must be denied")
    }

    func testNonRootWithZeroConsoleIsNotAuthorized() {
        // uid 501, consoleUID 0 — they differ, uid != 0, so denied.
        XCTAssertFalse(HelperPeerAuth.isAuthorized(uid: 501, consoleUID: 0))
    }

    func testHighUIDMatchingConsoleIsAuthorized() {
        // Sanity-check with a high system-assigned UID (e.g. service accounts).
        let uid: uid_t = 65534
        XCTAssertTrue(HelperPeerAuth.isAuthorized(uid: uid, consoleUID: uid))
    }

    func testHighUIDNotMatchingConsoleIsDenied() {
        XCTAssertFalse(HelperPeerAuth.isAuthorized(uid: 65534, consoleUID: 65533))
    }

    // MARK: - Interaction: hold state doesn't affect auth (independence check)

    func testHoldStateAndAuthAreIndependent() {
        // HelperHoldState carries no auth knowledge; verify a full hold cycle
        // alongside auth checks doesn't interfere with either result.
        var state = HelperHoldState()
        state.hold("fan0", rpm: 3000)
        XCTAssertTrue(HelperPeerAuth.isAuthorized(uid: 0, consoleUID: nil))
        XCTAssertFalse(HelperPeerAuth.isAuthorized(uid: 999, consoleUID: nil))
        state.release("fan0")
        XCTAssertTrue(state.reassertTargets.isEmpty)
    }
}

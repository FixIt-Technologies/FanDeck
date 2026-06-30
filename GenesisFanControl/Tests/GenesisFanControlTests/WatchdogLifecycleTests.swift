//
//  WatchdogLifecycleTests.swift
//  GenesisFanControlTests
//
//  Unit tests for the max-hold watchdog seam: MaxHoldDecider.fansToRevert
//  and MaxHoldDecider.nonAutoFanIDs. All tests are pure value logic — no
//  timers, no singletons, no UI.
//

import XCTest
@testable import GenesisFanControlCore

final class WatchdogLifecycleTests: XCTestCase {

    // MARK: - Helpers

    private let maxHold: TimeInterval = 60 * 30 // 30 minutes, a realistic default

    private func makeFan(id: String = "F0",
                         name: String? = nil,
                         mode: FanMode = .auto) -> Fan {
        Fan(id: id, name: name ?? "Fan \(id)",
            minRPM: 1200, maxRPM: 5800,
            currentRPM: 2000, targetRPM: 2000,
            mode: mode)
    }

    private func makeSensorMode() -> FanMode {
        .sensorBased(sensorId: "TC0E", points: [
            RampPoint(tempC: 40, rpm: 1200),
            RampPoint(tempC: 80, rpm: 5800),
        ])
    }

    // Convenience: call fansToRevert and return a stable-ordered Set for
    // unordered comparisons (dictionary iteration order is non-deterministic).
    private func revert(holdSince: [String: Date],
                        now: Date,
                        maxHold: TimeInterval,
                        currentModes: [String: FanMode]) -> Set<String> {
        Set(MaxHoldDecider.fansToRevert(holdSince: holdSince,
                                        now: now,
                                        maxHold: maxHold,
                                        currentModes: currentModes))
    }

    // MARK: - fansToRevert: empty / baseline

    func testFansToRevertEmptyHoldSince() {
        let result = MaxHoldDecider.fansToRevert(
            holdSince: [:],
            now: Date(),
            maxHold: maxHold,
            currentModes: ["F0": .constant(rpm: 3000)]
        )
        XCTAssertTrue(result.isEmpty, "No tracked fans → nothing to revert")
    }

    func testFansToRevertEmptyCurrentModes() {
        // Fan is in holdSince and past deadline, but it has vanished from the
        // system (currentModes is empty) → must be excluded.
        let now = Date()
        let holdSince = ["F0": now.addingTimeInterval(-maxHold)]
        let result = MaxHoldDecider.fansToRevert(
            holdSince: holdSince,
            now: now,
            maxHold: maxHold,
            currentModes: [:]
        )
        XCTAssertTrue(result.isEmpty, "Fan absent from currentModes must be excluded")
    }

    // MARK: - fansToRevert: deadline boundary

    func testFansToRevertBelowDeadlineExcluded() {
        let now = Date()
        // Held for (maxHold - 1s) — not yet due.
        let holdSince = ["F0": now.addingTimeInterval(-(maxHold - 1))]
        let result = revert(holdSince: holdSince, now: now, maxHold: maxHold,
                            currentModes: ["F0": .constant(rpm: 3500)])
        XCTAssertFalse(result.contains("F0"),
                       "Fan held for less than maxHold must not be reverted")
    }

    func testFansToRevertExactlyAtDeadlineIncluded() {
        // now - holdSince == maxHold exactly (>= condition is inclusive).
        let now = Date()
        let holdSince = ["F0": now.addingTimeInterval(-maxHold)]
        let result = revert(holdSince: holdSince, now: now, maxHold: maxHold,
                            currentModes: ["F0": .constant(rpm: 3500)])
        XCTAssertTrue(result.contains("F0"),
                      "Fan held for exactly maxHold must be reverted")
    }

    func testFansToRevertPastDeadlineIncluded() {
        let now = Date()
        // Well past deadline: maxHold + 5 minutes.
        let holdSince = ["F0": now.addingTimeInterval(-(maxHold + 300))]
        let result = revert(holdSince: holdSince, now: now, maxHold: maxHold,
                            currentModes: ["F0": .constant(rpm: 4000)])
        XCTAssertTrue(result.contains("F0"),
                      "Fan held longer than maxHold must be reverted")
    }

    func testFansToRevertJustBelowBoundaryByTinyDelta() {
        // Subtract a small positive epsilon so the held duration is strictly < maxHold.
        let now = Date()
        let epsilon: TimeInterval = 0.001
        let holdSince = ["F0": now.addingTimeInterval(-(maxHold - epsilon))]
        let result = revert(holdSince: holdSince, now: now, maxHold: maxHold,
                            currentModes: ["F0": .constant(rpm: 3200)])
        XCTAssertFalse(result.contains("F0"),
                       "Fan just under maxHold by \(epsilon)s must not be reverted")
    }

    // MARK: - fansToRevert: mode filtering

    func testFansToRevertAutoModeExcludedEvenPastDeadline() {
        // The user manually returned to .auto before the watchdog fired —
        // we must NOT force a revert that would be a no-op / confusing.
        let now = Date()
        let holdSince = ["F0": now.addingTimeInterval(-(maxHold + 60))]
        let result = revert(holdSince: holdSince, now: now, maxHold: maxHold,
                            currentModes: ["F0": .auto])
        XCTAssertFalse(result.contains("F0"),
                       "Fan already in .auto mode must be excluded from revert list")
    }

    func testFansToRevertConstantModeIncluded() {
        let now = Date()
        let holdSince = ["F0": now.addingTimeInterval(-(maxHold + 1))]
        let result = revert(holdSince: holdSince, now: now, maxHold: maxHold,
                            currentModes: ["F0": .constant(rpm: 2800)])
        XCTAssertTrue(result.contains("F0"),
                      "Fan in .constant mode past deadline must be reverted")
    }

    func testFansToRevertSensorBasedModeIncluded() {
        let now = Date()
        let holdSince = ["F0": now.addingTimeInterval(-(maxHold + 1))]
        let result = revert(holdSince: holdSince, now: now, maxHold: maxHold,
                            currentModes: ["F0": makeSensorMode()])
        XCTAssertTrue(result.contains("F0"),
                      "Fan in .sensorBased mode past deadline must be reverted")
    }

    func testFansToRevertDisappearedFanExcluded() {
        // Fan is tracked in holdSince, has been past deadline for an hour,
        // but it no longer appears in currentModes (hardware disappeared).
        let now = Date()
        let holdSince = ["F0": now.addingTimeInterval(-(maxHold + 3600))]
        let result = revert(holdSince: holdSince, now: now, maxHold: maxHold,
                            currentModes: ["F1": .constant(rpm: 2000)])  // different fan
        XCTAssertFalse(result.contains("F0"),
                       "Fan absent from currentModes must be excluded (caller cleans holdSince)")
    }

    // MARK: - fansToRevert: multiple fans

    func testFansToRevertSelectsOnlyEligibleFromMixed() {
        // F0: past deadline, non-auto  → should revert
        // F1: past deadline, .auto     → excluded (user already auto'd)
        // F2: below deadline, .constant → excluded (not yet due)
        // F3: past deadline, disappeared → excluded (missing from currentModes)
        let now = Date()
        let holdSince: [String: Date] = [
            "F0": now.addingTimeInterval(-(maxHold + 60)),
            "F1": now.addingTimeInterval(-(maxHold + 60)),
            "F2": now.addingTimeInterval(-(maxHold - 120)),
            "F3": now.addingTimeInterval(-(maxHold + 60)),
        ]
        let currentModes: [String: FanMode] = [
            "F0": .constant(rpm: 3000),
            "F1": .auto,
            "F2": .constant(rpm: 2500),
            // F3 intentionally absent
        ]
        let result = revert(holdSince: holdSince, now: now, maxHold: maxHold,
                            currentModes: currentModes)
        XCTAssertEqual(result, ["F0"],
                       "Only F0 meets all three criteria (past deadline, non-auto, present)")
    }

    func testFansToRevertAllEligibleReturnsAll() {
        let now = Date()
        let holdSince: [String: Date] = [
            "F0": now.addingTimeInterval(-(maxHold + 10)),
            "F1": now.addingTimeInterval(-(maxHold + 20)),
            "F2": now.addingTimeInterval(-(maxHold + 30)),
        ]
        let currentModes: [String: FanMode] = [
            "F0": .constant(rpm: 3000),
            "F1": makeSensorMode(),
            "F2": .constant(rpm: 4500),
        ]
        let result = revert(holdSince: holdSince, now: now, maxHold: maxHold,
                            currentModes: currentModes)
        XCTAssertEqual(result, ["F0", "F1", "F2"],
                       "All three fans past deadline with non-auto modes must be reverted")
    }

    func testFansToRevertNoneEligibleWhenAllAuto() {
        // All fans are past deadline, but every one is already in .auto.
        let now = Date()
        let holdSince: [String: Date] = [
            "F0": now.addingTimeInterval(-(maxHold + 5)),
            "F1": now.addingTimeInterval(-(maxHold + 5)),
        ]
        let currentModes: [String: FanMode] = ["F0": .auto, "F1": .auto]
        let result = revert(holdSince: holdSince, now: now, maxHold: maxHold,
                            currentModes: currentModes)
        XCTAssertTrue(result.isEmpty,
                      "No fans should be reverted when all are already .auto")
    }

    func testFansToRevertExactBoundaryVsJustBelowForTwoFans() {
        // F0 is exactly at maxHold → included; F1 is 1 second short → excluded.
        let now = Date()
        let holdSince: [String: Date] = [
            "F0": now.addingTimeInterval(-maxHold),
            "F1": now.addingTimeInterval(-(maxHold - 1)),
        ]
        let currentModes: [String: FanMode] = [
            "F0": .constant(rpm: 3000),
            "F1": .constant(rpm: 3000),
        ]
        let result = revert(holdSince: holdSince, now: now, maxHold: maxHold,
                            currentModes: currentModes)
        XCTAssertEqual(result, ["F0"],
                       "Only F0 (exactly at boundary) must be reverted; F1 (1s short) must not")
    }

    // MARK: - nonAutoFanIDs: empty / all-auto

    func testNonAutoFanIDsEmptyFans() {
        let result = MaxHoldDecider.nonAutoFanIDs(fans: [])
        XCTAssertTrue(result.isEmpty, "No fans → no non-auto IDs")
    }

    func testNonAutoFanIDsAllAutoReturnsEmpty() {
        let fans = [
            makeFan(id: "F0", mode: .auto),
            makeFan(id: "F1", mode: .auto),
        ]
        let result = MaxHoldDecider.nonAutoFanIDs(fans: fans)
        XCTAssertTrue(result.isEmpty,
                      "All-auto fan list must produce empty non-auto ID set")
    }

    // MARK: - nonAutoFanIDs: single fan

    func testNonAutoFanIDsSingleConstantFan() {
        let fans = [makeFan(id: "F0", mode: .constant(rpm: 3000))]
        let result = MaxHoldDecider.nonAutoFanIDs(fans: fans)
        XCTAssertEqual(result, ["F0"],
                       "Single .constant fan → its ID must appear")
    }

    func testNonAutoFanIDsSingleSensorBasedFan() {
        let fans = [makeFan(id: "F0", mode: makeSensorMode())]
        let result = MaxHoldDecider.nonAutoFanIDs(fans: fans)
        XCTAssertEqual(result, ["F0"],
                       "Single .sensorBased fan → its ID must appear")
    }

    func testNonAutoFanIDsSingleAutoFanReturnsEmpty() {
        let fans = [makeFan(id: "F0", mode: .auto)]
        let result = MaxHoldDecider.nonAutoFanIDs(fans: fans)
        XCTAssertTrue(result.isEmpty,
                      "Single .auto fan → result must be empty")
    }

    // MARK: - nonAutoFanIDs: mixed modes

    func testNonAutoFanIDsMixedModesFiltersCorrectly() {
        let fans = [
            makeFan(id: "F0", mode: .auto),
            makeFan(id: "F1", mode: .constant(rpm: 2500)),
            makeFan(id: "F2", mode: makeSensorMode()),
        ]
        let result = MaxHoldDecider.nonAutoFanIDs(fans: fans)
        XCTAssertEqual(Set(result), ["F1", "F2"],
                       "Only F1 (.constant) and F2 (.sensorBased) must appear; F0 (.auto) excluded")
    }

    func testNonAutoFanIDsPreservesInputOrder() {
        // compactMap preserves the order of the source array — verify this.
        let fans = [
            makeFan(id: "F2", mode: .constant(rpm: 3000)),
            makeFan(id: "F0", mode: .constant(rpm: 2000)),
            makeFan(id: "F1", mode: makeSensorMode()),
        ]
        let result = MaxHoldDecider.nonAutoFanIDs(fans: fans)
        XCTAssertEqual(result, ["F2", "F0", "F1"],
                       "nonAutoFanIDs must preserve the order of the fans array")
    }

    func testNonAutoFanIDsAllNonAutoReturnsAllIDs() {
        let fans = [
            makeFan(id: "F0", mode: .constant(rpm: 1800)),
            makeFan(id: "F1", mode: .constant(rpm: 3200)),
            makeFan(id: "F2", mode: makeSensorMode()),
        ]
        let result = MaxHoldDecider.nonAutoFanIDs(fans: fans)
        XCTAssertEqual(result, ["F0", "F1", "F2"],
                       "All non-auto fans must appear in the result")
    }

    // MARK: - Integration: nonAutoFanIDs feeds fansToRevert (sleep/wake scenario)

    func testSleepWakeReassertFilterThenWatchdog() {
        // Simulate a sleep/wake flow:
        //   1. nonAutoFanIDs picks the non-auto fans to re-assert after wake.
        //   2. Later the watchdog calls fansToRevert to find those now-overdue.
        let wakeTime = Date()
        let fans = [
            makeFan(id: "F0", mode: .constant(rpm: 3000)),
            makeFan(id: "F1", mode: .auto),
            makeFan(id: "F2", mode: makeSensorMode()),
        ]

        // Step 1 — on wake, re-assert these fans.
        let toReassert = MaxHoldDecider.nonAutoFanIDs(fans: fans)
        XCTAssertEqual(Set(toReassert), ["F0", "F2"],
                       "Re-assert only non-auto fans after wake")

        // Step 2 — watchdog fires 31 minutes later.
        let now = wakeTime.addingTimeInterval(maxHold + 60)
        let holdSince: [String: Date] = Dictionary(uniqueKeysWithValues:
            toReassert.map { ($0, wakeTime) })
        let currentModes: [String: FanMode] = [
            "F0": .constant(rpm: 3000),
            "F1": .auto,           // still auto — not in holdSince anyway
            "F2": makeSensorMode(),
        ]
        let toRevert = revert(holdSince: holdSince, now: now, maxHold: maxHold,
                              currentModes: currentModes)
        XCTAssertEqual(toRevert, ["F0", "F2"],
                       "Both reasserted non-auto fans must be reverted after maxHold elapses")
    }

    func testTerminateRevertFilterOnlyNonAutoFans() {
        // applicationWillTerminate: revert only the fans that are non-auto.
        let fans = [
            makeFan(id: "F0", mode: .auto),
            makeFan(id: "F1", mode: .constant(rpm: 4000)),
            makeFan(id: "F2", mode: .auto),
            makeFan(id: "F3", mode: makeSensorMode()),
        ]
        let result = MaxHoldDecider.nonAutoFanIDs(fans: fans)
        XCTAssertEqual(Set(result), ["F1", "F3"],
                       "Only F1 and F3 need to be reverted to AUTO on terminate")
        XCTAssertFalse(result.contains("F0"), "F0 is already .auto")
        XCTAssertFalse(result.contains("F2"), "F2 is already .auto")
    }
}

//
//  MaxHoldDecider.swift
//  GenesisFanControlCore
//
//  Pure deadline + mode decisions for the max-hold watchdog.
//  Timer, DispatchWorkItem, and NSAlert stay in AppDelegate; only the
//  fan-selection logic moves here so it can be unit-tested.
//

import Foundation

public struct MaxHoldDecider {

    /// Fans that should be reverted to AUTO: those whose hold duration has
    /// reached or exceeded `maxHold` AND whose current mode is still
    /// non-auto. Fans absent from `currentModes` (fan disappeared) are
    /// also excluded — the caller should clean up `holdSince` for those.
    ///
    /// - Parameters:
    ///   - holdSince: Per-fan timestamps of the most-recent user-initiated
    ///     non-auto transition. Keyed by fanID.
    ///   - now: Current date (injectable for testing).
    ///   - maxHold: Maximum hold duration before revert (e.g. 30 * 60).
    ///   - currentModes: Live mode for each fan. Fans not present here are
    ///     considered "disappeared" and excluded from the result.
    /// - Returns: Fan IDs that should be reverted to `.auto`.
    public static func fansToRevert(holdSince: [String: Date],
                                    now: Date,
                                    maxHold: TimeInterval,
                                    currentModes: [String: FanMode]) -> [String] {
        var result: [String] = []
        for (fanID, since) in holdSince {
            let held = now.timeIntervalSince(since)
            guard held >= maxHold else { continue }
            // Fan disappeared from the system — skip (caller cleans up holdSince)
            guard let mode = currentModes[fanID] else { continue }
            // User switched back to auto manually — skip
            if case .auto = mode { continue }
            result.append(fanID)
        }
        return result
    }

    /// Fan IDs from `fans` that are currently in a non-auto mode.
    /// Used by applicationWillTerminate and systemDidWake to enumerate
    /// which fans need to be re-asserted or reverted.
    public static func nonAutoFanIDs(fans: [Fan]) -> [String] {
        fans.compactMap { fan in
            if case .auto = fan.mode { return nil }
            return fan.id
        }
    }
}

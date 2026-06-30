//
//  HelperHoldState.swift
//  GenesisFanControlCore
//
//  Pure hold/release state transitions for the privileged helper.
//  Threading (stateQueue.sync gating), DispatchSourceTimer (1 Hz
//  re-assertion), and the watchdog DispatchSourceTimer STAY in
//  main.swift so performance characteristics are unchanged.
//  Only the pure dictionary mutations and idle/auth decisions move here.
//

import Foundation
#if canImport(Darwin)
import Darwin   // uid_t
#endif

// MARK: - HelperHoldState

/// Value-type store of fanID → target RPM. The helper's stateQueue
/// serialises all mutations; only the pure state transitions live here.
public struct HelperHoldState: Sendable {
    public private(set) var reassertTargets: [String: Int] = [:]

    public init() {}

    /// Register or update a hold for `fanID` at `rpm`.
    public mutating func hold(_ fanID: String, rpm: Int) {
        reassertTargets[fanID] = rpm
    }

    /// Remove the hold for `fanID`. No-op if not held.
    public mutating func release(_ fanID: String) {
        reassertTargets.removeValue(forKey: fanID)
    }

    /// True when `lastActivity` is more than `threshold` seconds before
    /// `now` — i.e. the GUI has been silent long enough to be presumed dead.
    public func shouldRevertIdle(lastActivity: Date, now: Date,
                                 threshold: TimeInterval) -> Bool {
        now.timeIntervalSince(lastActivity) >= threshold
    }
}

// MARK: - HelperPeerAuth

public enum HelperPeerAuth {
    /// Allow root (uid 0) always; allow the active console user when their
    /// uid matches. Mirrors `isAuthorizedPeer` in helper/main.swift exactly.
    public static func isAuthorized(uid: uid_t, consoleUID: uid_t?) -> Bool {
        if uid == 0 { return true }
        if let consoleUID, uid == consoleUID { return true }
        return false
    }
}

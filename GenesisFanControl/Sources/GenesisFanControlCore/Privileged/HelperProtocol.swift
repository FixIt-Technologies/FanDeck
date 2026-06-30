//
//  HelperProtocol.swift
//  GenesisFanControlCore
//
//  Wire types shared by the unprivileged GUI / CLI and the privileged
//  helper daemon. Plain JSON over a Unix domain socket — one request per
//  line, one response per line. Codable on both ends.
//

import Foundation

public enum HelperConstants {
    /// Unix domain socket the helper binds and the client connects to.
    public static let socketPath = "/var/run/genesis-fan-control.sock"
    /// Where the privileged binary lives once installed.
    public static let installedHelperPath = "/usr/local/sbin/genesis-fan-control-helper"
    /// launchd label + plist path.
    public static let helperLabel = "dev.foltyn.genesis-fan-control.helper"
    public static let launchDaemonPath = "/Library/LaunchDaemons/dev.foltyn.genesis-fan-control.helper.plist"
    /// Bumped whenever the helper's behavior changes in a way the GUI
    /// needs to know about — even bug-fix-only changes (like the AUTO
    /// unlock order inversion). When this constant differs from what
    /// the installed helper returns, HelperClient.health() reports
    /// `.outdated` and the GUI raises the elevation banner so the user
    /// can re-install. Bump on every helper-side fix.
    ///
    /// v3 (2026-06-30): cred-check on accept, 0660 socket, locked-fan
    /// tracking + SIGTERM revert, idle watchdog. Old v2 helper has no
    /// safety net for a crashed GUI; everyone should upgrade.
    /// v4 (2026-06-30): canonical AUTO release — drop F0Md=0 readback
    /// retry (mode 0 is transient on AS, never stably reads back),
    /// classify md==3 as auto (firmware-System resting state), settle
    /// window after release. The old helper still does the readback
    /// retry which fails on every M-series Mac — must upgrade.
    /// v5 (2026-06-30): fix re-entrant dispatch_sync deadlock in the
    /// watchdog timer — the source was scheduled on stateQueue and its
    /// handler called stateQueue.sync, crashing libdispatch every ~60s.
    /// Watchdog now has its own dedicated queue.
    /// v6 (2026-06-30): pass `forceSafeReset: false` to the helper's own
    /// AppleSMCService. The old v5 helper called safeResetAllFansToAuto
    /// on every respawn (KeepAlive=true), silently wiping the user's
    /// pinned CONSTANT back to AUTO whenever launchd restarted it —
    /// manifesting in the GUI as the "constant speed jumping around"
    /// bug. v6 helpers leave user state alone on respawn.
    /// v7 (2026-06-30): the cached-.constant preservation branch in
    /// primeSnapshot was held regardless of SMC md value — so once a
    /// fan was set to CONSTANT, setMode(.auto) could never take effect
    /// (the per-tick reassertion would immediately re-push CONSTANT,
    /// and thermalmonitord, locked out, would let temperatures crash
    /// to ~1°C as feedback loops broke). v7 gates the cache hold on
    /// md == 1; firmware reclaim to md=3 now correctly flips us back
    /// to .auto. EMERGENCY upgrade.
    /// v8 (2026-06-30): ARCHITECTURE FIX. The helper now OWNS the hold:
    /// it tracks heldTargets and re-asserts CONSTANT on its own 1 Hz
    /// timer (root, persistent). The unprivileged GUI no longer
    /// re-asserts (it can't write SMC at all) — it set-once and the
    /// helper holds. This fixes AUTO (no GUI re-assertion fighting the
    /// release), constant-not-holding-via-CLI, and the 1 Hz socket
    /// spam / Ftst-bounce. The v7 helper has no re-assertion timer and
    /// would let CONSTANT drift; must upgrade.
    public static let protocolVersion = 8
}

public enum HelperRequest: Codable {
    case ping
    case setAuto(fanID: String)
    case setConstant(fanID: String, rpm: Int)
}

public struct HelperResponse: Codable {
    public let ok: Bool
    public let error: String?
    public let backendName: String?
    public let protocolVersion: Int?

    public init(ok: Bool, error: String? = nil, backendName: String? = nil, protocolVersion: Int? = nil) {
        self.ok = ok
        self.error = error
        self.backendName = backendName
        self.protocolVersion = protocolVersion
    }
}

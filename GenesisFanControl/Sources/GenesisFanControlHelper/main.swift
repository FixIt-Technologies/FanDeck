//
//  main.swift
//  genesis-fan-control-helper
//
//  Privileged daemon. Runs as root via launchd, owns AppleSMCService
//  writes, listens on a Unix domain socket for JSON requests from the
//  unprivileged GUI. Hardened per review #27:
//   • Socket is root:admin 0660 (so non-admin UIDs can't even connect).
//   • Every accepted connection is checked via getpeereid(2) — must be
//     root or the active console user.
//   • Every non-auto fan write is tracked in `lockedFans`. SIGTERM /
//     SIGINT revert every tracked fan to .auto before unlink + exit, so
//     a daemon kill (launchctl bootout, system shutdown, manual kill)
//     can't strand the fan at a pinned RPM.
//   • Idle watchdog: if no client has talked to us in >60s AND we hold
//     locked fans, revert them. Guards against a crashed GUI that
//     would otherwise leave fans pinned forever.
//

import Foundation
import Darwin
import SystemConfiguration
import GenesisFanControlCore

let stderrStream = FileHandle.standardError

func log(_ message: String) {
    let line = "[helper] \(Date()) \(message)\n"
    if let data = line.data(using: .utf8) { stderrStream.write(data) }
}

log("genesis-fan-control-helper starting (uid=\(getuid()))")

// helperClient: nil — we ARE the helper. Without this the helper's own
// AppleSMCService would try to connect to its own socket on any
// fallback path and deadlock.
guard let smc = AppleSMCService(helperClient: nil) else {
    log("FATAL: AppleSMCService failed to open")
    exit(1)
}
log("AppleSMC opened — backend=\(smc.backendName)")

let listenFD: Int32
do {
    listenFD = try UnixSocket.listen(atPath: HelperConstants.socketPath)
} catch {
    log("FATAL: bind/listen on \(HelperConstants.socketPath): \(error)")
    exit(2)
}
log("listening on \(HelperConstants.socketPath) (root:admin 0660)")

// MARK: - Locked-fan tracking + revert

/// Fans this helper has put into non-auto mode this session. Used by:
///   • SIGTERM/SIGINT — revert each one to .auto before exit so a kill
///     can't strand a fan at high RPM.
///   • Idle watchdog — if no client has talked to us in 60s and we're
///     holding locks, revert them.
///
/// SwiftAtomics not in std, so use a global serial queue to gate every
/// touch. Helper is otherwise single-threaded (accept loop), but the
/// watchdog timer fires on its own dispatch queue.
let stateQueue = DispatchQueue(label: "dev.foltyn.gfc.helper.state")
nonisolated(unsafe) var lockedFans: Set<String> = []
nonisolated(unsafe) var lastActivity: Date = Date()

@Sendable func recordActivity() {
    stateQueue.sync { lastActivity = Date() }
}

@Sendable func markLocked(_ fanID: String) {
    _ = stateQueue.sync { lockedFans.insert(fanID) }
}

@Sendable func markUnlocked(_ fanID: String) {
    _ = stateQueue.sync { lockedFans.remove(fanID) }
}

/// Revert every fan in `lockedFans` to auto. Best-effort — failures are
/// logged. Called from the SIGTERM handler (signal-safe enough — we're
/// already on our way out) and the idle watchdog.
func revertAllLockedFans(reason: String) {
    let snap = stateQueue.sync { lockedFans }
    guard !snap.isEmpty else { return }
    log("revertAllLockedFans: \(reason) — reverting \(snap.sorted())")
    for fanID in snap {
        let ok = smc.setMode(.auto, for: fanID)
        log("  revert \(fanID) -> \(ok ? "AUTO" : "FAILED")")
        if ok { markUnlocked(fanID) }
    }
}

// MARK: - Signal cleanup

// `signal(_:_:)` with a Swift closure that captures globals can't be
// formed into a C function pointer, and a signal handler doing real
// Swift work isn't async-signal-safe anyway. Use DispatchSourceSignal
// instead: ignore the signal at the libc layer (so default-terminate
// behavior doesn't fire), then the dispatch source delivers it as a
// normal queue event where we can safely call Swift, log, and revert.
//
// Don't trap SIGKILL — kernel doesn't deliver it; that's the failure
// mode the next helper boot's safeResetAllFansToAuto defends against.
// Background queue — main thread is pinned in the blocking accept() loop,
// so a main-queue signal source would never fire.
let signalQueue = DispatchQueue(label: "dev.foltyn.gfc.helper.signals")
func installSignalCleanup(_ sig: Int32, name: String) -> DispatchSourceSignal {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: signalQueue)
    src.setEventHandler {
        revertAllLockedFans(reason: name)
        unlink(HelperConstants.socketPath)
        _exit(0)
    }
    src.resume()
    return src
}
let sigterm = installSignalCleanup(SIGTERM, name: "SIGTERM")
let sigint  = installSignalCleanup(SIGINT,  name: "SIGINT")
_ = sigterm; _ = sigint   // retain past end of statement

// MARK: - Idle watchdog

/// Tick every 10s. If we're holding locks AND no client has talked to
/// us in >IDLE_REVERT_SECONDS, the GUI is presumed dead — revert. This
/// is the safety net for a crashed unprivileged process; the SIGTERM
/// path covers ordered shutdown.
///
/// IMPORTANT: the timer source runs on a DEDICATED queue, NOT stateQueue.
/// If it ran on stateQueue, the handler would already be on stateQueue
/// when it tries `stateQueue.sync { ... }` to peek at lockedFans —
/// libdispatch detects the re-entrant dispatch_sync and traps with
/// "BUG IN CLIENT OF LIBDISPATCH: dispatch_sync called on queue already
/// owned by current thread", crashing the helper every IDLE_REVERT
/// interval. Crash signature observed in DiagnosticReports/
/// genesis-fan-control-helper-2026-06-30-015838.ips.
let IDLE_REVERT_SECONDS: TimeInterval = 60
let watchdogQueue = DispatchQueue(label: "dev.foltyn.gfc.helper.watchdog")
let watchdog = DispatchSource.makeTimerSource(queue: watchdogQueue)
watchdog.schedule(deadline: .now() + 10, repeating: 10)
watchdog.setEventHandler {
    let (held, last) = stateQueue.sync { (lockedFans, lastActivity) }
    guard !held.isEmpty else { return }
    let idle = Date().timeIntervalSince(last)
    if idle >= IDLE_REVERT_SECONDS {
        // Do the revert OUTSIDE stateQueue.sync — setMode can take
        // seconds (Ftst unlock dance). The watchdog timer fires every
        // 10s and would otherwise pile up.
        DispatchQueue.global(qos: .userInitiated).async {
            revertAllLockedFans(reason: "idle \(Int(idle))s > \(Int(IDLE_REVERT_SECONDS))s")
        }
    }
}
watchdog.resume()

// MARK: - Per-request processing

let encoder = JSONEncoder()
let decoder = JSONDecoder()

func process(_ req: HelperRequest) -> HelperResponse {
    recordActivity()
    switch req {
    case .ping:
        return HelperResponse(ok: true,
                              backendName: smc.backendName,
                              protocolVersion: HelperConstants.protocolVersion)
    case .setAuto(let fanID):
        let ok = smc.setMode(.auto, for: fanID)
        log("setAuto \(fanID) -> \(ok)")
        if ok { markUnlocked(fanID) }
        return HelperResponse(ok: ok, error: ok ? nil : "SMC write rejected")
    case .setConstant(let fanID, let rpm):
        let ok = smc.setMode(.constant(rpm: rpm), for: fanID)
        log("setConstant \(fanID) \(rpm) -> \(ok)")
        if ok { markLocked(fanID) }
        return HelperResponse(ok: ok, error: ok ? nil : "SMC write rejected")
    }
}

/// Resolve the console user (the one logged in at the GUI). Falls back
/// to the SCDynamicStore copy; if that's empty, allow only root. This
/// is the standard macOS pattern for "is the request coming from the
/// person sitting at the screen" — the un-signed-dev replacement for
/// SMAppService + connection auditing.
func consoleUserUID() -> uid_t? {
    var uid: uid_t = 0
    var gid: gid_t = 0
    if let user = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) as String? {
        if !user.isEmpty && user != "loginwindow" { return uid }
    }
    return nil
}

/// Decide whether to accept the connection. Allow root (uid 0) always,
/// and the active console user. Reject everything else — explicitly
/// closes off the "any local UID can pin fans at 5800" attack the
/// world-writable socket allowed.
func isAuthorizedPeer(uid: uid_t, gid: gid_t) -> Bool {
    if uid == 0 { return true }
    if let consoleUID = consoleUserUID(), uid == consoleUID { return true }
    return false
}

func handle(client fd: Int32) {
    // Snap timeouts on every accepted fd — a malicious or stuck client
    // can't pin the helper indefinitely. 5s covers a worst-case Ftst
    // dance with comfortable headroom.
    UnixSocket.setTimeouts(fd, seconds: 5)

    // Cred check FIRST. Reject anything that isn't root or the console
    // user before reading a single byte.
    if let peer = UnixSocket.peerEUID(fd) {
        if !isAuthorizedPeer(uid: peer.uid, gid: peer.gid) {
            log("REJECT connection from euid=\(peer.uid) egid=\(peer.gid) — not root or console user")
            // Still write a response so the (hostile) caller doesn't
            // see EOF and silently retry — they get an explicit "no".
            if let payload = try? encoder.encode(
                HelperResponse(ok: false, error: "unauthorized peer")) {
                _ = try? UnixSocket.writeLine(fd, payload: payload)
            }
            return
        }
    } else {
        log("REJECT connection — getpeereid failed (errno=\(errno))")
        return
    }

    let response: HelperResponse
    do {
        let raw = try UnixSocket.readLine(fd)
        let req = try decoder.decode(HelperRequest.self, from: raw)
        response = process(req)
    } catch {
        response = HelperResponse(ok: false, error: "\(error)")
    }
    do {
        let payload = try encoder.encode(response)
        try UnixSocket.writeLine(fd, payload: payload)
    } catch {
        log("response write failed: \(error)")
    }
}

while true {
    let client = accept(listenFD, nil, nil)
    if client < 0 {
        if errno == EINTR { continue }
        log("accept(): \(String(cString: strerror(errno)))")
        continue
    }
    handle(client: client)
    close(client)
}

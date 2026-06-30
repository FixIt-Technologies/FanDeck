//
//  AppState.swift
//  GenesisFanControlCore
//
//  Polls the SMC service and republishes fans + sensors for the UI.
//  All SMC I/O (reads + writes) runs on a dedicated serial queue so a
//  slow operation — notably the Apple Silicon `Ftst` unlock dance, which
//  sleeps for ~3 s — can't freeze the SwiftUI main thread.
//

import Foundation
import Combine

public extension Notification.Name {
    /// Posted by AppState.setMode every time the user (UI / CLI / helper)
    /// initiates a mode change. The max-hold watchdog in the GUI listens
    /// for it to stamp / clear the per-fan deadline clock.
    /// userInfo: { "fanID": String, "isAuto": Bool }.
    static let gfcUserSetMode = Notification.Name("dev.foltyn.genesis-fan-control.userSetMode")
}

@MainActor
public final class AppState: ObservableObject {
    public static let shared = AppState()

    @Published public private(set) var fans: [Fan] = []
    @Published public private(set) var sensors: [TempSensor] = []
    @Published public private(set) var lastUpdated: Date = .distantPast
    /// Set to true the first time a fan write is rejected by the SMC —
    /// almost always means "needs root". The UI surfaces a banner.
    @Published public var needsElevation: Bool = false
    /// True when the privileged helper is installed and answering pings.
    @Published public private(set) var helperAvailable: Bool = false
    /// While `installHelper()` is running so the UI can show a spinner.
    @Published public private(set) var helperInstalling: Bool = false
    @Published public var helperInstallError: String?
    /// Most recent helper liveness/version check. Drives the banner copy
    /// so we can say "Install Helper" (down) vs. "Update Helper" (stale
    /// installed version vs. current).
    @Published public private(set) var helperHealth: HelperClient.Health = .down
    /// True while at least one SMC write is in flight — UI can show a
    /// spinner / disable controls if it wants. Backed by a counter, not
    /// a Bool, so overlapping writes (rapid clicks, drag commit + final
    /// click) don't flicker the indicator off mid-batch (review MED —
    /// "writeInFlight toggles false before queued writes drain").
    @Published public private(set) var writeInFlight: Bool = false
    private var inFlightCount: Int = 0 {
        didSet { writeInFlight = inFlightCount > 0 }
    }

    public nonisolated let helperClient = HelperClient()
    public nonisolated let smc: SMCService

    /// Serializes ALL access to `smc`. The Timer-driven tick(), the user's
    /// drag-driven setMode(), and the helper install completion handler all
    /// funnel through this queue so the underlying SMCService never sees
    /// concurrent calls.
    private nonisolated let smcQueue = DispatchQueue(
        label: "dev.foltyn.genesis-fan-control.smc",
        qos: .userInitiated
    )

    private var timer: Timer?

    public init(smc: SMCService? = nil, autoStartPolling: Bool = true) {
        let resolved: SMCService = smc ?? AppleSMCService() ?? MockSMCService()
        self.smc = resolved
        Log.lifecycle.info("AppState init — backend=\(resolved.backendName) simulated=\(resolved.isSimulated)")
        let snap = resolved.snapshot()
        self.fans = snap.fans
        self.sensors = snap.sensors
        if autoStartPolling { startPolling() }
    }

    public func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        Log.lifecycle.debug("Polling timer started (1s interval)")
    }

    public func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    /// Refresh from SMC. Dispatches the slow read pass to the SMC queue
    /// and republishes on the main actor. Safe to call from main.
    public func tick() {
        // Suppress polling ticks while a user-initiated write is in flight.
        // unlockFanControl can sleep up to ~10s on Apple Silicon (3s wait
        // for thermalmonitord + 300×100ms confirm loop). Without this
        // guard, the 1Hz polling timer queues 8+ ticks behind a single
        // setMode and they all drain in a 100ms burst on completion, each
        // one publishing a fresh snapshot to the UI → gauge flicker.
        // Both `inFlightCount` and tick() are @MainActor → race-free.
        guard inFlightCount == 0 else {
            Log.lifecycle.debug("tick suppressed — \(inFlightCount) write(s) in flight")
            return
        }
        let smc = self.smc
        let helperClient = self.helperClient
        // Throttle the helper liveness check to once every 5 s instead of
        // every tick. health() is a full socket round-trip (connect + write
        // + read + close + JSON-decode) — ~0.1% CPU but a steady stream of
        // syscalls + context switches for a value that changes only on
        // install/uninstall. `nil` means "skipped — leave health as-is".
        // (Banner liveness updating every 5 s rather than 1 s is
        // imperceptible.) tick() is @MainActor so `lastHealthCheck` is
        // race-free.
        let now = Date()
        let needHealth = now.timeIntervalSince(lastHealthCheck) >= 5
        smcQueue.async { [weak self] in
            smc.refresh()
            let snap = smc.snapshot()
            let health = needHealth ? helperClient.health() : nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.publish(snapshot: snap)
                if let health {
                    self.lastHealthCheck = now
                    self.applyHealth(health)
                }
            }
        }
    }

    /// When we last completed a helper liveness round-trip. Gates `tick()`'s
    /// `health()` call down to ~1/5 s (see `tick`).
    private var lastHealthCheck: Date = .distantPast

    /// Apply a fresh helper health reading, assigning each `@Published` only
    /// when it actually changes so an unchanged reading fires no
    /// objectWillChange (and thus no view invalidation).
    private func applyHealth(_ health: HelperClient.Health) {
        if helperHealth != health { helperHealth = health }
        switch health {
        case .healthy:
            if !helperAvailable { helperAvailable = true }
            // Only auto-clear the banner if the user hasn't been told they
            // need to act. installHelperError stays around so the user sees
            // the result of their last attempt.
            if needsElevation { needsElevation = false }
        case .outdated:
            if !helperAvailable { helperAvailable = true }
            if !needsElevation { needsElevation = true }
        case .down:
            if helperAvailable { helperAvailable = false }
            // Don't auto-flip needsElevation on .down alone — a brand-new
            // launch with no helper installed should wait for the first
            // failed write to surface the banner, otherwise users see it
            // before they've tried to do anything.
        }
    }

    /// Publish a fresh snapshot onto @Published fans/sensors, but FIRST
    /// merge in any pending user intent (modes the user has just clicked
    /// in the UI but whose SMC write hasn't completed yet). Without this
    /// merge, a polling tick that fires between the optimistic UI update
    /// and the setMode completion publishes the stale SMC snapshot and
    /// the gauge briefly flickers back to the firmware-clamped target.
    private func publish(snapshot snap: (fans: [Fan], sensors: [TempSensor])) {
        var merged = snap.fans
        for (id, intent) in pendingIntent {
            guard let i = merged.firstIndex(where: { $0.id == id }) else { continue }
            merged[i].mode = intent.mode
            if let t = intent.targetRPM { merged[i].targetRPM = t }
        }
        // SENSORS publish EVERY tick. This is a live temperature monitor —
        // its entire job is showing the current reading each second, so the
        // sensor array + the "Xs ago" timestamp must always advance. (A
        // 0.5 °C deadband here made the panel look frozen for many seconds
        // at idle and made "just now" lie — user-reported.) The cost is
        // bounded by SensorRow being Equatable (`.equatable()`), so only the
        // rows whose value actually moved re-render their body.
        sensors = snap.sensors
        lastUpdated = Date()

        // FANS stay deadbanded. The gauge is a control surface, not a live
        // graph: ±6–20 RPM of idle tach jitter shouldn't re-trigger the
        // fill's ease animation every tick. Republish only on a genuine
        // change (mode/target/envelope exact, currentRPM past a small
        // tolerance) so the gauge rests between real movements.
        if !Self.fansApproxEqual(fans, merged) {
            fans = merged
        }
    }

    /// Tolerant fan compare. Control-relevant fields (mode, targetRPM,
    /// envelope, identity) compare EXACTLY so any real change republishes
    /// instantly; only the noisy `currentRPM` live readout is deadbanded.
    /// `tol` = max(25 RPM, 1% of the fan envelope) — below human perception
    /// on the gauge, and below the ±6–20 RPM idle jitter measured on real
    /// hardware (which refuted Focus B's "Int RPMs are stable at idle"
    /// assumption). Compared against the last published value, so noise never
    /// accumulates a republish — only genuine drift past `tol` does.
    nonisolated static func fansApproxEqual(_ a: [Fan], _ b: [Fan]) -> Bool {
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) {
            if x.id != y.id || x.name != y.name { return false }
            if x.minRPM != y.minRPM || x.maxRPM != y.maxRPM { return false }
            if x.mode != y.mode || x.targetRPM != y.targetRPM { return false }
            let tol = max(25, (y.maxRPM - y.minRPM) / 100)
            if abs(x.currentRPM - y.currentRPM) >= tol { return false }
        }
        return true
    }

    /// Tolerant sensor compare — 0.5 °C deadband per sensor, measured from
    /// the last published reading. IDs/order/count must match exactly. A
    /// deadband (not a rounding bucket) is essential: ~30 diodes each carry
    /// ≥0.1 °C noise, so bucket-edge straddling would flip several sensors
    /// every tick and republish anyway; a deadband filters that flicker and
    /// fires only on genuine ≥0.5 °C drift. Tradeoff: precise-mode (0.1 °C)
    /// readouts update in coarser time steps — imperceptible on a fan monitor.
    nonisolated static func sensorsApproxEqual(_ a: [TempSensor], _ b: [TempSensor]) -> Bool {
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) {
            if x.id != y.id { return false }
            if abs(x.celsius - y.celsius) >= 0.5 { return false }
        }
        return true
    }

    /// Per-fan intent captured by `applyOptimisticMode` and cleared once
    /// the corresponding setMode write completes. Token-versioned so a
    /// click on fan F0 doesn't wipe a still-in-flight intent for fan F1,
    /// AND so click B's completion doesn't blow away click A's intent
    /// when A's setMode completes after B's enqueue (review MED — "multi-
    /// click setMode race wipes pendingIntent"). Only the writer holding
    /// the current per-fan token may clear it.
    private var pendingIntent: [String: PendingIntent] = [:]
    private var intentTokens: [String: UInt64] = [:]
    private var nextIntentToken: UInt64 = 1
    private struct PendingIntent {
        let mode: FanMode
        let targetRPM: Int?
        let token: UInt64
    }

    public func installHelper() {
        helperInstalling = true
        helperInstallError = nil
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try HelperInstaller.install()
                await MainActor.run { [weak self] in
                    self?.helperInstalling = false
                    self?.helperAvailable = true
                    self?.needsElevation = false
                }
            } catch {
                let msg = "\(error)"
                await MainActor.run { [weak self] in
                    self?.helperInstalling = false
                    self?.helperInstallError = msg
                }
            }
        }
    }

    // MARK: - Public mutators

    /// Apply a new fan mode. Returns immediately. The UI is updated
    /// optimistically so the gauge reflects the user's intent right away;
    /// the actual SMC write happens on `smcQueue` (where the M-series
    /// `Ftst` dance is free to sleep for several seconds without freezing
    /// the cursor). When the write resolves we refresh the snapshot — if
    /// the kernel rejected the write, the optimistic state is overwritten
    /// with reality and the elevation banner is raised.
    public func setMode(_ mode: FanMode, for fanID: String) {
        let myToken = applyOptimisticMode(mode, for: fanID)
        inFlightCount += 1
        // Stamp the max-hold clock — AppDelegate's watchdog listens
        // for this and auto-reverts fans held in non-auto for >30 min.
        // Sent for every user-driven setMode (including .auto, which
        // CLEARS the hold). The polling-loop's per-tick re-assertion
        // does NOT post this notification, so silent re-asserts don't
        // reset the deadline.
        let isAuto: Bool = { if case .auto = mode { return true } else { return false } }()
        NotificationCenter.default.post(
            name: .gfcUserSetMode,
            object: nil,
            userInfo: ["fanID": fanID, "isAuto": isAuto]
        )

        let smc = self.smc
        smcQueue.async { [weak self] in
            let ok = smc.setMode(mode, for: fanID)
            smc.refresh()
            let snap = smc.snapshot()
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !ok { self.needsElevation = true }
                // Only clear the pendingIntent entry if WE'RE still the
                // latest writer for this fan. A faster subsequent click
                // (B) would have replaced our token (A) before we got
                // here; clearing then would discard B's still-in-flight
                // intent and republish A's old SMC snapshot to the UI.
                if self.intentTokens[fanID] == myToken {
                    self.pendingIntent.removeValue(forKey: fanID)
                    self.intentTokens.removeValue(forKey: fanID)
                }
                self.publish(snapshot: snap)
                self.inFlightCount = max(0, self.inFlightCount - 1)
            }
        }
    }

    /// Push the requested mode into the published state immediately so the
    /// gauge tracks the user's drag even while the SMC write is still in
    /// flight. Also captured into `pendingIntent` so any polling-tick
    /// snapshot that lands between now and write-completion is merged with
    /// the user's intent (otherwise the UI flickers back to whatever the
    /// firmware reports — typically the previous setpoint).
    ///
    /// Returns the monotonic per-fan token assigned to THIS intent. The
    /// caller (setMode) passes it into the completion handler so a
    /// later click on the same fan can supersede earlier ones cleanly.
    @discardableResult
    private func applyOptimisticMode(_ mode: FanMode, for fanID: String) -> UInt64 {
        let token = nextIntentToken
        nextIntentToken &+= 1
        intentTokens[fanID] = token
        guard let i = fans.firstIndex(where: { $0.id == fanID }) else {
            return token
        }
        let intent: PendingIntent
        switch mode {
        case .auto:
            fans[i].mode = .auto
            intent = PendingIntent(mode: .auto, targetRPM: nil, token: token)
        case .constant(let rpm):
            let clamped = max(fans[i].minRPM, min(fans[i].maxRPM, rpm))
            fans[i].mode = .constant(rpm: clamped)
            fans[i].targetRPM = clamped
            // Deliberately DO NOT touch fans[i].currentRPM here. Previously
            // we set currentRPM = clamped to make the green fill snap to
            // the target, but the SetpointWall already telegraphs intent,
            // and a few seconds later setMode's completion publishes the
            // real (lower) currentRPM and the fill visibly DROPS — looks
            // like the bar is "jumping". Let the fill track physical RPM
            // honestly; it will animate up to the target over the next
            // 1–3 polling ticks.
            intent = PendingIntent(mode: .constant(rpm: clamped), targetRPM: clamped, token: token)
        case .sensorBased:
            fans[i].mode = mode
            intent = PendingIntent(mode: mode, targetRPM: nil, token: token)
        }
        pendingIntent[fanID] = intent
        return token
    }

    // MARK: - Convenience lookups

    public func fan(withID id: String) -> Fan? { fans.first { $0.id == id } }
    public func sensor(withID id: String) -> TempSensor? { sensors.first { $0.id == id } }

    public var headlineSensor: TempSensor? {
        sensors.filter { $0.kind == .cpu }.max(by: { $0.celsius < $1.celsius })
            ?? sensors.first
    }
}

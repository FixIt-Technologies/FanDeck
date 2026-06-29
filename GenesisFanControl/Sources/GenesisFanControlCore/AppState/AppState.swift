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
    /// spinner / disable controls if it wants.
    @Published public private(set) var writeInFlight: Bool = false

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
        let smc = self.smc
        let helperClient = self.helperClient
        smcQueue.async { [weak self] in
            smc.refresh()
            let snap = smc.snapshot()
            let health = helperClient.health()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.publish(snapshot: snap)
                self.helperHealth = health
                switch health {
                case .healthy:
                    self.helperAvailable = true
                    // Only auto-clear the banner if the user hasn't been
                    // told they need to act. installHelperError stays
                    // around so the user sees the result of their last
                    // attempt.
                    self.needsElevation = false
                case .outdated:
                    self.helperAvailable = true
                    self.needsElevation = true
                case .down:
                    self.helperAvailable = false
                    // Don't auto-flip needsElevation on .down alone — a
                    // brand-new launch with no helper installed should
                    // wait for the first failed write to surface the
                    // banner, otherwise users see it before they've
                    // tried to do anything.
                }
            }
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
        self.fans = merged
        self.sensors = snap.sensors
        self.lastUpdated = Date()
    }

    /// Per-fan intent captured by `applyOptimisticMode` and cleared once
    /// the corresponding setMode write completes. Read on the main actor
    /// only.
    private var pendingIntent: [String: PendingIntent] = [:]
    private struct PendingIntent {
        let mode: FanMode
        let targetRPM: Int?
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
        applyOptimisticMode(mode, for: fanID)
        writeInFlight = true

        let smc = self.smc
        smcQueue.async { [weak self] in
            let ok = smc.setMode(mode, for: fanID)
            smc.refresh()
            let snap = smc.snapshot()
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !ok { self.needsElevation = true }
                // The SMC cache has been updated by setMode, so primeSnapshot
                // returns the user's intent for this fan. Clear the pending
                // intent entry BEFORE publishing — if we still had it, the
                // merge would overwrite with stale-yet-identical data, no
                // harm but unnecessary work.
                self.pendingIntent.removeValue(forKey: fanID)
                self.publish(snapshot: snap)
                self.writeInFlight = false
            }
        }
    }

    /// Push the requested mode into the published state immediately so the
    /// gauge tracks the user's drag even while the SMC write is still in
    /// flight. Also captured into `pendingIntent` so any polling-tick
    /// snapshot that lands between now and write-completion is merged with
    /// the user's intent (otherwise the UI flickers back to whatever the
    /// firmware reports — typically the previous setpoint).
    private func applyOptimisticMode(_ mode: FanMode, for fanID: String) {
        guard let i = fans.firstIndex(where: { $0.id == fanID }) else { return }
        let intent: PendingIntent
        switch mode {
        case .auto:
            fans[i].mode = .auto
            intent = PendingIntent(mode: .auto, targetRPM: nil)
        case .constant(let rpm):
            let clamped = max(fans[i].minRPM, min(fans[i].maxRPM, rpm))
            fans[i].mode = .constant(rpm: clamped)
            fans[i].targetRPM = clamped
            fans[i].currentRPM = clamped
            intent = PendingIntent(mode: .constant(rpm: clamped), targetRPM: clamped)
        case .sensorBased:
            fans[i].mode = mode
            intent = PendingIntent(mode: mode, targetRPM: nil)
        }
        pendingIntent[fanID] = intent
    }

    // MARK: - Convenience lookups

    public func fan(withID id: String) -> Fan? { fans.first { $0.id == id } }
    public func sensor(withID id: String) -> TempSensor? { sensors.first { $0.id == id } }

    public var headlineSensor: TempSensor? {
        sensors.filter { $0.kind == .cpu }.max(by: { $0.celsius < $1.celsius })
            ?? sensors.first
    }
}

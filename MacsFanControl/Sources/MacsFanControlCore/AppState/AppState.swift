//
//  AppState.swift
//  MacsFanControlCore
//
//  Polls the SMC service and republishes fans + sensors for the UI.
//  Owns the singleton SMC service handle (mock for now).
//

import Foundation
import Combine

@MainActor
public final class AppState: ObservableObject {
    public static let shared = AppState()

    @Published public private(set) var fans: [Fan] = []
    @Published public private(set) var sensors: [TempSensor] = []
    @Published public private(set) var lastUpdated: Date = .distantPast

    public let smc: SMCService
    private var timer: Timer?

    public init(smc: SMCService = MockSMCService(), autoStartPolling: Bool = true) {
        self.smc = smc
        Log.lifecycle.info("AppState init — backend=\(smc.backendName) simulated=\(smc.isSimulated)")
        let snap = smc.snapshot()
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

    /// Manually advance the SMC and refresh the snapshot. Useful for
    /// tests + the CLI's one-shot mode.
    public func tick() {
        smc.refresh()
        let snap = smc.snapshot()
        fans = snap.fans
        sensors = snap.sensors
        lastUpdated = Date()
    }

    // MARK: - Public mutators

    public func setMode(_ mode: FanMode, for fanID: String) {
        smc.setMode(mode, for: fanID)
        let snap = smc.snapshot()
        fans = snap.fans
        sensors = snap.sensors
    }

    // MARK: - Convenience lookups

    public func fan(withID id: String) -> Fan? { fans.first { $0.id == id } }
    public func sensor(withID id: String) -> TempSensor? { sensors.first { $0.id == id } }

    public var headlineSensor: TempSensor? {
        sensors.filter { $0.kind == .cpu }.max(by: { $0.celsius < $1.celsius })
            ?? sensors.first
    }
}

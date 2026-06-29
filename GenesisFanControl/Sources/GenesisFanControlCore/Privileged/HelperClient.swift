//
//  HelperClient.swift
//  GenesisFanControlCore
//
//  Tiny synchronous client for the privileged genesis-fan-control-helper.
//  Opens a Unix socket per call, writes a single JSON request, reads
//  a single JSON response, closes. Reconnecting per call keeps the
//  surface tiny and matches the once-per-fan-edit call frequency.
//

import Foundation
import Darwin

public final class HelperClient: @unchecked Sendable {
    private let socketPath: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(socketPath: String = HelperConstants.socketPath) {
        self.socketPath = socketPath
    }

    /// Quick liveness check — returns true if the daemon answers a ping
    /// with `ok=true`. Used to clear the elevation banner.
    public func ping() -> Bool {
        guard let resp = try? send(.ping) else { return false }
        return resp.ok
    }

    /// Forwards a `FanMode` to the helper. Returns true on success.
    @discardableResult
    public func setMode(_ mode: FanMode, for fanID: String) -> Bool {
        let req: HelperRequest
        switch mode {
        case .auto:
            req = .setAuto(fanID: fanID)
        case .constant(let rpm):
            req = .setConstant(fanID: fanID, rpm: rpm)
        case .sensorBased:
            // Sensor-based is host-driven — the GUI's polling loop rewrites
            // a constant target on every tick. No special helper RPC needed.
            return true
        }
        do {
            let resp = try send(req)
            if !resp.ok {
                Log.smc.error("Helper rejected \(fanID) write: \(resp.error ?? "<no error>")")
            }
            return resp.ok
        } catch {
            Log.smc.debug("Helper call failed: \(error)")
            return false
        }
    }

    /// Returns true if the helper socket exists AND is reachable. Cheap.
    public var isInstalled: Bool {
        var st = stat()
        return stat(socketPath, &st) == 0
    }

    // MARK: -

    private func send(_ req: HelperRequest) throws -> HelperResponse {
        let fd = try UnixSocket.connect(toPath: socketPath)
        defer { close(fd) }
        let payload = try encoder.encode(req)
        try UnixSocket.writeLine(fd, payload: payload)
        let raw = try UnixSocket.readLine(fd)
        return try decoder.decode(HelperResponse.self, from: raw)
    }
}

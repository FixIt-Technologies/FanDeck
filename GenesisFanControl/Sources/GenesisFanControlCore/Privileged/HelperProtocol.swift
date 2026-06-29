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
    /// Bumped when the wire protocol breaks compatibility.
    public static let protocolVersion = 1
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

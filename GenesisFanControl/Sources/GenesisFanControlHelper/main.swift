//
//  main.swift
//  genesis-fan-control-helper
//
//  Privileged daemon. Runs as root via launchd, owns AppleSMCService
//  writes, listens on a Unix domain socket for JSON requests from the
//  unprivileged GUI.
//

import Foundation
import Darwin
import GenesisFanControlCore

let stderrStream = FileHandle.standardError

func log(_ message: String) {
    let line = "[helper] \(Date()) \(message)\n"
    if let data = line.data(using: .utf8) { stderrStream.write(data) }
}

log("genesis-fan-control-helper starting (uid=\(getuid()))")

guard let smc = AppleSMCService() else {
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
log("listening on \(HelperConstants.socketPath)")

signal(SIGTERM) { _ in
    unlink(HelperConstants.socketPath)
    _exit(0)
}
signal(SIGINT) { _ in
    unlink(HelperConstants.socketPath)
    _exit(0)
}

let encoder = JSONEncoder()
let decoder = JSONDecoder()

func process(_ req: HelperRequest) -> HelperResponse {
    switch req {
    case .ping:
        return HelperResponse(ok: true,
                              backendName: smc.backendName,
                              protocolVersion: HelperConstants.protocolVersion)
    case .setAuto(let fanID):
        let ok = smc.setMode(.auto, for: fanID)
        log("setAuto \(fanID) -> \(ok)")
        return HelperResponse(ok: ok, error: ok ? nil : "SMC write rejected")
    case .setConstant(let fanID, let rpm):
        let ok = smc.setMode(.constant(rpm: rpm), for: fanID)
        log("setConstant \(fanID) \(rpm) -> \(ok)")
        return HelperResponse(ok: ok, error: ok ? nil : "SMC write rejected")
    }
}

func handle(client fd: Int32) {
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

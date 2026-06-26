//
//  MFCLogger.swift
//  MacsFanControl
//
//  Ported from TimeTravel/TTLogger. Unified-logging façade using os.Logger.
//  View logs with:
//      log stream --predicate 'subsystem == "dev.foltyn.macsfancontrol"' --level debug
//      log stream --predicate 'subsystem == "dev.foltyn.macsfancontrol" AND category == "smc"' --level debug
//      log show   --predicate 'subsystem == "dev.foltyn.macsfancontrol"' --last 1h
//

import Foundation
import os.log

public enum MFCLogger {

    public static let subsystem = "dev.foltyn.macsfancontrol"

    // MARK: - Categories

    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let ui = Logger(subsystem: subsystem, category: "ui")
    public static let settings = Logger(subsystem: subsystem, category: "settings")
    public static let smc = Logger(subsystem: subsystem, category: "smc")
    public static let fans = Logger(subsystem: subsystem, category: "fans")
    public static let sensors = Logger(subsystem: subsystem, category: "sensors")
    public static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")

    // MARK: - Structured helpers

    public static func logAppLaunch() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let msgs = [
            "🚀 MacsFanControl launched",
            "Version: \(version)",
            "Build: \(build)",
            "macOS: \(os)",
        ]
        for m in msgs { app.info("\(m, privacy: .public)") }
        Task { @MainActor in
            for m in msgs {
                LogStore.shared.append(level: .info, category: "app", message: m)
            }
        }
    }

    public static func logSMCBackend(_ name: String, simulated: Bool) {
        let msg = "🔌 SMC backend: \(name)\(simulated ? " (simulated)" : "")"
        smc.info("\(msg, privacy: .public)")
        Task { @MainActor in
            LogStore.shared.append(level: .info, category: "smc", message: msg)
        }
    }

    public static func logError(_ error: Error, context: String, logger: Logger = app, category: String = "app") {
        let head = "❌ Error in \(context): \(error.localizedDescription)"
        logger.error("\(head, privacy: .public)")
        var msgs = [head]
        let nsError = error as NSError
        let domain = "  Domain: \(nsError.domain), Code: \(nsError.code)"
        logger.error("\(domain, privacy: .public)")
        msgs.append(domain)
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            let line = "  Underlying: \(underlying.localizedDescription)"
            logger.error("\(line, privacy: .public)")
            msgs.append(line)
        }
        Task { @MainActor in
            for m in msgs {
                LogStore.shared.append(level: .error, category: category, message: m)
            }
        }
    }
}

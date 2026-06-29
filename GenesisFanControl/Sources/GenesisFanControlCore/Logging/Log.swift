//
//  Log.swift
//  GenesisFanControlCore
//
//  Thin proxy around GFCLogger so call sites don't need `import os`.
//  Every call double-writes to the unified log AND the in-memory LogStore
//  (rendered by the in-app Logs panel).
//
//  Privacy note (verbatim from TimeTravel's Log.swift):
//  os.Logger redacts interpolated strings as "<private>" in unified logs
//  by default. Marking each interpolation `.public` lets `log stream` and
//  `log show` display the actual message — without this every line shows
//  as `<private>` and is useless for diagnosing runtime hangs. We do not
//  log secrets through Log.*.
//

import Foundation
import os.log

public struct LogCategory {
    public let logger: Logger
    public let categoryName: String

    public init(logger: Logger, categoryName: String) {
        self.logger = logger
        self.categoryName = categoryName
    }

    public func debug(_ message: String) {
        #if DEBUG
        print("🔍 [\(categoryName)] \(message)")
        #endif
        logger.debug("\(message, privacy: .public)")
        Task { @MainActor in
            LogStore.shared.append(level: .debug, category: categoryName, message: message)
        }
    }

    public func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        Task { @MainActor in
            LogStore.shared.append(level: .info, category: categoryName, message: message)
        }
    }

    public func notice(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        Task { @MainActor in
            LogStore.shared.append(level: .notice, category: categoryName, message: message)
        }
    }

    public func warning(_ message: String) {
        logger.warning("⚠️ \(message, privacy: .public)")
        Task { @MainActor in
            LogStore.shared.append(level: .warning, category: categoryName, message: message)
        }
    }

    public func error(_ message: String) {
        logger.error("❌ \(message, privacy: .public)")
        Task { @MainActor in
            LogStore.shared.append(level: .error, category: categoryName, message: message)
        }
    }

    public func fault(_ message: String) {
        logger.fault("🔥 \(message, privacy: .public)")
        Task { @MainActor in
            LogStore.shared.append(level: .fault, category: categoryName, message: message)
        }
    }
}

public enum Log {
    public static var app: LogCategory { LogCategory(logger: GFCLogger.app, categoryName: "app") }
    public static var ui: LogCategory { LogCategory(logger: GFCLogger.ui, categoryName: "ui") }
    public static var settings: LogCategory { LogCategory(logger: GFCLogger.settings, categoryName: "settings") }
    public static var smc: LogCategory { LogCategory(logger: GFCLogger.smc, categoryName: "smc") }
    public static var fans: LogCategory { LogCategory(logger: GFCLogger.fans, categoryName: "fans") }
    public static var sensors: LogCategory { LogCategory(logger: GFCLogger.sensors, categoryName: "sensors") }
    public static var lifecycle: LogCategory { LogCategory(logger: GFCLogger.lifecycle, categoryName: "lifecycle") }

    public static func logAppLaunch() { GFCLogger.logAppLaunch() }
    public static func logSMCBackend(_ name: String, simulated: Bool) { GFCLogger.logSMCBackend(name, simulated: simulated) }
    public static func logError(_ error: Error, context: String, category: LogCategory = Log.app) {
        GFCLogger.logError(error, context: context, logger: category.logger, category: category.categoryName)
    }
}

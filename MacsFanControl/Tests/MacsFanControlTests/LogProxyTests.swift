//
//  LogProxyTests.swift
//  MacsFanControlTests
//
//  Smoke tests for the Log façade in Log.swift and the MFCLogger helpers.
//  Every Log.<category>.<level>(msg) call also enqueues into LogStore via
//  Task { @MainActor in … }. We wait one tick (~50 ms) for that queue to drain
//  and then assert the entry made it through.
//

import XCTest
@testable import MacsFanControlCore

@MainActor
final class LogProxyTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        LogStore.shared.clear()
    }

    override func tearDown() async throws {
        LogStore.shared.clear()
        try await super.tearDown()
    }

    // MARK: - Per-level smoke

    func testLogAppInfoReachesStore() async throws {
        Log.app.info("hello-info")
        try await Task.sleep(nanoseconds: 50_000_000)
        let match = LogStore.shared.entries.first { $0.message == "hello-info" }
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.level, .info)
        XCTAssertEqual(match?.category, "app")
    }

    func testLogDebugWarningErrorAllReachStore() async throws {
        Log.smc.debug("dbg")
        Log.fans.warning("warn")
        Log.sensors.error("err")
        Log.lifecycle.notice("notice")
        Log.app.fault("fault")
        try await Task.sleep(nanoseconds: 80_000_000)

        let entries = LogStore.shared.entries
        XCTAssertNotNil(entries.first { $0.message == "dbg" && $0.level == .debug && $0.category == "smc" })
        XCTAssertNotNil(entries.first { $0.message == "warn" && $0.level == .warning && $0.category == "fans" })
        XCTAssertNotNil(entries.first { $0.message == "err" && $0.level == .error && $0.category == "sensors" })
        XCTAssertNotNil(entries.first { $0.message == "notice" && $0.level == .notice && $0.category == "lifecycle" })
        XCTAssertNotNil(entries.first { $0.message == "fault" && $0.level == .fault && $0.category == "app" })
    }

    // MARK: - Category names

    func testAllSevenCategoriesPresent() async throws {
        Log.app.info("a")
        Log.ui.info("b")
        Log.settings.info("c")
        Log.smc.info("d")
        Log.fans.info("e")
        Log.sensors.info("f")
        Log.lifecycle.info("g")
        try await Task.sleep(nanoseconds: 80_000_000)

        let expected: Set<String> = ["app", "ui", "settings", "smc", "fans", "sensors", "lifecycle"]
        XCTAssertTrue(expected.isSubset(of: LogStore.shared.categories),
                      "All seven categories should be registered")
    }

    // MARK: - MFCLogger helpers

    func testLogSMCBackendWritesToStore() async throws {
        Log.logSMCBackend("TestBackend", simulated: true)
        try await Task.sleep(nanoseconds: 80_000_000)
        let smcEntries = LogStore.shared.entries.filter { $0.category == "smc" }
        XCTAssertFalse(smcEntries.isEmpty)
        XCTAssertTrue(smcEntries.contains { $0.message.contains("TestBackend") })
        XCTAssertTrue(smcEntries.contains { $0.message.contains("simulated") })
    }

    func testLogAppLaunchWritesMultipleEntries() async throws {
        Log.logAppLaunch()
        try await Task.sleep(nanoseconds: 80_000_000)
        let appEntries = LogStore.shared.entries.filter { $0.category == "app" }
        // 🚀 launched + Version + Build + macOS = 4 lines
        XCTAssertGreaterThanOrEqual(appEntries.count, 4,
                                    "logAppLaunch should write at least four diagnostic lines")
        XCTAssertTrue(appEntries.contains { $0.message.contains("launched") })
        XCTAssertTrue(appEntries.contains { $0.message.contains("Version") })
        XCTAssertTrue(appEntries.contains { $0.message.contains("macOS") })
    }

    func testLogErrorEnqueuesErrorLevelEntries() async throws {
        struct Boom: LocalizedError {
            var errorDescription: String? { "kaboom" }
        }
        Log.logError(Boom(), context: "unit-test", category: Log.smc)
        try await Task.sleep(nanoseconds: 80_000_000)
        let errs = LogStore.shared.entries.filter { $0.level == .error }
        XCTAssertFalse(errs.isEmpty, "logError must enqueue at least one .error entry")
        XCTAssertTrue(errs.contains { $0.message.contains("kaboom") })
        XCTAssertTrue(errs.contains { $0.message.contains("unit-test") })
        XCTAssertTrue(errs.allSatisfy { $0.category == "smc" },
                      "logError should tag entries with the supplied category")
    }
}

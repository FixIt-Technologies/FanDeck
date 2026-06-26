//
//  LogStoreTests.swift
//  MacsFanControlTests
//
//  LogStore.shared is a MainActor singleton — clear() between tests.
//  Covers ring-buffer cap (1000 entries), category tracking, LogFilter
//  combinators, exportText line shape, exportJSON round-trip, clear.
//

import XCTest
@testable import MacsFanControlCore

@MainActor
final class LogStoreTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        LogStore.shared.clear()
    }

    override func tearDown() async throws {
        LogStore.shared.clear()
        try await super.tearDown()
    }

    // MARK: - Append

    func testAppendAddsEntry() {
        let store = LogStore.shared
        store.append(level: .info, category: "test", message: "hello")
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.message, "hello")
        XCTAssertEqual(store.entries.first?.level, .info)
        XCTAssertEqual(store.entries.first?.category, "test")
    }

    func testAppendTracksCategories() {
        let store = LogStore.shared
        store.append(level: .info, category: "alpha", message: "a")
        store.append(level: .info, category: "beta", message: "b")
        store.append(level: .info, category: "alpha", message: "a2")
        XCTAssertEqual(store.categories, Set(["alpha", "beta"]))
    }

    // MARK: - Ring buffer

    func testRingBufferCapsAt1000() {
        let store = LogStore.shared
        for i in 0..<1500 {
            store.append(level: .debug, category: "ring", message: "msg-\(i)")
        }
        XCTAssertEqual(store.entries.count, 1000,
                       "Ring buffer should evict oldest, capping at 1000")
        // Oldest surviving entry is msg-500 (0..499 evicted).
        XCTAssertEqual(store.entries.first?.message, "msg-500")
        XCTAssertEqual(store.entries.last?.message, "msg-1499")
    }

    // MARK: - Clear

    func testClearEmptiesEverything() {
        let store = LogStore.shared
        store.append(level: .info, category: "x", message: "y")
        store.append(level: .warning, category: "z", message: "w")
        store.clear()
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(store.categories.isEmpty)
    }

    // MARK: - LogFilter

    func testFilterAllMatchesEverything() {
        let entry = LogEntry(level: .info, category: "any", message: "hi")
        XCTAssertTrue(LogFilter.all.matches(entry))
    }

    func testFilterByLevelInclusion() {
        let filter = LogFilter(levels: [.error, .fault])
        XCTAssertTrue(filter.matches(LogEntry(level: .error, category: "c", message: "m")))
        XCTAssertTrue(filter.matches(LogEntry(level: .fault, category: "c", message: "m")))
        XCTAssertFalse(filter.matches(LogEntry(level: .info, category: "c", message: "m")))
        XCTAssertFalse(filter.matches(LogEntry(level: .debug, category: "c", message: "m")))
    }

    func testFilterByCategoryInclusion() {
        let filter = LogFilter(categories: ["smc", "fans"])
        XCTAssertTrue(filter.matches(LogEntry(level: .info, category: "smc", message: "m")))
        XCTAssertTrue(filter.matches(LogEntry(level: .info, category: "fans", message: "m")))
        XCTAssertFalse(filter.matches(LogEntry(level: .info, category: "ui", message: "m")))
    }

    func testFilterByDateRange() {
        let now = Date()
        let earlier = now.addingTimeInterval(-3600)
        let later = now.addingTimeInterval(3600)
        let filter = LogFilter(dateRange: earlier...later)
        XCTAssertTrue(filter.matches(LogEntry(timestamp: now, level: .info, category: "c", message: "m")))
        XCTAssertFalse(filter.matches(LogEntry(timestamp: now.addingTimeInterval(-7200),
                                               level: .info, category: "c", message: "m")))
        XCTAssertFalse(filter.matches(LogEntry(timestamp: now.addingTimeInterval(7200),
                                               level: .info, category: "c", message: "m")))
    }

    func testFilterBySearchTextMatchesMessage() {
        let filter = LogFilter(searchText: "boom")
        XCTAssertTrue(filter.matches(LogEntry(level: .info, category: "c", message: "Big BOOM today")))
        XCTAssertFalse(filter.matches(LogEntry(level: .info, category: "c", message: "all quiet")))
    }

    func testFilterBySearchTextMatchesCategory() {
        let filter = LogFilter(searchText: "settings")
        XCTAssertTrue(filter.matches(LogEntry(level: .info, category: "settings", message: "anything")))
        XCTAssertFalse(filter.matches(LogEntry(level: .info, category: "ui", message: "anything")))
    }

    func testFilterEmptySearchTextMatches() {
        let filter = LogFilter(searchText: "")
        // empty search treated as no filter
        XCTAssertTrue(filter.matches(LogEntry(level: .info, category: "c", message: "m")))
    }

    func testFilterCombinatorsAllMustMatch() {
        let now = Date()
        let filter = LogFilter(
            levels: [.error],
            categories: ["smc"],
            dateRange: now.addingTimeInterval(-60)...now.addingTimeInterval(60),
            searchText: "fail"
        )
        // Matches all four predicates:
        XCTAssertTrue(filter.matches(LogEntry(timestamp: now, level: .error,
                                              category: "smc", message: "fail to read")))
        // Wrong level:
        XCTAssertFalse(filter.matches(LogEntry(timestamp: now, level: .info,
                                               category: "smc", message: "fail to read")))
        // Wrong category:
        XCTAssertFalse(filter.matches(LogEntry(timestamp: now, level: .error,
                                               category: "ui", message: "fail to read")))
        // Wrong text:
        XCTAssertFalse(filter.matches(LogEntry(timestamp: now, level: .error,
                                               category: "smc", message: "all good")))
    }

    func testGetEntriesAppliesFilter() {
        let store = LogStore.shared
        store.append(level: .info, category: "a", message: "one")
        store.append(level: .error, category: "b", message: "boom")
        store.append(level: .warning, category: "a", message: "two")
        let errs = store.getEntries(filter: LogFilter(levels: [.error]))
        XCTAssertEqual(errs.count, 1)
        XCTAssertEqual(errs.first?.message, "boom")
    }

    // MARK: - exportText

    func testExportTextSingleEntryShape() {
        let store = LogStore.shared
        store.append(level: .info, category: "smc", message: "hello")
        let text = store.exportText()

        // Shape: "[YYYY-MM-DD HH:MM:SS.SSS] [INFO   ] [smc       ] hello"
        XCTAssertEqual(text.filter { $0 == "[" }.count, 3,
                       "Should have three [..] sections per line")
        XCTAssertTrue(text.contains("[INFO   ]"),
                      "Level 'info' should be uppercased and padded to width 7")
        XCTAssertTrue(text.contains("[smc       ]"),
                      "Category should be left-padded to width 10")
        XCTAssertTrue(text.hasSuffix("hello"))
    }

    func testExportTextMultipleLinesJoinedByNewline() {
        let store = LogStore.shared
        store.append(level: .info, category: "a", message: "one")
        store.append(level: .error, category: "b", message: "two")
        let text = store.exportText()
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasSuffix("one"))
        XCTAssertTrue(lines[1].hasSuffix("two"))
    }

    func testExportTextEmptyStoreIsEmptyString() {
        let store = LogStore.shared
        XCTAssertEqual(store.exportText(), "")
    }

    // MARK: - exportJSON

    func testExportJSONDecodesBackToEntries() throws {
        let store = LogStore.shared
        store.append(level: .info, category: "smc", message: "alpha")
        store.append(level: .fault, category: "fans", message: "beta")

        let data = try store.exportJSON()
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let decoded = try dec.decode([LogEntry].self, from: data)

        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].category, "smc")
        XCTAssertEqual(decoded[0].level, .info)
        XCTAssertEqual(decoded[0].message, "alpha")
        XCTAssertEqual(decoded[1].category, "fans")
        XCTAssertEqual(decoded[1].level, .fault)
        XCTAssertEqual(decoded[1].message, "beta")
    }

    func testExportJSONEmptyStoreIsEmptyArray() throws {
        let data = try LogStore.shared.exportJSON()
        let decoded = try JSONDecoder().decode([LogEntry].self, from: data)
        XCTAssertTrue(decoded.isEmpty)
    }

    // MARK: - LogLevel ordering

    func testLogLevelComparable() {
        XCTAssertLessThan(LogLevel.debug, LogLevel.info)
        XCTAssertLessThan(LogLevel.info, LogLevel.notice)
        XCTAssertLessThan(LogLevel.notice, LogLevel.warning)
        XCTAssertLessThan(LogLevel.warning, LogLevel.error)
        XCTAssertLessThan(LogLevel.error, LogLevel.fault)
    }

    func testLogLevelIconNonEmpty() {
        for level in LogLevel.allCases {
            XCTAssertFalse(level.icon.isEmpty, "Icon for \(level) is empty")
        }
    }

    func testLogLevelCodableRoundTrip() throws {
        for level in LogLevel.allCases {
            let data = try JSONEncoder().encode(level)
            let decoded = try JSONDecoder().decode(LogLevel.self, from: data)
            XCTAssertEqual(decoded, level)
        }
    }
}

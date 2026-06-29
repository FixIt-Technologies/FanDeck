//
//  LogStore.swift
//  GenesisFanControlCore
//
//  In-memory log storage with circular buffer for the in-app log viewer.
//  Ported verbatim from TimeTravel; only the singleton name + visibility changed.
//

import Foundation
import Combine

public enum LogLevel: String, Codable, CaseIterable, Comparable, Sendable {
    case debug, info, notice, warning, error, fault

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        let order: [LogLevel] = [.debug, .info, .notice, .warning, .error, .fault]
        guard let l = order.firstIndex(of: lhs), let r = order.firstIndex(of: rhs) else { return false }
        return l < r
    }

    public var icon: String {
        switch self {
        case .debug: return "🔍"
        case .info: return "ℹ️"
        case .notice: return "📌"
        case .warning: return "⚠️"
        case .error: return "❌"
        case .fault: return "🔥"
        }
    }
}

public struct LogEntry: Identifiable, Codable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let level: LogLevel
    public let category: String
    public let message: String

    public init(id: UUID = UUID(), timestamp: Date = Date(), level: LogLevel,
                category: String, message: String) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
    }
}

public struct LogFilter {
    public var levels: Set<LogLevel>?
    public var categories: Set<String>?
    public var dateRange: ClosedRange<Date>?
    public var searchText: String?

    public init(levels: Set<LogLevel>? = nil,
                categories: Set<String>? = nil,
                dateRange: ClosedRange<Date>? = nil,
                searchText: String? = nil) {
        self.levels = levels
        self.categories = categories
        self.dateRange = dateRange
        self.searchText = searchText
    }

    public static let all = LogFilter()

    public func matches(_ entry: LogEntry) -> Bool {
        if let levels, !levels.contains(entry.level) { return false }
        if let categories, !categories.contains(entry.category) { return false }
        if let dateRange, !dateRange.contains(entry.timestamp) { return false }
        if let searchText, !searchText.isEmpty {
            let q = searchText.lowercased()
            if !entry.message.lowercased().contains(q) && !entry.category.lowercased().contains(q) {
                return false
            }
        }
        return true
    }
}

@MainActor
public final class LogStore: ObservableObject {
    public static let shared = LogStore()

    @Published public private(set) var entries: [LogEntry] = []
    @Published public private(set) var categories: Set<String> = []

    private let maxEntries: Int
    private var buffer: [LogEntry] = []

    private init(maxEntries: Int = 1000) { self.maxEntries = maxEntries }

    public func append(level: LogLevel, category: String, message: String) {
        let entry = LogEntry(level: level, category: category, message: message)
        buffer.append(entry)
        categories.insert(category)
        if buffer.count > maxEntries {
            buffer.removeFirst(buffer.count - maxEntries)
        }
        entries = buffer
    }

    public func getEntries(filter: LogFilter = .all) -> [LogEntry] {
        buffer.filter { filter.matches($0) }
    }

    public func clear() {
        buffer.removeAll()
        categories.removeAll()
        entries = []
    }

    public func exportText() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return buffer.map { e in
            let ts = f.string(from: e.timestamp)
            let lvl = e.level.rawValue.uppercased().padding(toLength: 7, withPad: " ", startingAt: 0)
            let cat = e.category.padding(toLength: 10, withPad: " ", startingAt: 0)
            return "[\(ts)] [\(lvl)] [\(cat)] \(e.message)"
        }.joined(separator: "\n")
    }

    public func exportJSON() throws -> Data {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(buffer)
    }
}

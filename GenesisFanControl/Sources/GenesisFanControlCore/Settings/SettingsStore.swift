//
//  SettingsStore.swift
//  GenesisFanControlCore
//
//  User preferences (mirroring screenshots 1–3): General, Temperature
//  Sensor inclusion rules, Menu-bar icon presentation. Persisted to
//  UserDefaults via @Published+didSet.
//

import Foundation
import Combine

public enum MenuBarIconStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case color
    case monochrome
    case temperature
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .color: return "Color icon"
        case .monochrome: return "Monochrome icon"
        case .temperature: return "Headline temperature"
        }
    }
}

public enum MenuBarFanDisplay: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case rpm
    case percent
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .none: return "Don't show"
        case .rpm: return "RPM"
        case .percent: return "Load %"
        }
    }
}

@MainActor
public final class SettingsStore: ObservableObject {
    public static let shared = SettingsStore()

    // MARK: - General
    @Published public var openAtLogin: Bool {
        didSet { ud.set(openAtLogin, forKey: K.openAtLogin); Log.settings.info("openAtLogin=\(openAtLogin)") }
    }
    @Published public var checkUpdatesOnLaunch: Bool {
        didSet { ud.set(checkUpdatesOnLaunch, forKey: K.checkUpdatesOnLaunch) }
    }
    @Published public var showDockIcon: Bool {
        didSet { ud.set(showDockIcon, forKey: K.showDockIcon); Log.settings.info("showDockIcon=\(showDockIcon)") }
    }
    @Published public var languageCode: String {
        didSet { ud.set(languageCode, forKey: K.languageCode) }
    }

    // MARK: - Temperature sensors
    @Published public var includeSATANVMe: Bool {
        didSet { ud.set(includeSATANVMe, forKey: K.includeSATANVMe) }
    }
    @Published public var includeExternalDrives: Bool {
        didSet { ud.set(includeExternalDrives, forKey: K.includeExternalDrives) }
    }
    @Published public var includeEGPU: Bool {
        didSet { ud.set(includeEGPU, forKey: K.includeEGPU) }
    }
    @Published public var useFahrenheit: Bool {
        didSet { ud.set(useFahrenheit, forKey: K.useFahrenheit); Log.settings.info("useFahrenheit=\(useFahrenheit)") }
    }
    @Published public var precise: Bool {
        didSet { ud.set(precise, forKey: K.precise) }
    }

    // MARK: - Menu bar icon
    @Published public var menuBarIconStyle: MenuBarIconStyle {
        didSet { ud.set(menuBarIconStyle.rawValue, forKey: K.menuBarIconStyle) }
    }
    @Published public var menuBarFan: MenuBarFanDisplay {
        didSet { ud.set(menuBarFan.rawValue, forKey: K.menuBarFan) }
    }
    @Published public var menuBarSensorIDs: [String] {
        didSet {
            if let data = try? JSONEncoder().encode(menuBarSensorIDs) {
                ud.set(data, forKey: K.menuBarSensorIDs)
            }
        }
    }

    // MARK: - Persistence backend

    private let ud: UserDefaults

    public enum K {
        public static let openAtLogin = "general.openAtLogin"
        public static let checkUpdatesOnLaunch = "general.checkUpdatesOnLaunch"
        public static let showDockIcon = "general.showDockIcon"
        public static let languageCode = "general.languageCode"
        public static let includeSATANVMe = "sensors.includeSATANVMe"
        public static let includeExternalDrives = "sensors.includeExternalDrives"
        public static let includeEGPU = "sensors.includeEGPU"
        public static let useFahrenheit = "sensors.useFahrenheit"
        public static let precise = "sensors.precise"
        public static let menuBarIconStyle = "menubar.iconStyle"
        public static let menuBarFan = "menubar.fan"
        public static let menuBarSensorIDs = "menubar.sensorIDs"
    }

    /// Designated init — defaults to `.standard`. Tests can inject a
    /// suite-scoped UserDefaults to round-trip without polluting the user's defaults.
    public init(defaults: UserDefaults = .standard) {
        self.ud = defaults
        openAtLogin = ud.object(forKey: K.openAtLogin) as? Bool ?? false
        checkUpdatesOnLaunch = ud.object(forKey: K.checkUpdatesOnLaunch) as? Bool ?? true
        showDockIcon = ud.object(forKey: K.showDockIcon) as? Bool ?? false
        languageCode = ud.string(forKey: K.languageCode) ?? "en"
        includeSATANVMe = ud.object(forKey: K.includeSATANVMe) as? Bool ?? true
        includeExternalDrives = ud.object(forKey: K.includeExternalDrives) as? Bool ?? false
        includeEGPU = ud.object(forKey: K.includeEGPU) as? Bool ?? false
        useFahrenheit = ud.object(forKey: K.useFahrenheit) as? Bool ?? false
        precise = ud.object(forKey: K.precise) as? Bool ?? true
        menuBarIconStyle = MenuBarIconStyle(rawValue: ud.string(forKey: K.menuBarIconStyle) ?? "color") ?? .color
        menuBarFan = MenuBarFanDisplay(rawValue: ud.string(forKey: K.menuBarFan) ?? "none") ?? .none
        if let data = ud.data(forKey: K.menuBarSensorIDs),
           let arr = try? JSONDecoder().decode([String].self, from: data) {
            menuBarSensorIDs = arr
        } else {
            menuBarSensorIDs = []
        }
        Log.settings.debug("SettingsStore loaded")
    }
}

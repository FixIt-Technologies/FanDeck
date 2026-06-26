//
//  SMCModels.swift
//  MacsFanControlCore
//
//  Domain types shared by the SMC service, the UI, and the `fans` CLI.
//

import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif

// MARK: - Sensor

public enum SensorKind: String, Codable, CaseIterable, Sendable {
    case cpu
    case gpu
    case battery
    case storage
    case airport
    case thunderbolt
    case proximity
    case power
    case trackpad
    case other

    public var sfSymbol: String {
        switch self {
        case .cpu: return "cpu"
        case .gpu: return "memorychip"
        case .battery: return "battery.100"
        case .storage: return "internaldrive"
        case .airport: return "wifi"
        case .thunderbolt: return "bolt.horizontal"
        case .proximity: return "location.viewfinder"
        case .power: return "powerplug"
        case .trackpad: return "rectangle.and.hand.point.up.left"
        case .other: return "thermometer"
        }
    }
}

public struct TempSensor: Identifiable, Hashable, Codable, Sendable {
    public let id: String          // SMC key, e.g. "TC0P"
    public let name: String        // "CPU Performance Core 1"
    public let kind: SensorKind
    public var celsius: Double

    public init(id: String, name: String, kind: SensorKind, celsius: Double) {
        self.id = id
        self.name = name
        self.kind = kind
        self.celsius = celsius
    }

    public var fahrenheit: Double { celsius * 9.0 / 5.0 + 32.0 }

    public func formatted(useFahrenheit: Bool, precise: Bool) -> String {
        let value = useFahrenheit ? fahrenheit : celsius
        let symbol = useFahrenheit ? "°F" : "°C"
        return precise
            ? String(format: "%.1f %@", value, symbol)
            : String(format: "%.0f %@", value, symbol)
    }
}

// MARK: - Fan

public enum FanMode: Codable, Hashable, Sendable {
    case auto
    case constant(rpm: Int)
    case sensorBased(sensorId: String, lowTempC: Double, highTempC: Double)

    public var displayName: String {
        switch self {
        case .auto: return "Automatic (OS-managed)"
        case .constant: return "Constant speed"
        case .sensorBased: return "Sensor-based"
        }
    }
}

public struct Fan: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let name: String
    public let minRPM: Int
    public let maxRPM: Int
    public var currentRPM: Int
    public var targetRPM: Int
    public var mode: FanMode

    public init(id: String, name: String, minRPM: Int, maxRPM: Int,
                currentRPM: Int, targetRPM: Int, mode: FanMode) {
        self.id = id
        self.name = name
        self.minRPM = minRPM
        self.maxRPM = maxRPM
        self.currentRPM = currentRPM
        self.targetRPM = targetRPM
        self.mode = mode
    }

    public var loadFraction: Double {
        guard maxRPM > minRPM else { return 0 }
        let r = Double(currentRPM - minRPM) / Double(maxRPM - minRPM)
        return max(0, min(1, r))
    }
}

#if canImport(SwiftUI)
public extension SensorKind {
    var accent: Color {
        switch self {
        case .cpu: return Color(red: 0.35, green: 0.85, blue: 0.55)
        case .gpu: return Color(red: 0.0, green: 0.94, blue: 1.0)
        case .battery: return Color(red: 1.0, green: 0.63, blue: 0.20)
        case .storage: return Color(red: 0.66, green: 0.33, blue: 0.97)
        case .airport, .thunderbolt: return Color(red: 0.0, green: 0.94, blue: 1.0)
        case .proximity, .power: return Color(red: 1.0, green: 0.63, blue: 0.20)
        case .trackpad: return Color(red: 0.35, green: 0.85, blue: 0.55)
        case .other: return .gray
        }
    }
}

public extension Fan {
    var loadColor: Color {
        switch loadFraction {
        case ..<0.4: return Color(red: 0.35, green: 0.85, blue: 0.55)
        case ..<0.75: return Color(red: 1.0, green: 0.63, blue: 0.20)
        default: return Color(red: 1.0, green: 0.35, blue: 0.35)
        }
    }
}
#endif

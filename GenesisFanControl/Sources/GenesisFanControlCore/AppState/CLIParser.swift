//
//  CLIParser.swift
//  GenesisFanControlCore
//
//  Pure CLI argument parsing — no AppKit, no I/O, no AppState access.
//  The `fans` executable's FansCLI.cmdSet calls these after resolving
//  fan/sensor existence at runtime; the parse layer stays pure so it can
//  be unit-tested without a running SMC.
//

import Foundation

// MARK: - SetModeSpec

public enum SetModeSpec: Equatable {
    case auto
    case const(rpm: Int)
    case sensor(sensorID: String, lowC: Double, highC: Double)
    case ramp(sensorID: String, points: [RampPoint])
}

// MARK: - ParsedCommand

public enum ParsedCommand: Equatable {
    case list
    case sensors
    case help
    case get(fanID: String)
    case sensor(id: String)
    case set(fanID: String, spec: SetModeSpec)
    case watch(interval: TimeInterval)
}

// MARK: - CLIParseError

public enum CLIParseError: Error, Equatable {
    case unknownCommand(String)
    case missingArguments(String)
    case badRPM(String)
    case badSensorTemp(String)
    case badRampPoint(String)
    case rampTooFew
}

// MARK: - CLIParser

public struct CLIParser {

    /// Parse an argument list (CommandLine.arguments.dropFirst()) into a
    /// ParsedCommand, or throw CLIParseError. Existence checks (unknown
    /// fanID, unknown sensorID) are NOT performed here — those stay as
    /// runtime guards in FansCLI where AppState is available.
    public static func parse(_ args: [String]) throws -> ParsedCommand {
        guard let command = args.first else {
            return .help
        }
        switch command {
        case "list":
            return .list
        case "sensors":
            return .sensors
        case "-h", "--help", "help":
            return .help
        case "get":
            guard let fanID = args[safe: 1] else {
                throw CLIParseError.missingArguments("fans get <fanID>")
            }
            return .get(fanID: fanID)
        case "sensor":
            guard let id = args[safe: 1] else {
                throw CLIParseError.missingArguments("fans sensor <sensorID>")
            }
            return .sensor(id: id)
        case "set":
            return try parseSet(Array(args.dropFirst()))
        case "watch":
            let interval = args[safe: 1].flatMap(TimeInterval.init) ?? 1.0
            return .watch(interval: interval)
        default:
            throw CLIParseError.unknownCommand(command)
        }
    }

    private static func parseSet(_ args: [String]) throws -> ParsedCommand {
        guard args.count >= 2 else {
            throw CLIParseError.missingArguments("fans set <fanID> <auto|const|sensor|ramp> ...")
        }
        let fanID = args[0]
        let kind  = args[1]
        switch kind {
        case "auto":
            return .set(fanID: fanID, spec: .auto)
        case "const":
            guard let rpmStr = args[safe: 2], let rpm = Int(rpmStr) else {
                throw CLIParseError.badRPM(args[safe: 2] ?? "(missing)")
            }
            return .set(fanID: fanID, spec: .const(rpm: rpm))
        case "sensor":
            guard args.count >= 5 else {
                throw CLIParseError.missingArguments("fans set <fanID> sensor <sensorID> <lowC> <highC>")
            }
            guard let low = Double(args[3]) else {
                throw CLIParseError.badSensorTemp(args[3])
            }
            guard let high = Double(args[4]) else {
                throw CLIParseError.badSensorTemp(args[4])
            }
            let sid = args[2]
            return .set(fanID: fanID, spec: .sensor(sensorID: sid, lowC: low, highC: high))
        case "ramp":
            guard args.count >= 5 else {
                throw CLIParseError.missingArguments("fans set <fanID> ramp <sensorID> <c1:rpm1> <c2:rpm2> ...")
            }
            let sid = args[2]
            var pts: [RampPoint] = []
            for raw in args.dropFirst(3) {
                let parts = raw.split(separator: ":").map(String.init)
                guard parts.count == 2,
                      let c = Double(parts[0]),
                      let r = Int(parts[1]) else {
                    throw CLIParseError.badRampPoint(raw)
                }
                pts.append(RampPoint(tempC: c, rpm: r))
            }
            guard pts.count >= 2 else {
                throw CLIParseError.rampTooFew
            }
            return .set(fanID: fanID, spec: .ramp(sensorID: sid, points: pts))
        default:
            throw CLIParseError.unknownCommand(kind)
        }
    }

    /// Convert a SetModeSpec to a FanMode. The const RPM is passed through
    /// as-is (no clamping — mirrors fans/main.swift cmdSet; SMC clamps at
    /// write time). Sensor-based modes use the provided min/max as RPM
    /// endpoints of the 2-point convenience form; ramp points pass through.
    public static func fanMode(from spec: SetModeSpec, fanMin: Int, fanMax: Int) -> FanMode {
        switch spec {
        case .auto:
            return .auto
        case .const(let rpm):
            // No clamping: mirrors fans/main.swift cmdSet which passes the raw
            // user-supplied RPM straight to .constant. Hardware/SMC will clamp
            // at write time. Clamping here changed the displayName in "OK — …"
            // output, which is observable behaviour — executable wins (divergence rule).
            return .constant(rpm: rpm)
        case .sensor(let sid, let lowC, let highC):
            return .sensorBased(sensorId: sid,
                                lowTempC: lowC, highTempC: highC,
                                minRPM: fanMin, maxRPM: fanMax)
        case .ramp(let sid, let points):
            return .sensorBased(sensorId: sid, points: points)
        }
    }
}

// MARK: - Array safe subscript (private, mirrors fans/main.swift)

private extension Array {
    subscript(safe i: Int) -> Element? {
        indices.contains(i) ? self[i] : nil
    }
}

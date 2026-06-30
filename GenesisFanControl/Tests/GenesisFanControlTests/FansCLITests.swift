//
//  FansCLITests.swift
//  GenesisFanControlTests
//
//  Tests for CLIParser.parse(_:) and CLIParser.fanMode(from:fanMin:fanMax:).
//  Pure unit tests — no I/O, no AppState, no SMC, no runloop draining.
//

import XCTest
@testable import GenesisFanControlCore

final class FansCLITests: XCTestCase {

    // MARK: - parse: help / empty

    func testParseEmptyArgsReturnsHelp() throws {
        let cmd = try CLIParser.parse([])
        XCTAssertEqual(cmd, .help)
    }

    func testParseHelpKeywordReturnsHelp() throws {
        let cmd = try CLIParser.parse(["help"])
        XCTAssertEqual(cmd, .help)
    }

    func testParseShortHelpFlagReturnsHelp() throws {
        let cmd = try CLIParser.parse(["-h"])
        XCTAssertEqual(cmd, .help)
    }

    func testParseLongHelpFlagReturnsHelp() throws {
        let cmd = try CLIParser.parse(["--help"])
        XCTAssertEqual(cmd, .help)
    }

    // MARK: - parse: top-level leaf commands

    func testParseList() throws {
        let cmd = try CLIParser.parse(["list"])
        XCTAssertEqual(cmd, .list)
    }

    func testParseSensors() throws {
        let cmd = try CLIParser.parse(["sensors"])
        XCTAssertEqual(cmd, .sensors)
    }

    func testParseWatchDefaultsToOneSecond() throws {
        // No interval arg → flatMap(TimeInterval.init) returns nil → ?? 1.0
        let cmd = try CLIParser.parse(["watch"])
        XCTAssertEqual(cmd, .watch(interval: 1.0))
    }

    func testParseWatchWithExplicitInterval() throws {
        let cmd = try CLIParser.parse(["watch", "5"])
        XCTAssertEqual(cmd, .watch(interval: 5.0))
    }

    func testParseWatchWithFractionalInterval() throws {
        let cmd = try CLIParser.parse(["watch", "0.5"])
        XCTAssertEqual(cmd, .watch(interval: 0.5))
    }

    func testParseWatchWithBadIntervalDefaultsToOne() throws {
        // Non-numeric string → TimeInterval.init fails → fallback 1.0 (no throw)
        let cmd = try CLIParser.parse(["watch", "fast"])
        XCTAssertEqual(cmd, .watch(interval: 1.0))
    }

    // MARK: - parse: get

    func testParseGetWithFanID() throws {
        let cmd = try CLIParser.parse(["get", "F0"])
        XCTAssertEqual(cmd, .get(fanID: "F0"))
    }

    func testParseGetMissingFanIDThrows() {
        XCTAssertThrowsError(try CLIParser.parse(["get"])) { err in
            guard case CLIParseError.missingArguments = err else {
                return XCTFail("Expected .missingArguments, got \(err)")
            }
        }
    }

    // MARK: - parse: sensor

    func testParseSensorCommand() throws {
        let cmd = try CLIParser.parse(["sensor", "TC0E"])
        XCTAssertEqual(cmd, .sensor(id: "TC0E"))
    }

    func testParseSensorMissingIDThrows() {
        XCTAssertThrowsError(try CLIParser.parse(["sensor"])) { err in
            guard case CLIParseError.missingArguments = err else {
                return XCTFail("Expected .missingArguments, got \(err)")
            }
        }
    }

    // MARK: - parse: unknown command

    func testParseUnknownCommandThrows() {
        XCTAssertThrowsError(try CLIParser.parse(["frobnicate"])) { err in
            guard case CLIParseError.unknownCommand(let name) = err else {
                return XCTFail("Expected .unknownCommand, got \(err)")
            }
            XCTAssertEqual(name, "frobnicate")
        }
    }

    // MARK: - parse: set — top-level missing / bad args

    func testParseSetNoArgsThrows() {
        // "set" alone → parseSet([]) → args.count 0 < 2 → .missingArguments
        XCTAssertThrowsError(try CLIParser.parse(["set"])) { err in
            guard case CLIParseError.missingArguments = err else {
                return XCTFail("Expected .missingArguments, got \(err)")
            }
        }
    }

    func testParseSetOnlyFanIDThrows() {
        // "set F0" → parseSet(["F0"]) → args.count 1 < 2 → .missingArguments
        XCTAssertThrowsError(try CLIParser.parse(["set", "F0"])) { err in
            guard case CLIParseError.missingArguments = err else {
                return XCTFail("Expected .missingArguments, got \(err)")
            }
        }
    }

    func testParseSetUnknownKindThrows() {
        XCTAssertThrowsError(try CLIParser.parse(["set", "F0", "turbo"])) { err in
            guard case CLIParseError.unknownCommand(let name) = err else {
                return XCTFail("Expected .unknownCommand, got \(err)")
            }
            XCTAssertEqual(name, "turbo")
        }
    }

    // MARK: - parse: set auto

    func testParseSetAuto() throws {
        let cmd = try CLIParser.parse(["set", "F0", "auto"])
        XCTAssertEqual(cmd, .set(fanID: "F0", spec: .auto))
    }

    // MARK: - parse: set const

    func testParseSetConst() throws {
        let cmd = try CLIParser.parse(["set", "F0", "const", "3000"])
        XCTAssertEqual(cmd, .set(fanID: "F0", spec: .const(rpm: 3000)))
    }

    func testParseSetConstMissingRPMThrows() {
        // args[safe: 2] is nil → badRPM("(missing)")
        XCTAssertThrowsError(try CLIParser.parse(["set", "F0", "const"])) { err in
            guard case CLIParseError.badRPM(let s) = err else {
                return XCTFail("Expected .badRPM, got \(err)")
            }
            XCTAssertEqual(s, "(missing)")
        }
    }

    func testParseSetConstBadRPMStringThrows() {
        XCTAssertThrowsError(try CLIParser.parse(["set", "F0", "const", "fast"])) { err in
            guard case CLIParseError.badRPM(let s) = err else {
                return XCTFail("Expected .badRPM, got \(err)")
            }
            XCTAssertEqual(s, "fast")
        }
    }

    func testParseSetConstFloatStringThrows() {
        // Int("3000.0") fails even though it is a valid number
        XCTAssertThrowsError(try CLIParser.parse(["set", "F0", "const", "3000.0"])) { err in
            guard case CLIParseError.badRPM(let s) = err else {
                return XCTFail("Expected .badRPM, got \(err)")
            }
            XCTAssertEqual(s, "3000.0")
        }
    }

    func testParseSetConstNegativeRPMIsAccepted() throws {
        // The parser accepts any valid Int — no clamping occurs at parse or fanMode time;
        // the raw value passes through to the executable, which lets the SMC clamp at write.
        let cmd = try CLIParser.parse(["set", "F0", "const", "-100"])
        XCTAssertEqual(cmd, .set(fanID: "F0", spec: .const(rpm: -100)))
    }

    // MARK: - parse: set sensor

    func testParseSetSensor() throws {
        let cmd = try CLIParser.parse(["set", "F0", "sensor", "TC0E", "40.0", "80.0"])
        XCTAssertEqual(cmd, .set(fanID: "F0", spec: .sensor(sensorID: "TC0E", lowC: 40.0, highC: 80.0)))
    }

    func testParseSetSensorMissingArgsThrows() {
        // "set F0 sensor TC0E" — missing lowC and highC → args.count 4 < 5
        XCTAssertThrowsError(try CLIParser.parse(["set", "F0", "sensor", "TC0E"])) { err in
            guard case CLIParseError.missingArguments = err else {
                return XCTFail("Expected .missingArguments, got \(err)")
            }
        }
    }

    func testParseSetSensorBadLowTempThrows() {
        XCTAssertThrowsError(try CLIParser.parse(["set", "F0", "sensor", "TC0E", "hot", "80.0"])) { err in
            guard case CLIParseError.badSensorTemp(let s) = err else {
                return XCTFail("Expected .badSensorTemp, got \(err)")
            }
            XCTAssertEqual(s, "hot")
        }
    }

    func testParseSetSensorBadHighTempThrows() {
        XCTAssertThrowsError(try CLIParser.parse(["set", "F0", "sensor", "TC0E", "40.0", "hot"])) { err in
            guard case CLIParseError.badSensorTemp(let s) = err else {
                return XCTFail("Expected .badSensorTemp, got \(err)")
            }
            XCTAssertEqual(s, "hot")
        }
    }

    // MARK: - parse: set ramp

    func testParseSetRampTwoPoints() throws {
        let cmd = try CLIParser.parse(["set", "F0", "ramp", "TC0E", "40:1200", "80:5800"])
        let expected = ParsedCommand.set(fanID: "F0", spec: .ramp(sensorID: "TC0E", points: [
            RampPoint(tempC: 40, rpm: 1200),
            RampPoint(tempC: 80, rpm: 5800),
        ]))
        XCTAssertEqual(cmd, expected)
    }

    func testParseSetRampThreePoints() throws {
        let cmd = try CLIParser.parse(["set", "F0", "ramp", "TC0E", "40:1200", "65:3000", "80:5800"])
        let expected = ParsedCommand.set(fanID: "F0", spec: .ramp(sensorID: "TC0E", points: [
            RampPoint(tempC: 40, rpm: 1200),
            RampPoint(tempC: 65, rpm: 3000),
            RampPoint(tempC: 80, rpm: 5800),
        ]))
        XCTAssertEqual(cmd, expected)
    }

    func testParseSetRampMissingBothPointsThrows() {
        // "set F0 ramp TC0E" → parseSet count 3 < 5 → .missingArguments
        XCTAssertThrowsError(try CLIParser.parse(["set", "F0", "ramp", "TC0E"])) { err in
            guard case CLIParseError.missingArguments = err else {
                return XCTFail("Expected .missingArguments, got \(err)")
            }
        }
    }

    func testParseSetRampOnePointThrowsMissingArguments() {
        // 1 point arg → parseSet count 4 < 5 → .missingArguments fires before
        // the rampTooFew guard; the public API surface cannot produce .rampTooFew
        // for a 1-point call via normal argv.
        XCTAssertThrowsError(try CLIParser.parse(["set", "F0", "ramp", "TC0E", "40:1200"])) { err in
            guard case CLIParseError.missingArguments = err else {
                return XCTFail("Expected .missingArguments for single-point ramp, got \(err)")
            }
        }
    }

    func testParseSetRampBadPointNoColonThrows() {
        // "bad" has no ':' separator → parts.count == 1 ≠ 2 → .badRampPoint
        XCTAssertThrowsError(try CLIParser.parse(["set", "F0", "ramp", "TC0E", "bad", "80:5800"])) { err in
            guard case CLIParseError.badRampPoint(let s) = err else {
                return XCTFail("Expected .badRampPoint, got \(err)")
            }
            XCTAssertEqual(s, "bad")
        }
    }

    func testParseSetRampBadRPMInPointThrows() {
        // "40:abc" — temp parses but rpm does not parse as Int
        XCTAssertThrowsError(try CLIParser.parse(["set", "F0", "ramp", "TC0E", "40:abc", "80:5800"])) { err in
            guard case CLIParseError.badRampPoint(let s) = err else {
                return XCTFail("Expected .badRampPoint, got \(err)")
            }
            XCTAssertEqual(s, "40:abc")
        }
    }

    func testParseSetRampBadTempInPointThrows() {
        // "hot:5800" — temp does not parse as Double
        XCTAssertThrowsError(try CLIParser.parse(["set", "F0", "ramp", "TC0E", "hot:5800", "80:5800"])) { err in
            guard case CLIParseError.badRampPoint(let s) = err else {
                return XCTFail("Expected .badRampPoint, got \(err)")
            }
            XCTAssertEqual(s, "hot:5800")
        }
    }

    func testParseSetRampBadSecondPointThrows() {
        // First point is valid; second point is malformed → .badRampPoint on second
        XCTAssertThrowsError(try CLIParser.parse(["set", "F0", "ramp", "TC0E", "40:1200", "bad"])) { err in
            guard case CLIParseError.badRampPoint(let s) = err else {
                return XCTFail("Expected .badRampPoint, got \(err)")
            }
            XCTAssertEqual(s, "bad")
        }
    }

    // MARK: - fanMode(from:fanMin:fanMax:) — auto

    func testFanModeFromSpecAuto() {
        let mode = CLIParser.fanMode(from: .auto, fanMin: 1200, fanMax: 5800)
        XCTAssertEqual(mode, .auto)
    }

    // MARK: - fanMode(from:fanMin:fanMax:) — const (no clamping; executable wins per divergence rule)
    // fans/main.swift cmdSet passes the raw Int straight to .constant(rpm:), so the Core
    // seam matches: no min/max clamping. The SMC (or hardware) clamps at write time.

    func testFanModeFromConstInRange() {
        let mode = CLIParser.fanMode(from: .const(rpm: 3000), fanMin: 1200, fanMax: 5800)
        XCTAssertEqual(mode, .constant(rpm: 3000))
    }

    func testFanModeFromConstAboveMaxPassesThrough() {
        // No clamping: 6000 > fanMax 4000 but the raw RPM is returned as-is.
        let mode = CLIParser.fanMode(from: .const(rpm: 6000), fanMin: 1200, fanMax: 4000)
        XCTAssertEqual(mode, .constant(rpm: 6000))
    }

    func testFanModeFromConstBelowMinPassesThrough() {
        // No clamping: 100 < fanMin 1200 but the raw RPM is returned as-is.
        let mode = CLIParser.fanMode(from: .const(rpm: 100), fanMin: 1200, fanMax: 5800)
        XCTAssertEqual(mode, .constant(rpm: 100))
    }

    func testFanModeFromConstAtMinBoundary() {
        let mode = CLIParser.fanMode(from: .const(rpm: 1200), fanMin: 1200, fanMax: 5800)
        XCTAssertEqual(mode, .constant(rpm: 1200))
    }

    func testFanModeFromConstAtMaxBoundary() {
        let mode = CLIParser.fanMode(from: .const(rpm: 5800), fanMin: 1200, fanMax: 5800)
        XCTAssertEqual(mode, .constant(rpm: 5800))
    }

    func testFanModeFromConstNegativePassesThrough() {
        // Negative RPM passes through unchanged — SMC clamps at write time.
        let mode = CLIParser.fanMode(from: .const(rpm: -500), fanMin: 1200, fanMax: 5800)
        XCTAssertEqual(mode, .constant(rpm: -500))
    }

    // MARK: - fanMode(from:fanMin:fanMax:) — sensor (2-point convenience form)

    func testFanModeFromSensorBuildsTwoPointRamp() {
        let mode = CLIParser.fanMode(
            from: .sensor(sensorID: "TC0E", lowC: 40.0, highC: 80.0),
            fanMin: 1200,
            fanMax: 5800
        )
        // The 2-point convenience constructor maps lowC→fanMin, highC→fanMax.
        let expected = FanMode.sensorBased(
            sensorId: "TC0E",
            points: [
                RampPoint(tempC: 40.0, rpm: 1200),
                RampPoint(tempC: 80.0, rpm: 5800),
            ]
        )
        XCTAssertEqual(mode, expected)
    }

    func testFanModeFromSensorUsesProvidedFanMinMaxAsRPMEndpoints() {
        // fanMin/fanMax become the RPM endpoints of the 2-point ramp.
        let mode = CLIParser.fanMode(
            from: .sensor(sensorID: "TC0E", lowC: 50.0, highC: 90.0),
            fanMin: 800,
            fanMax: 6000
        )
        let expected = FanMode.sensorBased(
            sensorId: "TC0E",
            points: [
                RampPoint(tempC: 50.0, rpm: 800),
                RampPoint(tempC: 90.0, rpm: 6000),
            ]
        )
        XCTAssertEqual(mode, expected)
    }

    // MARK: - fanMode(from:fanMin:fanMax:) — ramp (pass-through, no clamping)

    func testFanModeFromRampPassesThroughPoints() {
        let pts = [
            RampPoint(tempC: 40, rpm: 1200),
            RampPoint(tempC: 65, rpm: 3000),
            RampPoint(tempC: 85, rpm: 5800),
        ]
        let mode = CLIParser.fanMode(
            from: .ramp(sensorID: "TC0E", points: pts),
            fanMin: 1200,
            fanMax: 5800
        )
        XCTAssertEqual(mode, .sensorBased(sensorId: "TC0E", points: pts))
    }

    func testFanModeFromRampDoesNotClampPointRPMs() {
        // fanMin/fanMax are NOT applied to ramp points — the ramp owns its RPMs.
        let pts = [
            RampPoint(tempC: 40, rpm: 800),   // below fanMin
            RampPoint(tempC: 85, rpm: 7000),  // above fanMax
        ]
        let mode = CLIParser.fanMode(
            from: .ramp(sensorID: "Fx", points: pts),
            fanMin: 1200,
            fanMax: 5800
        )
        XCTAssertEqual(mode, .sensorBased(sensorId: "Fx", points: pts))
    }

    func testFanModeFromRampPreservesPointOrder() {
        // Points are passed through in the same order they were parsed.
        let pts = [
            RampPoint(tempC: 85, rpm: 5800),
            RampPoint(tempC: 40, rpm: 1200),
        ]
        let mode = CLIParser.fanMode(
            from: .ramp(sensorID: "TC0E", points: pts),
            fanMin: 1200,
            fanMax: 5800
        )
        XCTAssertEqual(mode, .sensorBased(sensorId: "TC0E", points: pts))
    }
}

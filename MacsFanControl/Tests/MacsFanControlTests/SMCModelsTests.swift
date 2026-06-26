//
//  SMCModelsTests.swift
//  MacsFanControlTests
//
//  Pure model tests for SMCModels.swift — Fan / TempSensor / SensorKind /
//  FanMode. No singletons, no UI.
//

import XCTest
@testable import MacsFanControlCore

final class SMCModelsTests: XCTestCase {

    // MARK: - Fan.loadFraction

    func testFanLoadFractionAtMin() {
        let fan = makeFan(currentRPM: 1200)
        XCTAssertEqual(fan.loadFraction, 0.0, accuracy: 0.0001)
    }

    func testFanLoadFractionAtMax() {
        let fan = makeFan(currentRPM: 5800)
        XCTAssertEqual(fan.loadFraction, 1.0, accuracy: 0.0001)
    }

    func testFanLoadFractionAtMidpoint() {
        let fan = makeFan(currentRPM: 3500) // halfway between 1200 and 5800
        XCTAssertEqual(fan.loadFraction, 0.5, accuracy: 0.01)
    }

    func testFanLoadFractionClampedBelowMin() {
        let fan = makeFan(currentRPM: 0) // below minRPM
        XCTAssertEqual(fan.loadFraction, 0.0)
    }

    func testFanLoadFractionClampedAboveMax() {
        let fan = makeFan(currentRPM: 99_999) // above maxRPM
        XCTAssertEqual(fan.loadFraction, 1.0)
    }

    func testFanLoadFractionWhenMinEqualsMax() {
        // Degenerate fan — guard clause returns 0
        let fan = Fan(id: "Fx", name: "Stuck", minRPM: 2000, maxRPM: 2000,
                      currentRPM: 2000, targetRPM: 2000, mode: .auto)
        XCTAssertEqual(fan.loadFraction, 0.0)
    }

    // MARK: - Fan.loadColor (compare by sampling fraction thresholds)

    @MainActor
    func testFanLoadColorIdleIsGreen() {
        let fan = makeFan(currentRPM: 1200) // 0% load
        XCTAssertEqual(fan.loadColor, .mfcGreen)
    }

    @MainActor
    func testFanLoadColorLowMidIsGreen() {
        // 35% load -> still under 0.4 threshold
        let fan = makeFan(currentRPM: 1200 + Int(0.35 * Double(5800 - 1200)))
        XCTAssertEqual(fan.loadColor, .mfcGreen)
    }

    @MainActor
    func testFanLoadColorMidIsAmber() {
        // 50% load -> 0.4 ..< 0.75
        let fan = makeFan(currentRPM: 3500)
        XCTAssertEqual(fan.loadColor, .mfcAmber)
    }

    @MainActor
    func testFanLoadColorHighIsRed() {
        // 90% load -> >= 0.75
        let fan = makeFan(currentRPM: 1200 + Int(0.9 * Double(5800 - 1200)))
        XCTAssertEqual(fan.loadColor, .mfcRed)
    }

    // MARK: - TempSensor.fahrenheit

    func testFahrenheitAtZeroCelsius() {
        let s = makeSensor(celsius: 0)
        XCTAssertEqual(s.fahrenheit, 32.0, accuracy: 0.0001)
    }

    func testFahrenheitAt100Celsius() {
        let s = makeSensor(celsius: 100)
        XCTAssertEqual(s.fahrenheit, 212.0, accuracy: 0.0001)
    }

    func testFahrenheitAt37Celsius() {
        let s = makeSensor(celsius: 37)
        XCTAssertEqual(s.fahrenheit, 98.6, accuracy: 0.0001)
    }

    func testFahrenheitNegativeCelsius() {
        let s = makeSensor(celsius: -40) // -40C == -40F
        XCTAssertEqual(s.fahrenheit, -40.0, accuracy: 0.0001)
    }

    // MARK: - TempSensor.formatted

    func testFormattedCelsiusRounded() {
        let s = makeSensor(celsius: 42.7)
        XCTAssertEqual(s.formatted(useFahrenheit: false, precise: false), "43 °C")
    }

    func testFormattedCelsiusPrecise() {
        let s = makeSensor(celsius: 42.75)
        XCTAssertEqual(s.formatted(useFahrenheit: false, precise: true), "42.8 °C")
    }

    func testFormattedFahrenheitRounded() {
        let s = makeSensor(celsius: 100) // 212 F
        XCTAssertEqual(s.formatted(useFahrenheit: true, precise: false), "212 °F")
    }

    func testFormattedFahrenheitPrecise() {
        let s = makeSensor(celsius: 37) // 98.6 F
        XCTAssertEqual(s.formatted(useFahrenheit: true, precise: true), "98.6 °F")
    }

    // MARK: - SensorKind.sfSymbol

    func testSensorKindSFSymbolNonEmptyForEveryCase() {
        for kind in SensorKind.allCases {
            XCTAssertFalse(kind.sfSymbol.isEmpty, "SFSymbol for \(kind) should not be empty")
        }
    }

    func testSensorKindCodableRoundTrip() throws {
        for kind in SensorKind.allCases {
            let data = try JSONEncoder().encode(kind)
            let decoded = try JSONDecoder().decode(SensorKind.self, from: data)
            XCTAssertEqual(decoded, kind)
        }
    }

    // MARK: - FanMode Codable

    func testFanModeAutoCodableRoundTrip() throws {
        let original = FanMode.auto
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FanMode.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testFanModeConstantCodableRoundTrip() throws {
        let original = FanMode.constant(rpm: 3200)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FanMode.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testFanModeSensorBasedCodableRoundTrip() throws {
        let original = FanMode.sensorBased(sensorId: "TC0E", lowTempC: 45.0, highTempC: 85.0)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FanMode.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testFanModeDisplayNames() {
        XCTAssertEqual(FanMode.auto.displayName, "Automatic (OS-managed)")
        XCTAssertEqual(FanMode.constant(rpm: 1000).displayName, "Constant speed")
        XCTAssertEqual(FanMode.sensorBased(sensorId: "x", lowTempC: 1, highTempC: 2).displayName, "Sensor-based")
    }

    // MARK: - Helpers

    private func makeFan(currentRPM: Int) -> Fan {
        Fan(id: "F0", name: "Test", minRPM: 1200, maxRPM: 5800,
            currentRPM: currentRPM, targetRPM: currentRPM, mode: .auto)
    }

    private func makeSensor(celsius: Double) -> TempSensor {
        TempSensor(id: "TC0E", name: "Test", kind: .cpu, celsius: celsius)
    }
}

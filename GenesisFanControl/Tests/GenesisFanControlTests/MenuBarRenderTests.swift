//
//  MenuBarRenderTests.swift
//  GenesisFanControlTests
//
//  Tests for MenuBarContent — symbol selection, title composition,
//  and the cache-skip equality check (Seam 3).
//
//  Covered axes:
//    • symbol(for:) — one case per MenuBarIconStyle
//    • title(...)   — empty result, temperature headline (C/F/rounding),
//                     headline suppressed for non-.temperature styles,
//                     fan RPM/percent (values, rounding, nil guard),
//                     picked sensors (0/1/2/overflow), multi-part
//                     joining with " · ", leading-space contract
//    • shouldSkip() — nil cache (first render), identical hit, symbol
//                     change, title change, partial nil
//

import XCTest
@testable import GenesisFanControlCore

final class MenuBarRenderTests: XCTestCase {

    // MARK: - Helpers

    private func makeFan(id: String = "F0",
                         name: String = "Left Fan",
                         minRPM: Int = 1200,
                         maxRPM: Int = 5800,
                         currentRPM: Int) -> Fan {
        Fan(id: id, name: name, minRPM: minRPM, maxRPM: maxRPM,
            currentRPM: currentRPM, targetRPM: currentRPM, mode: .auto)
    }

    private func makeSensor(id: String = "TC0E",
                            celsius: Double,
                            kind: SensorKind = .cpu) -> TempSensor {
        TempSensor(id: id, name: "Test Sensor", kind: kind, celsius: celsius)
    }

    // MARK: - symbol(for:)

    func testSymbolColorStyle() {
        XCTAssertEqual(MenuBarContent.symbol(for: .color), "fanblades.fill")
    }

    func testSymbolMonochromeStyle() {
        XCTAssertEqual(MenuBarContent.symbol(for: .monochrome), "fanblades")
    }

    func testSymbolTemperatureStyle() {
        XCTAssertEqual(MenuBarContent.symbol(for: .temperature), "thermometer.medium")
    }

    // MARK: - title — empty / nothing configured

    func testTitleAllNilProducesEmpty() {
        let result = MenuBarContent.title(
            style: .color,
            menuBarFan: .none,
            firstFan: nil,
            headlineSensor: nil,
            pickedSensors: [],
            useFahrenheit: false
        )
        XCTAssertEqual(result, "")
    }

    func testTitleTemperatureStyleNilHeadlineNoOtherPartsProducesEmpty() {
        // .temperature selected but no headlineSensor and nothing else — must be ""
        let result = MenuBarContent.title(
            style: .temperature,
            menuBarFan: .none,
            firstFan: nil,
            headlineSensor: nil,
            pickedSensors: [],
            useFahrenheit: false
        )
        XCTAssertEqual(result, "")
    }

    // MARK: - title — temperature headline

    func testTitleTemperatureStyleHeadlineCelsius() {
        // 45°C → "45 °C"; title adds leading space → " 45 °C"
        let sensor = makeSensor(celsius: 45.0)
        let result = MenuBarContent.title(
            style: .temperature,
            menuBarFan: .none,
            firstFan: nil,
            headlineSensor: sensor,
            pickedSensors: [],
            useFahrenheit: false
        )
        XCTAssertEqual(result, " 45 °C")
    }

    func testTitleTemperatureStyleHeadlineFahrenheit() {
        // 40°C = 40*9/5+32 = 104°F
        let sensor = makeSensor(celsius: 40.0)
        let result = MenuBarContent.title(
            style: .temperature,
            menuBarFan: .none,
            firstFan: nil,
            headlineSensor: sensor,
            pickedSensors: [],
            useFahrenheit: true
        )
        XCTAssertEqual(result, " 104 °F")
    }

    func testTitleTemperatureStyleHeadlineRoundsCelsiusUp() {
        // 42.7°C → formatted(precise: false) → "43 °C"
        let sensor = makeSensor(celsius: 42.7)
        let result = MenuBarContent.title(
            style: .temperature,
            menuBarFan: .none,
            firstFan: nil,
            headlineSensor: sensor,
            pickedSensors: [],
            useFahrenheit: false
        )
        XCTAssertEqual(result, " 43 °C")
    }

    func testTitleTemperatureStyleHeadlineRoundsFahrenheitBoundary() {
        // 99.5°C = 99.5*9/5+32 = 179.1+32 = 211.1°F → "211 °F"
        let sensor = makeSensor(celsius: 99.5)
        let result = MenuBarContent.title(
            style: .temperature,
            menuBarFan: .none,
            firstFan: nil,
            headlineSensor: sensor,
            pickedSensors: [],
            useFahrenheit: true
        )
        XCTAssertEqual(result, " 211 °F")
    }

    // MARK: - title — headline suppressed for non-.temperature styles

    func testTitleColorStyleIgnoresHeadlineSensor() {
        // headlineSensor present but style == .color → not included
        let sensor = makeSensor(celsius: 70.0)
        let result = MenuBarContent.title(
            style: .color,
            menuBarFan: .none,
            firstFan: nil,
            headlineSensor: sensor,
            pickedSensors: [],
            useFahrenheit: false
        )
        XCTAssertEqual(result, "")
    }

    func testTitleMonochromeStyleIgnoresHeadlineSensor() {
        let sensor = makeSensor(celsius: 70.0)
        let result = MenuBarContent.title(
            style: .monochrome,
            menuBarFan: .none,
            firstFan: nil,
            headlineSensor: sensor,
            pickedSensors: [],
            useFahrenheit: false
        )
        XCTAssertEqual(result, "")
    }

    // MARK: - title — fan RPM

    func testTitleFanRPMDisplayed() {
        let fan = makeFan(currentRPM: 2400)
        let result = MenuBarContent.title(
            style: .color,
            menuBarFan: .rpm,
            firstFan: fan,
            headlineSensor: nil,
            pickedSensors: [],
            useFahrenheit: false
        )
        XCTAssertEqual(result, " 2400 RPM")
    }

    func testTitleFanRPMWithZeroFirstFanProducesEmpty() {
        // firstFan == nil → rpm branch skipped → no parts → ""
        let result = MenuBarContent.title(
            style: .color,
            menuBarFan: .rpm,
            firstFan: nil,
            headlineSensor: nil,
            pickedSensors: [],
            useFahrenheit: false
        )
        XCTAssertEqual(result, "")
    }

    // MARK: - title — fan percent

    func testTitleFanPercentAtHalfLoad() {
        // min=1200, max=5800, current=3500 → fraction=2300/4600=0.5 → 50%
        let fan = makeFan(currentRPM: 3500)
        let result = MenuBarContent.title(
            style: .color,
            menuBarFan: .percent,
            firstFan: fan,
            headlineSensor: nil,
            pickedSensors: [],
            useFahrenheit: false
        )
        XCTAssertEqual(result, " 50%")
    }

    func testTitleFanPercentAtMinRPM() {
        // fraction=0 → 0%
        let fan = makeFan(currentRPM: 1200)
        let result = MenuBarContent.title(
            style: .color,
            menuBarFan: .percent,
            firstFan: fan,
            headlineSensor: nil,
            pickedSensors: [],
            useFahrenheit: false
        )
        XCTAssertEqual(result, " 0%")
    }

    func testTitleFanPercentAtMaxRPM() {
        // fraction=1 → 100%
        let fan = makeFan(currentRPM: 5800)
        let result = MenuBarContent.title(
            style: .color,
            menuBarFan: .percent,
            firstFan: fan,
            headlineSensor: nil,
            pickedSensors: [],
            useFahrenheit: false
        )
        XCTAssertEqual(result, " 100%")
    }

    func testTitleFanPercentRoundsHalfUp() {
        // min=0, max=1000, current=745 → fraction=0.745 → 74.5 → rounds to 75
        let fan = Fan(id: "F0", name: "Fan", minRPM: 0, maxRPM: 1000,
                      currentRPM: 745, targetRPM: 745, mode: .auto)
        let result = MenuBarContent.title(
            style: .color,
            menuBarFan: .percent,
            firstFan: fan,
            headlineSensor: nil,
            pickedSensors: [],
            useFahrenheit: false
        )
        XCTAssertEqual(result, " 75%")
    }

    func testTitleFanPercentWithNilFanProducesEmpty() {
        let result = MenuBarContent.title(
            style: .color,
            menuBarFan: .percent,
            firstFan: nil,
            headlineSensor: nil,
            pickedSensors: [],
            useFahrenheit: false
        )
        XCTAssertEqual(result, "")
    }

    // MARK: - title — picked sensors

    func testTitleOneSensorCelsius() {
        let s = makeSensor(celsius: 60.0)
        let result = MenuBarContent.title(
            style: .color,
            menuBarFan: .none,
            firstFan: nil,
            headlineSensor: nil,
            pickedSensors: [s],
            useFahrenheit: false
        )
        XCTAssertEqual(result, " 60 °C")
    }

    func testTitleTwoSensorsJoinedWithMidDot() {
        let s1 = makeSensor(id: "TC0E", celsius: 55.0)
        let s2 = makeSensor(id: "TC1E", celsius: 70.0)
        let result = MenuBarContent.title(
            style: .color,
            menuBarFan: .none,
            firstFan: nil,
            headlineSensor: nil,
            pickedSensors: [s1, s2],
            useFahrenheit: false
        )
        XCTAssertEqual(result, " 55 °C · 70 °C")
    }

    func testTitlePickedSensorsUseFahrenheit() {
        // 50°C = 50*9/5+32 = 90+32 = 122°F
        let s = makeSensor(celsius: 50.0)
        let result = MenuBarContent.title(
            style: .color,
            menuBarFan: .none,
            firstFan: nil,
            headlineSensor: nil,
            pickedSensors: [s],
            useFahrenheit: true
        )
        XCTAssertEqual(result, " 122 °F")
    }

    func testTitlePickedSensorsLimitedToTwoViaPrefix() {
        // prefix(2) inside title() caps at 2 even when caller passes 3
        let s1 = makeSensor(id: "TC0E", celsius: 50.0)
        let s2 = makeSensor(id: "TC1E", celsius: 60.0)
        let s3 = makeSensor(id: "TC2E", celsius: 70.0) // should be dropped
        let result = MenuBarContent.title(
            style: .color,
            menuBarFan: .none,
            firstFan: nil,
            headlineSensor: nil,
            pickedSensors: [s1, s2, s3],
            useFahrenheit: false
        )
        XCTAssertEqual(result, " 50 °C · 60 °C")
        XCTAssertFalse(result.contains("70"), "Third sensor must be suppressed by prefix(2)")
    }

    // MARK: - title — multi-part combinations

    func testTitleTemperatureHeadlinePlusRPM() {
        // .temperature with headline + fan rpm → two parts joined by " · "
        let headline = makeSensor(celsius: 50.0)
        let fan = makeFan(currentRPM: 3000)
        let result = MenuBarContent.title(
            style: .temperature,
            menuBarFan: .rpm,
            firstFan: fan,
            headlineSensor: headline,
            pickedSensors: [],
            useFahrenheit: false
        )
        XCTAssertEqual(result, " 50 °C · 3000 RPM")
    }

    func testTitleRPMPlusTwoPickedSensors() {
        // fan rpm + two sensors → three parts
        let fan = makeFan(currentRPM: 2400)
        let s1 = makeSensor(id: "TC0E", celsius: 55.0)
        let s2 = makeSensor(id: "TC1E", celsius: 70.0)
        let result = MenuBarContent.title(
            style: .color,
            menuBarFan: .rpm,
            firstFan: fan,
            headlineSensor: nil,
            pickedSensors: [s1, s2],
            useFahrenheit: false
        )
        XCTAssertEqual(result, " 2400 RPM · 55 °C · 70 °C")
    }

    func testTitleTemperatureHeadlinePlusSensorFahrenheit() {
        // headline 40°C=104°F + picked 50°C=122°F
        let headline = makeSensor(id: "TC0E", celsius: 40.0)
        let picked = makeSensor(id: "TC1E", celsius: 50.0)
        let result = MenuBarContent.title(
            style: .temperature,
            menuBarFan: .none,
            firstFan: nil,
            headlineSensor: headline,
            pickedSensors: [picked],
            useFahrenheit: true
        )
        XCTAssertEqual(result, " 104 °F · 122 °F")
    }

    func testTitleNonEmptyResultHasLeadingSpace() {
        // Contract: any non-empty title starts with " "
        let fan = makeFan(currentRPM: 1800)
        let result = MenuBarContent.title(
            style: .color,
            menuBarFan: .rpm,
            firstFan: fan,
            headlineSensor: nil,
            pickedSensors: [],
            useFahrenheit: false
        )
        XCTAssertFalse(result.isEmpty)
        XCTAssertTrue(result.hasPrefix(" "), "Non-empty title must begin with a leading space")
    }

    // MARK: - shouldSkip — cache equality

    func testShouldSkipReturnsFalseWhenBothCacheNil() {
        // First render: no previous values → never skip
        XCTAssertFalse(
            MenuBarContent.shouldSkip(
                symbol: "fanblades.fill", title: " 45 °C",
                lastSymbol: nil, lastTitle: nil
            )
        )
    }

    func testShouldSkipReturnsFalseWhenLastSymbolNilOnly() {
        // guard let lastSymbol fails → false
        XCTAssertFalse(
            MenuBarContent.shouldSkip(
                symbol: "fanblades.fill", title: " 45 °C",
                lastSymbol: nil, lastTitle: " 45 °C"
            )
        )
    }

    func testShouldSkipReturnsFalseWhenLastTitleNilOnly() {
        // guard let lastTitle fails → false
        XCTAssertFalse(
            MenuBarContent.shouldSkip(
                symbol: "fanblades.fill", title: " 45 °C",
                lastSymbol: "fanblades.fill", lastTitle: nil
            )
        )
    }

    func testShouldSkipReturnsTrueWhenBothIdentical() {
        XCTAssertTrue(
            MenuBarContent.shouldSkip(
                symbol: "fanblades.fill", title: " 45 °C",
                lastSymbol: "fanblades.fill", lastTitle: " 45 °C"
            )
        )
    }

    func testShouldSkipReturnsFalseWhenSymbolChanged() {
        XCTAssertFalse(
            MenuBarContent.shouldSkip(
                symbol: "thermometer.medium", title: " 45 °C",
                lastSymbol: "fanblades.fill", lastTitle: " 45 °C"
            )
        )
    }

    func testShouldSkipReturnsFalseWhenTitleChanged() {
        XCTAssertFalse(
            MenuBarContent.shouldSkip(
                symbol: "fanblades.fill", title: " 46 °C",
                lastSymbol: "fanblades.fill", lastTitle: " 45 °C"
            )
        )
    }

    func testShouldSkipReturnsTrueForEmptyTitleWhenCached() {
        // Both empty string cached → still a valid cache hit
        XCTAssertTrue(
            MenuBarContent.shouldSkip(
                symbol: "fanblades", title: "",
                lastSymbol: "fanblades", lastTitle: ""
            )
        )
    }

    func testShouldSkipReturnsFalseFirstRenderEmptyState() {
        // No prior cache, both empty → still first render, must not skip
        XCTAssertFalse(
            MenuBarContent.shouldSkip(
                symbol: "fanblades", title: "",
                lastSymbol: nil, lastTitle: nil
            )
        )
    }
}

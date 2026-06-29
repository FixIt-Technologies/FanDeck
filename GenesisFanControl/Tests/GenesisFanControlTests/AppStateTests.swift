//
//  AppStateTests.swift
//  GenesisFanControlTests
//
//  Uses the test-only init AppState(smc:autoStartPolling:false) so we never
//  race the 1-second Timer. We drive the simulation manually via tick().
//

import XCTest
@testable import GenesisFanControlCore

@MainActor
final class AppStateTests: XCTestCase {

    private func makeState() -> AppState {
        AppState(smc: MockSMCService(), autoStartPolling: false)
    }

    // MARK: - Construction

    func testInitialPopulatesFromSnapshot() {
        let state = makeState()
        XCTAssertFalse(state.fans.isEmpty, "AppState should publish fans after init")
        XCTAssertFalse(state.sensors.isEmpty, "AppState should publish sensors after init")
        // lastUpdated is .distantPast until first tick().
        XCTAssertEqual(state.lastUpdated, .distantPast)
    }

    func testSMCBackendExposed() {
        let state = makeState()
        XCTAssertEqual(state.smc.backendName, "MockSMC")
        XCTAssertTrue(state.smc.isSimulated)
    }

    // MARK: - tick()

    func testTickAdvancesLastUpdated() {
        let state = makeState()
        let before = state.lastUpdated
        let beforeWallClock = Date()
        state.tick()
        XCTAssertGreaterThan(state.lastUpdated, before)
        XCTAssertGreaterThanOrEqual(state.lastUpdated, beforeWallClock)
    }

    func testTickRefreshesSensors() {
        let state = makeState()
        let initial = state.sensors.map(\.celsius)
        for _ in 0..<30 { state.tick() }
        let updated = state.sensors.map(\.celsius)
        let anyChanged = zip(initial, updated).contains { abs($0 - $1) > 0.01 }
        XCTAssertTrue(anyChanged, "Sensors should drift after many ticks")
    }

    func testTickRefreshesFansRPM() {
        let state = makeState()
        guard let fanID = state.fans.first?.id else { return XCTFail("No fans") }
        state.setMode(.constant(rpm: 4500), for: fanID)
        for _ in 0..<60 { state.tick() }
        let fan = state.fan(withID: fanID)
        XCTAssertEqual(fan?.currentRPM, 4500,
                       "After enough ticks the fan should reach the constant target")
    }

    // MARK: - setMode

    func testSetModeUpdatesPublishedFans() {
        let state = makeState()
        guard let fanID = state.fans.first?.id else { return XCTFail("No fans") }
        state.setMode(.constant(rpm: 3000), for: fanID)
        guard let fan = state.fan(withID: fanID) else { return XCTFail("Fan disappeared") }
        if case .constant(let rpm) = fan.mode {
            XCTAssertEqual(rpm, 3000)
        } else {
            XCTFail("Expected .constant mode, got \(fan.mode)")
        }
    }

    func testSetModeSensorBased() {
        let state = makeState()
        guard let fanID = state.fans.first?.id,
              let sensorID = state.sensors.first?.id else {
            return XCTFail("Need at least one fan + one sensor")
        }
        state.setMode(.sensorBased(sensorId: sensorID, lowTempC: 40, highTempC: 80), for: fanID)
        guard let fan = state.fan(withID: fanID) else { return XCTFail("Fan disappeared") }
        if case .sensorBased(let sid, let lo, let hi) = fan.mode {
            XCTAssertEqual(sid, sensorID)
            XCTAssertEqual(lo, 40)
            XCTAssertEqual(hi, 80)
        } else {
            XCTFail("Expected .sensorBased mode, got \(fan.mode)")
        }
    }

    func testSetModeBackToAuto() {
        let state = makeState()
        guard let fanID = state.fans.first?.id else { return XCTFail("No fans") }
        state.setMode(.constant(rpm: 3000), for: fanID)
        state.setMode(.auto, for: fanID)
        guard let fan = state.fan(withID: fanID) else { return XCTFail("Fan disappeared") }
        if case .auto = fan.mode {
            // ok
        } else {
            XCTFail("Expected .auto mode, got \(fan.mode)")
        }
    }

    // MARK: - Lookups

    func testFanLookupReturnsMatch() {
        let state = makeState()
        guard let fanID = state.fans.first?.id else { return XCTFail("No fans") }
        XCTAssertNotNil(state.fan(withID: fanID))
    }

    func testFanLookupReturnsNilForUnknown() {
        let state = makeState()
        XCTAssertNil(state.fan(withID: "DOES_NOT_EXIST"))
    }

    func testSensorLookupReturnsMatch() {
        let state = makeState()
        guard let sensorID = state.sensors.first?.id else { return XCTFail("No sensors") }
        XCTAssertNotNil(state.sensor(withID: sensorID))
    }

    func testSensorLookupReturnsNilForUnknown() {
        let state = makeState()
        XCTAssertNil(state.sensor(withID: "DOES_NOT_EXIST"))
    }

    // MARK: - headlineSensor

    func testHeadlineSensorIsHottestCPU() {
        let state = makeState()
        let head = state.headlineSensor
        XCTAssertNotNil(head)
        // It must be a CPU sensor when CPU sensors are present.
        XCTAssertEqual(head?.kind, .cpu)
        // Among CPU sensors it should be the hottest.
        let cpuTemps = state.sensors.filter { $0.kind == .cpu }.map(\.celsius)
        let max = cpuTemps.max()
        XCTAssertEqual(head?.celsius, max,
                       "headlineSensor should be the hottest CPU sensor")
    }

    // MARK: - polling lifecycle

    func testStopPollingIsSafeWhenNotStarted() {
        let state = makeState()
        // Should not crash / not throw.
        state.stopPolling()
        state.stopPolling()
    }
}

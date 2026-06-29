//
//  MockSMCServiceTests.swift
//  GenesisFanControlTests
//
//  Behaviour tests for the synthetic SMC backend. The mock seeds with a
//  fixed inventory and drives RPM/temperature drift on a sine wave —
//  these tests pin the contract: inventory non-empty, RPM converges
//  toward set-points, sensors stay in the 20…95 °C band.
//

import XCTest
@testable import GenesisFanControlCore

final class MockSMCServiceTests: XCTestCase {

    func testInitialSnapshotHasFans() {
        let mock = MockSMCService()
        let snap = mock.snapshot()
        XCTAssertFalse(snap.fans.isEmpty, "Mock should ship with at least one fan")
        XCTAssertGreaterThan(snap.fans.count, 0)
    }

    func testInitialSnapshotHasSensors() {
        let mock = MockSMCService()
        let snap = mock.snapshot()
        XCTAssertFalse(snap.sensors.isEmpty, "Mock should ship with at least one sensor")
        XCTAssertGreaterThan(snap.sensors.count, 10, "Realistic MBP inventory has many sensors")
    }

    func testInitialFansHaveValidRPMRanges() {
        let mock = MockSMCService()
        for fan in mock.snapshot().fans {
            XCTAssertGreaterThan(fan.maxRPM, fan.minRPM, "Fan \(fan.id) should have maxRPM > minRPM")
            XCTAssertGreaterThanOrEqual(fan.currentRPM, fan.minRPM)
            XCTAssertLessThanOrEqual(fan.currentRPM, fan.maxRPM)
        }
    }

    func testBackendNameAndSimulatedFlag() {
        let mock = MockSMCService()
        XCTAssertEqual(mock.backendName, "MockSMC")
        XCTAssertTrue(mock.isSimulated)
    }

    // MARK: - RPM convergence

    func testRefreshConvergesToConstantTarget() {
        let mock = MockSMCService()
        let firstFan = mock.snapshot().fans[0]
        let targetRPM = 4000 // inside [1200, 5800]
        mock.setMode(.constant(rpm: targetRPM), for: firstFan.id)

        // Drive enough ticks for stepRPM (step ~ |delta|/4, clamped 40..400) to land.
        for _ in 0..<60 { mock.refresh() }

        let final = mock.snapshot().fans.first { $0.id == firstFan.id }!
        XCTAssertEqual(final.currentRPM, targetRPM,
                       "After many refreshes the fan should hit the constant target exactly")
        XCTAssertEqual(final.targetRPM, targetRPM)
    }

    func testConstantModeClampsAboveMax() {
        let mock = MockSMCService()
        let fan = mock.snapshot().fans[0]
        let wildlyHigh = 99_999
        mock.setMode(.constant(rpm: wildlyHigh), for: fan.id)
        for _ in 0..<60 { mock.refresh() }

        let final = mock.snapshot().fans.first { $0.id == fan.id }!
        XCTAssertEqual(final.currentRPM, fan.maxRPM,
                       "Out-of-range RPM should clamp to maxRPM (\(fan.maxRPM))")
        XCTAssertLessThanOrEqual(final.targetRPM, fan.maxRPM)
    }

    func testConstantModeClampsBelowMin() {
        let mock = MockSMCService()
        let fan = mock.snapshot().fans[0]
        mock.setMode(.constant(rpm: -500), for: fan.id)
        for _ in 0..<60 { mock.refresh() }

        let final = mock.snapshot().fans.first { $0.id == fan.id }!
        XCTAssertEqual(final.currentRPM, fan.minRPM,
                       "Out-of-range RPM should clamp to minRPM (\(fan.minRPM))")
        XCTAssertGreaterThanOrEqual(final.targetRPM, fan.minRPM)
    }

    func testSetModeUnknownFanIsNoop() {
        let mock = MockSMCService()
        let beforeFans = mock.snapshot().fans
        mock.setMode(.constant(rpm: 4000), for: "DOES_NOT_EXIST")
        let afterFans = mock.snapshot().fans
        XCTAssertEqual(beforeFans.map(\.currentRPM), afterFans.map(\.currentRPM))
        XCTAssertEqual(beforeFans.map(\.mode), afterFans.map(\.mode))
    }

    // MARK: - Sensor band

    func testSensorTemperaturesStayInValidBand() {
        let mock = MockSMCService()
        for _ in 0..<200 { mock.refresh() }
        for s in mock.snapshot().sensors {
            XCTAssertGreaterThanOrEqual(s.celsius, 20.0, "Sensor \(s.id) dipped below 20°C")
            XCTAssertLessThanOrEqual(s.celsius, 95.0, "Sensor \(s.id) exceeded 95°C")
        }
    }

    func testSensorTemperaturesActuallyMove() {
        let mock = MockSMCService()
        let initial = mock.snapshot().sensors.map(\.celsius)
        for _ in 0..<30 { mock.refresh() }
        let updated = mock.snapshot().sensors.map(\.celsius)
        // At least one sensor should have changed reading after 30 ticks.
        let anyChanged = zip(initial, updated).contains { abs($0 - $1) > 0.01 }
        XCTAssertTrue(anyChanged, "After 30 refreshes some sensor should drift")
    }

    // MARK: - Mode mutation

    func testSetModeAutoLeavesTargetFlexible() {
        let mock = MockSMCService()
        let fan = mock.snapshot().fans[0]
        mock.setMode(.auto, for: fan.id)
        for _ in 0..<20 { mock.refresh() }
        let final = mock.snapshot().fans.first { $0.id == fan.id }!
        if case .auto = final.mode {
            // ok
        } else {
            XCTFail("Mode should remain .auto after setMode(.auto)")
        }
        // Auto target must stay in fan's range.
        XCTAssertGreaterThanOrEqual(final.currentRPM, fan.minRPM)
        XCTAssertLessThanOrEqual(final.currentRPM, fan.maxRPM)
    }

    func testSetModeSensorBasedDrivesTargetFromSensor() {
        let mock = MockSMCService()
        let fan = mock.snapshot().fans[0]
        let sensorID = mock.snapshot().sensors.first!.id
        // Make the band so wide that any temp in [20, 95] maps inside [min, max].
        mock.setMode(.sensorBased(sensorId: sensorID, points: [
            RampPoint(tempC: 0, rpm: fan.minRPM),
            RampPoint(tempC: 200, rpm: fan.maxRPM),
        ]), for: fan.id)
        for _ in 0..<30 { mock.refresh() }
        let final = mock.snapshot().fans.first { $0.id == fan.id }!
        if case .sensorBased = final.mode {
            // ok
        } else {
            XCTFail("Mode should remain .sensorBased after setMode")
        }
        XCTAssertGreaterThanOrEqual(final.currentRPM, fan.minRPM)
        XCTAssertLessThanOrEqual(final.currentRPM, fan.maxRPM)
    }

    func testSensorBasedUnknownSensorIsHandled() {
        // The implementation `continue`s when the sensor id is missing.
        // Verifies no crash + fan RPM stays in legal range.
        let mock = MockSMCService()
        let fan = mock.snapshot().fans[0]
        mock.setMode(.sensorBased(sensorId: "GHOST", points: [
            RampPoint(tempC: 40, rpm: fan.minRPM),
            RampPoint(tempC: 80, rpm: fan.maxRPM),
        ]), for: fan.id)
        for _ in 0..<10 { mock.refresh() }
        let final = mock.snapshot().fans.first { $0.id == fan.id }!
        XCTAssertGreaterThanOrEqual(final.currentRPM, fan.minRPM)
        XCTAssertLessThanOrEqual(final.currentRPM, fan.maxRPM)
    }
}

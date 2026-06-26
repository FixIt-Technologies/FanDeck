//
//  SettingsStoreTests.swift
//  MacsFanControlTests
//
//  Round-trip every published property through a per-test suite-scoped
//  UserDefaults so the real user defaults stay untouched. Each test
//  constructs its own SettingsStore via the public test init that takes
//  a `UserDefaults` and uses a UUID-namespaced suite that's wiped before
//  use.
//

import XCTest
@testable import MacsFanControlCore

@MainActor
final class SettingsStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "test-mfc-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        // Defensive: a brand-new suite is empty, but if the OS recycled the
        // name we want a clean slate.
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    // MARK: - Defaults

    func testDefaultsOnFreshSuite() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertFalse(store.openAtLogin)
        XCTAssertTrue(store.checkUpdatesOnLaunch)
        XCTAssertFalse(store.showDockIcon)
        XCTAssertEqual(store.languageCode, "en")
        XCTAssertTrue(store.includeSATANVMe)
        XCTAssertFalse(store.includeExternalDrives)
        XCTAssertFalse(store.includeEGPU)
        XCTAssertFalse(store.useFahrenheit)
        XCTAssertTrue(store.precise)
        XCTAssertEqual(store.menuBarIconStyle, .color)
        XCTAssertEqual(store.menuBarFan, .none)
        XCTAssertEqual(store.menuBarSensorIDs, [])
    }

    // MARK: - Round-trips (write through one instance, read through a second)

    func testRoundTripOpenAtLogin() {
        let a = SettingsStore(defaults: defaults)
        a.openAtLogin = true
        let b = SettingsStore(defaults: defaults)
        XCTAssertTrue(b.openAtLogin)
    }

    func testRoundTripCheckUpdatesOnLaunch() {
        let a = SettingsStore(defaults: defaults)
        a.checkUpdatesOnLaunch = false
        let b = SettingsStore(defaults: defaults)
        XCTAssertFalse(b.checkUpdatesOnLaunch)
    }

    func testRoundTripShowDockIcon() {
        let a = SettingsStore(defaults: defaults)
        a.showDockIcon = true
        let b = SettingsStore(defaults: defaults)
        XCTAssertTrue(b.showDockIcon)
    }

    func testRoundTripLanguageCode() {
        let a = SettingsStore(defaults: defaults)
        a.languageCode = "cs"
        let b = SettingsStore(defaults: defaults)
        XCTAssertEqual(b.languageCode, "cs")
    }

    func testRoundTripIncludeSATANVMe() {
        let a = SettingsStore(defaults: defaults)
        a.includeSATANVMe = false
        let b = SettingsStore(defaults: defaults)
        XCTAssertFalse(b.includeSATANVMe)
    }

    func testRoundTripIncludeExternalDrives() {
        let a = SettingsStore(defaults: defaults)
        a.includeExternalDrives = true
        let b = SettingsStore(defaults: defaults)
        XCTAssertTrue(b.includeExternalDrives)
    }

    func testRoundTripIncludeEGPU() {
        let a = SettingsStore(defaults: defaults)
        a.includeEGPU = true
        let b = SettingsStore(defaults: defaults)
        XCTAssertTrue(b.includeEGPU)
    }

    func testRoundTripUseFahrenheit() {
        let a = SettingsStore(defaults: defaults)
        a.useFahrenheit = true
        let b = SettingsStore(defaults: defaults)
        XCTAssertTrue(b.useFahrenheit)
    }

    func testRoundTripPrecise() {
        let a = SettingsStore(defaults: defaults)
        a.precise = false
        let b = SettingsStore(defaults: defaults)
        XCTAssertFalse(b.precise)
    }

    func testRoundTripMenuBarIconStyle() {
        let a = SettingsStore(defaults: defaults)
        a.menuBarIconStyle = .temperature
        let b = SettingsStore(defaults: defaults)
        XCTAssertEqual(b.menuBarIconStyle, .temperature)
    }

    func testRoundTripMenuBarFan() {
        let a = SettingsStore(defaults: defaults)
        a.menuBarFan = .percent
        let b = SettingsStore(defaults: defaults)
        XCTAssertEqual(b.menuBarFan, .percent)
    }

    func testRoundTripMenuBarSensorIDsEmpty() {
        let a = SettingsStore(defaults: defaults)
        a.menuBarSensorIDs = []
        let b = SettingsStore(defaults: defaults)
        XCTAssertEqual(b.menuBarSensorIDs, [])
    }

    func testRoundTripMenuBarSensorIDsTwo() {
        let a = SettingsStore(defaults: defaults)
        a.menuBarSensorIDs = ["TC0E", "TG0c"]
        let b = SettingsStore(defaults: defaults)
        XCTAssertEqual(b.menuBarSensorIDs, ["TC0E", "TG0c"])
    }

    /// SettingsStore intentionally does NOT enforce the "up to two" cap —
    /// the cap is implemented in `MenuBarIconTab.toggle()` (UI target).
    /// The store itself is permissive: it persists whatever array it's given.
    func testStoreDoesNotEnforceTwoItemCap() {
        let a = SettingsStore(defaults: defaults)
        a.menuBarSensorIDs = ["s1", "s2", "s3"]
        let b = SettingsStore(defaults: defaults)
        XCTAssertEqual(b.menuBarSensorIDs, ["s1", "s2", "s3"],
                       "Store persists arbitrary-length arrays; the 2-cap is a UI-layer concern")
    }

    // MARK: - Storage keys

    func testRoundTripUsesExpectedKeys() {
        let store = SettingsStore(defaults: defaults)
        store.openAtLogin = true
        store.useFahrenheit = true
        store.menuBarIconStyle = .monochrome
        store.menuBarFan = .rpm
        store.languageCode = "de"

        // Direct UserDefaults reads using the published K constants
        XCTAssertEqual(defaults.bool(forKey: SettingsStore.K.openAtLogin), true)
        XCTAssertEqual(defaults.bool(forKey: SettingsStore.K.useFahrenheit), true)
        XCTAssertEqual(defaults.string(forKey: SettingsStore.K.menuBarIconStyle), "monochrome")
        XCTAssertEqual(defaults.string(forKey: SettingsStore.K.menuBarFan), "rpm")
        XCTAssertEqual(defaults.string(forKey: SettingsStore.K.languageCode), "de")
    }

    func testMenuBarSensorIDsPersistAsJSONData() throws {
        let store = SettingsStore(defaults: defaults)
        store.menuBarSensorIDs = ["X", "Y"]
        guard let data = defaults.data(forKey: SettingsStore.K.menuBarSensorIDs) else {
            return XCTFail("menuBarSensorIDs should be persisted as Data")
        }
        let arr = try JSONDecoder().decode([String].self, from: data)
        XCTAssertEqual(arr, ["X", "Y"])
    }

    // MARK: - Enum surface

    func testMenuBarIconStyleAllCases() {
        XCTAssertEqual(MenuBarIconStyle.allCases, [.color, .monochrome, .temperature])
        XCTAssertFalse(MenuBarIconStyle.color.label.isEmpty)
        XCTAssertFalse(MenuBarIconStyle.monochrome.label.isEmpty)
        XCTAssertFalse(MenuBarIconStyle.temperature.label.isEmpty)
    }

    func testMenuBarFanDisplayAllCases() {
        XCTAssertEqual(MenuBarFanDisplay.allCases, [.none, .rpm, .percent])
        XCTAssertFalse(MenuBarFanDisplay.none.label.isEmpty)
        XCTAssertFalse(MenuBarFanDisplay.rpm.label.isEmpty)
        XCTAssertFalse(MenuBarFanDisplay.percent.label.isEmpty)
    }

    func testMenuBarIconStyleCodableRoundTrip() throws {
        for style in MenuBarIconStyle.allCases {
            let data = try JSONEncoder().encode(style)
            let decoded = try JSONDecoder().decode(MenuBarIconStyle.self, from: data)
            XCTAssertEqual(decoded, style)
        }
    }

    func testMenuBarFanDisplayCodableRoundTrip() throws {
        for fan in MenuBarFanDisplay.allCases {
            let data = try JSONEncoder().encode(fan)
            let decoded = try JSONDecoder().decode(MenuBarFanDisplay.self, from: data)
            XCTAssertEqual(decoded, fan)
        }
    }
}

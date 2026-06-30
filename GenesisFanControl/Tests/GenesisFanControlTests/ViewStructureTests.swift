//
//  ViewStructureTests.swift
//  GenesisFanControlTests
//
//  ViewInspector structural tests for four SwiftUI views:
//    • MainViewStructureTests  — topStatusBar allowsHitTesting(false); no Buttons in status bar
//    • SensorPanelStructureTests — header has a gear Button; sensor groups render
//    • FanGaugeCardStructureTests — Auto button conditional on fan mode; Configure… always present
//    • FanControlSheetStructureTests — Apply to all conditional on fan count; ramp points render
//

import XCTest
import SwiftUI
import ViewInspector
@testable import GenesisFanControl
@testable import GenesisFanControlCore

// MARK: - Helpers

/// A trivial SMCService that returns exactly ONE fan so we can test the
/// "Apply to all" button being hidden on a single-fan machine.
private final class SingleFanSMCService: SMCService {
    let backendName = "SingleFanTest"
    let isSimulated = true

    func snapshot() -> (fans: [Fan], sensors: [TempSensor]) {
        let f = Fan(id: "F0", name: "Left side",
                    minRPM: 1200, maxRPM: 5800,
                    currentRPM: 2000, targetRPM: 2000, mode: .auto)
        return ([f], [])
    }

    func refresh() {}

    @discardableResult
    func setMode(_ mode: FanMode, for fanID: String) -> Bool { false }
}

// MARK: - Shared fixture helpers

/// Fresh isolated SettingsStore backed by a UUID-keyed UserDefaults suite.
/// Returns the SettingsStore and the suite name so tearDown can clean up.
@MainActor
private func makeIsolatedSettings() -> (SettingsStore, String) {
    let suite = "test-vs-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return (SettingsStore(defaults: defaults), suite)
}

/// AppState.init is @MainActor-isolated; this wrapper must be too.
@MainActor
private func makeState(smc: SMCService? = nil) -> AppState {
    AppState(smc: smc ?? MockSMCService(), autoStartPolling: false)
}

// MARK: - MainView structure

@MainActor
final class MainViewStructureTests: XCTestCase {

    private var settingsSuite: String!
    private var settings: SettingsStore!

    override func setUp() async throws {
        try await super.setUp()
        let (s, name) = makeIsolatedSettings()
        settings = s
        settingsSuite = name
    }

    override func tearDown() async throws {
        UserDefaults.standard.removePersistentDomain(forName: settingsSuite)
        settings = nil
        settingsSuite = nil
        try await super.tearDown()
    }

    /// topStatusBar is ZStack child [1]. Confirm `.allowsHitTesting(false)` is set
    /// so the decorative strip never swallows clicks destined for SensorPanel's gear.
    func testTopStatusBarHitTestingDisabled() throws {
        let appState = makeState()
        let view = MainView()
            .environmentObject(appState)
            .environmentObject(settings)
        let zstack = try view.inspect().zStack()
        // Child 1 = topStatusBar VStack; needsElevation is false by default so
        // the optional elevationBanner child [3] is absent and indices are stable.
        let topBar = try zstack.vStack(1)
        XCTAssertFalse(topBar.allowsHitTesting(),
                       "topStatusBar must carry .allowsHitTesting(false) so clicks pass through to SensorPanel")
    }

    /// topStatusBar is purely decorative (Image + Text + TagPill + Spacer).
    /// Assert it contains zero interactive Button controls.
    func testTopStatusBarContainsNoButtons() throws {
        let appState = makeState()
        let view = MainView()
            .environmentObject(appState)
            .environmentObject(settings)
        let zstack = try view.inspect().zStack()
        let topBar = try zstack.vStack(1)
        XCTAssertThrowsError(
            try topBar.find(ViewType.Button.self),
            "topStatusBar must have no Buttons — the gear lives in SensorPanel, not here"
        )
    }
}

// MARK: - SensorPanel structure

@MainActor
final class SensorPanelStructureTests: XCTestCase {

    private var settingsSuite: String!
    private var settings: SettingsStore!

    override func setUp() async throws {
        try await super.setUp()
        let (s, name) = makeIsolatedSettings()
        settings = s
        settingsSuite = name
    }

    override func tearDown() async throws {
        UserDefaults.standard.removePersistentDomain(forName: settingsSuite)
        settings = nil
        settingsSuite = nil
        try await super.tearDown()
    }

    /// The header row contains a gear Button (GearButton) that opens Settings.
    func testHeaderContainsGearButton() throws {
        let appState = makeState()
        let view = SensorPanel()
            .environmentObject(appState)
            .environmentObject(settings)
        // Recursive search — finds the Button anywhere inside SensorPanel.
        XCTAssertNoThrow(
            try view.inspect().find(ViewType.Button.self),
            "SensorPanel header must contain at least one Button (the gear / GearButton)"
        )
    }

    /// The "TEMPERATURES" label in the header confirms the view renders its structure.
    func testHeaderShowsTemperaturesLabel() throws {
        let appState = makeState()
        let view = SensorPanel()
            .environmentObject(appState)
            .environmentObject(settings)
        XCTAssertNoThrow(
            try view.inspect().find(text: "TEMPERATURES"),
            "SensorPanel header must display the 'TEMPERATURES' label"
        )
    }

    /// MockSMCService provides sensors from multiple kinds (cpu, battery, storage, …).
    /// With default SettingsStore (includeEGPU = false), at least one non-GPU group renders.
    func testSensorGroupsRenderWithMockSensors() throws {
        let appState = makeState()
        XCTAssertFalse(appState.sensors.isEmpty, "MockSMCService must provide sensors for this test to be meaningful")
        let view = SensorPanel()
            .environmentObject(appState)
            .environmentObject(settings)
        // ForEach(groupedSensors) produces at least one SensorGroupView whose
        // kind label (e.g. "CPU") is findable as a Text anywhere in the tree.
        XCTAssertNoThrow(
            try view.inspect().find(text: "CPU"),
            "SensorPanel must render a 'CPU' sensor group header from MockSMCService data"
        )
    }
}

// MARK: - FanGaugeCard structure

// FanGaugeCard has NO @EnvironmentObject; these tests need no env injection.
// @MainActor is required because ViewInspector's find() calls MainActor.assumeIsolated.
@MainActor
final class FanGaugeCardStructureTests: XCTestCase {

    private func makeFan(mode: FanMode) -> Fan {
        Fan(id: "F0", name: "Left side",
            minRPM: 1200, maxRPM: 5800,
            currentRPM: 2400, targetRPM: 2400, mode: mode)
    }

    /// The "Auto" button resets the fan to macOS-managed mode.
    /// It must NOT appear when the fan is already in .auto mode.
    func testAutoButtonAbsentInAutoMode() throws {
        let card = FanGaugeCard(
            fan: makeFan(mode: .auto),
            onConfigure: {},
            onSetManual: { _ in },
            onResetAuto: {}
        )
        XCTAssertThrowsError(
            try card.inspect().find(button: "Auto"),
            "FanGaugeCard in .auto mode must NOT show an 'Auto' reset button"
        )
    }

    /// When the fan is in .constant mode, "Auto" lets the user return to automatic control.
    func testAutoButtonPresentInConstantMode() throws {
        let card = FanGaugeCard(
            fan: makeFan(mode: .constant(rpm: 3000)),
            onConfigure: {},
            onSetManual: { _ in },
            onResetAuto: {}
        )
        XCTAssertNoThrow(
            try card.inspect().find(button: "Auto"),
            "FanGaugeCard in .constant mode must show an 'Auto' button"
        )
    }

    /// Same as constant — sensor-based is also a non-auto mode so "Auto" appears.
    func testAutoButtonPresentInSensorBasedMode() throws {
        let card = FanGaugeCard(
            fan: makeFan(mode: .sensorBased(sensorId: "TC0E", points: [
                RampPoint(tempC: 45, rpm: 1200),
                RampPoint(tempC: 85, rpm: 5800),
            ])),
            onConfigure: {},
            onSetManual: { _ in },
            onResetAuto: {}
        )
        XCTAssertNoThrow(
            try card.inspect().find(button: "Auto"),
            "FanGaugeCard in .sensorBased mode must show an 'Auto' button"
        )
    }

    /// "Configure…" opens FanControlSheet — it must always be present
    /// regardless of the current fan mode.
    func testConfigureButtonAlwaysPresentInAutoMode() throws {
        let card = FanGaugeCard(
            fan: makeFan(mode: .auto),
            onConfigure: {},
            onSetManual: { _ in },
            onResetAuto: {}
        )
        XCTAssertNoThrow(
            try card.inspect().find(button: "Configure…"),
            "FanGaugeCard must always show a 'Configure…' button"
        )
    }

    func testConfigureButtonAlwaysPresentInConstantMode() throws {
        let card = FanGaugeCard(
            fan: makeFan(mode: .constant(rpm: 3000)),
            onConfigure: {},
            onSetManual: { _ in },
            onResetAuto: {}
        )
        XCTAssertNoThrow(
            try card.inspect().find(button: "Configure…"),
            "FanGaugeCard must always show a 'Configure…' button (constant mode)"
        )
    }

    /// Verify the card renders at least the fan name — confirms body evaluates
    /// without crashing even when all closures are empty stubs.
    func testCardRendersWithFanName() throws {
        let card = FanGaugeCard(
            fan: makeFan(mode: .auto),
            onConfigure: {},
            onSetManual: { _ in },
            onResetAuto: {}
        )
        XCTAssertNoThrow(
            try card.inspect().find(text: "Left side"),
            "FanGaugeCard must render the fan name"
        )
    }
}

// MARK: - FanControlSheet structure

@MainActor
final class FanControlSheetStructureTests: XCTestCase {

    private var settingsSuite: String!
    private var settings: SettingsStore!

    override func setUp() async throws {
        try await super.setUp()
        let (s, name) = makeIsolatedSettings()
        settings = s
        settingsSuite = name
    }

    override func tearDown() async throws {
        UserDefaults.standard.removePersistentDomain(forName: settingsSuite)
        settings = nil
        settingsSuite = nil
        try await super.tearDown()
    }

    private func makeFan(mode: FanMode = .auto) -> Fan {
        Fan(id: "F0", name: "Left side",
            minRPM: 1200, maxRPM: 5800,
            currentRPM: 2400, targetRPM: 2400, mode: mode)
    }

    // MARK: Apply-to-all visibility

    /// MockSMCService provides 2 fans (F0 + F1). With > 1 fan, the footer
    /// must show an "Apply to all" button so the user can sync both fans at once.
    func testApplyToAllVisibleWithMultipleFans() throws {
        let appState = makeState()           // MockSMCService → 2 fans
        XCTAssertGreaterThan(appState.fans.count, 1,
                             "Pre-condition: MockSMCService must supply more than 1 fan")
        let sheet = FanControlSheet(fan: makeFan())
            .environmentObject(appState)
            .environmentObject(settings)
        XCTAssertNoThrow(
            try sheet.inspect().find(button: "Apply to all"),
            "Footer must show 'Apply to all' when appState.fans.count > 1"
        )
    }

    /// With exactly ONE fan the "Apply to all" button is redundant and must be hidden.
    func testApplyToAllHiddenWithSingleFan() throws {
        let appState = makeState(smc: SingleFanSMCService())
        XCTAssertEqual(appState.fans.count, 1,
                       "Pre-condition: SingleFanSMCService must supply exactly 1 fan")
        let sheet = FanControlSheet(fan: makeFan())
            .environmentObject(appState)
            .environmentObject(settings)
        XCTAssertThrowsError(
            try sheet.inspect().find(button: "Apply to all"),
            "Footer must hide 'Apply to all' when there is only 1 fan"
        )
    }

    // MARK: Footer always-present controls

    /// "Apply" and "Cancel" must be in the footer regardless of mode.
    func testApplyAndCancelAlwaysPresent() throws {
        let appState = makeState()
        let sheet = FanControlSheet(fan: makeFan())
            .environmentObject(appState)
            .environmentObject(settings)
        XCTAssertNoThrow(
            try sheet.inspect().find(button: "Apply"),
            "'Apply' button must always appear in FanControlSheet footer"
        )
        XCTAssertNoThrow(
            try sheet.inspect().find(button: "Cancel"),
            "'Cancel' button must always appear in FanControlSheet footer"
        )
    }

    // MARK: Mode choice labels

    /// The three mode radio rows (auto / constant / sensor) each render
    /// a label Text. Find them recursively to confirm the modeChoiceCard renders.
    func testModeChoiceLabelsPresent() throws {
        let appState = makeState()
        let sheet = FanControlSheet(fan: makeFan())
            .environmentObject(appState)
            .environmentObject(settings)
        let body = try sheet.inspect()
        XCTAssertNoThrow(
            try body.find(text: "Automatic (OS-managed)"),
            "Mode picker must show 'Automatic (OS-managed)' label"
        )
        XCTAssertNoThrow(
            try body.find(text: "Constant speed"),
            "Mode picker must show 'Constant speed' label"
        )
        XCTAssertNoThrow(
            try body.find(text: "Sensor-based"),
            "Mode picker must show 'Sensor-based' label"
        )
    }

    // MARK: Sensor mode — ramp points editor
    //
    // These tests use RampPointsEditor directly instead of wrapping a full
    // FanControlSheet in sensor mode. FanControlSheet in sensor mode always
    // renders livePreviewCard → rampGraph (Charts.Chart), which SIGTRAP-crashes
    // ViewInspector in the headless test environment. RampPointsEditor is the
    // extracted struct that contains only the points list — no Charts dependency.

    /// RampPointsEditor must render the "Ramp points" section header.
    func testRampPointsHeaderRenderedInSensorMode() throws {
        var pts = [RampPoint(tempC: 45, rpm: 1200), RampPoint(tempC: 85, rpm: 5800)]
        let editor = RampPointsEditor(
            points: Binding(get: { pts }, set: { pts = $0 }),
            minRPM: 1200,
            maxRPM: 5800
        )
        XCTAssertNoThrow(
            try editor.inspect().find(text: "Ramp points"),
            "RampPointsEditor must show 'Ramp points' section header"
        )
    }

    /// Each ramp vertex generates a pointRow containing an "at" label.
    /// With 3 points the "at" Text must appear at least once.
    func testRampPointRowsRenderedInSensorMode() throws {
        var pts = [
            RampPoint(tempC: 45, rpm: 1200),
            RampPoint(tempC: 65, rpm: 3000),
            RampPoint(tempC: 85, rpm: 5800),
        ]
        let editor = RampPointsEditor(
            points: Binding(get: { pts }, set: { pts = $0 }),
            minRPM: 1200,
            maxRPM: 5800
        )
        // Each pointRow renders a Text("at") separator; finding it confirms at least
        // one ramp-point row was produced by ForEach(points.indices).
        XCTAssertNoThrow(
            try editor.inspect().find(text: "at"),
            "RampPointsEditor ForEach must render at least one ramp-point row with an 'at' separator"
        )
    }
}

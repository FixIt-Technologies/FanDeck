//
//  ViewInspectorProbeTests.swift
//  GenesisFanControlTests
//
//  JOB-1 wiring probe: one trivial ViewInspector test + one extracted-logic stub.
//  This file is TEMPORARY scaffolding — it will be replaced by the full
//  extraction + test suite described in the JOB-2 plan once approved.
//

import XCTest
import SwiftUI
import ViewInspector
@testable import GenesisFanControl
@testable import GenesisFanControlCore

// MARK: - ViewInspector wiring probe (MetricChip — no @EnvironmentObject)

@MainActor
final class ViewInspectorProbeTests: XCTestCase {

    /// Verifies that ViewInspector can inspect a simple view that has NO
    /// @EnvironmentObject dependencies (MetricChip). Proves the package
    /// wiring compiles and the inspect() path works without environment setup.
    func testMetricChipContainsLabelText() throws {
        let chip = MetricChip(
            label: "CURRENT",
            value: "2400",
            suffix: "RPM",
            color: .green
        )
        let vstack = try chip.inspect().vStack()
        // First child is the "CURRENT" label text
        let labelText = try vstack.text(0).string()
        XCTAssertEqual(labelText, "CURRENT")
    }

    /// Verifies the RPM value text is present in the view hierarchy.
    func testMetricChipContainsValueText() throws {
        let chip = MetricChip(
            label: "TARGET",
            value: "3500",
            suffix: "RPM",
            color: .cyan
        )
        // Walk: VStack → HStack(1) → Text(0) (the value)
        let vstack = try chip.inspect().vStack()
        let hstack = try vstack.hStack(1)
        let valueText = try hstack.text(0).string()
        XCTAssertEqual(valueText, "3500")
    }
}

// MARK: - Extracted-logic stub (menuBarSymbol — pure function)

/// First slice of the menu-bar render model extraction (JOB-2 process 3).
/// `menuBarSymbol(for:)` is extracted as a pure, AppKit-free function whose
/// 3-case switch is immediately unit-testable without any running AppState.
///
/// NOTE: This stub lives here for JOB-1 "proof of extracted logic" only.
/// The real extraction will move it into GenesisFanControlCore once the
/// full plan is approved.
enum MenuBarSymbolStub {
    static func symbol(for style: MenuBarIconStyle) -> String {
        switch style {
        case .color:       return "fanblades.fill"
        case .monochrome:  return "fanblades"
        case .temperature: return "thermometer.medium"
        }
    }
}

@MainActor
final class MenuBarSymbolStubTests: XCTestCase {

    func testColorStyleSymbol() {
        XCTAssertEqual(MenuBarSymbolStub.symbol(for: .color), "fanblades.fill")
    }

    func testMonochromeStyleSymbol() {
        XCTAssertEqual(MenuBarSymbolStub.symbol(for: .monochrome), "fanblades")
    }

    func testTemperatureStyleSymbol() {
        XCTAssertEqual(MenuBarSymbolStub.symbol(for: .temperature), "thermometer.medium")
    }
}

//
//  WriterSettingsViewControllerTests.swift
//  LunaTests
//

import UIKit
import XCTest
@testable import LunaWriterLibraryUI
import LunaWriterModels
import LunaWriterStorage

final class WriterSettingsViewControllerTests: XCTestCase {

    private enum EditorRowIndex {
        static let syntaxColouring = 4
    }

    @MainActor
    func testReadAlongSectionIsAbsentWithNoHandler() throws {
        let stack = try makeWriterStack()
        let environment = makeLibraryEnvironment(stack: stack, readAlongSettings: nil)
        let controller = WriterSettingsViewController(environment: environment)
        layoutWriterScreen(controller)

        // Editor, Library, Appearance, About — no Read-along.
        XCTAssertEqual(controller.numberOfSections(in: controller.tableView), 4)
    }

    @MainActor
    func testReadAlongSectionListsOnlyTheAvailableCapabilityPlusCalibrate() throws {
        let stack = try makeWriterStack()
        let handler = ScriptedReadAlongSettings()
        handler.gazeAvailable = true
        handler.voiceAvailable = false
        let environment = makeLibraryEnvironment(stack: stack, readAlongSettings: handler)
        let controller = WriterSettingsViewController(environment: environment)
        layoutWriterScreen(controller)

        XCTAssertEqual(controller.numberOfSections(in: controller.tableView), 5)
        // Gaze + Calibrate, no Voice row.
        XCTAssertEqual(controller.tableView(controller.tableView, numberOfRowsInSection: 1), 2)
    }

    @MainActor
    func testTogglingSyntaxColouringWritesThroughToWriterSettings() throws {
        let stack = try makeWriterStack()
        let environment = makeLibraryEnvironment(stack: stack)
        let controller = WriterSettingsViewController(environment: environment)
        layoutWriterScreen(controller)

        XCTAssertFalse(environment.settings.syntaxColouring)
        let indexPath = IndexPath(row: EditorRowIndex.syntaxColouring, section: 0)
        let cell = controller.tableView(controller.tableView, cellForRowAt: indexPath)
        let toggle = try XCTUnwrap(cell.accessoryView as? UISwitch)

        toggle.isOn = true
        toggle.sendActions(for: .valueChanged)

        XCTAssertTrue(environment.settings.syntaxColouring)
    }

    @MainActor
    func testSelectingCalibrateRowRoutesThroughTheReadAlongHandler() throws {
        let stack = try makeWriterStack()
        let handler = ScriptedReadAlongSettings()
        let environment = makeLibraryEnvironment(stack: stack, readAlongSettings: handler)
        let controller = WriterSettingsViewController(environment: environment)
        layoutWriterScreen(controller)

        // Gaze(0), Voice(1), Calibrate(2) — both capabilities default to available.
        controller.tableView(controller.tableView, didSelectRowAt: IndexPath(row: 2, section: 1))

        XCTAssertTrue(handler.calibrationPresentedFrom === controller)
    }

    @MainActor
    func testCalibrationGradeShowsOnTheCalibrateRowWhenSet() throws {
        let stack = try makeWriterStack()
        let handler = ScriptedReadAlongSettings()
        handler.lastCalibrationGrade = "Good"
        let environment = makeLibraryEnvironment(stack: stack, readAlongSettings: handler)
        let controller = WriterSettingsViewController(environment: environment)
        layoutWriterScreen(controller)

        let cell = controller.tableView(controller.tableView, cellForRowAt: IndexPath(row: 2, section: 1))
        XCTAssertEqual(cell.detailTextLabel?.text, "Good")
    }
}

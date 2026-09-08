//
//  WriterSettingsViewControllerTests.swift
//  LunaWriterTests
//

import UIKit
import XCTest
@testable import LunaWriterLibraryUI
import LunaWriterModels
import LunaWriterStorage

final class WriterSettingsViewControllerTests: XCTestCase {

    private enum EditorRowIndex {
        static let font = 0
        static let lineWidth = 2
        static let focusMode = 3
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

    /// organiser #12: font, line width and focus mode used to present a
    /// `UIAlertController(.actionSheet)` with no popover anchor, which
    /// crashes on iPad. They now carry their own `UIMenu`.
    @MainActor
    func testFontLineWidthAndFocusModeRowsCarryAMenuInsteadOfAnActionSheet() throws {
        let stack = try makeWriterStack()
        let environment = makeLibraryEnvironment(stack: stack)
        let controller = WriterSettingsViewController(environment: environment)
        layoutWriterScreen(controller)

        for row in [EditorRowIndex.font, EditorRowIndex.lineWidth, EditorRowIndex.focusMode] {
            let cell = controller.tableView(controller.tableView, cellForRowAt: IndexPath(row: row, section: 0))
            let button = try XCTUnwrap(cell.accessoryView as? UIButton, "row \(row)")
            XCTAssertNotNil(button.menu, "row \(row)")
            XCTAssertTrue(button.showsMenuAsPrimaryAction, "row \(row)")
        }
    }

    /// organiser #12: selecting any settings row — including the three that
    /// used to open an action sheet — never presents a view controller. On a
    /// regular-width (iPad-shaped) trait collection an action sheet with no
    /// anchor would have crashed; a `UIMenu` never presents one at all.
    @MainActor
    func testNoRowPresentsAnActionSheetOnARegularWidthTraitCollection() throws {
        let stack = try makeWriterStack()
        let handler = ScriptedReadAlongSettings()
        let environment = makeLibraryEnvironment(stack: stack, readAlongSettings: handler)
        let controller = WriterSettingsViewController(environment: environment)
        let host = UINavigationController(rootViewController: controller)
        host.setOverrideTraitCollection(UITraitCollection(horizontalSizeClass: .regular), forChild: controller)
        layoutWriterScreen(host, width: 1024, height: 768)

        for section in 0..<controller.numberOfSections(in: controller.tableView) {
            for row in 0..<controller.tableView(controller.tableView, numberOfRowsInSection: section) {
                controller.tableView(
                    controller.tableView, didSelectRowAt: IndexPath(row: row, section: section))
            }
        }

        XCTAssertNil(controller.presentedViewController)
    }

    /// organiser #33: nothing constructed this screen. `present(from:)` picks
    /// a form sheet on a wide presenter and a push when a nav stack exists.
    @MainActor
    func testPresentFromChoosesAFormSheetOnAWidePresenter() throws {
        let stack = try makeWriterStack()
        let environment = makeLibraryEnvironment(stack: stack)
        let presenter = UIViewController()
        let window = hostWriterScreenInWindow(presenter, width: 1024, height: 768)

        WriterSettingsViewController.present(from: presenter, environment: environment)

        let nav = try XCTUnwrap(presenter.presentedViewController as? UINavigationController)
        XCTAssertTrue(window.rootViewController === presenter)
        XCTAssertEqual(nav.modalPresentationStyle, .formSheet)
        XCTAssertTrue(nav.viewControllers.first is WriterSettingsViewController)
    }

    @MainActor
    func testPresentFromPushesOntoAnExistingNavigationStackOnACompactPresenter() throws {
        let stack = try makeWriterStack()
        let environment = makeLibraryEnvironment(stack: stack)
        let root = UIViewController()
        let nav = UINavigationController(rootViewController: root)
        layoutWriterScreen(nav, width: 390, height: 844)

        WriterSettingsViewController.present(from: root, environment: environment)

        XCTAssertNil(root.presentedViewController)
        XCTAssertTrue(nav.viewControllers.last is WriterSettingsViewController)
    }
}

//
//  WriterSettingsTests.swift
//  LunaWriterTests
//

import Foundation
import XCTest
@testable import LunaWriterStorage
import LunaWriterModels

final class WriterSettingsTests: XCTestCase {

    func testASettingSurvivesANewReaderOfTheSameSuite() throws {
        let suite = try makeSuite()
        let settings = WriterSettings(defaults: suite)

        settings.focusMode = .sentence
        settings.lineWidth = .wide
        settings.fontSize = 21
        settings.showAuthorship = false
        settings.lastCalibrationGrade = "Good"
        settings.paletteTrigger = .atSign

        let reader = WriterSettings(defaults: suite)
        XCTAssertEqual(reader.focusMode, .sentence)
        XCTAssertEqual(reader.lineWidth, .wide)
        XCTAssertEqual(reader.fontSize, 21)
        XCTAssertFalse(reader.showAuthorship)
        XCTAssertEqual(reader.paletteTrigger, .atSign)
        XCTAssertEqual(reader.lastCalibrationGrade, "Good")
    }

    func testAValueAnOlderBuildNeverWroteReadsAsTheShippedDefault() throws {
        let settings = WriterSettings(defaults: try makeSuite())

        XCTAssertEqual(settings.focusMode, .off)
        XCTAssertEqual(settings.lineWidth, .medium)
        XCTAssertEqual(settings.fontSize, WriterSettings.defaultFontSize)
        XCTAssertTrue(settings.showAuthorship, "authorship is shown until it is turned off")
        XCTAssertFalse(settings.gazeEnabled)
        XCTAssertFalse(settings.voiceEnabled)
        XCTAssertNil(settings.fontIdentifier)
        XCTAssertEqual(settings.paletteTrigger, .doubleSpace, "the palette opens on a double space until changed")
    }

    func testAValueFromANewerBuildReadsAsTheShippedDefault() throws {
        let suite = try makeSuite()
        suite.set("kaleidoscope", forKey: "luna.writer.focusMode")
        suite.set("enormous", forKey: "luna.writer.lineWidth")
        suite.set("whistle", forKey: "luna.writer.paletteTrigger")

        let settings = WriterSettings(defaults: suite)
        XCTAssertEqual(settings.focusMode, .off)
        XCTAssertEqual(settings.lineWidth, .medium)
        XCTAssertEqual(settings.paletteTrigger, .doubleSpace)
    }

    func testEveryChangeIsAnnouncedOnce() throws {
        let center = NotificationCenter()
        let settings = WriterSettings(defaults: try makeSuite(), center: center)
        var announcements = 0
        let token = center.addObserver(
            forName: WriterSettings.didChange, object: nil, queue: nil
        ) { _ in announcements += 1 }
        addTeardownBlock { center.removeObserver(token) }

        settings.focusMode = .paragraph
        settings.voiceEnabled = true
        settings.lastCalibrationGrade = nil

        XCTAssertEqual(announcements, 3)
        XCTAssertNil(settings.lastCalibrationGrade)
    }

    func testAChangeFromABackgroundQueueIsAnnouncedOnMain() throws {
        let center = NotificationCenter()
        let settings = WriterSettings(defaults: try makeSuite(), center: center)
        let announced = expectation(description: "announced on main")
        let token = center.addObserver(
            forName: WriterSettings.didChange, object: nil, queue: nil
        ) { _ in
            XCTAssertTrue(Thread.isMainThread)
            announced.fulfill()
        }
        addTeardownBlock { center.removeObserver(token) }

        DispatchQueue.global().async { settings.lastCalibrationGrade = "Fair" }

        wait(for: [announced], timeout: 2)
        XCTAssertEqual(settings.lastCalibrationGrade, "Fair")
    }

    private func makeSuite() throws -> UserDefaults {
        let name = "luna.writer.tests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return try XCTUnwrap(UserDefaults(suiteName: name))
    }
}

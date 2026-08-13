//
//  FactoryResetTests.swift
//  LunaTests
//

import XCTest
@testable import LunaStorage

/// The factory reset's file sweep, over a temporary tree rather than the real
/// containers. The rest of `eraseEverything()` (defaults domains, the keychain,
/// the notification queue) is process-global by nature and would erase the test
/// host's own state, so it is exercised on device instead — the sweep is the
/// part with rules in it.
final class FactoryResetTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("factory-reset-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func write(_ name: String, contents: String = "x") throws {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    func testEveryChildGoesIncludingWholeSubtreesAndDotfiles() throws {
        try write("saves.sqlite")
        // WAL's siblings live beside the database and are as much of the saved
        // list as the file they belong to.
        try write("saves.sqlite-wal")
        try write("saves.sqlite-shm")
        try write("Articles/abc-source.epub")
        try write("Articles/images/lead.jpg")
        try write(".hidden-marker")

        var report = FactoryReset.Report()
        FactoryReset.empty(root, into: &report)

        let survivors = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)
        XCTAssertEqual(survivors, [], "the sweep leaves nothing behind")
        XCTAssertTrue(report.failures.isEmpty)
        // CHILDREN only — the nested files go with `Articles`, not as entries.
        XCTAssertEqual(
            Set(report.removedPaths),
            ["saves.sqlite", "saves.sqlite-wal", "saves.sqlite-shm", "Articles", ".hidden-marker"])
        // The directory itself stays: nothing recreates `Documents` at launch.
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testContainerManagerBookkeepingIsLeftAlone() throws {
        try write("saves.sqlite")
        try write("SystemData/keep-me")
        try write(".com.apple.mobile_container_manager.metadata.plist")

        var report = FactoryReset.Report()
        FactoryReset.empty(root, into: &report)

        let survivors = Set(try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil).map(\.lastPathComponent))
        XCTAssertEqual(
            survivors,
            ["SystemData", ".com.apple.mobile_container_manager.metadata.plist"],
            "the container manager's own entries are not the app's to delete")
        XCTAssertEqual(report.removedPaths, ["saves.sqlite"])
        XCTAssertTrue(
            report.failures.isEmpty,
            "skipping them is not a failure — a failure list full of expected ones says nothing")
    }

    func testAMissingDirectoryIsNotAnError() {
        var report = FactoryReset.Report()
        FactoryReset.empty(root.appendingPathComponent("never-existed"), into: &report)
        XCTAssertTrue(report.removedPaths.isEmpty)
        XCTAssertTrue(report.failures.isEmpty)
    }

    func testTheSummaryNamesFailuresSoAPartialWipeIsNotReadAsAWholeOne() {
        var partial = FactoryReset.Report()
        partial.removedPaths = ["a"]
        partial.failures = ["Library: busy"]
        XCTAssertTrue(partial.summary.contains("1 failure(s)"))
        XCTAssertTrue(partial.summary.contains("Library: busy"))
    }
}

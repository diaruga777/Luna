//
//  LibraryFolderWatcherTests.swift
//  LunaWriterTests
//

import Foundation
import XCTest
@testable import LunaWriterStorage

final class LibraryFolderWatcherTests: XCTestCase {

    private final class RecordingHandler: LibraryScanHandling {
        private let lock = NSLock()
        private var _scans: [[ExternalFileSnapshot]] = []
        let expectation: XCTestExpectation

        init(expectation: XCTestExpectation) { self.expectation = expectation }

        var scans: [[ExternalFileSnapshot]] {
            lock.lock()
            defer { lock.unlock() }
            return _scans
        }

        func libraryDidScan(_ files: [ExternalFileSnapshot]) {
            lock.lock()
            _scans.append(files)
            lock.unlock()
            expectation.fulfill()
        }
    }

    /// Pins the P1 fix: a `DispatchSourceFileSystemObject` reports for its
    /// own directory only, and a sheet's file lives inside a group folder —
    /// never directly under the root. Before the fix, only the root's own
    /// vnode was watched, so this write raised no event at all.
    func testWritingIntoAnAlreadyWatchedGroupFolderTriggersAScan() throws {
        let root = try makeWriterTemporaryDirectory()
        let groupFolder = root.appendingPathComponent("Travel", isDirectory: true)
        try FileManager.default.createDirectory(at: groupFolder, withIntermediateDirectories: true)
        try Data("# One".utf8).write(to: groupFolder.appendingPathComponent("One.md"))

        let watcher = LibraryFolderWatcher(rootDirectory: root, coalescingInterval: 0.05)
        let expectation = expectation(description: "scan after a write inside the group folder")
        let handler = RecordingHandler(expectation: expectation)
        watcher.handler = handler
        watcher.start()
        addTeardownBlock { watcher.stop() }

        try Data("# Two".utf8).write(to: groupFolder.appendingPathComponent("Two.md"))

        wait(for: [expectation], timeout: 5)
        let sawTwo = handler.scans.contains { $0.contains { $0.relativePath == "Travel/Two.md" } }
        XCTAssertTrue(sawTwo, "a write inside an existing group folder must reach the handler")
    }

    func testScanOnForegroundScansImmediatelyWithoutWaitingForAnEvent() throws {
        let root = try makeWriterTemporaryDirectory()
        try Data("# One".utf8).write(to: root.appendingPathComponent("One.md"))

        // A coalescing interval long enough that only an explicit foreground
        // scan — not the coalesced watch — could satisfy the expectation
        // inside the wait below.
        let watcher = LibraryFolderWatcher(rootDirectory: root, coalescingInterval: 30)
        let expectation = expectation(description: "foreground scan")
        let handler = RecordingHandler(expectation: expectation)
        watcher.handler = handler
        watcher.start()
        addTeardownBlock { watcher.stop() }

        watcher.scanOnForeground()

        wait(for: [expectation], timeout: 5)
        XCTAssertEqual(handler.scans.first?.map(\.relativePath), ["One.md"])
    }
}

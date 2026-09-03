//
//  WriterStorageTestSupport.swift
//  LunaTests
//

import Foundation
import XCTest
@testable import LunaWriterStorage

/// A sentence embedding a test writes the answers for, so a score in an
/// assertion is a fact rather than a model's opinion.
final class ScriptedEmbedding: SentenceEmbedding {
    let modelVersion = "scripted-1"
    var dimensions: Int
    /// Vectors by the exact text they are asked for.
    var exact: [String: [Float]] = [:]
    /// Returned for any text the script does not name; nil stores no vector.
    var fallback: [Float]?

    init(dimensions: Int = 2, fallback: [Float]? = nil) {
        self.dimensions = dimensions
        self.fallback = fallback
    }

    func vector(for text: String) -> [Float]? {
        exact[text] ?? fallback
    }
}

/// Reports a sheet as unsaved, so the reconciler's defer path can be driven.
final class StubOpenDocuments: OpenDocumentQuerying {
    var unsaved: Set<DocumentID> = []
    func hasUnsavedEdits(_ id: DocumentID) -> Bool { unsaved.contains(id) }
}

/// Records the changes a repository posts.
final class RecordingLibraryObserver: LibraryChangeObserving {
    var changes: [LibraryChange] = []
    func libraryDidChange(_ change: LibraryChange) { changes.append(change) }
}

extension XCTestCase {

    /// A directory of this test's own, removed when the test ends. Nothing in
    /// this suite may touch the real Application Support.
    func makeWriterTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LunaWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// A whole storage stack in a temp directory, on its own defaults suite.
    func makeWriterStack(embedding: SentenceEmbedding? = nil) throws -> WriterStorageStack {
        let root = try makeWriterTemporaryDirectory()
        let suiteName = "luna.writer.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suiteName) }
        return try WriterStorageStack(
            databaseURL: root.appendingPathComponent("writer.sqlite"),
            libraryRoot: root.appendingPathComponent("Library", isDirectory: true),
            embedding: embedding, defaults: defaults)
    }

    /// Writes a `.md` file under the library root and returns its scan entry.
    @discardableResult
    func writeWriterFile(
        _ text: String, at relativePath: String, in stack: WriterStorageStack,
        modified: Date = Date()
    ) throws -> ExternalFileSnapshot {
        let url = stack.libraryRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: modified], ofItemAtPath: url.path)
        return ExternalFileSnapshot(
            relativePath: relativePath, modifiedAt: modified, size: text.utf8.count)
    }
}

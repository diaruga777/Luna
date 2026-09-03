import Foundation
import LunaWriterModels

/// Sheets as plain `.md` files under the library root.
///
/// A save re-derives everything the library shows about a sheet from the text
/// it just wrote — title, snippet, counts — and moves the file when the title
/// changed, so what Files shows and what the library shows cannot drift.
public final class FileDocumentTextStore: DocumentTextStoring {

    public let rootDirectory: URL
    private let library: WriterLibraryStoring
    private let documentIndex: DocumentIndexing?
    private let fileManager = FileManager.default

    public init(
        rootDirectory: URL, library: WriterLibraryStoring, documentIndex: DocumentIndexing? = nil
    ) {
        self.rootDirectory = rootDirectory
        self.library = library
        self.documentIndex = documentIndex
        try? fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
    }

    public func url(for relativePath: String) -> URL {
        rootDirectory.appendingPathComponent(relativePath)
    }

    public func loadText(_ document: WriterDocument) throws -> String {
        guard !document.fileRelativePath.isEmpty else { return "" }
        let url = url(for: document.fileRelativePath)
        guard fileManager.fileExists(atPath: url.path) else { return "" }
        return try String(contentsOf: url, encoding: .utf8)
    }

    public func saveText(_ text: String, for document: inout WriterDocument) throws {
        let summary = DocumentTextSummary.summarize(text)
        document.title = summary.title
        document.snippet = summary.snippet
        document.wordCount = summary.words
        document.characterCount = summary.characters

        let previousPath = document.fileRelativePath
        let target = LibraryFileLayout.path(
            for: document, groups: try library.groups(),
            taken: try takenPaths(excluding: document, previousPath: previousPath))
        let targetURL = url(for: target)
        try fileManager.createDirectory(
            at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !previousPath.isEmpty, previousPath != target {
            let previousURL = url(for: previousPath)
            if fileManager.fileExists(atPath: previousURL.path) {
                try? fileManager.removeItem(at: targetURL)
                try fileManager.moveItem(at: previousURL, to: targetURL)
            }
        }
        try write(text, to: targetURL)

        document.fileRelativePath = target
        document.revision += 1
        document.updatedAt = Date()
        try library.update(document)
        try documentIndex?.index(document, body: text)
    }

    public func deleteText(_ document: WriterDocument) throws {
        guard !document.fileRelativePath.isEmpty else { return }
        let url = url(for: document.fileRelativePath)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    /// Files already in the destination folder, so a rename onto an occupied
    /// name takes a suffix instead of overwriting a neighbour.
    private func takenPaths(excluding document: WriterDocument, previousPath: String) throws -> Set<String> {
        let folder = LibraryFileLayout.folderPath(for: document.groupID, groups: try library.groups())
        let folderURL = folder.reduce(rootDirectory) { $0.appendingPathComponent($1) }
        let names = (try? fileManager.contentsOfDirectory(atPath: folderURL.path)) ?? []
        let prefix = folder.isEmpty ? "" : folder.joined(separator: "/") + "/"
        return Set(names
            .filter { $0.hasSuffix(".\(LibraryFileLayout.fileExtension)") }
            .map { prefix + $0 }
            .filter { $0 != previousPath })
    }

    /// Coordinated so an edit made in Files is not overwritten mid-write, and
    /// atomic so a crash leaves the previous text rather than half of this one.
    private func write(_ text: String, to url: URL) throws {
        var coordinatorError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(
            writingItemAt: url, options: .forReplacing, error: &coordinatorError
        ) { destination in
            do {
                try Data(text.utf8).write(to: destination, options: .atomic)
            } catch {
                writeError = error
            }
        }
        if let writeError { throw writeError }
        if let coordinatorError { throw coordinatorError }
    }
}

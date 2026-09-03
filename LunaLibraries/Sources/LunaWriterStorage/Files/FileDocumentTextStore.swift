import Foundation
import LunaWriterModels

/// A sheet's file exists but nothing here could read it as text — still
/// downloading from iCloud, or bytes that no encoding this store tries
/// decodes. Distinct from "no file yet", which is a legitimately empty sheet.
public struct DocumentTextUnavailable: Error {}

/// What reading a file at a relative path found.
enum TextLoadResult: Equatable {
    case text(String)
    case absent
    case unavailable
}

/// Moves or removes a sheet's file on the library's behalf. The database
/// layer calls this rather than touching the file system itself, so
/// `SQLiteWriterLibrary` stays ignorant of where — or whether — a sheet's
/// text lives on disk; only the store that owns the library root knows that.
public protocol DocumentFileRelocating: AnyObject {
    /// Moves the file to `.Trash`, flattened and collision-safe, and answers
    /// its new relative path. Nil when there was no file to move — an unsaved
    /// sheet, or one whose file is already gone.
    func relocateToTrash(_ relativePath: String) -> String?
    /// Moves a trashed sheet's file back under the folder its current group
    /// and title resolve to. Nil when there was nothing to move back.
    func restore(_ document: WriterDocument, groups: [WriterGroup]) -> String?
    /// Removes the file for good. A no-op when there is none.
    func removePermanently(_ relativePath: String)
}

/// Sheets as plain `.md` files under the library root.
///
/// A save re-derives everything the library shows about a sheet from the text
/// it just wrote — title, snippet, counts — and moves the file when the title
/// changed, so what Files shows and what the library shows cannot drift.
public final class FileDocumentTextStore: DocumentTextStoring {

    public let rootDirectory: URL
    private let library: WriterLibraryStoring
    private let documentIndex: DocumentIndexing?
    private let fileManager: FileManager

    public init(
        rootDirectory: URL, library: WriterLibraryStoring, documentIndex: DocumentIndexing? = nil,
        fileManager: FileManager = .default
    ) {
        self.rootDirectory = rootDirectory
        self.library = library
        self.documentIndex = documentIndex
        self.fileManager = fileManager
        try? fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
    }

    public func url(for relativePath: String) -> URL {
        rootDirectory.appendingPathComponent(relativePath)
    }

    public func loadText(_ document: WriterDocument) throws -> String {
        switch loadText(atRelativePath: document.fileRelativePath) {
        case .text(let text): return text
        case .absent: return ""
        case .unavailable: throw DocumentTextUnavailable()
        }
    }

    /// Reads the text at a path relative to the root, distinguishing "no file
    /// there" from "a file is there but could not be read" — a scan skips a
    /// file it cannot read rather than adopting or reloading it as empty.
    func loadText(atRelativePath relativePath: String) -> TextLoadResult {
        guard !relativePath.isEmpty else { return .text("") }
        let fileURL = url(for: relativePath)
        guard fileManager.fileExists(atPath: fileURL.path) else { return .absent }
        if let values = try? fileURL.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
           let status = values.ubiquitousItemDownloadingStatus, status != .current {
            return .unavailable
        }
        guard let data = try? Data(contentsOf: fileURL) else { return .unavailable }
        if data.isEmpty { return .text("") }
        if let decoded = Self.decode(data) { return .text(decoded) }
        return .unavailable
    }

    /// UTF-8 first (the common, correct case), then UTF-16 (a BOM identifies
    /// it), then Latin-1 as the floor: every byte value decodes under it, so
    /// this never fails and a strange encoding shows as real text rather than
    /// an empty sheet.
    private static func decode(_ data: Data) -> String? {
        for encoding: String.Encoding in [.utf8, .utf16, .isoLatin1] {
            if let decoded = String(data: data, encoding: encoding) { return decoded }
        }
        return nil
    }

    public func saveText(_ text: String, for document: inout WriterDocument) throws {
        let summary = DocumentTextSummary.summarize(text)
        document.title = summary.title
        document.snippet = summary.snippet
        document.wordCount = summary.words
        document.characterCount = summary.characters
        document.sentenceCount = summary.sentences

        let previousPath = document.fileRelativePath
        let groups = try library.groups()
        let target = LibraryFileLayout.path(
            for: document, groups: groups,
            taken: try takenPaths(excluding: document, previousPath: previousPath, groups: groups))
        let targetURL = url(for: target)
        try fileManager.createDirectory(
            at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        // The new content lands at its new path first, atomically, so a save
        // that fails partway never destroys a file that already existed. The
        // old path is cleaned up only once the new one is safely down.
        try write(text, to: targetURL)
        if !previousPath.isEmpty, previousPath != target {
            let previousURL = url(for: previousPath)
            if fileManager.fileExists(atPath: previousURL.path) {
                coordinatedRemove(previousURL)
            }
        }

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
        coordinatedRemove(url)
    }

    /// Files already in the destination folder, so a rename onto an occupied
    /// name takes a suffix instead of overwriting a neighbour.
    private func takenPaths(
        excluding document: WriterDocument, previousPath: String, groups: [WriterGroup]
    ) throws -> Set<String> {
        let folder = LibraryFileLayout.folderPath(for: document.groupID, groups: groups)
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

    /// Best-effort and coordinated: a stray file left behind by a failed
    /// removal is a cleanup problem, not a reason to fail the save that
    /// already landed.
    private func coordinatedRemove(_ url: URL) {
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(
            writingItemAt: url, options: .forDeleting, error: &coordinatorError
        ) { destination in
            try? self.fileManager.removeItem(at: destination)
        }
    }

    private func existingTrashPaths() -> Set<String> {
        let trashURL = rootDirectory.appendingPathComponent(LibraryFileLayout.trashFolderName)
        let names = (try? fileManager.contentsOfDirectory(atPath: trashURL.path)) ?? []
        return Set(names
            .filter { $0.hasSuffix(".\(LibraryFileLayout.fileExtension)") }
            .map { "\(LibraryFileLayout.trashFolderName)/\($0)" })
    }

    private func coordinatedMove(from source: URL, to destination: URL) throws {
        var coordinatorError: NSError?
        var moveError: Error?
        NSFileCoordinator().coordinate(
            writingItemAt: source, options: .forMoving,
            writingItemAt: destination, options: .forReplacing,
            error: &coordinatorError
        ) { sourceURL, destinationURL in
            do {
                if self.fileManager.fileExists(atPath: destinationURL.path) {
                    try self.fileManager.removeItem(at: destinationURL)
                }
                try self.fileManager.moveItem(at: sourceURL, to: destinationURL)
            } catch {
                moveError = error
            }
        }
        if let moveError { throw moveError }
        if let coordinatorError { throw coordinatorError }
    }
}

extension FileDocumentTextStore: DocumentFileRelocating {
    public func relocateToTrash(_ relativePath: String) -> String? {
        guard !relativePath.isEmpty else { return nil }
        let source = url(for: relativePath)
        guard fileManager.fileExists(atPath: source.path) else { return nil }
        let target = LibraryFileLayout.trashPath(
            forOriginalPath: relativePath, taken: existingTrashPaths())
        let targetURL = url(for: target)
        do {
            try fileManager.createDirectory(
                at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try coordinatedMove(from: source, to: targetURL)
            return target
        } catch {
            return nil
        }
    }

    public func restore(_ document: WriterDocument, groups: [WriterGroup]) -> String? {
        let source = url(for: document.fileRelativePath)
        guard fileManager.fileExists(atPath: source.path) else { return nil }
        let taken = (try? takenPaths(excluding: document, previousPath: "", groups: groups)) ?? []
        let target = LibraryFileLayout.path(for: document, groups: groups, taken: taken)
        let targetURL = url(for: target)
        do {
            try fileManager.createDirectory(
                at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try coordinatedMove(from: source, to: targetURL)
            return target
        } catch {
            return nil
        }
    }

    public func removePermanently(_ relativePath: String) {
        guard !relativePath.isEmpty else { return }
        let target = url(for: relativePath)
        guard fileManager.fileExists(atPath: target.path) else { return }
        coordinatedRemove(target)
    }
}

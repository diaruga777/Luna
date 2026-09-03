import Foundation
import LunaWriterModels

/// Everything this tier owns, built from two folders.
///
/// One place assembles the graph so the app's wiring and a test's temp
/// directory get the same object, wired the same way. The watcher is started
/// by the caller: a test drives the reconciler directly, and a background
/// process has no folder to watch.
public final class WriterStorageStack {

    public let database: WriterDatabase
    public let library: SQLiteWriterLibrary
    public let documentIndex: SQLiteDocumentIndex
    public let noteIndex: SQLiteNoteIndex
    public let textStore: FileDocumentTextStore
    public let watcher: LibraryFolderWatcher
    public let reconciler: ExternalChangeReconciler
    public let router: NoteRouter
    public let intents: WriterIntentServices
    public let settings: WriterSettings
    public let libraryRoot: URL

    public init(
        databaseURL: URL, libraryRoot: URL,
        embedding: SentenceEmbedding? = nil,
        defaults: UserDefaults = .standard
    ) throws {
        self.libraryRoot = libraryRoot
        self.database = try WriterDatabase(fileURL: databaseURL)
        self.documentIndex = SQLiteDocumentIndex(database: database, embedding: embedding)
        self.noteIndex = SQLiteNoteIndex(database: database, embedding: embedding)
        // The library takes both indexes as collaborators, so its own writes
        // (update, setKeywords, note insert/update) keep search current
        // without every call site having to remember to re-index.
        self.library = try SQLiteWriterLibrary(
            database: database, documentIndex: documentIndex, noteIndex: noteIndex)
        self.textStore = FileDocumentTextStore(
            rootDirectory: libraryRoot, library: library, documentIndex: documentIndex)
        // Weak back-reference: the library reads a body through the text
        // store only when a metadata-only write needs to refresh the
        // (contentless, so body-less) search index.
        library.textStore = textStore
        self.watcher = LibraryFolderWatcher(rootDirectory: libraryRoot)
        self.reconciler = ExternalChangeReconciler(
            library: library, textStore: textStore, snapshots: library, marks: library,
            documentIndex: documentIndex)
        self.router = NoteRouter(library: library, documentIndex: documentIndex)
        self.settings = WriterSettings(defaults: defaults)
        self.intents = WriterIntentServices(
            library: library, notes: library, textStore: textStore, router: router)
        watcher.handler = reconciler
    }

    /// The app's own locations: the database in Application Support, where a
    /// writer never sees it, and the sheets in Documents, where Files does.
    public static func makeDefault(
        embedding: SentenceEmbedding? = NLSentenceEmbedding()
    ) throws -> WriterStorageStack {
        let manager = FileManager.default
        let support = try manager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
            create: true).appendingPathComponent("LunaWriter", isDirectory: true)
        let documents = try manager.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Library", isDirectory: true)
        return try WriterStorageStack(
            databaseURL: support.appendingPathComponent("writer.sqlite"),
            libraryRoot: documents, embedding: embedding)
    }

    /// Creates the Welcome sheet on a first run.
    @discardableResult
    public func bootstrap() throws -> WriterDocument? {
        try LibraryBootstrap.run(library: library, textStore: textStore)
    }
}

import UIKit
import LunaDesignSystem
import LunaGaze
import LunaWriterEditor
import LunaWriterLibraryUI
import LunaWriterModels
import LunaWriterReadAlong
import LunaWriterStorage
import LunaWriterText
import LunaWriterVoice

/// The composition root for Luna Writer. It builds the storage stack once and
/// installs every protocol witness; view controllers receive built services
/// and never locate them (claudedocs/plans/writer-app.md §10).
@MainActor enum WriterWiring {
    private static var storage: WriterStorageStack?
    private static let openSessions = OpenSessionRegistry()
    private static var editorMaker: WriterEditorMaker?
    private static var readAlong: WriterReadAlongChrome?
    private static weak var root: LibraryRootViewController?
    /// A sheet asked for before the window existed (a deep link or an intent
    /// that launched the app); shown by the first root.
    private static var pendingDocument: DocumentID?

    static func install() {
        _ = try? storageStack()
    }

    /// Built on first use so an intent that runs before `didFinishLaunching`
    /// finishes still has a store.
    @discardableResult
    static func storageStack() throws -> WriterStorageStack {
        if let storage { return storage }
        let stack = try WriterStorageStack.makeDefault()
        try stack.bootstrap()
        stack.reconciler.openDocuments = openSessions
        stack.watcher.start()
        storage = stack
        return stack
    }

    nonisolated static func intentServices() throws -> WriterIntentServices {
        try MainActor.assumeIsolatedIfNeeded { try storageStack().intents }
    }

    static func applicationDidEnterBackground() {
        openSessions.flushAll()
    }

    /// A folder change made while suspended (an iCloud sync, another
    /// process) is not seen until the watcher's next event; forcing a scan
    /// on the way back to the foreground picks it up immediately instead of
    /// waiting for the next unrelated write.
    static func sceneWillEnterForeground() {
        storage?.watcher.scanNow()
    }

    static func makeRootViewController() -> UIViewController {
        guard let stack = try? storageStack() else {
            let placeholder = UIViewController()
            placeholder.view.backgroundColor = LunaColors.background
            return placeholder
        }
        let maker = WriterEditorMaker(
            storage: stack, registry: openSessions, aiAssistant: makeAIAssistant())
        editorMaker = maker
        let readAlong = WriterReadAlongChrome(storage: stack, trackerMaker: Self.makeGazeTrackerMaker())
        self.readAlong = readAlong
        let environment = LibraryEnvironment(
            library: stack.library, notes: stack.library, marks: stack.library,
            textStore: stack.textStore, snapshots: stack.library, noteIndex: stack.noteIndex,
            settings: stack.settings, editorMaker: maker,
            readAlongChrome: readAlong, readAlongSettings: readAlong,
            libraryRootPath: stack.libraryRoot.path)
        let root = LibraryRootViewController(environment: environment)
        self.root = root
        if let pendingDocument {
            self.pendingDocument = nil
            show(document: pendingDocument)
        }
        return root
    }

    /// The camera tracker exists only where ARKit does; elsewhere read-along
    /// runs voice-only.
    private static func makeGazeTrackerMaker() -> GazeTrackerMaking? {
        #if canImport(ARKit)
        return ARFaceGazeTrackerMaker()
        #else
        return nil
        #endif
    }

    /// On-device generation exists only on iOS 26 hardware that has the model.
    private static func makeAIAssistant() -> AIWritingAssisting? {
        if #available(iOS 26, *) {
            let assistant = FoundationModelsWritingAssistant()
            return assistant.isAvailable ? assistant : nil
        }
        return nil
    }

    /// Parks the id only when there is no root yet to show it in (a deep
    /// link or intent that raced app launch); a root that exists but cannot
    /// find the document has nothing left to wait for, so it drops the
    /// request instead of parking it forever.
    static func show(document id: DocumentID) {
        guard let root else {
            pendingDocument = id
            return
        }
        guard let stack = storage, let document = try? stack.library.document(id) else { return }
        root.show(document: document)
    }

    static func open(_ url: URL) {
        if url.isFileURL {
            importFile(at: url)
            return
        }
        guard let route = WriterDeepLink(url: url) else { return }
        switch route {
        case .document(let id): show(document: id)
        case .newSheet:
            if let document = try? storageStack().intents.createDocument(title: nil, text: nil, in: nil) {
                show(document: document.id)
            }
        }
    }

    /// Files' "Open in Luna Writer", or a file dropped on the Dock icon on
    /// Mac: the text is copied into a new Inbox sheet rather than opened in
    /// place, since a sheet is a database row plus a file this tier owns —
    /// not an arbitrary document Luna Writer edits where it sits.
    private static func importFile(at url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        guard let document = try? storageStack().intents.createDocument(title: nil, text: text, in: nil)
        else { return }
        show(document: document.id)
    }
}

extension MainActor {
    /// Intents may arrive on any thread; the store is main-actor owned.
    static func assumeIsolatedIfNeeded<T>(_ body: @MainActor () throws -> T) rethrows -> T {
        if Thread.isMainThread {
            return try MainActor.assumeIsolated(body)
        }
        return try DispatchQueue.main.sync { try MainActor.assumeIsolated(body) }
    }
}

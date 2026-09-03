import UIKit
import LunaDesignSystem
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

    static func makeRootViewController() -> UIViewController {
        guard let stack = try? storageStack() else {
            let placeholder = UIViewController()
            placeholder.view.backgroundColor = LunaColors.background
            return placeholder
        }
        let maker = WriterEditorMaker(
            storage: stack, registry: openSessions, aiAssistant: makeAIAssistant())
        editorMaker = maker
        let readAlong = WriterReadAlongChrome(storage: stack)
        self.readAlong = readAlong
        let environment = LibraryEnvironment(
            library: stack.library, notes: stack.library, marks: stack.library,
            textStore: stack.textStore, snapshots: stack.library, noteIndex: stack.noteIndex,
            settings: stack.settings, editorMaker: maker,
            readAlongChrome: readAlong, readAlongSettings: readAlong, noteRelevance: nil,
            libraryRootPath: stack.libraryRoot.path)
        let root = LibraryRootViewController(environment: environment)
        self.root = root
        if let pendingDocument {
            self.pendingDocument = nil
            show(document: pendingDocument)
        }
        return root
    }

    /// On-device generation exists only on iOS 26 hardware that has the model.
    private static func makeAIAssistant() -> AIWritingAssisting? {
        if #available(iOS 26, *) {
            let assistant = FoundationModelsWritingAssistant()
            return assistant.isAvailable ? assistant : nil
        }
        return nil
    }

    static func show(document id: DocumentID) {
        guard let root, let stack = storage, let document = try? stack.library.document(id) else {
            pendingDocument = id
            return
        }
        root.show(document: document)
    }

    static func open(_ url: URL) {
        guard let route = WriterDeepLink(url: url) else { return }
        switch route {
        case .document(let id): show(document: id)
        case .newSheet:
            if let document = try? storageStack().intents.createDocument(title: nil, text: nil, in: nil) {
                show(document: document.id)
            }
        }
    }
}

/// `lunawriter://document/<uuid>` and `lunawriter://new`.
enum WriterDeepLink: Equatable {
    case document(DocumentID)
    case newSheet

    init?(url: URL) {
        guard url.scheme?.lowercased() == "lunawriter" else { return nil }
        switch url.host?.lowercased() {
        case "new": self = .newSheet
        case "document":
            let component = url.pathComponents.dropFirst().first ?? ""
            guard let uuid = UUID(uuidString: component) else { return nil }
            self = .document(DocumentID(uuid))
        default: return nil
        }
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

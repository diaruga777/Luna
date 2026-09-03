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
        stack.watcher.start()
        storage = stack
        return stack
    }

    nonisolated static func intentServices() throws -> WriterIntentServices {
        try MainActor.assumeIsolatedIfNeeded { try storageStack().intents }
    }

    static func applicationDidEnterBackground() {}

    static func makeRootViewController() -> UIViewController {
        let placeholder = UIViewController()
        placeholder.view.backgroundColor = LunaColors.background
        return placeholder
    }

    static func show(document id: DocumentID) {
        pendingDocument = id
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
    static func assumeIsolatedIfNeeded<T>(_ body: @MainActor () throws -> T) throws -> T {
        if Thread.isMainThread {
            return try MainActor.assumeIsolated(body)
        }
        return try DispatchQueue.main.sync { try MainActor.assumeIsolated(body) }
    }
}

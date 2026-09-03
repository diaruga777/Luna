import UIKit
import LunaWriterEditor
import LunaWriterLibraryUI
import LunaWriterModels
import LunaWriterStorage

/// The organiser's `DocumentEditing` face over the real `EditorViewController`.
/// Hosts the editor as its one child and forwards the two delegate events.
final class WriterEditorScreen: UIViewController, DocumentEditing, EditorViewControllerDelegate {
    let editor: EditorViewController
    let session: DocumentSession
    weak var editingDelegate: DocumentEditingDelegate?

    /// Surfaces the editor's layout witness, so a wiring root that only
    /// holds this `DocumentEditing` value's own concrete type (read-along's,
    /// in `WriterReadAlongWiring`) can reach it without importing
    /// `LunaWriterEditor` at the container's tier.
    weak var layoutObserver: EditorLayoutObserving? {
        get { editor.layoutObserver }
        set { editor.layoutObserver = newValue }
    }

    init(session: DocumentSession, environment: EditorEnvironment) {
        self.session = session
        self.editor = EditorViewController(session: session, environment: environment)
        super.init(nibName: nil, bundle: nil)
        editor.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(editor)
        editor.view.frame = view.bounds
        editor.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(editor.view)
        editor.didMove(toParent: self)
    }

    var document: WriterDocument { session.document }

    func focus(on anchor: TextAnchor) { editor.focus(on: anchor) }

    func flushPendingSave() { try? session.save() }

    func editorRequestsNotesPanel(_ editor: EditorViewController) {
        editingDelegate?.editorRequestsNotesPanel(self)
    }

    func editorDidUpdateDocument(_ editor: EditorViewController, document: WriterDocument) {
        editingDelegate?.editor(self, didUpdate: document)
    }
}

/// Builds one `WriterEditorScreen` per opened sheet and keeps the session in
/// the registry so the reconciler and the background hook can find it.
@MainActor final class WriterEditorMaker: DocumentEditorMaking {
    private let storage: WriterStorageStack
    private let registry: OpenSessionRegistry
    private let aiAssistant: AIWritingAssisting?

    init(storage: WriterStorageStack, registry: OpenSessionRegistry, aiAssistant: AIWritingAssisting?) {
        self.storage = storage
        self.registry = registry
        self.aiAssistant = aiAssistant
    }

    func makeEditor(for document: WriterDocument) -> UIViewController & DocumentEditing {
        let environment = EditorEnvironment(
            noteIndex: storage.noteIndex, noteStore: storage.library,
            marksStore: storage.library, settings: storage.settings, aiAssistant: aiAssistant)
        do {
            let session = try DocumentSession(
                document: document, textStore: storage.textStore, marksStore: storage.library,
                settings: storage.settings, snapshots: storage.library)
            registry.register(session)
            return WriterEditorScreen(session: session, environment: environment)
        } catch {
            return UnavailableEditorScreen(document: document, error: error)
        }
    }
}

/// Shown when a sheet's file cannot be read. Says so instead of opening an
/// empty editor that would overwrite the file on its first autosave.
final class UnavailableEditorScreen: UIViewController, DocumentEditing {
    weak var editingDelegate: DocumentEditingDelegate?
    let document: WriterDocument
    private let error: Error

    init(document: WriterDocument, error: Error) {
        self.document = document
        self.error = error
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        let label = UILabel()
        label.numberOfLines = 0
        label.textAlignment = .center
        label.text = error.localizedDescription
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
        ])
    }

    func focus(on anchor: TextAnchor) {}
    func flushPendingSave() {}
}

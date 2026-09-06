import UIKit
import LunaWriterEditor
import LunaWriterLibraryUI
import LunaWriterModels
import LunaWriterStorage

/// The organiser's `DocumentEditing` face over the real `EditorViewController`.
/// Hosts the editor as its one child and forwards the two delegate events.
final class WriterEditorScreen: UIViewController, DocumentEditing, EditorViewControllerDelegate, LibraryChangeObserving {
    let editor: EditorViewController
    let session: DocumentSession
    weak var editingDelegate: DocumentEditingDelegate?
    private let library: WriterLibraryStoring

    /// Surfaces the editor's layout witness, so a wiring root that only
    /// holds this `DocumentEditing` value's own concrete type (read-along's,
    /// in `WriterReadAlongWiring`) can reach it without importing
    /// `LunaWriterEditor` at the container's tier.
    weak var layoutObserver: EditorLayoutObserving? {
        get { editor.layoutObserver }
        set { editor.layoutObserver = newValue }
    }

    init(session: DocumentSession, environment: EditorEnvironment, library: WriterLibraryStoring) {
        self.library = library
        self.session = session
        self.editor = EditorViewController(session: session, environment: environment)
        super.init(nibName: nil, bundle: nil)
        editor.delegate = self
        library.addObserver(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The one place the session's I/O actually ends — this screen leaving
    /// scope is what "the sheet is closing" means.
    deinit {
        library.removeObserver(self)
        editor.close()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(editor)
        editor.view.frame = view.bounds
        editor.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(editor.view)
        editor.didMove(toParent: self)
    }

    func libraryDidChange(_ change: LibraryChange) {
        guard case .document(let id) = change, id == session.document.id,
              let latest = try? library.document(id) else { return }
        session.refreshDocument(latest)
    }

    var document: WriterDocument { session.document }

    func focus(on anchor: TextAnchor) { editor.focus(on: anchor) }

    var editingState: EditorEditingState { editor.editingState }

    func restoreEditingState(_ state: EditorEditingState) { editor.restoreEditingState(state) }

    func flushPendingSave() { session.saveNow() }

    func replaceText(_ text: String) { session.replaceWholeText(text) }

    func presentStatistics(from presenter: UIViewController) -> Bool {
        editor.presentStatisticsSheet()
        return true
    }

    func editorRequestsNotesPanel(_ editor: EditorViewController) {
        editingDelegate?.editorRequestsNotesPanel(self)
    }

    func editorDidUpdateDocument(_ editor: EditorViewController, document: WriterDocument) {
        editingDelegate?.editor(self, didUpdate: document)
    }

    func editorDidChangeEditingState(_ editor: EditorViewController, state: EditorEditingState) {
        editingDelegate?.editor(self, didChangeEditingState: state)
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
            return WriterEditorScreen(session: session, environment: environment, library: storage.library)
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

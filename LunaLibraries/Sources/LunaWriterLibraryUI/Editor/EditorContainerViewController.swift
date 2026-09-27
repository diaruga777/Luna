import UIKit
import LunaDesignSystem
import LunaModels
import LunaWriterModels
import LunaWriterStorage
import LunaWriterText

/// A document editor with native navigation, chapter controls, and a notes
/// inspector that adapts to a sheet on compact widths.
public final class EditorContainerViewController: UIViewController {

    private let environment: LibraryEnvironment
    private(set) var document: WriterDocument

    private(set) var editor: (UIViewController & DocumentEditing)!
    private var notesPanel: DocumentNotesPanelViewController?
    /// A caret and keyboard state handed in before `viewDidLoad` built the
    /// editor; given to it as soon as it exists.
    private var pendingEditingState: EditorEditingState?
    private var editorTrailingConstraint: NSLayoutConstraint!
    /// The editor's top constraint when the header is shown (pinned below
    /// it) and when the header is hidden (pinned to the view's own top —
    /// the text view's own inset adjustment still clears the safe area).
    /// Exactly one is active at a time.
    private var editorTopToHeaderConstraint: NSLayoutConstraint!
    private var editorTopToViewConstraint: NSLayoutConstraint!
    /// The open notes panel's top constraint, when it is hosted as a side
    /// child — re-pinned alongside the editor when the chrome toggles.
    private var notesPanelTopConstraint: NSLayoutConstraint?
    /// Whether the header, the read-along chip and the side notes panel are
    /// hidden right now: typing hides them, losing focus or reaching the
    /// top of the page shows them, and a double tap on blank space toggles.
    private var isChromeHidden = false
    /// The chrome's hidden state, for a test that cannot see `isChromeHidden`.
    var isChromeHiddenForTesting: Bool { isChromeHidden }

    private lazy var notesButton = UIBarButtonItem(
        image: UIImage(systemName: "note.text"), style: .plain, target: self, action: #selector(notesTapped))

    /// Told where the caret rests in this sheet, so the root can record the
    /// page for the next launch.
    public weak var editingStateObserver: EditorEditingStateObserving?
    /// Opens the sheet a "new chapter" made. The root installs itself.
    public weak var documentOpener: DocumentOpening?

    /// The header's current title — for tests, which cannot see `header`.
    var headerTitleForTesting: String? { title }
    /// The header's current trailing controls — for a test that must tell a
    /// rebuilt control apart from the same one left alone.
    var trailingControlsForTesting: [UIBarButtonItem] { navigationItem.rightBarButtonItems ?? [] }
    /// Whether the notes panel is hosted as a side child right now.
    var isNotesPanelChildForTesting: Bool { notesPanel?.parent === self }
    /// Whether the notes panel is presented as a sheet right now.
    var isNotesPanelPresentedForTesting: Bool {
        notesPanel != nil && notesPanel?.parent !== self
    }

    public init(environment: LibraryEnvironment, document: WriterDocument) {
        self.environment = environment
        self.document = document
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        updateLeadingControls()
    }

    /// The header's back chevron pops a collapsed stack. Beside a visible
    /// sheets column there is nothing to pop, so the control is dropped
    /// rather than left as a dead button.
    ///
    /// Every layout pass asks, so the answer must only be acted on when it
    /// changed: replacing the leading stack dirties layout, and a rebuild
    /// per pass never lets the pass settle.
    private func updateLeadingControls() {
        navigationItem.leftItemsSupplementBackButton = true
        if !(splitViewController?.isCollapsed ?? true) {
            navigationItem.leftBarButtonItem = splitViewController?.displayModeButtonItem
        }
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent || navigationController?.topViewController !== self {
            navigationController?.setNavigationBarHidden(false, animated: animated)
        }
    }



    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LunaColors.background
        // The header carries its own back control; the collapsed stack's bar
        // would otherwise show a second one above it.
        navigationItem.hidesBackButton = false
        navigationItem.largeTitleDisplayMode = .never

        editor = environment.editorMaker.makeEditor(for: document)
        editor.editingDelegate = self
        if let pendingEditingState {
            self.pendingEditingState = nil
            editor.restoreEditingState(pendingEditingState)
        }

        title = displayTitle(for: document)
        updateLeadingControls()
        configureNavigationBar()
        let contentTop = view.safeAreaLayoutGuide.topAnchor

        addChild(editor)
        editor.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(editor.view)
        editor.didMove(toParent: self)

        editorTrailingConstraint = editor.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        editorTopToHeaderConstraint = editor.view.topAnchor.constraint(equalTo: contentTop)
        editorTopToViewConstraint = editor.view.topAnchor.constraint(equalTo: view.topAnchor)
        editorTopToViewConstraint.isActive = false
        NSLayoutConstraint.activate([
            editorTopToHeaderConstraint,
            editor.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            editor.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            editorTrailingConstraint,
        ])

        updateNotesButton()
        layoutForCurrentWidth()
        environment.library.addObserver(self)
    }

    deinit {
        environment.library.removeObserver(self)
    }

    public override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        layoutForCurrentWidth()
    }

    private func displayTitle(for document: WriterDocument) -> String {
        document.title.isEmpty ? L10n.string("Common_untitled") : document.title
    }

    /// Assigning `header.title` re-renders its label even when the string is
    /// unchanged, which an autosave one second after every typing burst
    /// otherwise does for nothing.
    private func setTitleIfChanged(_ title: String) {
        guard self.title != title else { return }
        self.title = title
    }

    private func configureNavigationBar() {
        notesButton.accessibilityLabel = L10n.string("WriterLibrary_polish_documentNotes")
        let chapters = UIBarButtonItem(image: UIImage(systemName: "list.bullet"), style: .plain, target: self, action: #selector(chaptersTapped))
        chapters.accessibilityLabel = L10n.string("WriterLibrary_polish_chapters")
        let more = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in completion(self?.ellipsisMenuChildren() ?? []) }
        ]))
        more.accessibilityLabel = L10n.string("WriterLibrary_polish_more")
        navigationItem.rightBarButtonItems = [more, notesButton, chapters]
    }

    @objc private func chaptersTapped() {
        editor.flushPendingSave()
        let organizer = ChapterOrganizer(library: environment.library, textStore: environment.textStore)
        do {
            if let book = try organizer.book(containing: document) {
                let screen = ChaptersViewController(library: environment.library, textStore: environment.textStore,
                                                    book: book, currentID: document.id) { [weak self] chapter in
                    self?.documentOpener?.openDocument(chapter)
                }
                present(UINavigationController(rootViewController: screen), animated: true)
            } else {
                let alert = UIAlertController(title: L10n.string("WriterLibrary_polish_organizeAsBook"), message: L10n.string("WriterLibrary_polish_organizeAsBookDetail"), preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                alert.addAction(UIAlertAction(title: L10n.string("WriterLibrary_polish_createBook"), style: .default) { [weak self] _ in self?.addNextChapter() })
                present(alert, animated: true)
            }
        } catch { showChapterError(error) }
    }

    private func addNextChapter() {
        editor.flushPendingSave()
        do {
            let chapter = try ChapterOrganizer(library: environment.library, textStore: environment.textStore)
                .startNewChapter(after: document, text: "")
            documentOpener?.openDocument(chapter)
        } catch { showChapterError(error) }
    }

    private func adjacentChapter(_ offset: Int) {
        let organizer = ChapterOrganizer(library: environment.library, textStore: environment.textStore)
        do {
            guard let book = try organizer.book(containing: document) else { return }
            let chapters = try organizer.contents(of: book.id).flatMap(\.chapters)
            guard let index = chapters.firstIndex(where: { $0.id == document.id }), chapters.indices.contains(index + offset) else { return }
            editor.flushPendingSave()
            documentOpener?.openDocument(chapters[index + offset])
        } catch { showChapterError(error) }
    }

    private func showChapterError(_ error: Error) {
        let alert = UIAlertController(title: L10n.string("WriterLibrary_polish_updateBookError"), message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func updateNotesButton() {
        let count = (try? environment.notes.notes(for: document.id).count) ?? 0
        notesButton.accessibilityLabel = "Document Notes, \(count) notes"
    }

    /// For tests, which cannot see the private trailing header button whose
    /// menu this is. Resolves the children eagerly, unlike the deferred
    /// element the real button opens.
    var ellipsisMenuForTesting: UIMenu { UIMenu(children: ellipsisMenuChildren()) }

    /// Identifies the export submenu so a test can find it among the ⋯
    /// menu's other children without depending on its position.
    static let exportMenuIdentifier = UIMenu.Identifier("com.hsanabria.luna.writer.exportMenu")

    private func ellipsisMenuChildren() -> [UIMenuElement] {
        [
            UIAction(title: L10n.string("WriterLibrary_polish_newChapterAfter"), image: UIImage(systemName: "doc.badge.plus")) { [weak self] _ in self?.addNextChapter() },
            UIAction(title: L10n.string("WriterLibrary_polish_previousChapter"), image: UIImage(systemName: "chevron.left")) { [weak self] _ in self?.adjacentChapter(-1) },
            UIAction(title: L10n.string("WriterLibrary_polish_nextChapter"), image: UIImage(systemName: "chevron.right")) { [weak self] _ in self?.adjacentChapter(1) },
            UIAction(title: L10n.string("WriterLibrary_polish_copyChapterLink"), image: UIImage(systemName: "link")) { [weak self] _ in
                guard let self else { return }
                UIPasteboard.general.url = URL(string: "lunawriter://document/\(self.document.id.storageValue)")
            },
            exportMenu(),
            UIAction(
                title: L10n.string("WriterLibrary_sheets_moveAction"),
                image: UIImage(systemName: "folder")
            ) { [weak self] _ in self?.presentMovePicker() },
            UIAction(
                title: L10n.string("Common_delete"),
                image: UIImage(systemName: "trash"), attributes: .destructive
            ) { [weak self] _ in self?.trashDocument() },
        ]
    }

    /// The export formats as a `UIMenu` submenu — never an action sheet,
    /// which crashes on iPad with no popover anchor (organiser #12).
    private func exportMenu() -> UIMenu {
        UIMenu(
            title: L10n.string("WriterLibrary_export_chooseFormatTitle"),
            image: UIImage(systemName: "square.and.arrow.up"),
            identifier: Self.exportMenuIdentifier,
            children: DocumentExportFormat.allCases.map { format in
                UIAction(title: format.displayName) { [weak self] _ in self?.export(as: format) }
            })
    }

    // MARK: - Menu actions

    public func export(as format: DocumentExportFormat) {
        editor.flushPendingSave()
        let text = (try? environment.textStore.loadText(document)) ?? ""
        DocumentExporter.exportAndPresent(
            document: document, text: text, format: format, from: self, anchor: .view(view))
    }

    public func statisticsMessage() -> String {
        editor.flushPendingSave()
        let text = (try? environment.textStore.loadText(document)) ?? ""
        let stats = TextStatistics.measure(text)
        return L10n.string(
            "WriterLibrary_editor_statisticsMessage",
            stats.words, stats.characters, stats.sentences, stats.paragraphs)
    }

    /// Presents the editor's own statistics surface when it exposes one, so
    /// the app shows exactly one statistics presentation instead of this
    /// alert duplicating `StatisticsSheet` (organiser #16).
    public func presentStatistics() {
        guard !editor.presentStatistics(from: self) else { return }
        let alert = UIAlertController(
            title: L10n.string("WriterLibrary_editor_statisticsAction"), message: statisticsMessage(),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.string("Common_ok"), style: .default))
        present(alert, animated: true)
    }

    public func presentKeywordEditor() {
        let screen = KeywordEditorViewController(library: environment.library, document: document)
        present(UINavigationController(rootViewController: screen), animated: true)
    }

    public func presentGoalEditor() {
        let screen = GoalEditorViewController(library: environment.library, document: document)
        present(UINavigationController(rootViewController: screen), animated: true)
    }

    public func presentMovePicker() {
        let picker = MoveDestinationPicker(library: environment.library) { [weak self] group in
            guard let self else { return }
            _ = try? self.environment.library.moveDocument(self.document.id, to: group, at: 0)
        }
        present(UINavigationController(rootViewController: picker), animated: true)
    }

    @discardableResult
    public func toggleFavorite() -> Bool {
        guard (try? environment.library.setFavorite(!document.isFavorite, for: document.id)) != nil else { return false }
        document.isFavorite.toggle()
        return true
    }

    @discardableResult
    public func trashDocument() -> Bool {
        guard (try? environment.library.trash(document.id)) != nil else { return false }
        navigationController?.popViewController(animated: true)
        return true
    }

    public func presentSnapshots() {
        editor.flushPendingSave()
        let screen = SnapshotsViewController(
            snapshotStore: environment.snapshots, textStore: environment.textStore, document: document)
        screen.editor = editor
        present(UINavigationController(rootViewController: screen), animated: true)
    }

    // MARK: - Notes panel

    @objc private func notesTapped() {
        toggleNotesPanel()
    }

    public func toggleNotesPanel() {
        if let notesPanel {
            dismissNotesPanel(notesPanel)
        } else {
            presentNotesPanel()
        }
    }

    /// The notes panel's fixed side-child width.
    private static let notesPanelWidth: CGFloat = 320

    private func presentNotesPanel() {
        let panel = DocumentNotesPanelViewController(
            library: environment.library, notesStore: environment.notes,
            textStore: environment.textStore, document: document)
        panel.editor = editor
        notesPanel = panel
        host(panel, asSideChild: LunaLayout.isWide(containerWidth: view.bounds.width), animated: true)
    }

    private func dismissNotesPanel(_ panel: DocumentNotesPanelViewController) {
        panel.saveDraft { [weak self, weak panel] saved in
            guard saved, let self, let panel else { return }
            self.removeNotesPanel(panel)
        }
    }

    private func removeNotesPanel(_ panel: DocumentNotesPanelViewController) {
        if panel.parent === self {
            panel.willMove(toParent: nil)
            panel.view.removeFromSuperview()
            panel.removeFromParent()
            editorTrailingConstraint.constant = 0
            notesPanelTopConstraint = nil
        } else {
            panel.presentingViewController?.dismiss(animated: true)
        }
        notesPanel = nil
    }

    private func host(_ panel: DocumentNotesPanelViewController, asSideChild sideChild: Bool, animated: Bool) {
        if sideChild {
            addChild(panel)
            panel.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(panel.view)
            panel.showsLeadingSeparator = true
            let topConstraint = panel.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor)
            notesPanelTopConstraint = topConstraint
            NSLayoutConstraint.activate([
                topConstraint,
                panel.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                panel.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                panel.view.widthAnchor.constraint(equalToConstant: Self.notesPanelWidth),
            ])
            editorTrailingConstraint.constant = -Self.notesPanelWidth
            panel.didMove(toParent: self)
        } else {
            panel.showsLeadingSeparator = false
            let nav = UINavigationController(rootViewController: panel)
            nav.presentationController?.delegate = self
            panel.navigationItem.rightBarButtonItem = UIBarButtonItem(
                title: L10n.string("Common_done"), style: .done, target: self,
                action: #selector(doneWithPresentedNotesPanel))
            present(nav, animated: animated)
        }
    }

    /// Interactive dismissal (a swipe down on the sheet) never calls
    /// `dismissNotesPanel`, so `notesPanel` was left stale and the next tap
    /// tried to dismiss a controller that was already gone (organiser #13).
    @objc private func doneWithPresentedNotesPanel() {
        if let notesPanel { dismissNotesPanel(notesPanel) }
    }

    /// Re-hosts the open notes panel as a side child or a sheet when the
    /// container crosses `LunaLayout.wideThreshold`.
    private func layoutForCurrentWidth() {
        updateLeadingControls()
        guard let notesPanel else { return }
        let isWide = LunaLayout.isWide(containerWidth: view.bounds.width)
        let isSideChild = notesPanel.parent === self
        guard isWide != isSideChild else { return }
        removeNotesPanel(notesPanel)
        self.notesPanel = notesPanel
        host(notesPanel, asSideChild: isWide, animated: false)
    }

    // MARK: - Chrome

    /// Hides or shows the header, the read-along chip and the side notes
    /// panel — the editor's own inset adjustment keeps its text clear of the
    /// safe area either way. Idempotent: a repeated call for the state
    /// already showing does nothing.
    func setChromeHidden(_ hidden: Bool, animated: Bool) {
        guard isChromeHidden != hidden else { return }
        isChromeHidden = hidden

        editorTopToHeaderConstraint.isActive = !hidden
        editorTopToViewConstraint.isActive = hidden
        reanchorNotesPanelTop()

        navigationController?.setNavigationBarHidden(hidden, animated: animated)
        view.layoutIfNeeded()
    }

    /// Re-pins the side notes panel's top between the header's bottom and
    /// the safe-area top, alongside the editor's own top constraint.
    private func reanchorNotesPanelTop() {
        guard let notesPanel, notesPanel.parent === self else { return }
        if let notesPanelTopConstraint { notesPanelTopConstraint.isActive = false }
        let topConstraint = notesPanel.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor)
        topConstraint.isActive = true
        notesPanelTopConstraint = topConstraint
    }
}

extension EditorContainerViewController {
    /// Where the caret rests in this sheet right now.
    public var editingState: EditorEditingState { editor?.editingState ?? EditorEditingState() }

    /// Reopens this sheet where it was left. Called before the container is
    /// on screen, so the editor may not exist yet.
    public func restoreEditingState(_ state: EditorEditingState) {
        if let editor {
            editor.restoreEditingState(state)
        } else {
            pendingEditingState = state
        }
    }
}

/// Weak reference from `EditorContainerViewController` back to the root,
/// which records the caret for the next launch.
public protocol EditorEditingStateObserving: AnyObject {
    func editorContainer(
        _ container: EditorContainerViewController, didChangeEditingState state: EditorEditingState)
}

extension EditorContainerViewController: DocumentEditingDelegate {
    public func editor(_ editor: DocumentEditing, didUpdate document: WriterDocument) {
        self.document = document
        setTitleIfChanged(displayTitle(for: document))
    }

    public func editorRequestsNotesPanel(_ editor: DocumentEditing) {
        if notesPanel == nil { presentNotesPanel() }
    }

    public func editor(_ editor: DocumentEditing, didChangeEditingState state: EditorEditingState) {
        editingStateObserver?.editorContainer(self, didChangeEditingState: state)
    }

    public func editor(_ editor: DocumentEditing, wantsChromeHidden hidden: Bool) {
        // Native navigation stays available while writing.
    }

    public func editorDidRequestChromeToggle(_ editor: DocumentEditing) {
        setChromeHidden(!isChromeHidden, animated: true)
    }

    public func editor(_ editor: DocumentEditing, requestsOpening document: WriterDocument) {
        documentOpener?.openDocument(document)
    }
}

extension EditorContainerViewController: UIAdaptivePresentationControllerDelegate {
    public func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        notesPanel = nil
    }
}

extension EditorContainerViewController: LibraryChangeObserving {
    public func libraryDidChange(_ change: LibraryChange) {
        switch change {
        case .notes(let id) where id == nil || id == document.id:
            updateNotesButton()
        case .document(let id) where id == document.id:
            refreshFromStore()
        default:
            break
        }
    }

    /// A favourite, keyword or goal change made elsewhere (the sheets list,
    /// an intent) is not reported through `DocumentEditingDelegate`, which
    /// only carries the editor's own saves — re-read the row (organiser #15).
    private func refreshFromStore() {
        guard let latest = try? environment.library.document(document.id) else { return }
        document = latest
        setTitleIfChanged(displayTitle(for: document))
    }
}

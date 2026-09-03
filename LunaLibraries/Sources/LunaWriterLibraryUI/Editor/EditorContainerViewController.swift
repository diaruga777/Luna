import UIKit
import LunaDesignSystem
import LunaModels
import LunaWriterModels
import LunaWriterStorage
import LunaWriterText

/// Hosts one open sheet's editor behind a `NavHeaderBar`: back, the sheet's
/// title, a notes button carrying its count, the read-along chrome host, and
/// the ⋯ menu. The notes panel is a side child on a wide layout and a
/// presented sheet on a compact one — never a modal that would swallow
/// touches meant for a card next door.
public final class EditorContainerViewController: UIViewController {

    private let environment: LibraryEnvironment
    private(set) var document: WriterDocument

    private let header = NavHeaderBar()
    private(set) var editor: (UIViewController & DocumentEditing)!
    private var readAlongChromeView: UIView?
    private var notesPanel: DocumentNotesPanelViewController?
    private var editorTrailingConstraint: NSLayoutConstraint!

    private let notesButton = UIButton(type: .system)

    /// The header's current title — for tests, which cannot see `header`.
    var headerTitleForTesting: String? { header.title }
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

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LunaColors.background

        editor = environment.editorMaker.makeEditor(for: document)
        editor.editingDelegate = self

        notesButton.setImage(UIImage(systemName: "note.text"), for: .normal)
        notesButton.tintColor = LunaColors.primaryText
        notesButton.addTarget(self, action: #selector(notesTapped), for: .touchUpInside)

        header.title = displayTitle(for: document)
        header.setLeadingControls([NavHeaderBar.backButton(target: self, action: #selector(backTapped))])
        header.setTrailingControls(trailingHeaderControls())
        let contentTop = header.mount(in: self)

        addChild(editor)
        editor.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(editor.view)
        editor.didMove(toParent: self)

        if let chrome = environment.readAlongChrome?.readAlongChrome(for: editor) {
            readAlongChromeView = chrome
            chrome.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(chrome)
            NSLayoutConstraint.activate([
                chrome.topAnchor.constraint(equalTo: contentTop),
                chrome.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                chrome.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
        }

        editorTrailingConstraint = editor.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        NSLayoutConstraint.activate([
            editor.view.topAnchor.constraint(equalTo: readAlongChromeView?.bottomAnchor ?? contentTop),
            editor.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            editor.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            editorTrailingConstraint,
        ])
        updateNotesButton()
        layoutForCurrentWidth()
    }

    public override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        layoutForCurrentWidth()
    }

    private func displayTitle(for document: WriterDocument) -> String {
        document.title.isEmpty ? L10n.string("Common_untitled") : document.title
    }

    @objc private func backTapped() {
        if let navigationController, navigationController.viewControllers.count > 1 {
            navigationController.popViewController(animated: true)
        }
    }

    // MARK: - Header controls

    private func trailingHeaderControls() -> [UIView] {
        let menuButton = NavHeaderBar.imageButton(
            systemName: "ellipsis.circle", target: self, action: #selector(menuTapped),
            accessibilityLabel: L10n.string("WriterLibrary_editor_moreMenuTitle"))
        menuButton.menu = ellipsisMenu()
        menuButton.showsMenuAsPrimaryAction = true
        return [notesButton, menuButton]
    }

    private func updateNotesButton() {
        let count = (try? environment.notes.notes(for: document.id).count) ?? 0
        notesButton.setTitle(count > 0 ? " \(count)" : nil, for: .normal)
    }

    @objc private func menuTapped() {}

    private func ellipsisMenu() -> UIMenu {
        UIMenu(children: [
            UIAction(
                title: L10n.string("WriterLibrary_editor_shareExportAction"),
                image: UIImage(systemName: "square.and.arrow.up")
            ) { [weak self] _ in self?.presentExportOptions() },
            UIAction(
                title: L10n.string("WriterLibrary_editor_statisticsAction"),
                image: UIImage(systemName: "chart.bar")
            ) { [weak self] _ in self?.presentStatistics() },
            UIAction(
                title: L10n.string("WriterLibrary_editor_keywordsAction"),
                image: UIImage(systemName: "tag")
            ) { [weak self] _ in self?.presentKeywordEditor() },
            UIAction(
                title: L10n.string("WriterLibrary_editor_goalAction"),
                image: UIImage(systemName: "flag")
            ) { [weak self] _ in self?.presentGoalEditor() },
            UIAction(
                title: L10n.string("WriterLibrary_sheets_moveAction"),
                image: UIImage(systemName: "folder")
            ) { [weak self] _ in self?.presentMovePicker() },
            UIAction(
                title: self.document.isFavorite
                    ? L10n.string("WriterLibrary_sheets_unfavoriteAction")
                    : L10n.string("WriterLibrary_sheets_favoriteAction"),
                image: UIImage(systemName: document.isFavorite ? "star.slash" : "star")
            ) { [weak self] _ in self?.toggleFavorite() },
            UIAction(
                title: L10n.string("Common_delete"),
                image: UIImage(systemName: "trash"), attributes: .destructive
            ) { [weak self] _ in self?.trashDocument() },
            UIAction(
                title: L10n.string("WriterLibrary_snapshots_title"),
                image: UIImage(systemName: "clock.arrow.circlepath")
            ) { [weak self] _ in self?.presentSnapshots() },
        ])
    }

    // MARK: - Menu actions

    public func presentExportOptions() {
        editor.flushPendingSave()
        let text = (try? environment.textStore.loadText(document)) ?? ""
        let alert = UIAlertController(
            title: L10n.string("WriterLibrary_export_chooseFormatTitle"), message: nil,
            preferredStyle: .actionSheet)
        for format in DocumentExportFormat.allCases {
            alert.addAction(UIAlertAction(title: format.displayName, style: .default) { [weak self] _ in
                guard let self else { return }
                DocumentExporter.exportAndPresent(
                    document: self.document, text: text, format: format, from: self, anchor: .view(self.view))
            })
        }
        alert.addAction(UIAlertAction(title: L10n.string("Common_cancel"), style: .cancel))
        present(alert, animated: true)
    }

    public func statisticsMessage() -> String {
        editor.flushPendingSave()
        let text = (try? environment.textStore.loadText(document)) ?? ""
        let stats = TextStatistics.measure(text)
        return L10n.string(
            "WriterLibrary_editor_statisticsMessage",
            stats.words, stats.characters, stats.sentences, stats.paragraphs)
    }

    public func presentStatistics() {
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
        document.isFavorite.toggle()
        guard (try? environment.library.update(document)) != nil else { return false }
        header.setTrailingControls(trailingHeaderControls())
        return true
    }

    @discardableResult
    public func trashDocument() -> Bool {
        guard (try? environment.library.trash(document.id)) != nil else { return false }
        backTapped()
        return true
    }

    public func presentSnapshots() {
        editor.flushPendingSave()
        let screen = SnapshotsViewController(
            snapshotStore: environment.snapshots, textStore: environment.textStore, document: document)
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
            notesStore: environment.notes, noteIndex: environment.noteIndex,
            textStore: environment.textStore, document: document)
        panel.editor = editor
        panel.relevance = environment.noteRelevance
        notesPanel = panel
        host(panel, asSideChild: LunaLayout.isWide(containerWidth: view.bounds.width), animated: true)
    }

    private func dismissNotesPanel(_ panel: DocumentNotesPanelViewController) {
        if panel.parent === self {
            panel.willMove(toParent: nil)
            panel.view.removeFromSuperview()
            panel.removeFromParent()
            editorTrailingConstraint.constant = 0
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
            NSLayoutConstraint.activate([
                panel.view.topAnchor.constraint(equalTo: header.bottomAnchor),
                panel.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                panel.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                panel.view.widthAnchor.constraint(equalToConstant: Self.notesPanelWidth),
            ])
            editorTrailingConstraint.constant = -Self.notesPanelWidth
            panel.didMove(toParent: self)
        } else {
            present(UINavigationController(rootViewController: panel), animated: animated)
        }
    }

    /// Re-hosts the open notes panel as a side child or a sheet when the
    /// container crosses `LunaLayout.wideThreshold`.
    private func layoutForCurrentWidth() {
        guard let notesPanel else { return }
        let isWide = LunaLayout.isWide(containerWidth: view.bounds.width)
        let isSideChild = notesPanel.parent === self
        guard isWide != isSideChild else { return }
        dismissNotesPanel(notesPanel)
        self.notesPanel = notesPanel
        host(notesPanel, asSideChild: isWide, animated: false)
    }
}

extension EditorContainerViewController: DocumentEditingDelegate {
    public func editor(_ editor: DocumentEditing, didUpdate document: WriterDocument) {
        self.document = document
        header.title = displayTitle(for: document)
        updateNotesButton()
        header.setTrailingControls(trailingHeaderControls())
    }

    public func editorRequestsNotesPanel(_ editor: DocumentEditing) {
        if notesPanel == nil { presentNotesPanel() }
    }
}

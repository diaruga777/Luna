import UIKit
import LunaDesignSystem
import LunaModels
import LunaWriterModels
import LunaWriterStorage

/// The Ulysses organiser's root: groups in the primary column, that group's
/// sheets in the supplementary column, and the open sheet's editor in the
/// secondary column. `preferredDisplayMode` follows the real column budget
/// (`Self.displayMode(forContainerWidth:)`) rather than the size class UIKit
/// would otherwise pick.
public final class LibraryRootViewController: UISplitViewController {

    private let environment: LibraryEnvironment
    private let groupsViewController: GroupsViewController
    private let sheetsViewController: SheetsViewController
    private let primaryNavigation: UINavigationController
    private let supplementaryNavigation: UINavigationController

    /// The primary and supplementary columns' preferred width, and the
    /// narrowest an expanded editor column is allowed to end up. Below
    /// `tripleColumnMinWidth` two side columns plus this editor budget no
    /// longer fit, so the third column is dropped instead of starving it —
    /// an iPad in portrait shows two columns, not three (organiser #7).
    static let primaryColumnWidth: CGFloat = 320
    static let supplementaryColumnWidth: CGFloat = 320
    static let minimumEditorWidth: CGFloat = 560
    static let tripleColumnMinWidth: CGFloat =
        primaryColumnWidth + supplementaryColumnWidth + minimumEditorWidth

    public init(environment: LibraryEnvironment) {
        self.environment = environment
        self.groupsViewController = GroupsViewController(
            library: environment.library, notes: environment.notes)
        self.sheetsViewController = SheetsViewController(
            library: environment.library, notes: environment.notes, textStore: environment.textStore)
        self.primaryNavigation = UINavigationController(rootViewController: groupsViewController)
        self.supplementaryNavigation = UINavigationController(rootViewController: sheetsViewController)
        super.init(style: .tripleColumn)
        delegate = self
        groupsViewController.selectionDelegate = self
        sheetsViewController.selectionDelegate = self
        environment.library.addObserver(self)
    }

    deinit { environment.library.removeObserver(self) }

    /// Whether a sheet is open in the detail column (or on the collapsed
    /// stack). Until then a compact width collapses to the groups list,
    /// never to the empty placeholder.
    private var hasOpenDocument: Bool { currentContainer != nil }
    /// The container currently hosted in the secondary column, so a
    /// re-selection can no-op and an outgoing editor can be flushed before
    /// it is replaced (organiser #10).
    private weak var currentContainer: EditorContainerViewController?
    /// The last session is reopened once, when the root first appears.
    private var didRestore = false
    /// The scope the sidebar is on, so a snapshot written from anywhere
    /// records the scope the writer can see.
    private var currentSelection: LibrarySelection = .all

    var hasOpenDocumentForTesting: Bool { hasOpenDocument }
    var currentDocumentIDForTesting: DocumentID? { currentContainer?.document.id }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LunaColors.background
        setViewController(primaryNavigation, for: .primary)
        setViewController(supplementaryNavigation, for: .supplementary)
        setViewController(Self.emptySecondaryPlaceholder(), for: .secondary)
        configureColumnWidths()
        updatePreferredDisplayMode()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updatePreferredDisplayMode()
    }

    /// The last page is reopened here rather than in `viewDidLoad`: this is
    /// the first moment `isCollapsed` says which columns exist, and setting
    /// a navigation stack from inside a layout pass loops UIKit's layout
    /// until it runs out of memory.
    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        restoreLastSession()
    }

    private func configureColumnWidths() {
        preferredPrimaryColumnWidth = Self.primaryColumnWidth
        minimumPrimaryColumnWidth = 280
        maximumPrimaryColumnWidth = 400
        preferredSupplementaryColumnWidth = Self.supplementaryColumnWidth
        minimumSupplementaryColumnWidth = 280
        maximumSupplementaryColumnWidth = 400
    }

    /// Assigning `preferredDisplayMode` schedules another layout pass, so the
    /// assignment happens only when the mode actually changed; writing the
    /// same value from `viewDidLayoutSubviews` spins the main thread.
    private func updatePreferredDisplayMode() {
        let wanted = Self.displayMode(forContainerWidth: view.bounds.width)
        if preferredDisplayMode != wanted {
            preferredDisplayMode = wanted
        }
    }

    /// Three columns only once the primary and supplementary columns can sit
    /// beside an editor at least `minimumEditorWidth` wide; two columns down
    /// to `LunaLayout.wideThreshold`; below that UIKit's own compact
    /// collapsing takes over.
    static func displayMode(forContainerWidth width: CGFloat) -> UISplitViewController.DisplayMode {
        if width >= tripleColumnMinWidth { return .twoBesideSecondary }
        if LunaLayout.isWide(containerWidth: width) { return .oneBesideSecondary }
        return .automatic
    }

    private static func emptySecondaryPlaceholder() -> UIViewController {
        let placeholder = UIViewController()
        placeholder.view.backgroundColor = LunaColors.background
        let label = UILabel()
        label.text = L10n.string("WriterLibrary_editor_emptySelection")
        label.textColor = LunaColors.secondaryText
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        placeholder.view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: placeholder.view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: placeholder.view.centerYAnchor),
        ])
        return placeholder
    }

    // MARK: - Session restoration

    /// Reopens the page the last run ended on: the sidebar scope, the sheet,
    /// and the caret inside it.
    ///
    /// A sheet opened before the first layout (a deep link, an intent, or a
    /// first run's Welcome sheet) is already the page, so restoring is
    /// finished. A recorded sheet that is gone or trashed restores the scope
    /// alone. Nothing here animates: the app is meant to be back where it
    /// was, not to be seen travelling there.
    private func restoreLastSession() {
        guard !didRestore else { return }
        didRestore = true
        let hadSession = environment.sessionState.hasSnapshot
        let snapshot = environment.sessionState.snapshot
        let selection = LibrarySelection(snapshot.selection)
        currentSelection = selection
        groupsViewController.highlight(selection)
        sheetsViewController.select(selection)
        guard currentContainer == nil else { return }
        guard let id = snapshot.documentID, let document = try? environment.library.document(id),
              document.trashedAt == nil
        else {
            environment.sessionState.recordOpenDocument(nil)
            // The scope is a page of its own on a phone: a writer who left
            // the app on a sheets list comes back to that list.
            if hadSession, isCollapsed {
                supplementaryNavigation.setViewControllers([], animated: false)
                primaryNavigation.setViewControllers(
                    [groupsViewController, sheetsViewController], animated: false)
            }
            return
        }
        let container = EditorContainerViewController(environment: environment, document: document)
        container.editingStateObserver = self
        container.restoreEditingState(
            EditorEditingState(
                caretLocation: snapshot.caretLocation ?? 0,
                isKeyboardVisible: snapshot.keyboardVisible))
        currentContainer = container
        sheetsViewController.openDocumentID = document.id
        if isCollapsed {
            container.loadViewIfNeeded()
            supplementaryNavigation.setViewControllers([], animated: false)
            primaryNavigation.setViewControllers(
                [groupsViewController, sheetsViewController, container], animated: false)
        } else {
            setViewController(container, for: .secondary)
        }
    }

    /// Writes the page as it stands now. The app calls this on its way to
    /// the background, where an editor that has not autosaved since the last
    /// caret move would otherwise leave a stale caret behind.
    public func recordSessionState() {
        var snapshot = WriterSessionState.Snapshot(
            documentID: currentContainer?.document.id, selection: currentSelection.storedValue)
        if let container = currentContainer {
            let state = container.editingState
            snapshot.caretLocation = state.caretLocation
            snapshot.keyboardVisible = state.isKeyboardVisible
        }
        environment.sessionState.snapshot = snapshot
    }

    // MARK: - Keyboard commands

    public override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(
                title: L10n.string("WriterLibrary_command_newSheet"),
                action: #selector(newSheetKeyCommand), input: "n", modifierFlags: .command),
            UIKeyCommand(
                title: L10n.string("WriterLibrary_command_newGroup"),
                action: #selector(newGroupKeyCommand), input: "n", modifierFlags: [.command, .shift]),
            UIKeyCommand(
                title: L10n.string("WriterLibrary_command_focusSearch"),
                action: #selector(focusSearchKeyCommand), input: "f", modifierFlags: .command),
            UIKeyCommand(
                title: L10n.string("WriterLibrary_command_toggleNotes"),
                action: #selector(toggleNotesKeyCommand), input: "n", modifierFlags: [.command, .alternate]),
            UIKeyCommand(
                title: L10n.string("WriterLibrary_command_settings"),
                action: #selector(openSettingsKeyCommand), input: ",", modifierFlags: .command),
            UIKeyCommand(
                title: L10n.string("WriterLibrary_command_trash"),
                action: #selector(trashOpenDocumentKeyCommand),
                input: UIKeyCommand.inputDelete, modifierFlags: .command),
            UIKeyCommand(
                title: L10n.string("WriterLibrary_command_export"),
                action: #selector(exportOpenDocumentKeyCommand), input: "e", modifierFlags: .command),
            UIKeyCommand(
                title: L10n.string("WriterLibrary_command_openSelection"),
                action: #selector(openSelectionKeyCommand), input: "\r", modifierFlags: .command),
            UIKeyCommand(
                title: L10n.string("WriterLibrary_command_focusGroups"),
                action: #selector(focusGroupsKeyCommand), input: "1", modifierFlags: .command),
            UIKeyCommand(
                title: L10n.string("WriterLibrary_command_focusSheets"),
                action: #selector(focusSheetsKeyCommand), input: "2", modifierFlags: .command),
            UIKeyCommand(
                title: L10n.string("WriterLibrary_command_focusEditor"),
                action: #selector(focusEditorKeyCommand), input: "3", modifierFlags: .command),
        ]
    }

    @objc private func newSheetKeyCommand() { sheetsViewController.createSheet() }
    @objc private func newGroupKeyCommand() { groupsViewController.createGroup(parent: nil) }
    @objc private func focusSearchKeyCommand() { sheetsViewController.focusSearch() }
    @objc private func toggleNotesKeyCommand() { currentContainer?.toggleNotesPanel() }
    @objc private func openSettingsKeyCommand() { presentSettings() }
    /// ⌘E exports the open sheet as Markdown; the other formats are one
    /// step further in the container's ⋯ menu.
    @objc private func exportOpenDocumentKeyCommand() { currentContainer?.export(as: .markdown) }
    @objc private func openSelectionKeyCommand() { sheetsViewController.openFirstOrSelectedSheet() }
    @objc private func focusGroupsKeyCommand() { show(.primary) }
    @objc private func focusSheetsKeyCommand() { show(.supplementary) }
    @objc private func focusEditorKeyCommand() { show(.secondary) }

    @objc private func trashOpenDocumentKeyCommand() {
        guard let id = currentContainer?.document.id else { return }
        _ = try? environment.library.trash(id)
    }

    private func presentSettings() {
        WriterSettingsViewController.present(from: self, environment: environment)
    }
}

/// The same command titles `LibraryRootViewController.keyCommands` uses,
/// exposed so `WriterAppDelegate.buildMenu(with:)` (a different module, the
/// app target) can read them for the Mac menu bar without importing
/// `LunaModels` itself just for this.
public enum WriterCommandTitles {
    public static var newSheet: String { L10n.string("WriterLibrary_command_newSheet") }
    public static var newGroup: String { L10n.string("WriterLibrary_command_newGroup") }
    public static var focusSearch: String { L10n.string("WriterLibrary_command_focusSearch") }
    public static var toggleNotes: String { L10n.string("WriterLibrary_command_toggleNotes") }
    public static var settings: String { L10n.string("WriterLibrary_command_settings") }
    public static var trash: String { L10n.string("WriterLibrary_command_trash") }
    public static var export: String { L10n.string("WriterLibrary_command_export") }
    public static var focusGroups: String { L10n.string("WriterLibrary_command_focusGroups") }
    public static var focusSheets: String { L10n.string("WriterLibrary_command_focusSheets") }
    public static var focusEditor: String { L10n.string("WriterLibrary_command_focusEditor") }
}

extension LibraryRootViewController: GroupsSelectionDelegate {
    public func groupsViewController(_ controller: GroupsViewController, didSelect selection: LibrarySelection) {
        currentSelection = selection
        environment.sessionState.recordSelection(selection.storedValue)
        sheetsViewController.select(selection)
        showSheetsList()
    }

    /// A collapsed split view pushes only its secondary column when asked;
    /// `show(.supplementary)` does nothing there (measured on iOS 26, and
    /// pinned by `LibraryRootViewControllerTests`), so on a compact width the
    /// sheets list is pushed onto the primary stack by hand. Expanding hands
    /// it back to its column (organiser #29).
    private func showSheetsList() {
        guard isCollapsed else {
            show(.supplementary)
            return
        }
        if primaryNavigation.viewControllers.contains(sheetsViewController) {
            primaryNavigation.popToViewController(sheetsViewController, animated: true)
            return
        }
        supplementaryNavigation.setViewControllers([], animated: false)
        whenPrimaryStackSettles { [self] in
            primaryNavigation.pushViewController(sheetsViewController, animated: true)
        }
    }

    /// UIKit drops a stack change made while the primary stack is mid-
    /// transition ("the navigation stack will not be updated"), so `work`
    /// waits for the running transition to finish when there is one.
    private func whenPrimaryStackSettles(_ work: @escaping () -> Void) {
        guard let coordinator = primaryNavigation.transitionCoordinator else {
            work()
            return
        }
        coordinator.animate(alongsideTransition: nil) { _ in work() }
    }

    public func groupsViewController(_ controller: GroupsViewController, requestsNewDocumentIn group: GroupID?) {
        sheetsViewController.createSheet(in: group ?? environment.library.inboxGroupID)
    }

    public func groupsViewControllerRequestsSettings(_ controller: GroupsViewController) {
        presentSettings()
    }
}

extension LibraryRootViewController: SheetsSelectionDelegate {
    public func sheetsViewController(_ controller: SheetsViewController, didSelect document: WriterDocument) {
        show(document: document)
    }

    /// Opens a sheet in the detail column. Deep links and intents arrive here
    /// as well as the sheets list. Re-selecting the already-open sheet just
    /// brings the column forward; switching to a different one flushes the
    /// outgoing editor first so its last edit is not lost to a bare `deinit`.
    public func show(document: WriterDocument) {
        if let currentContainer, currentContainer.document.id == document.id {
            show(.secondary)
            return
        }
        currentContainer?.editor.flushPendingSave()
        let editorContainer = EditorContainerViewController(environment: environment, document: document)
        editorContainer.editingStateObserver = self
        currentContainer = editorContainer
        // A sheet opened before the first layout is the page to come back
        // to, so the restore pass has nothing left to do.
        didRestore = true
        environment.sessionState.recordOpenDocument(document.id)
        sheetsViewController.openDocumentID = document.id
        if isCollapsed {
            // Same as `showSheetsList()`: the collapsed split view does not
            // push a freshly set secondary column, so the editor replaces
            // any editor already on the stack and goes on top by hand.
            // Loaded now, so `editor` exists for the flush the next
            // `show(document:)` performs even before the push lands.
            editorContainer.loadViewIfNeeded()
            whenPrimaryStackSettles { [self] in
                var stack = primaryNavigation.viewControllers.filter { !($0 is EditorContainerViewController) }
                stack.append(editorContainer)
                primaryNavigation.setViewControllers(stack, animated: true)
            }
        } else {
            setViewController(editorContainer, for: .secondary)
            show(.secondary)
        }
    }
}

extension LibraryRootViewController: LibraryNavigationHandling {
    public func documentDidClose(_ id: DocumentID) {
        guard currentContainer?.document.id == id else { return }
        currentContainer = nil
        environment.sessionState.recordOpenDocument(nil)
        sheetsViewController.openDocumentID = nil
        whenPrimaryStackSettles { [self] in
            let stack = primaryNavigation.viewControllers.filter { !($0 is EditorContainerViewController) }
            if stack.count != primaryNavigation.viewControllers.count {
                primaryNavigation.setViewControllers(stack, animated: true)
            }
        }
        if !isCollapsed {
            setViewController(Self.emptySecondaryPlaceholder(), for: .secondary)
        }
    }
}

extension LibraryRootViewController: EditorEditingStateObserving {
    public func editorContainer(
        _ container: EditorContainerViewController, didChangeEditingState state: EditorEditingState
    ) {
        environment.sessionState.recordEditingState(state, for: container.document.id)
    }
}

extension LibraryRootViewController: LibraryChangeObserving {
    /// Trashing the open sheet — from its own menu, a sheets-list swipe, a
    /// multi-select trash, or the folder reconciler — always lands here as a
    /// `.document(id)` broadcast, so one observer closes it from every path
    /// (organiser #9).
    public func libraryDidChange(_ change: LibraryChange) {
        guard case .document(let id) = change, currentContainer?.document.id == id else { return }
        guard let document = try? environment.library.document(id), document.trashedAt == nil else {
            documentDidClose(id)
            return
        }
    }
}

extension LibraryRootViewController: UISplitViewControllerDelegate {
    public func splitViewController(
        _ svc: UISplitViewController,
        topColumnForCollapsingToProposedTopColumn proposedTopColumn: UISplitViewController.Column
    ) -> UISplitViewController.Column {
        hasOpenDocument ? .secondary : .primary
    }

    /// Puts every column back where it belongs after a collapse: UIKit
    /// restores what it moved itself, and this restores the sheets list
    /// `showSheetsList()` pushed by hand.
    public func splitViewControllerDidExpand(_ svc: UISplitViewController) {
        if primaryNavigation.viewControllers.contains(sheetsViewController) {
            primaryNavigation.setViewControllers([groupsViewController], animated: false)
        }
        if supplementaryNavigation.viewControllers.isEmpty {
            supplementaryNavigation.setViewControllers([sheetsViewController], animated: false)
        }
        if let currentContainer, currentContainer.parent !== self {
            setViewController(currentContainer, for: .secondary)
        }
    }
}

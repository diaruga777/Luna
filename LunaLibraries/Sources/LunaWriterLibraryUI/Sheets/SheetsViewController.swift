import UIKit
import LunaDesignSystem
import LunaModels
import LunaWriterModels
import LunaWriterStorage

/// One row of the sheets list: a sheet, or (Inbox only) an unattached note.
public enum SheetsRow: Hashable {
    case document(DocumentID)
    case unattachedNote(NoteID)
}

/// The sheets list for whatever the sidebar selected: a library scope, a
/// group, a filter, or the trash. Search, sort, swipe actions, multi-select,
/// manual drag reorder, and — in the Inbox — a second section of unattached
/// notes.
public final class SheetsViewController: UICollectionViewController {

    private enum Section: Int, CaseIterable { case documents, unattachedNotes }

    public weak var selectionDelegate: SheetsSelectionDelegate?

    private let library: WriterLibraryStoring
    private let notes: NoteStoring
    private let textStore: DocumentTextStoring

    private var dataSource: UICollectionViewDiffableDataSource<Section, SheetsRow>!
    private var documentsByID: [DocumentID: WriterDocument] = [:]
    private var notesByID: [NoteID: WriterNote] = [:]
    private var currentSelection: LibrarySelection = .all
    /// The sheet open in the editor. Beside a visible editor column the row
    /// stays highlighted, so the list says which sheet is on screen.
    public var openDocumentID: DocumentID? {
        didSet {
            guard openDocumentID != oldValue else { return }
            reselectOpenDocument()
        }
    }
    private var currentSort: DocumentSort = .modifiedDescending
    private var isChapterList = false
    private var nonChapterSort: DocumentSort = .modifiedDescending
    private var chapterOrdinals: [DocumentID: Int] = [:]
    private var searchQuery: String?
    private var needsScrollToTop = true
    private var pendingResort: DispatchWorkItem?
    /// How long a `.document` change (typing autosave) waits before the list
    /// re-sorts; a reconfigured row updates immediately (organiser #21).
    private static let resortDebounceInterval: TimeInterval = 2

    private let searchController = UISearchController(searchResultsController: nil)
    private var groupNames: [GroupID: String] = [:]
    /// The live configuration the list layout was built from — reachable so
    /// a test can pull a swipe action through the SAME provider the real
    /// layout uses, rather than calling `leadingSwipeActions(for:)` directly
    /// (organiser #18).
    private(set) var swipeConfigurationForTesting: UICollectionLayoutListConfiguration!

    /// The rows drawn highlighted. Internal rather than private so a test
    /// can read the highlight the collection view actually holds.
    var selectedRowsForTesting: [SheetsRow] {
        (collectionView.indexPathsForSelectedItems ?? []).compactMap { dataSource.itemIdentifier(for: $0) }
    }

    /// The rows on screen, flattened in display order. Internal rather than
    /// private so tests can assert on the applied snapshot directly.
    var visibleRowsForTesting: [SheetsRow] { dataSource.snapshot().itemIdentifiers }
    var currentSortForTesting: DocumentSort {
        get { currentSort }
        set {
            currentSort = newValue
            reload()
        }
    }
    var currentSearchQueryForTesting: String? {
        get { searchQuery }
        set {
            searchQuery = newValue
            reload()
        }
    }

    public init(library: WriterLibraryStoring, notes: NoteStoring, textStore: DocumentTextStoring) {
        self.library = library
        self.notes = notes
        self.textStore = textStore
        // A placeholder layout for `super.init`; `viewDidLoad` replaces it
        // with one whose swipe providers can capture `self`.
        let placeholder = UICollectionViewCompositionalLayout.list(
            using: UICollectionLayoutListConfiguration(appearance: .plain))
        super.init(collectionViewLayout: placeholder)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    public override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        navigationItem.standardAppearance = appearance
        navigationItem.scrollEdgeAppearance = appearance
        collectionView.backgroundColor = .systemGroupedBackground
        configureSwipeActionsLayout()
        configureDataSource()
        configureDragAndDrop()
        configureNavigationItems()
        configureSearch()
        library.addObserver(self)
        select(currentSelection)
    }

    deinit { library.removeObserver(self) }

    /// Builds the real compositional layout with swipe providers wired to
    /// this screen's own helpers — a plain (non-`override`) delegate method
    /// for swipe actions is never called by a compositional list layout, so
    /// the providers on `UICollectionLayoutListConfiguration` are the only
    /// place they can live (organiser #18).
    private func configureSwipeActionsLayout() {
        var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        configuration.backgroundColor = .systemGroupedBackground
        configuration.leadingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard let self, case .document(let id) = self.dataSource.itemIdentifier(for: indexPath)
            else { return nil }
            return self.leadingSwipeActions(for: id)
        }
        configuration.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard let self, case .document(let id) = self.dataSource.itemIdentifier(for: indexPath)
            else { return nil }
            return self.trailingSwipeActions(for: id)
        }
        swipeConfigurationForTesting = configuration
        collectionView.collectionViewLayout = UICollectionViewCompositionalLayout.list(using: configuration)
    }

    // MARK: - Selection

    public func select(_ selection: LibrarySelection) {
        let wasChapterList = isChapterList
        let changedScope = currentSelection != selection
        currentSelection = selection
        if changedScope {
            needsScrollToTop = true
            if isEditing { setEditing(false, animated: false) }
            searchQuery = nil
            searchController.searchBar.text = nil
            searchController.isActive = false
        }
        if case .group(let id) = selection {
            isChapterList = (try? library.groups())?.first { $0.id == id }?.kind == .project
        } else { isChapterList = false }
        if !wasChapterList && isChapterList { nonChapterSort = currentSort }
        if isChapterList && (changedScope || !wasChapterList) { currentSort = .manual }
        if wasChapterList && !isChapterList { currentSort = nonChapterSort }
        if isViewLoaded && wasChapterList != isChapterList { configureSwipeActionsLayout() }
        navigationItem.largeTitleDisplayMode = .never
        title = titleText(for: selection)
        navigationItem.leftBarButtonItem = nil
        searchController.searchBar.placeholder = selection == .notes ? L10n.string("WriterLibrary_polish_searchNotes") : L10n.string("WriterLibrary_polish_searchDocuments")
        navigationItem.rightBarButtonItems = trailingBarButtons()
        reload()
    }

    /// Never clears the open sheet's highlight on a wide layout, where the
    /// list stays on screen beside the editor; behaves normally when
    /// collapsed, where the list is what the writer came back to.
    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        clearsSelectionOnViewWillAppear = splitViewController?.isCollapsed ?? false
        navigationController?.setToolbarHidden(!isEditing, animated: animated)
        reselectOpenDocument()
    }

    public override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        if needsScrollToTop {
            view.layoutIfNeeded()
            collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.adjustedContentInset.top), animated: false)
            needsScrollToTop = false
        }
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isEditing { setEditing(false, animated: false) }
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    /// Puts `openDocumentID`'s highlight back after a snapshot rebuild,
    /// which otherwise drops it (organiser #8).
    private func reselectOpenDocument() {
        guard isViewLoaded, !isEditing, !(splitViewController?.isCollapsed ?? true) else { return }
        guard let id = openDocumentID, let indexPath = dataSource.indexPath(for: .document(id))
        else { return }
        collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
    }

    /// A group or filter's own name, looked up from the store — `title(for:)`
    /// used to return an empty string for both (organiser #20).
    private func titleText(for selection: LibrarySelection) -> String {
        switch selection {
        case .all: return L10n.string("WriterLibrary_groups_libraryAll")
        case .notes: return L10n.string("WriterLibrary_polish_allNotes")
        case .recent: return L10n.string("WriterLibrary_groups_libraryRecent")
        case .favorites: return L10n.string("WriterLibrary_groups_libraryFavorites")
        case .inbox: return L10n.string("WriterLibrary_groups_inboxRow")
        case .trash: return L10n.string("WriterLibrary_groups_trashRow")
        case .group(let id):
            return (try? library.groups())?.first { $0.id == id }?.name ?? L10n.string("Common_untitled")
        case .filter(let id):
            return (try? library.filters())?.first { $0.id == id }?.name ?? L10n.string("Common_untitled")
        }
    }

    // MARK: - Loading

    /// On a compact width the split view is collapsed and this column's view
    /// loads only when it is first pushed, so a `select(_:)` from the sidebar
    /// can arrive before `viewDidLoad` built the data source. The selection
    /// is kept and `viewDidLoad` applies it (organiser #29).
    public func reload() {
        guard isViewLoaded else { return }
        if isChapterList, case .group(let id) = currentSelection {
            let chapters = (try? library.documents(in: id, sort: .manual)) ?? []
            chapterOrdinals = Dictionary(uniqueKeysWithValues: chapters.enumerated().map { ($1.id, $0 + 1) })
        } else { chapterOrdinals.removeAll() }
        groupNames = Dictionary(uniqueKeysWithValues: ((try? library.groups()) ?? [])
            .filter { $0.kind.isEditable }.map { ($0.id, $0.name) })
        let documents = loadDocuments()
        documentsByID = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })

        var snapshot = NSDiffableDataSourceSnapshot<Section, SheetsRow>()
        snapshot.appendSections(Section.allCases)
        snapshot.appendItems(documents.map { .document($0.id) }, toSection: .documents)

        if currentSelection == .inbox || currentSelection == .notes {
            let all = (try? (currentSelection == .notes ? notes.allNotes() : notes.unattachedNotes())) ?? []
            let unattached = all.filter { note in
                guard let query = searchQuery?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else { return true }
                return note.text.localizedCaseInsensitiveContains(query)
            }
            notesByID = Dictionary(uniqueKeysWithValues: unattached.map { ($0.id, $0) })
            snapshot.appendItems(unattached.map { .unattachedNote($0.id) }, toSection: .unattachedNotes)
        }
        // `apply` updates asynchronously even with no animation, so the
        // reselect waits for its completion rather than running against a
        // collection view that has not caught up yet.
        let existing = Set(dataSource.snapshot().itemIdentifiers)
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { existing.contains($0) })
        dataSource.apply(snapshot, animatingDifferences: isChapterList && collectionView.window != nil
                         && !UIAccessibility.isReduceMotionEnabled) { [weak self] in
            self?.reselectOpenDocument()
            self?.updateSelectionToolbar()
        }
        updateEmptyState(rowCount: snapshot.numberOfItems)
        let count = snapshot.numberOfItems
        let key = currentSelection == .notes ? "notes" : (isChapterList ? "chapters" : "documents")
        if #available(iOS 26, *) {
            navigationItem.subtitle = L10n.string("WriterLibrary_navigation_\(key)\(count == 1 ? "One" : "Many")", count)
        }
        navigationItem.rightBarButtonItems = trailingBarButtons()
    }

    private func updateEmptyState(rowCount: Int) {
        guard rowCount == 0 else { contentUnavailableConfiguration = nil; return }
        let searching = !(searchQuery?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        var empty = searching ? UIContentUnavailableConfiguration.search() : UIContentUnavailableConfiguration.empty()
        if searching {
            empty.secondaryText = L10n.string("WriterLibrary_sheets_emptySearch")
        } else {
            let key = currentSelection == .notes ? "notes" : (isChapterList ? "chapters" : (currentSelection == .trash ? "trash" : "documents"))
            empty.text = L10n.string("WriterLibrary_navigation_empty_\(key)")
            empty.secondaryText = L10n.string(currentSelection == .notes ? "WriterLibrary_polish_notesEmpty"
                : (isChapterList ? "WriterLibrary_polish_bookEmpty"
                   : (currentSelection == .trash ? "WriterLibrary_sheets_emptyTrash" : "WriterLibrary_sheets_emptyScope")))
            empty.image = UIImage(systemName: currentSelection == .notes ? "note.text"
                : (isChapterList ? "book.closed" : (currentSelection == .trash ? "trash" : "doc.text")))
            if currentSelection != .trash {
                empty.button = .borderedProminent()
                empty.button.title = L10n.string(currentSelection == .notes ? "WriterLibrary_navigation_newNote"
                    : (isChapterList ? "WriterLibrary_polish_newChapter" : "WriterLibrary_command_newSheet"))
                empty.buttonProperties.primaryAction = UIAction { [weak self] _ in
                    guard let self else { return }
                    if self.currentSelection == .notes { self.createNote() } else { self.createSheet() }
                }
            }
        }
        contentUnavailableConfiguration = empty
    }

    private func loadDocuments() -> [WriterDocument] {
        let base: [WriterDocument]
        switch currentSelection {
        case .all: base = (try? library.documents(matching: FilterPredicate(), scope: nil)) ?? []
        case .notes: base = []
        case .recent: base = (try? library.recent(days: 7)) ?? []
        case .favorites: base = (try? library.favorites()) ?? []
        case .inbox: base = (try? library.documents(in: library.inboxGroupID, sort: currentSort)) ?? []
        case .trash: base = (try? library.documents(in: library.trashGroupID, sort: currentSort)) ?? []
        case .group(let id): base = (try? library.documents(in: id, sort: currentSort)) ?? []
        case .filter(let id):
            guard let filter = (try? library.filters())?.first(where: { $0.id == id }) else { base = []; break }
            base = (try? library.documents(matching: filter.predicate, scope: filter.scopeGroupID)) ?? []
        }
        let filtered: [WriterDocument]
        if let searchQuery, !searchQuery.isEmpty {
            let hits = (try? library.searchDocuments(searchQuery, limit: 200)) ?? []
            let order = Dictionary(uniqueKeysWithValues: hits.enumerated().map { ($1.documentID, $0) })
            filtered = base.filter { order[$0.id] != nil }.sorted { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
        } else {
            filtered = base
        }
        return Self.sorted(filtered, by: currentSort)
    }

    private static func sorted(_ documents: [WriterDocument], by sort: DocumentSort) -> [WriterDocument] {
        switch sort {
        case .manual: return documents.sorted { $0.sortIndex < $1.sortIndex }
        case .titleAscending: return documents.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .modifiedDescending: return documents.sorted { $0.updatedAt > $1.updatedAt }
        case .createdDescending: return documents.sorted { $0.createdAt > $1.createdAt }
        }
    }

    // MARK: - Diffable data source

    private func configureDataSource() {
        let documentCellRegistration = UICollectionView.CellRegistration<SheetCell, SheetsRow> {
            [weak self] cell, _, row in
            guard case .document(let id) = row, let document = self?.documentsByID[id] else { return }
            let showsLocation: Bool
            if case .group = self?.currentSelection { showsLocation = false } else { showsLocation = true }
            cell.configure(with: document, chapterOrdinal: self?.chapterOrdinals[id],
                           location: showsLocation ? self?.groupNames[document.groupID] : nil)
            cell.accessories = [.multiselect(displayed: .whenEditing)]
        }
        let noteCellRegistration = UICollectionView.CellRegistration<UnattachedNoteCell, SheetsRow> {
            [weak self] cell, _, row in
            guard case .unattachedNote(let id) = row, let note = self?.notesByID[id] else { return }
            let names = note.documentIDs.compactMap { try? self?.library.document($0)?.title }
            cell.configure(with: note, linkedTitles: names)
            cell.attachButton.removeTarget(nil, action: nil, for: .allEvents)
            cell.attachButton.addAction(UIAction { [weak self] _ in self?.presentAttachPicker(for: id) }, for: .touchUpInside)
        }
        dataSource = UICollectionViewDiffableDataSource<Section, SheetsRow>(
            collectionView: collectionView
        ) { collectionView, indexPath, row in
            switch row {
            case .document:
                return collectionView.dequeueConfiguredReusableCell(
                    using: documentCellRegistration, for: indexPath, item: row)
            case .unattachedNote:
                return collectionView.dequeueConfiguredReusableCell(
                    using: noteCellRegistration, for: indexPath, item: row)
            }
        }
    }

    // MARK: - Navigation bar

    private func configureNavigationItems() {
        navigationItem.rightBarButtonItems = trailingBarButtons()
        navigationItem.leftItemsSupplementBackButton = true
        navigationItem.backButtonDisplayMode = .minimal
    }

    private func trailingBarButtons() -> [UIBarButtonItem] {
        if isEditing { return [editButtonItem] }
        var items: [UIBarButtonItem] = []
        if currentSelection != .trash {
            let compose = UIBarButtonItem(barButtonSystemItem: .compose, target: self,
                action: currentSelection == .notes ? #selector(newNoteTapped) : #selector(newSheetTapped))
            compose.accessibilityLabel = L10n.string(currentSelection == .notes ? "WriterLibrary_navigation_newNote"
                : (isChapterList ? "WriterLibrary_polish_newChapter" : "WriterLibrary_command_newSheet"))
            items.append(compose)
        }
        guard currentSelection != .notes else { return items }
        let more = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: organizationMenu())
        more.accessibilityLabel = L10n.string("WriterLibrary_navigation_documentActions")
        items.append(more)
        return items
    }

    private func organizationMenu() -> UIMenu {
        let hasDocuments = !(dataSource?.snapshot().itemIdentifiers.isEmpty ?? true)
        var actions: [UIMenuElement] = []
        if isChapterList {
            actions.append(UIAction(title: L10n.string("WriterLibrary_polish_contents"), image: UIImage(systemName: "list.bullet")) { [weak self] _ in self?.showContents() })
        }
        actions.append(UIAction(title: L10n.string("WriterLibrary_navigation_selectDocuments"),
            image: UIImage(systemName: "checkmark.circle"), attributes: hasDocuments ? [] : [.disabled]) { [weak self] _ in
            self?.setEditing(true, animated: true)
        })
        if !isChapterList { actions.append(sortMenu()) }
        if currentSelection == .trash {
            actions.append(UIAction(title: L10n.string("WriterLibrary_sheets_emptyTrashAction"),
                image: UIImage(systemName: "trash"), attributes: hasDocuments ? [.destructive] : [.destructive, .disabled]) { [weak self] _ in self?.emptyTrashTapped() })
        }
        return UIMenu(children: actions)
    }

    @objc private func emptyTrashTapped() {
        let count = dataSource.snapshot().numberOfItems(inSection: .documents)
        guard count > 0 else { return }
        let alert = UIAlertController(
            title: L10n.string("WriterLibrary_sheets_emptyTrashConfirmTitle"),
            message: count == 1
                ? L10n.string("WriterLibrary_sheets_emptyTrashConfirmMessageOne")
                : L10n.string("WriterLibrary_sheets_emptyTrashConfirmMessage", count),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.string("Common_cancel"), style: .cancel))
        alert.addAction(UIAlertAction(
            title: L10n.string("WriterLibrary_sheets_emptyTrashAction"), style: .destructive
        ) { [weak self] _ in self?.emptyTrash() })
        present(alert, animated: true)
    }

    /// Deletes every trashed document for good. Exposed for tests.
    @discardableResult
    public func emptyTrash() -> Bool {
        guard (try? library.emptyTrash()) != nil else { return false }
        reload()
        return true
    }

    private func sortMenu() -> UIMenu {
        let options: [(DocumentSort, String)] = [
            (.manual, L10n.string("WriterLibrary_sheets_sortManual")),
            (.titleAscending, L10n.string("WriterLibrary_sheets_sortTitle")),
            (.modifiedDescending, L10n.string("WriterLibrary_sheets_sortModified")),
            (.createdDescending, L10n.string("WriterLibrary_sheets_sortCreated")),
        ]
        let actions = options.map { sort, title in
            UIAction(title: title, state: currentSort == sort ? .on : .off) { [weak self] _ in
                self?.currentSort = sort
                self?.reload()
                self?.navigationItem.rightBarButtonItems = self?.trailingBarButtons()
            }
        }
        return UIMenu(title: L10n.string("WriterLibrary_sheets_sortMenuTitle"), children: actions)
    }

    private func configureSearch() {
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = L10n.string("WriterLibrary_sheets_searchPlaceholder")
        navigationItem.searchController = searchController
        navigationItem.preferredSearchBarPlacement = .stacked
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
    }

    /// What `⌘F` on the root focuses.
    func focusSearch() {
        navigationItem.searchController?.isActive = true
        navigationItem.searchController?.searchBar.becomeFirstResponder()
    }

    /// What `⌘↩` on the root opens: the multi-select highlight if one is
    /// live, otherwise the top row of the current scope.
    func openFirstOrSelectedSheet() {
        let selected = (collectionView.indexPathsForSelectedItems ?? [])
            .compactMap { dataSource.itemIdentifier(for: $0) }
        let target = selected.first ?? dataSource.snapshot().itemIdentifiers.first
        if case .unattachedNote(let id)? = target { presentNote(notesByID[id]); return }
        guard case .document(let id)? = target, let document = documentsByID[id] else { return }
        selectionDelegate?.sheetsViewController(self, didSelect: document)
    }

    @objc private func newNoteTapped() { presentNote(nil) }
    func createNote() { presentNote(nil) }

    private func presentNote(_ note: WriterNote?) {
        let editor = NoteEditorViewController(note: note, store: notes, library: library) { [weak self] document in
            guard let self else { return }
            self.selectionDelegate?.sheetsViewController(self, didSelect: document)
        }
        let navigation = UINavigationController(rootViewController: editor)
        navigation.modalPresentationStyle = .formSheet
        present(navigation, animated: true)
    }

    @objc private func newSheetTapped() {
        createSheet()
    }

    /// Creates a document in `group`, or in the current selection's group
    /// (the Inbox for a library scope), and opens it.
    @discardableResult
    public func createSheet(in group: GroupID? = nil) -> WriterDocument? {
        let group = group ?? targetGroupForNewSheet()
        let document: WriterDocument
        do {
            if (try library.groups()).first(where: { $0.id == group })?.kind == .project {
                document = try ChapterOrganizer(library: library, textStore: textStore).appendChapter(in: group)
            } else { document = try library.createDocument(in: group, title: nil) }
        } catch { showOrganizationError(error); return nil }
        reload()
        selectionDelegate?.sheetsViewController(self, didSelect: document)
        return document
    }

    @objc private func showContents() {
        guard case .group(let id) = currentSelection,
              let group = (try? library.groups())?.first(where: { $0.id == id }) else { return }
        let screen = ChaptersViewController(library: library, textStore: textStore, book: group, currentID: openDocumentID) { [weak self] document in
            guard let self else { return }
            self.selectionDelegate?.sheetsViewController(self, didSelect: document)
        }
        present(UINavigationController(rootViewController: screen), animated: true)
    }

    private func showOrganizationError(_ error: Error) {
        let alert = UIAlertController(title: L10n.string("WriterLibrary_polish_saveChangesError"), message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func targetGroupForNewSheet() -> GroupID {
        switch currentSelection {
        case .group(let id): return id
        default: return library.inboxGroupID
        }
    }

    // MARK: - Selection

    public override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if isEditing { updateSelectionToolbar(); return }
        guard let row = dataSource.itemIdentifier(for: indexPath) else { return }
        let opensASheet: Bool
        if case .document(let id) = row, let document = documentsByID[id] {
            opensASheet = true
            selectionDelegate?.sheetsViewController(self, didSelect: document)
        } else {
            opensASheet = false
            if case .unattachedNote(let id) = row, let note = notesByID[id] { presentNote(note) }
        }
        // Beside a visible editor column the open sheet's row keeps its
        // highlight, which is what says which sheet is on screen. A
        // collapsed list is about to be pushed off screen, and a note row
        // opens no sheet, so both just flash.
        if !opensASheet || (splitViewController?.isCollapsed ?? true) {
            collectionView.deselectItem(at: indexPath, animated: true)
        }
    }

    // MARK: - Context menu

    public override func collectionView(
        _ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        if indexPaths.count == 1, case .unattachedNote(let id)? = dataSource.itemIdentifier(for: indexPaths[0]) {
            return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
                UIMenu(children: [UIAction(title: L10n.string("WriterLibrary_polish_deleteNote"), image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                    do { try self?.notes.delete(id); self?.reload() }
                    catch { self?.showOrganizationError(error) }
                }])
            })
        }
        guard indexPaths.count == 1, case .document(let id)? = dataSource.itemIdentifier(for: indexPaths[0])
        else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            self?.documentContextMenu(for: id)
        })
    }

    /// Exposed (rather than `private`) for the same reason
    /// `leadingSwipeActions(for:)` is: `UIContextMenuConfiguration.actionProvider`
    /// has no public getter, so a test builds the menu through this instead
    /// of trying to read it back out of the opaque configuration.
    func documentContextMenu(for id: DocumentID) -> UIMenu? {
        guard let document = documentsByID[id] else { return nil }
        var actions: [UIMenuElement] = [
            UIAction(
                title: L10n.string("WriterLibrary_editor_openAction"),
                image: UIImage(systemName: "arrow.up.forward.square")
            ) { [weak self] _ in
                guard let self, let document = self.documentsByID[id] else { return }
                self.selectionDelegate?.sheetsViewController(self, didSelect: document)
            },
            UIAction(
                title: L10n.string("WriterLibrary_sheets_moveAction"), image: UIImage(systemName: "folder")
            ) { [weak self] _ in self?.presentMovePicker(for: [id]) },
            UIAction(
                title: L10n.string("WriterLibrary_sheets_duplicateAction"),
                image: UIImage(systemName: "doc.on.doc")
            ) { [weak self] _ in self?.duplicateDocument(id) },
        ]
        if currentSelection == .trash {
            actions.append(UIAction(
                title: L10n.string("WriterLibrary_sheets_restoreAction"),
                image: UIImage(systemName: "arrow.uturn.backward")
            ) { [weak self] _ in self?.restoreDocument(id) })
        } else {
            actions.append(UIAction(
                title: L10n.string("Common_delete"), image: UIImage(systemName: "trash"), attributes: .destructive
            ) { [weak self] _ in self?.trashDocument(id) })
        }
        return UIMenu(children: actions)
    }

    private func presentKeywordEditor(for id: DocumentID) {
        guard let document = documentsByID[id] else { return }
        let editor = KeywordEditorViewController(library: library, document: document)
        present(UINavigationController(rootViewController: editor), animated: true)
    }

    private func presentGoalEditor(for id: DocumentID) {
        guard let document = documentsByID[id] else { return }
        let editor = GoalEditorViewController(library: library, document: document)
        present(UINavigationController(rootViewController: editor), animated: true)
    }

    /// Copies a sheet's text into a new one alongside it. The new sheet's
    /// title derives from that same text, the same way every save derives
    /// one, so it reads identically until the writer changes it (organiser
    /// #19).
    @discardableResult
    public func duplicateDocument(_ id: DocumentID) -> WriterDocument? {
        guard let original = documentsByID[id], let text = try? textStore.loadText(original) else { return nil }
        guard var copy = try? library.createDocument(in: original.groupID, title: nil) else { return nil }
        guard (try? textStore.saveText(text, for: &copy)) != nil else { return nil }
        reload()
        return copy
    }

    public override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        collectionView.allowsMultipleSelectionDuringEditing = editing
        for index in collectionView.indexPathsForSelectedItems ?? [] {
            collectionView.deselectItem(at: index, animated: false)
        }
        if !editing { reselectOpenDocument() }
        navigationItem.leftBarButtonItem = nil
        navigationItem.rightBarButtonItems = trailingBarButtons()
        navigationController?.setToolbarHidden(!editing, animated: animated)
        updateSelectionToolbar()
    }

    public override func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
        if isEditing { updateSelectionToolbar() }
    }

    private func updateSelectionToolbar() {
        guard isEditing else { toolbarItems = nil; return }
        let count = selectedDocumentIDs().count
        let action = UIBarButtonItem(title: L10n.string(currentSelection == .trash ? "WriterLibrary_sheets_restoreAction" : "WriterLibrary_sheets_moveAction"),
            style: .plain, target: self, action: currentSelection == .trash ? #selector(restoreSelectedTapped) : #selector(moveSelectedTapped))
        action.isEnabled = count > 0
        let selectionLabel = UILabel()
        selectionLabel.text = L10n.string("WriterLibrary_navigation_selectedCount", count)
        selectionLabel.font = .preferredFont(forTextStyle: .footnote)
        selectionLabel.adjustsFontForContentSizeCategory = true
        selectionLabel.textColor = .secondaryLabel
        let status = UIBarButtonItem(customView: selectionLabel)
        if #available(iOS 26, *) { status.hidesSharedBackground = true }
        var items = [action, UIBarButtonItem.flexibleSpace(), status]
        if currentSelection != .trash {
            let trash = UIBarButtonItem(barButtonSystemItem: .trash, target: self, action: #selector(trashSelectedTapped))
            trash.isEnabled = count > 0
            trash.tintColor = .systemRed
            items += [.flexibleSpace(), trash]
        }
        setToolbarItems(items, animated: false)
    }

    @objc private func restoreSelectedTapped() {
        for id in selectedDocumentIDs() { _ = restoreDocument(id) }
        setEditing(false, animated: true)
    }

    private func selectedDocumentIDs() -> [DocumentID] {
        (collectionView.indexPathsForSelectedItems ?? []).compactMap {
            guard case .document(let id) = dataSource.itemIdentifier(for: $0) else { return nil }
            return id
        }
    }

    @objc private func moveSelectedTapped() {
        presentMovePicker(for: selectedDocumentIDs())
    }

    @objc private func keywordSelectedTapped() {
        let ids = selectedDocumentIDs()
        guard !ids.isEmpty else { return }
        let editor = KeywordEditorViewController(library: library, documentIDs: ids)
        present(UINavigationController(rootViewController: editor), animated: true)
    }

    @objc private func trashSelectedTapped() {
        for id in selectedDocumentIDs() { _ = try? library.trash(id) }
        reload()
        setEditing(false, animated: true)
    }

    // MARK: - Swipe actions
    //
    // A compositional list layout takes its swipe actions from
    // `UICollectionLayoutListConfiguration`'s own providers
    // (`configureSwipeActionsLayout()`), never from a `UICollectionViewDelegate`
    // method — there is no such delegate method for this layout kind, so one
    // declared here would silently never fire.

    /// The favourite toggle. Exposed so tests can invoke the action's handler
    /// directly instead of driving a real swipe gesture.
    public func leadingSwipeActions(for id: DocumentID) -> UISwipeActionsConfiguration? {
        nil
    }

    /// Move + Trash normally; Restore in the Trash. Exposed for the same
    /// reason as `leadingSwipeActions(for:)`.
    public func trailingSwipeActions(for id: DocumentID) -> UISwipeActionsConfiguration? {
        if currentSelection == .trash {
            let restore = UIContextualAction(style: .normal, title: L10n.string("WriterLibrary_sheets_restoreAction")) {
                [weak self] _, _, completion in
                self?.restoreDocument(id)
                completion(true)
            }
            restore.backgroundColor = LunaColors.secondaryFill
            return UISwipeActionsConfiguration(actions: [restore])
        }
        let trash = UIContextualAction(style: .destructive, title: L10n.string("Common_delete")) {
            [weak self] _, _, completion in
            self?.trashDocument(id)
            completion(true)
        }
        let move = UIContextualAction(style: .normal, title: L10n.string("WriterLibrary_sheets_moveAction")) {
            [weak self] _, _, completion in
            self?.presentMovePicker(for: [id])
            completion(true)
        }
        move.backgroundColor = LunaColors.tertiaryFill
        return UISwipeActionsConfiguration(actions: [trash, move])
    }

    @discardableResult
    public func toggleFavorite(_ id: DocumentID) -> Bool {
        guard var document = documentsByID[id] else { return false }
        document.isFavorite.toggle()
        guard (try? library.update(document)) != nil else { return false }
        reload()
        return true
    }

    @discardableResult
    public func trashDocument(_ id: DocumentID) -> Bool {
        guard (try? library.trash(id)) != nil else { return false }
        reload()
        return true
    }

    @discardableResult
    public func restoreDocument(_ id: DocumentID) -> Bool {
        guard (try? library.restore(id)) != nil else { return false }
        reload()
        return true
    }

    public func presentMovePicker(for ids: [DocumentID]) {
        guard !ids.isEmpty else { return }
        let picker = MoveDestinationPicker(library: library) { [weak self] group in
            self?.moveDocuments(ids, to: group)
        }
        present(UINavigationController(rootViewController: picker), animated: true)
    }

    @discardableResult
    public func moveDocuments(_ ids: [DocumentID], to group: GroupID) -> Bool {
        var ok = true
        for id in ids where (try? library.moveDocument(id, to: group, at: 0)) == nil { ok = false }
        reload()
        setEditing(false, animated: true)
        return ok
    }

    private func presentAttachPicker(for noteID: NoteID) {
        let picker = SheetPickerViewController(library: library) { [weak self] document in
            self?.attachNote(noteID, to: document)
        }
        present(UINavigationController(rootViewController: picker), animated: true)
    }

    @discardableResult
    public func attachNote(_ noteID: NoteID, to document: DocumentID) -> Bool {
        guard (try? notes.attach(noteID, to: document, attachment: .manual)) != nil else { return false }
        reload()
        return true
    }

    // MARK: - Manual reorder

    private func configureDragAndDrop() {
        collectionView.dragDelegate = self
        collectionView.dropDelegate = self
        collectionView.dragInteractionEnabled = true
    }

    /// Called by the drop delegate, and directly by tests, to place a sheet
    /// at a new manual-sort position within its own group.
    @discardableResult
    public func reorderDocument(_ id: DocumentID, toIndex index: Int) -> Bool {
        guard let document = documentsByID[id] else { return false }
        guard (try? library.moveDocument(id, to: document.groupID, at: index)) != nil else { return false }
        reload()
        return true
    }
}

extension SheetsViewController: UICollectionViewDragDelegate, UICollectionViewDropDelegate {
    public func collectionView(
        _ collectionView: UICollectionView, itemsForBeginning session: UIDragSession, at indexPath: IndexPath
    ) -> [UIDragItem] {
        guard case .document(let id) = dataSource.itemIdentifier(for: indexPath) else { return [] }
        let provider = NSItemProvider(item: id.storageValue as NSString, typeIdentifier: WriterDragTypes.documentIdentifier)
        let item = UIDragItem(itemProvider: provider)
        item.localObject = id
        return [item]
    }

    public func collectionView(
        _ collectionView: UICollectionView, performDropWith coordinator: UICollectionViewDropCoordinator
    ) {
        // The unattached-notes section (Inbox only) is not reorderable —
        // `destination.item` there is a note row's index, not a place among
        // sheets (organiser #25).
        guard currentSort == .manual, let destination = coordinator.destinationIndexPath,
              destination.section == Section.documents.rawValue
        else { return }
        for item in coordinator.items {
            guard let id = item.dragItem.localObject as? DocumentID else { continue }
            reorderDocument(id, toIndex: destination.item)
        }
    }

    public func collectionView(_ collectionView: UICollectionView, canHandle session: UIDropSession) -> Bool {
        session.hasItemsConforming(toTypeIdentifiers: [WriterDragTypes.documentIdentifier])
    }
}

extension SheetsViewController: UISearchResultsUpdating {
    public func updateSearchResults(for searchController: UISearchController) {
        searchQuery = searchController.searchBar.text
        reload()
    }
}

extension SheetsViewController: LibraryChangeObserving {
    public func libraryDidChange(_ change: LibraryChange) {
        switch change {
        case .groups, .documents: reload()
        case .document(let id): handleDocumentChange(id)
        case .notes: if currentSelection == .inbox || currentSelection == .notes { reload() }
        }
    }

    /// A metadata change to a row already on screen updates just that row and
    /// defers the re-sort a couple of seconds, so typing in the open sheet
    /// does not walk its own row to the top of a "Date Modified" list on
    /// every autosave. Anything that could change which rows belong in this
    /// scope at all (new match, trashed, moved out) reloads immediately
    /// instead (organiser #21).
    private func handleDocumentChange(_ id: DocumentID) {
        guard documentsByID[id] != nil, let updated = try? library.document(id) else { reload(); return }
        guard matchesCurrentScope(updated) else { reload(); return }
        documentsByID[id] = updated
        var snapshot = dataSource.snapshot()
        if snapshot.itemIdentifiers.contains(.document(id)) {
            snapshot.reconfigureItems([.document(id)])
            dataSource.apply(snapshot, animatingDifferences: false)
        }
        scheduleResort()
    }

    private func matchesCurrentScope(_ document: WriterDocument) -> Bool {
        switch currentSelection {
        case .trash: return document.trashedAt != nil
        case .group(let id): return document.trashedAt == nil && document.groupID == id
        case .favorites: return document.trashedAt == nil && document.isFavorite
        case .notes: return false
        case .inbox: return document.trashedAt == nil && document.groupID == library.inboxGroupID
        // `.recent` and `.filter` scopes can depend on more than this one
        // row (a rolling date window, an arbitrary predicate) — a full
        // reload after the debounce is correct where a narrower check would
        // risk being wrong.
        case .all, .recent, .filter: return document.trashedAt == nil
        }
    }

    private func scheduleResort() {
        pendingResort?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload() }
        pendingResort = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.resortDebounceInterval, execute: work)
    }
}

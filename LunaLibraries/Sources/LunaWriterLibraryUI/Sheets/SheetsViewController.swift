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

    private var dataSource: UICollectionViewDiffableDataSource<Section, SheetsRow>!
    private var documentsByID: [DocumentID: WriterDocument] = [:]
    private var notesByID: [NoteID: WriterNote] = [:]
    private var currentSelection: LibrarySelection = .all
    private var currentSort: DocumentSort = .modifiedDescending
    private var searchQuery: String?

    private let searchController = UISearchController(searchResultsController: nil)

    public init(library: WriterLibraryStoring, notes: NoteStoring) {
        self.library = library
        self.notes = notes
        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        configuration.trailingSwipeActionsConfigurationProvider = nil
        let layout = UICollectionViewCompositionalLayout.list(using: configuration)
        super.init(collectionViewLayout: layout)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    public override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.backgroundColor = LunaColors.background
        configureDataSource()
        configureDragAndDrop()
        configureNavigationItems()
        configureSearch()
        library.addObserver(self)
        select(.all)
    }

    deinit { library.removeObserver(self) }

    // MARK: - Selection

    public func select(_ selection: LibrarySelection) {
        currentSelection = selection
        title = Self.title(for: selection)
        navigationItem.rightBarButtonItems = trailingBarButtons()
        reload()
    }

    private static func title(for selection: LibrarySelection) -> String {
        switch selection {
        case .all: return L10n.string("WriterLibrary_groups_libraryAll")
        case .recent: return L10n.string("WriterLibrary_groups_libraryRecent")
        case .favorites: return L10n.string("WriterLibrary_groups_libraryFavorites")
        case .inbox: return L10n.string("WriterLibrary_groups_inboxRow")
        case .trash: return L10n.string("WriterLibrary_groups_trashRow")
        case .group, .filter: return ""
        }
    }

    // MARK: - Loading

    public func reload() {
        let documents = loadDocuments()
        documentsByID = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })

        var snapshot = NSDiffableDataSourceSnapshot<Section, SheetsRow>()
        snapshot.appendSections(Section.allCases)
        snapshot.appendItems(documents.map { .document($0.id) }, toSection: .documents)

        if currentSelection == .inbox {
            let unattached = (try? notes.unattachedNotes()) ?? []
            notesByID = Dictionary(uniqueKeysWithValues: unattached.map { ($0.id, $0) })
            snapshot.appendItems(unattached.map { .unattachedNote($0.id) }, toSection: .unattachedNotes)
        }
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func loadDocuments() -> [WriterDocument] {
        let base: [WriterDocument]
        switch currentSelection {
        case .all: base = (try? library.documents(matching: FilterPredicate(), scope: nil)) ?? []
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
            cell.configure(with: document)
        }
        let noteCellRegistration = UICollectionView.CellRegistration<UnattachedNoteCell, SheetsRow> {
            [weak self] cell, _, row in
            guard case .unattachedNote(let id) = row, let note = self?.notesByID[id] else { return }
            cell.configure(with: note)
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
        navigationItem.leftBarButtonItem = editButtonItem
    }

    private func trailingBarButtons() -> [UIBarButtonItem] {
        var items = [UIBarButtonItem(
            image: UIImage(systemName: "arrow.up.arrow.down"), menu: sortMenu())]
        if currentSelection != .trash {
            items.append(UIBarButtonItem(
                barButtonSystemItem: .add, target: self, action: #selector(newSheetTapped)))
        }
        return items
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
    }

    @objc private func newSheetTapped() {
        createSheet()
    }

    @discardableResult
    public func createSheet() -> WriterDocument? {
        let group = targetGroupForNewSheet()
        guard let document = try? library.createDocument(in: group, title: nil) else { return nil }
        reload()
        selectionDelegate?.sheetsViewController(self, didSelect: document)
        return document
    }

    private func targetGroupForNewSheet() -> GroupID {
        switch currentSelection {
        case .group(let id): return id
        default: return library.inboxGroupID
        }
    }

    // MARK: - Selection

    public override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard !isEditing, let row = dataSource.itemIdentifier(for: indexPath) else { return }
        collectionView.deselectItem(at: indexPath, animated: true)
        guard case .document(let id) = row, let document = documentsByID[id] else { return }
        selectionDelegate?.sheetsViewController(self, didSelect: document)
    }

    public override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        collectionView.allowsMultipleSelectionDuringEditing = editing
        navigationItem.leftBarButtonItem = editButtonItem
        navigationController?.setToolbarHidden(!editing, animated: animated)
        if editing {
            navigationController?.toolbar?.items = multiSelectToolbarItems()
        }
    }

    private func multiSelectToolbarItems() -> [UIBarButtonItem] {
        [
            UIBarButtonItem(
                title: L10n.string("WriterLibrary_sheets_moveAction"), style: .plain, target: self,
                action: #selector(moveSelectedTapped)),
            UIBarButtonItem.flexibleSpace(),
            UIBarButtonItem(
                title: L10n.string("WriterLibrary_sheets_keywordAction"), style: .plain, target: self,
                action: #selector(keywordSelectedTapped)),
            UIBarButtonItem.flexibleSpace(),
            UIBarButtonItem(
                title: L10n.string("Common_delete"), style: .plain, target: self,
                action: #selector(trashSelectedTapped)),
        ]
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

    public func collectionView(
        _ collectionView: UICollectionView, leadingSwipeActionsConfigurationForItemAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard case .document(let id) = dataSource.itemIdentifier(for: indexPath) else { return nil }
        return leadingSwipeActions(for: id)
    }

    public func collectionView(
        _ collectionView: UICollectionView, trailingSwipeActionsConfigurationForItemAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard case .document(let id) = dataSource.itemIdentifier(for: indexPath) else { return nil }
        return trailingSwipeActions(for: id)
    }

    /// The favourite toggle. Exposed so tests can invoke the action's handler
    /// directly instead of driving a real swipe gesture.
    public func leadingSwipeActions(for id: DocumentID) -> UISwipeActionsConfiguration? {
        guard let document = documentsByID[id] else { return nil }
        let title = document.isFavorite
            ? L10n.string("WriterLibrary_sheets_unfavoriteAction")
            : L10n.string("WriterLibrary_sheets_favoriteAction")
        let action = UIContextualAction(style: .normal, title: title) { [weak self] _, _, completion in
            self?.toggleFavorite(id)
            completion(true)
        }
        action.backgroundColor = LunaColors.tertiaryFill
        action.image = UIImage(systemName: document.isFavorite ? "star.slash" : "star.fill")
        return UISwipeActionsConfiguration(actions: [action])
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
        guard currentSort == .manual, let destination = coordinator.destinationIndexPath else { return }
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
        case .groups, .documents, .document: reload()
        case .notes: if currentSelection == .inbox { reload() }
        }
    }
}

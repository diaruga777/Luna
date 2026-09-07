import UIKit
import LunaDesignSystem
import LunaModels
import LunaWriterModels
import LunaWriterStorage

/// Uniform type identifiers an `NSItemProvider` drag carries a row's id
/// under, so `GroupsViewController`'s drop delegate can tell a dragged sheet
/// apart from a dragged group.
public enum WriterDragTypes {
    public static let documentIdentifier = "com.hsanabria.luna.writer.documentID"
    public static let groupIdentifier = "com.hsanabria.luna.writer.groupID"
}

/// One row of the sidebar. Library/Inbox/Trash rows are fixed; groups and
/// filters come from the store.
public enum GroupsRow: Hashable {
    case libraryAll
    case libraryRecent
    case libraryFavorites
    case inboxRow
    case trashRow
    case group(GroupID)
    case filter(FilterID)
}

/// The Ulysses sidebar: Library (All / Last 7 Days / Favorites), Inbox,
/// nested Groups (with filters as children), and Trash. A `UICollectionView`
/// sidebar list, one section per fixed area plus a nested section for Groups.
public final class GroupsViewController: UICollectionViewController {

    private enum Section: Int, CaseIterable {
        case library, inbox, groups, trash
    }

    public weak var selectionDelegate: GroupsSelectionDelegate?

    private let library: WriterLibraryStoring
    private let notes: NoteStoring
    private let collapseStore: GroupCollapseStore

    private var dataSource: UICollectionViewDiffableDataSource<Section, GroupsRow>!
    private var groupsByID: [GroupID: WriterGroup] = [:]
    private var childGroups: [GroupID?: [WriterGroup]] = [:]
    /// Filters by scope; `nil` holds the library-wide ones, shown at the
    /// root of the Groups section.
    private var filtersByGroup: [GroupID?: [WriterFilter]] = [:]
    private var unattachedNoteCount = 0
    /// The row shown highlighted — kept so a reload from a `LibraryChange`
    /// does not lose the sidebar's selection (organiser #8).
    private var selectedRow: GroupsRow = .libraryAll

    /// The rows on screen, flattened in display order — a collapsed group's
    /// children are absent. Internal rather than private so tests can assert
    /// on the applied snapshot directly.
    var visibleRowsForTesting: [GroupsRow] { dataSource.snapshot().itemIdentifiers }

    /// Whether `group`'s children are currently shown.
    func isExpandedForTesting(_ group: GroupID) -> Bool {
        dataSource.snapshot(for: .groups).isExpanded(.group(group))
    }

    /// The name this screen currently has cached for `group` — reflects
    /// whatever the last `reload()` (including one from a `LibraryChange`)
    /// read back from the store.
    func nameForTesting(_ group: GroupID) -> String? { groupsByID[group]?.name }

    public init(
        library: WriterLibraryStoring, notes: NoteStoring,
        collapseStore: GroupCollapseStore = GroupCollapseStore()
    ) {
        self.library = library
        self.notes = notes
        self.collapseStore = collapseStore
        self.collapsedGroups = collapseStore.collapsedGroupIDs
        var configuration = UICollectionLayoutListConfiguration(appearance: .sidebar)
        configuration.headerMode = .supplementary
        let layout = UICollectionViewCompositionalLayout.list(using: configuration)
        super.init(collectionViewLayout: layout)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.string("WriterLibrary_groups_screenTitle")
        collectionView.backgroundColor = LunaColors.background
        configureDataSource()
        configureDragAndDrop()
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "plus"), menu: newItemMenu())
        let settings = UIBarButtonItem(
            image: UIImage(systemName: "gearshape"), style: .plain, target: self,
            action: #selector(settingsTapped))
        settings.accessibilityLabel = L10n.string("Common_settings")
        navigationItem.leftBarButtonItem = settings
        library.addObserver(self)
        reload()
    }

    deinit { library.removeObserver(self) }

    /// Never clears the highlighted row on a wide layout, where the sidebar
    /// stays on screen beside its content; behaves normally when collapsed,
    /// where reappearing after a push is the usual "nothing is selected yet".
    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        clearsSelectionOnViewWillAppear = splitViewController?.isCollapsed ?? false
    }

    // MARK: - Data

    public func reload() {
        let groups = (try? library.groups()) ?? []
        groupsByID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        let userGroups = groups.filter { $0.kind == .user }
        childGroups = Dictionary(grouping: userGroups, by: \.parentID)
        for key in childGroups.keys {
            childGroups[key]?.sort { $0.sortIndex < $1.sortIndex }
        }
        let filters = (try? library.filters()) ?? []
        filtersByGroup = Dictionary(grouping: filters, by: \.scopeGroupID)
        for key in filtersByGroup.keys {
            filtersByGroup[key]?.sort { $0.sortIndex < $1.sortIndex }
        }
        unattachedNoteCount = (try? notes.unattachedNotes().count) ?? 0
        applySnapshots()
    }

    private func topLevelGroups() -> [WriterGroup] {
        childGroups[nil] ?? []
    }

    /// Every row nested under `group`: its child groups, then its filters.
    private func children(of group: GroupID) -> [GroupsRow] {
        var rows: [GroupsRow] = (childGroups[group] ?? []).map { .group($0.id) }
        rows += (filtersByGroup[group] ?? []).map { .filter($0.id) }
        return rows
    }

    private func hasChildren(_ group: GroupID) -> Bool {
        !(childGroups[group] ?? []).isEmpty || !(filtersByGroup[group] ?? []).isEmpty
    }

    // MARK: - Diffable data source

    private func configureDataSource() {
        let cellRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, GroupsRow> {
            [weak self] cell, _, row in
            self?.configure(cell: cell, for: row)
        }
        let headerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] header, _, indexPath in
            guard let section = Section(rawValue: indexPath.section) else { return }
            var content = UIListContentConfiguration.sidebarHeader()
            content.text = self?.headerTitle(for: section)
            header.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource<Section, GroupsRow>(
            collectionView: collectionView
        ) { collectionView, indexPath, row in
            collectionView.dequeueConfiguredReusableCell(
                using: cellRegistration, for: indexPath, item: row)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(
                using: headerRegistration, for: indexPath)
        }
        // The outline disclosure accessory mutates the section snapshot
        // itself rather than calling `toggleExpansion(of:)`, so a tap there
        // is invisible to `collapsedGroups` unless these handlers record it
        // too — otherwise the next unrelated reload silently re-expands the
        // group the user just collapsed (organiser #27).
        dataSource.sectionSnapshotHandlers.willCollapseItem = { [weak self] row in
            guard case .group(let id) = row else { return }
            self?.setCollapsed(true, for: id)
        }
        dataSource.sectionSnapshotHandlers.willExpandItem = { [weak self] row in
            guard case .group(let id) = row else { return }
            self?.setCollapsed(false, for: id)
        }
    }

    private func headerTitle(for section: Section) -> String {
        switch section {
        case .library: return L10n.string("WriterLibrary_groups_sectionLibrary")
        case .inbox: return L10n.string("WriterLibrary_groups_sectionInbox")
        case .groups: return L10n.string("WriterLibrary_groups_sectionGroups")
        case .trash: return L10n.string("WriterLibrary_groups_sectionTrash")
        }
    }

    private func applySnapshots() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, GroupsRow>()
        snapshot.appendSections(Section.allCases)
        dataSource.apply(snapshot, animatingDifferences: false)

        var library = NSDiffableDataSourceSectionSnapshot<GroupsRow>()
        library.append([.libraryAll, .libraryRecent, .libraryFavorites])
        dataSource.apply(library, to: .library, animatingDifferences: false)

        var inbox = NSDiffableDataSourceSectionSnapshot<GroupsRow>()
        inbox.append([.inboxRow])
        dataSource.apply(inbox, to: .inbox, animatingDifferences: false)

        var groupsSnapshot = NSDiffableDataSourceSectionSnapshot<GroupsRow>()
        appendGroupTree(into: &groupsSnapshot, parent: nil)
        dataSource.apply(groupsSnapshot, to: .groups, animatingDifferences: false)

        var trash = NSDiffableDataSourceSectionSnapshot<GroupsRow>()
        trash.append([.trashRow])
        // `apply` always updates asynchronously even with no animation, so
        // the reselect waits for this last section's completion rather than
        // running in the same call stack against a collection view that has
        // not caught up yet.
        dataSource.apply(trash, to: .trash, animatingDifferences: false) { [weak self] in
            self?.reselect()
        }
    }

    /// Highlights the row for `selection` without telling the delegate — a
    /// restored scope, not a tap. A call before `viewDidLoad` is kept and
    /// applied by the first snapshot.
    public func highlight(_ selection: LibrarySelection) {
        selectedRow = Self.row(for: selection)
        guard isViewLoaded else { return }
        reselect()
    }

    private static func row(for selection: LibrarySelection) -> GroupsRow {
        switch selection {
        case .all: return .libraryAll
        case .recent: return .libraryRecent
        case .favorites: return .libraryFavorites
        case .inbox: return .inboxRow
        case .trash: return .trashRow
        case .group(let id): return .group(id)
        case .filter(let id): return .filter(id)
        }
    }

    /// Re-applies `selectedRow`'s highlight after a snapshot rebuild, which
    /// otherwise drops it (organiser #8).
    private func reselect() {
        guard let indexPath = dataSource.indexPath(for: selectedRow) else { return }
        collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
    }

    private func appendGroupTree(
        into snapshot: inout NSDiffableDataSourceSectionSnapshot<GroupsRow>, parent: GroupID?
    ) {
        let groups = childGroups[parent] ?? []
        var rows = groups.map { GroupsRow.group($0.id) }
        if parent == nil {
            rows += (filtersByGroup[nil] ?? []).map { GroupsRow.filter($0.id) }
        }
        if let parent {
            snapshot.append(rows, to: .group(parent))
        } else {
            snapshot.append(rows)
        }
        for group in groups {
            let filterRows = (filtersByGroup[group.id] ?? []).map { GroupsRow.filter($0.id) }
            if !filterRows.isEmpty { snapshot.append(filterRows, to: .group(group.id)) }
            if hasChildren(group.id), !collapsedGroups.contains(group.id) {
                snapshot.expand([.group(group.id)])
            }
            appendGroupTree(into: &snapshot, parent: group.id)
        }
    }

    /// Groups the user has explicitly collapsed. Absent means expanded — a
    /// newly created group starts open. Loaded from, and written back to,
    /// `collapseStore` so it survives a relaunch.
    private var collapsedGroups: Set<GroupID>

    private func setCollapsed(_ collapsed: Bool, for group: GroupID) {
        if collapsed {
            collapsedGroups.insert(group)
        } else {
            collapsedGroups.remove(group)
        }
        collapseStore.collapsedGroupIDs = collapsedGroups
    }

    /// Flips a group's expanded/collapsed state. Tests call this directly;
    /// the sidebar's own outline-disclosure control instead mutates the
    /// section snapshot, which `sectionSnapshotHandlers` reports back to
    /// `setCollapsed(_:for:)` (organiser #27).
    public func toggleExpansion(of group: GroupID) {
        setCollapsed(!collapsedGroups.contains(group), for: group)
        applySnapshots()
    }

    // MARK: - Cell content

    private func configure(cell: UICollectionViewListCell, for row: GroupsRow) {
        var content = UIListContentConfiguration.sidebarCell()
        // Pinned, so a row reconfigured after it was selected does not keep
        // the accent tint UIKit gave its glyph while it was highlighted.
        content.imageProperties.tintColor = LunaColors.primaryText
        switch row {
        case .libraryAll:
            content.text = L10n.string("WriterLibrary_groups_libraryAll")
            content.image = UIImage(systemName: "tray.full")
        case .libraryRecent:
            content.text = L10n.string("WriterLibrary_groups_libraryRecent")
            content.image = UIImage(systemName: "clock")
        case .libraryFavorites:
            content.text = L10n.string("WriterLibrary_groups_libraryFavorites")
            content.image = UIImage(systemName: "star")
        case .inboxRow:
            content.text = L10n.string("WriterLibrary_groups_inboxRow")
            content.image = UIImage(systemName: "tray")
            if unattachedNoteCount > 0 {
                cell.accessories = [.label(text: "\(unattachedNoteCount)")]
            } else {
                cell.accessories = []
            }
        case .trashRow:
            content.text = L10n.string("WriterLibrary_groups_trashRow")
            content.image = UIImage(systemName: "trash")
        case .group(let id):
            let group = groupsByID[id]
            content.text = group?.name ?? ""
            content.image = UIImage(systemName: group?.iconName ?? "folder")
            if let id = group?.id, hasChildren(id) {
                cell.accessories = [.outlineDisclosure()]
            } else {
                cell.accessories = []
            }
        case .filter(let id):
            let filter = filtersByID(id)
            content.text = filter?.name ?? ""
            content.image = UIImage(systemName: "line.3.horizontal.decrease.circle")
        }
        cell.contentConfiguration = content
    }

    private func filtersByID(_ id: FilterID) -> WriterFilter? {
        filtersByGroup.values.flatMap { $0 }.first { $0.id == id }
    }

    // MARK: - Selection

    public override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let row = dataSource.itemIdentifier(for: indexPath) else { return }
        selectedRow = row
        switch row {
        case .libraryAll: selectionDelegate?.groupsViewController(self, didSelect: .all)
        case .libraryRecent: selectionDelegate?.groupsViewController(self, didSelect: .recent)
        case .libraryFavorites: selectionDelegate?.groupsViewController(self, didSelect: .favorites)
        case .inboxRow: selectionDelegate?.groupsViewController(self, didSelect: .inbox)
        case .trashRow: selectionDelegate?.groupsViewController(self, didSelect: .trash)
        case .group(let id): selectionDelegate?.groupsViewController(self, didSelect: .group(id))
        case .filter(let id): selectionDelegate?.groupsViewController(self, didSelect: .filter(id))
        }
    }

    // MARK: - New group / filter

    /// The group a document made from the sidebar lands in: the highlighted
    /// group, or the Inbox (`nil`) for a library scope, a filter or the Trash.
    private var newDocumentTargetGroup: GroupID? {
        if case .group(let id) = selectedRow { return id }
        return nil
    }

    /// The `+` menu. Tests read it through this rather than the bar button.
    func newItemMenu() -> UIMenu {
        UIMenu(children: [
            UIAction(
                title: L10n.string("WriterLibrary_command_newSheet"),
                image: UIImage(systemName: "square.and.pencil")
            ) { [weak self] _ in self?.requestNewDocument(in: self?.newDocumentTargetGroup) },
            UIAction(
                title: L10n.string("WriterLibrary_groups_newGroupAction"),
                image: UIImage(systemName: "folder.badge.plus")
            ) { [weak self] _ in self?.createGroupAndAskForName(parent: nil) },
            UIAction(
                title: L10n.string("WriterLibrary_groups_newFilterAction"),
                image: UIImage(systemName: "line.3.horizontal.decrease.circle")
            ) { [weak self] _ in self?.presentNewFilterEditor(scope: nil) },
        ])
    }

    /// A group made from a menu gets its name asked for at once, instead of
    /// landing as "New Group" and waiting for a long-press rename.
    private func createGroupAndAskForName(parent: GroupID?) {
        guard let created = createGroup(parent: parent) else { return }
        presentRename(for: created.id)
    }

    /// A filter's editor before it exists: nothing is stored until Save.
    public func presentNewFilterEditor(scope: GroupID?) {
        let filter = WriterFilter(
            scopeGroupID: scope, name: "",
            sortIndex: (filtersByGroup[scope] ?? []).count)
        presentFilterEditor(filter)
    }

    @objc private func settingsTapped() {
        selectionDelegate?.groupsViewControllerRequestsSettings(self)
    }

    public func requestNewDocument(in group: GroupID?) {
        selectionDelegate?.groupsViewController(self, requestsNewDocumentIn: group)
    }

    @discardableResult
    public func createGroup(parent: GroupID?) -> WriterGroup? {
        guard let created = try? library.createGroup(
            name: L10n.string("WriterLibrary_groups_newGroupDefaultName"),
            icon: "folder", parent: parent)
        else { return nil }
        if let parent { setCollapsed(false, for: parent) }
        reload()
        return created
    }

    @discardableResult
    public func createFilter(scope: GroupID?) -> WriterFilter? {
        let filter = WriterFilter(
            scopeGroupID: scope, name: L10n.string("WriterLibrary_groups_newFilterDefaultName"))
        try? library.save(filter)
        reload()
        return filter
    }

    // MARK: - Context menu

    public override func collectionView(
        _ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard indexPaths.count == 1, let row = dataSource.itemIdentifier(for: indexPaths[0]) else { return nil }
        switch row {
        case .group(let id):
            return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
                self?.groupContextMenu(for: id)
            })
        case .filter(let id):
            return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
                self?.filterContextMenu(for: id)
            })
        default:
            return nil
        }
    }

    func filterContextMenu(for id: FilterID) -> UIMenu {
        UIMenu(children: [
            UIAction(
                title: L10n.string("WriterLibrary_groups_editFilterAction"),
                image: UIImage(systemName: "pencil")
            ) { [weak self] _ in self?.presentFilterEditor(for: id) },
            UIAction(
                title: L10n.string("WriterLibrary_groups_deleteFilterAction"),
                image: UIImage(systemName: "trash"), attributes: .destructive
            ) { [weak self] _ in self?.deleteFilter(id) },
        ])
    }

    public func presentFilterEditor(for id: FilterID) {
        guard let filter = filtersByID(id) else { return }
        presentFilterEditor(filter)
    }

    private func presentFilterEditor(_ filter: WriterFilter) {
        let editor = FilterEditorViewController(library: library, filter: filter)
        editor.onSave = { [weak self] saved in
            guard let self else { return }
            if let scope = saved.scopeGroupID { self.setCollapsed(false, for: scope) }
            self.reload()
        }
        present(UINavigationController(rootViewController: editor), animated: true)
    }

    @discardableResult
    public func deleteFilter(_ id: FilterID) -> Bool {
        guard (try? library.deleteFilter(id)) != nil else { return false }
        if selectedRow == .filter(id) { selectedRow = .libraryAll }
        reload()
        return true
    }

    private func groupContextMenu(for id: GroupID) -> UIMenu {
        UIMenu(children: [
            UIAction(
                title: L10n.string("WriterLibrary_command_newSheet"),
                image: UIImage(systemName: "square.and.pencil")
            ) { [weak self] _ in self?.requestNewDocument(in: id) },
            UIAction(
                title: L10n.string("WriterLibrary_groups_newGroupAction"),
                image: UIImage(systemName: "folder.badge.plus")
            ) { [weak self] _ in self?.createGroupAndAskForName(parent: id) },
            UIAction(
                title: L10n.string("WriterLibrary_groups_newFilterAction"),
                image: UIImage(systemName: "line.3.horizontal.decrease.circle")
            ) { [weak self] _ in self?.presentNewFilterEditor(scope: id) },
            UIAction(
                title: L10n.string("WriterLibrary_groups_renameAction"),
                image: UIImage(systemName: "pencil")
            ) { [weak self] _ in self?.presentRename(for: id) },
            UIAction(
                title: L10n.string("WriterLibrary_groups_changeIconAction"),
                image: UIImage(systemName: "square.grid.2x2")
            ) { [weak self] _ in self?.presentIconPicker(for: id) },
            UIAction(
                title: L10n.string("WriterLibrary_groups_deleteAction"),
                image: UIImage(systemName: "trash"), attributes: .destructive
            ) { [weak self] _ in self?.presentDeleteConfirmation(for: id) },
        ])
    }

    /// How many sheets `deleteGroup` would trash: this group's own, plus
    /// every descendant's (organiser #26).
    private func totalDocumentCount(in group: GroupID) -> Int {
        var total = (try? library.documents(in: group, sort: .manual).count) ?? 0
        for child in childGroups[group] ?? [] {
            total += totalDocumentCount(in: child.id)
        }
        return total
    }

    public func presentDeleteConfirmation(for id: GroupID) {
        guard let group = groupsByID[id] else { return }
        let count = totalDocumentCount(in: id)
        let alert = UIAlertController(
            title: L10n.string("WriterLibrary_groups_deleteConfirmTitle", group.name),
            message: count == 0 ? nil : count == 1
                ? L10n.string("WriterLibrary_groups_deleteConfirmMessageOne")
                : L10n.string("WriterLibrary_groups_deleteConfirmMessage", count),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.string("Common_cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.string("Common_delete"), style: .destructive) { [weak self] _ in
            self?.deleteGroup(id)
        })
        present(alert, animated: true)
    }

    public func presentRename(for id: GroupID) {
        guard let group = groupsByID[id] else { return }
        let alert = UIAlertController(
            title: L10n.string("WriterLibrary_groups_renameAlertTitle"), message: nil,
            preferredStyle: .alert)
        alert.addTextField { $0.text = group.name }
        alert.addAction(UIAlertAction(title: L10n.string("Common_cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.string("Common_save"), style: .default) { [weak self] _ in
            guard let self, let text = alert.textFields?.first?.text, !text.isEmpty else { return }
            self.rename(id, to: text)
        })
        present(alert, animated: true)
    }

    @discardableResult
    public func rename(_ id: GroupID, to name: String) -> Bool {
        guard var group = groupsByID[id] else { return false }
        group.name = name
        guard (try? library.update(group)) != nil else { return false }
        reload()
        return true
    }

    public func presentIconPicker(for id: GroupID) {
        let picker = GroupIconPickerViewController(currentIcon: groupsByID[id]?.iconName ?? "folder") {
            [weak self] icon in
            self?.setIcon(icon, for: id)
        }
        present(UINavigationController(rootViewController: picker), animated: true)
    }

    @discardableResult
    public func setIcon(_ icon: String, for id: GroupID) -> Bool {
        guard var group = groupsByID[id] else { return false }
        group.iconName = icon
        guard (try? library.update(group)) != nil else { return false }
        reload()
        return true
    }

    @discardableResult
    public func deleteGroup(_ id: GroupID) -> Bool {
        guard (try? library.delete(id)) != nil else { return false }
        reload()
        return true
    }

    // MARK: - Drag and drop

    private func configureDragAndDrop() {
        collectionView.dragDelegate = self
        collectionView.dropDelegate = self
        collectionView.dragInteractionEnabled = true
    }
}

extension GroupsViewController: UICollectionViewDragDelegate, UICollectionViewDropDelegate {
    public func collectionView(
        _ collectionView: UICollectionView, itemsForBeginning session: UIDragSession, at indexPath: IndexPath
    ) -> [UIDragItem] {
        guard let row = dataSource.itemIdentifier(for: indexPath), case .group(let id) = row else { return [] }
        let provider = NSItemProvider(item: id.storageValue as NSString, typeIdentifier: WriterDragTypes.groupIdentifier)
        let item = UIDragItem(itemProvider: provider)
        item.localObject = id
        return [item]
    }

    public func collectionView(
        _ collectionView: UICollectionView, canHandle session: UIDropSession
    ) -> Bool {
        session.hasItemsConforming(toTypeIdentifiers: [
            WriterDragTypes.documentIdentifier, WriterDragTypes.groupIdentifier,
        ])
    }

    /// The group a drop onto `row` would land in — `nil` for a row that
    /// cannot accept one (a fixed Library scope, or a filter).
    private func targetGroup(for row: GroupsRow) -> GroupID? {
        switch row {
        case .group(let id): return id
        case .inboxRow: return library.inboxGroupID
        case .trashRow: return library.trashGroupID
        case .libraryAll, .libraryRecent, .libraryFavorites, .filter: return nil
        }
    }

    /// Whether `candidate` is `ancestor` itself, or nested under it.
    /// Reparenting a group onto its own subtree would make it unreachable
    /// (organiser #28).
    private func isDescendant(_ candidate: GroupID, ofOrEqualTo ancestor: GroupID) -> Bool {
        var current: GroupID? = candidate
        while let id = current {
            if id == ancestor { return true }
            current = groupsByID[id]?.parentID
        }
        return false
    }

    public func collectionView(
        _ collectionView: UICollectionView, dropSessionDidUpdate session: UIDropSession,
        withDestinationIndexPath destinationIndexPath: IndexPath?
    ) -> UICollectionViewDropProposal {
        guard let destinationIndexPath, let row = dataSource.itemIdentifier(for: destinationIndexPath),
              let targetGroup = targetGroup(for: row)
        else { return UICollectionViewDropProposal(operation: .forbidden) }
        let wouldNoOp = session.items.contains { item in
            guard let groupID = item.localObject as? GroupID else { return false }
            return groupID == targetGroup || isDescendant(targetGroup, ofOrEqualTo: groupID)
        }
        return wouldNoOp
            ? UICollectionViewDropProposal(operation: .forbidden)
            : UICollectionViewDropProposal(operation: .move, intent: .insertIntoDestinationIndexPath)
    }

    public func collectionView(
        _ collectionView: UICollectionView, performDropWith coordinator: UICollectionViewDropCoordinator
    ) {
        guard let destination = coordinator.destinationIndexPath,
              let row = dataSource.itemIdentifier(for: destination),
              let targetGroup = targetGroup(for: row)
        else { return }
        for item in coordinator.items {
            if let documentID = item.dragItem.localObject as? DocumentID {
                moveDocumentDropped(documentID, onto: targetGroup)
            } else if let groupID = item.dragItem.localObject as? GroupID, groupID != targetGroup {
                moveGroup(groupID, toParent: targetGroup, index: 0)
            }
        }
    }

    /// Called by the drop delegate, and directly by tests, when a sheet is
    /// dropped onto a group row.
    @discardableResult
    public func moveDocumentDropped(_ documentID: DocumentID, onto group: GroupID) -> Bool {
        guard (try? library.moveDocument(documentID, to: group, at: 0)) != nil else { return false }
        reload()
        return true
    }

    /// Called by the drag/drop machinery, and directly by tests, to move or
    /// reparent a group. No-ops rather than orphaning the tree when `parent`
    /// is `id` itself or one of its own descendants (organiser #28).
    @discardableResult
    public func moveGroup(_ id: GroupID, toParent parent: GroupID?, index: Int) -> Bool {
        if let parent, parent == id || isDescendant(parent, ofOrEqualTo: id) { return false }
        guard (try? library.moveGroup(id, to: parent, at: index)) != nil else { return false }
        if let parent { setCollapsed(false, for: parent) }
        reload()
        return true
    }
}

extension GroupsViewController: LibraryChangeObserving {
    public func libraryDidChange(_ change: LibraryChange) {
        switch change {
        case .groups, .notes: reload()
        default: break
        }
    }
}

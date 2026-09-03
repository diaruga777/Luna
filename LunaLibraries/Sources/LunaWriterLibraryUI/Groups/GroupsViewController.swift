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

    private var dataSource: UICollectionViewDiffableDataSource<Section, GroupsRow>!
    private var groupsByID: [GroupID: WriterGroup] = [:]
    private var childGroups: [GroupID?: [WriterGroup]] = [:]
    private var filtersByGroup: [GroupID: [WriterFilter]] = [:]
    private var expandedGroups: Set<GroupID> = []
    private var unattachedNoteCount = 0

    public init(library: WriterLibraryStoring, notes: NoteStoring) {
        self.library = library
        self.notes = notes
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
        library.addObserver(self)
        reload()
    }

    deinit { library.removeObserver(self) }

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
        filtersByGroup = Dictionary(grouping: filters.compactMap { filter -> (GroupID, WriterFilter)? in
            guard let scope = filter.scopeGroupID else { return nil }
            return (scope, filter)
        }, by: \.0).mapValues { $0.map(\.1) }
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
        dataSource.apply(trash, to: .trash, animatingDifferences: false)
    }

    private func appendGroupTree(
        into snapshot: inout NSDiffableDataSourceSectionSnapshot<GroupsRow>, parent: GroupID?
    ) {
        let groups = childGroups[parent] ?? []
        let rows = groups.map { GroupsRow.group($0.id) }
        if let parent {
            snapshot.append(rows, to: .group(parent))
        } else {
            snapshot.append(rows)
        }
        for group in groups {
            let filterRows = (filtersByGroup[group.id] ?? []).map { GroupsRow.filter($0.id) }
            if !filterRows.isEmpty { snapshot.append(filterRows, to: .group(group.id)) }
            if hasChildren(group.id) {
                snapshot.expand([.group(group.id)])
            }
            appendGroupTree(into: &snapshot, parent: group.id)
        }
    }

    // MARK: - Cell content

    private func configure(cell: UICollectionViewListCell, for row: GroupsRow) {
        var content = UIListContentConfiguration.sidebarCell()
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

    private func newItemMenu() -> UIMenu {
        UIMenu(children: [
            UIAction(
                title: L10n.string("WriterLibrary_groups_newGroupAction"),
                image: UIImage(systemName: "folder.badge.plus")
            ) { [weak self] _ in self?.createGroup(parent: nil) },
            UIAction(
                title: L10n.string("WriterLibrary_groups_newFilterAction"),
                image: UIImage(systemName: "line.3.horizontal.decrease.circle")
            ) { [weak self] _ in self?.createFilter(scope: nil) },
        ])
    }

    @discardableResult
    public func createGroup(parent: GroupID?) -> WriterGroup? {
        guard let created = try? library.createGroup(
            name: L10n.string("WriterLibrary_groups_newGroupDefaultName"),
            icon: "folder", parent: parent)
        else { return nil }
        if let parent { expandedGroups.insert(parent) }
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
        guard indexPaths.count == 1,
              let row = dataSource.itemIdentifier(for: indexPaths[0]),
              case .group(let id) = row
        else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            self?.groupContextMenu(for: id)
        })
    }

    private func groupContextMenu(for id: GroupID) -> UIMenu {
        UIMenu(children: [
            UIAction(
                title: L10n.string("WriterLibrary_groups_newGroupAction"),
                image: UIImage(systemName: "folder.badge.plus")
            ) { [weak self] _ in self?.createGroup(parent: id) },
            UIAction(
                title: L10n.string("WriterLibrary_groups_newFilterAction"),
                image: UIImage(systemName: "line.3.horizontal.decrease.circle")
            ) { [weak self] _ in self?.createFilter(scope: id) },
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
            ) { [weak self] _ in self?.deleteGroup(id) },
        ])
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

    public func collectionView(
        _ collectionView: UICollectionView, dropSessionDidUpdate session: UIDropSession,
        withDestinationIndexPath destinationIndexPath: IndexPath?
    ) -> UICollectionViewDropProposal {
        UICollectionViewDropProposal(operation: .move, intent: .insertIntoDestinationIndexPath)
    }

    public func collectionView(
        _ collectionView: UICollectionView, performDropWith coordinator: UICollectionViewDropCoordinator
    ) {
        guard let destination = coordinator.destinationIndexPath,
              let row = dataSource.itemIdentifier(for: destination)
        else { return }
        let targetGroup: GroupID?
        switch row {
        case .group(let id): targetGroup = id
        case .inboxRow: targetGroup = library.inboxGroupID
        case .trashRow: targetGroup = library.trashGroupID
        default: targetGroup = nil
        }
        guard let targetGroup else { return }
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
    /// reparent a group.
    @discardableResult
    public func moveGroup(_ id: GroupID, toParent parent: GroupID?, index: Int) -> Bool {
        guard (try? library.moveGroup(id, to: parent, at: index)) != nil else { return false }
        if let parent { expandedGroups.insert(parent) }
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

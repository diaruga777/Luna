//
//  ReadingListViewController.swift
//  Luna
//

import LunaReadingListUI
import LunaSocialUI
import LunaReadingList
import LunaSocial
import LunaDesignSystem
import LunaStorage
import LunaURLClassification
import LunaModels
import UIKit

/// The home screen. Items are grouped into sections in FIFO (oldest-saved
/// first) order:
/// - **From Pasteboard**: a one-tap suggestion for a readable URL on the
///   clipboard, shown above the list and only until tapped (not yet saved).
/// - **Reading**: unread items saved within the last week (always expanded).
/// - **Read**: finished items (collapsed by default).
/// - **Archive**: unread items older than a week by save date (collapsed by
///   default).
/// - **Couldn't Load**: items whose content failed to download/extract, in red,
///   at the very bottom (collapsed by default; pull to retry).
/// Collapsible headers expand/collapse on tap. Tap a row to read; long-press for
/// the action menu, whose "Edit List" enters edit mode (selection radios +
/// drag-anywhere reorder within Reading, no handle).
final class ReadingListViewController: UITableViewController {

    /// Which standalone app this list renders for. A concrete surface shows ONLY its
    /// content category (and hides the filter segments); `nil` is the legacy combined
    /// list — all categories with the Articles / Media / Price filter — kept for the
    /// dev/test harness.
    private let surface: AppSurface?
    private let pasteboardSuggestions: PasteboardSuggestionController

    init(surface: AppSurface? = nil) {
        self.surface = surface
        self.pasteboardSuggestions = PasteboardSuggestionController(surface: surface)
        super.init(style: .insetGrouped)
        pasteboardSuggestions.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The "now" used for date-relative sectioning (Reading vs Archive). Production
    /// uses the wall clock; a DEBUG UI-test seed pins it to the fixture's base date so
    /// fixed-date fixtures land in the Reading section (and renders are reproducible).
    private static func sectioningNow() -> Date {
        #if DEBUG
        if let pinned = UITestSeeder.sectioningNow { return pinned }
        #endif
        return Date()
    }

    /// Items older than this (by save date) move to the Archive section.
    private static let archiveAge: TimeInterval = ReadingListSectioning.archiveAge

    /// The list groups and the Articles / Media filter — pure section/filter
    /// logic lives in `ReadingListSectioning`.
    private typealias Section = ReadingListSectioning.Section
    private typealias ListFilter = ReadingListSectioning.ListFilter

    /// Whether the item opens in the text reader (articles, documents, emails), as
    /// opposed to media & links, which open
    /// in a player, embed, or browser. Mirrors the tap routing in `didSelectRowAt`.
    static func rendersAsReader(_ item: ReadingListItem) -> Bool {
        ReadingListSectioning.rendersAsReader(item)
    }

    // Internal (not private): UITestSeeder resets these between runs — a key
    // rename must not silently reintroduce cross-run state bleed.
    static let filterDefaultsKey = "readingListFilter"
    static let collapsedDefaultsKey = "readingListCollapsedSections"

    private var filter: ListFilter {
        get {
            ListFilter(rawValue: UserDefaults.standard.integer(forKey: Self.filterDefaultsKey))
                ?? .all
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.filterDefaultsKey) }
    }

    /// Persisted collapsed sections. Absent (first run) means Archive starts
    /// collapsed.
    private var collapsedSections: Set<Section> {
        get {
            guard let raw = UserDefaults.standard.array(forKey: Self.collapsedDefaultsKey) as? [Int]
            else { return [.archive, .error] }
            return Set(raw.compactMap(Section.init(rawValue:)))
        }
        set {
            UserDefaults.standard.set(newValue.map(\.rawValue), forKey: Self.collapsedDefaultsKey)
        }
    }

    private let store = ReadingListStore.shared

    /// The Articles / Media & Links filter — only shown when the list actually has
    /// both a reader item and a media/link item, otherwise it's pointless.
    private let filterControl = LunaSegmentedControl()
    /// Holds natural-width segments so "Media & Links" is never silently clipped.
    private let filterScrollView = UIScrollView()
    private var filterWidthConstraint: NSLayoutConstraint?
    /// Cached natural (content) width of the filter control, remeasured only when the
    /// segments change — read cheaply on every layout pass by `applyFilterWidth`.
    private var filterNaturalWidth: CGFloat = 0
    private var filterHeaderView: UIView?
    /// The combined scrolling table-header (large-title row + optional filter row).
    private var tableHeaderContainer: UIView?
    /// Whether the filter row is currently included in the table header.
    private var filterRowVisible = false
    /// The table width the header was last laid out at, so layout passes only rebuild
    /// the header frame when the width actually changes.
    private var lastHeaderLayoutWidth: CGFloat = 0

    /// The recreated navigation header bar — a normal content subview (NOT the
    /// UINavigationController nav bar) pinned to the visible top of the table. Holds
    /// settings/friends (leading) + add (trailing) controls; in edit mode it swaps to
    /// Done / Select All / Delete.
    private let header = NavHeaderBar()

    /// The scrolling large-title row ("Reading List"), sitting at the top of the
    /// table's content so it scrolls away under the pinned bar just like a system
    /// large title. Combined with the filter control into the table header view.
    private let largeTitleLabel = UILabel()

    /// Reader and Price Tracker deliberately start with content, rather than a generic
    /// "Reading List" title. Downloader and the combined dev list retain that header.
    private var showsLargeListHeader: Bool {
        surface != .reader && surface != .priceTracker
    }

    /// Reader items and trackers are self-describing cells, so their active sections
    /// should read as one uninterrupted list. Archive (and exceptional sections) keep
    /// their headers because they communicate a meaningful state.
    private func hidesHeader(for section: Section) -> Bool {
        switch (surface, section) {
        case (.reader, .reading),
             (.priceTracker, .priceAlert),
             (.priceTracker, .priceTracking):
            return true
        default:
            return false
        }
    }

    /// Non-blocking bottom pill for media-download progress/result (created lazily).
    private weak var mediaDownloadStatus: MediaDownloadStatusView?
    private var isPresentingSendFailureNotice = false

    /// Non-empty groups in display order; rebuilt on every `reload`.
    private var groups: [(section: Section, items: [ReadingListItem])] = []

    /// Set while persisting a manual reorder so the resulting
    /// `.readingListChanged` notification doesn't reload the table mid-drop
    /// (which mangles the layout).
    private var isApplyingReorder = false
    /// True while an animated single-row delete runs, so the `.readingListChanged`
    /// notification doesn't full-reload mid-animation (which kills the fade).
    private var isAnimatingRowChange = false

    /// A row-menu action deferred until the context menu has finished dismissing.
    /// Presenting a modal from a `UIAction` handler fires WHILE the menu is still
    /// collapsing, so presenting immediately would overlap the two animations. Actions that
    /// present UI stash their work here instead; `willEndContextMenuInteraction`
    /// runs it from the dismissal animator's completion, over a settled list.
    private var pendingContextMenuAction: (() -> Void)?

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    override func viewDidLoad() {
        super.viewDidLoad()

        tableView.register(
            ReadingListItemCell.self, forCellReuseIdentifier: ReadingListItemCell.reuseID)

        // The pinned header bar (replaces the nav bar) + its default buttons.
        header.mount(in: self)
        setDefaultHeaderControls()

        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(pulledToRefresh), for: .valueChanged)

        filterControl.addTarget(self, action: #selector(filterChanged(_:)), for: .valueChanged)
        filterControl.apportionsSegmentWidthsByContent = true
        let filterRow = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: 44))
        filterScrollView.showsHorizontalScrollIndicator = false
        filterScrollView.alwaysBounceHorizontal = true
        filterScrollView.translatesAutoresizingMaskIntoConstraints = false
        filterRow.addSubview(filterScrollView)
        filterControl.translatesAutoresizingMaskIntoConstraints = false
        filterScrollView.addSubview(filterControl)
        let width = filterControl.widthAnchor.constraint(equalToConstant: 0)
        filterWidthConstraint = width
        NSLayoutConstraint.activate([
            filterScrollView.leadingAnchor.constraint(equalTo: filterRow.leadingAnchor, constant: 16),
            filterScrollView.trailingAnchor.constraint(equalTo: filterRow.trailingAnchor, constant: -16),
            filterScrollView.topAnchor.constraint(equalTo: filterRow.topAnchor),
            filterScrollView.bottomAnchor.constraint(equalTo: filterRow.bottomAnchor),
            filterControl.leadingAnchor.constraint(equalTo: filterScrollView.contentLayoutGuide.leadingAnchor),
            filterControl.trailingAnchor.constraint(equalTo: filterScrollView.contentLayoutGuide.trailingAnchor),
            filterControl.centerYAnchor.constraint(equalTo: filterScrollView.frameLayoutGuide.centerYAnchor),
            filterControl.heightAnchor.constraint(equalToConstant: 32),
            width,
        ])
        filterHeaderView = filterRow

        // Edit mode is entered on demand from the row's long-press menu ("Edit
        // List"); it shows selection radios and enables drag-anywhere reorder (no
        // handle). Normally the list isn't editing — taps just open rows.
        tableView.allowsMultipleSelectionDuringEditing = true
        tableView.dragDelegate = self
        tableView.dropDelegate = self

        NotificationCenter.default.addObserver(
            self, selector: #selector(scheduleReload), name: .readingListChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(priceTrackerSavedInteractively(_:)),
            name: .priceTrackerSavedInteractively, object: nil)
        reload()
        pasteboardSuggestions.evaluate()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The list draws its own in-content header (pinned bar + scrolling large title),
        // so keep the shared nav bar hidden on every appearance.
        navigationController?.setNavigationBarHidden(true, animated: false)
        updateHeaderInsets()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Reaching the reading list (on launch or by navigating back) clears the
        // "open the app" follow-up share notifications; first-share prompts that
        // deep-link to settings are left intact.
        NotificationManager.clearShareNotifications()
        presentPendingSendFailureNoticeIfNeeded()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        updateHeaderInsets()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateHeaderInsets()
        // Rebuild the table header at the current width (its frame-height must be set
        // explicitly for a table header view); only when the width actually changed.
        let width = tableView.bounds.width
        if abs(width - lastHeaderLayoutWidth) > 0.5, width > 1 {
            lastHeaderLayoutWidth = width
            rebuildTableHeader(showsFilter: filterRowVisible)
        }
        applyFilterWidth()
    }

    /// Keeps the pinned header's height (= safe-area top + bar) and the table's top
    /// content/indicator insets in sync, so the scrolling large title starts just
    /// below the bar.
    private func updateHeaderInsets() {
        header.setManagedHeight(topSafeAreaInset: view.safeAreaInsets.top)
        guard abs(tableView.contentInset.top - NavHeaderBar.barHeight) > 0.5 else { return }
        // The table establishes its resting contentOffset (= -adjustedContentInset.top)
        // during its first layout, while contentInset.top is still 0 — so it rests at
        // just -safeArea. Growing the inset afterward does NOT re-settle that offset, so
        // the content (incl. the large title) would sit `barHeight` too high and slide
        // under the pinned bar. If the table is resting at its top, re-pin the offset to
        // the new adjusted inset so the title starts just below the bar; if the user has
        // scrolled, leave their position alone.
        let wasAtTop = tableView.contentOffset.y <= -tableView.adjustedContentInset.top + 0.5
        tableView.contentInset.top = NavHeaderBar.barHeight
        tableView.verticalScrollIndicatorInsets.top = NavHeaderBar.barHeight
        if wasAtTop {
            tableView.contentOffset.y = -tableView.adjustedContentInset.top
        }
    }

    // MARK: - Pasteboard suggestion

    /// `.readingListChanged` fires once per store mutation — ingest of one item can
    /// post several in a row. Dedupe a notification burst to a single `reload()` per
    /// main-runloop pass instead of reloading (and re-reading the store) once per
    /// notification.
    private var reloadPending = false

    @objc private func scheduleReload() {
        guard !reloadPending else { return }
        reloadPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reloadPending = false
            self.reload()
        }
    }

    @objc private func reload() {
        // A reorder we just persisted fires this notification; ignore it so the
        // drop animation isn't interrupted by a full reloadData.
        if isApplyingReorder || isAnimatingRowChange { return }

        // One store read for the whole reload, passed through to every helper below
        // instead of each one re-reading the store itself.
        let items = store.items()
        updateFilterVisibility(items: items)
        applyReloadedGroups(buildGroups(items: items))
        updateEmptyState()
        presentPendingSendFailureNoticeIfNeeded(items: items)
    }

    /// Swaps `groups` to the freshly-built model with the same id-keyed diff the filter
    /// path uses (`ReadingListDiff`), instead of unconditionally `reloadData()`-ing —
    /// ingest bursts, price refreshes, and read-state flips all route through `reload()`,
    /// so a blanket reload was rebuilding every visible cell (and cancelling any in-flight
    /// row animation) on every store mutation. Falls back to a full `reloadData()` for the
    /// cases the diff can't reason about:
    /// - first load / any empty↔non-empty flip (nothing meaningful to diff, and the table
    ///   may not have an established baseline yet)
    /// - a pasteboard row on either side: `buildGroups` synthesizes it fresh (with a NEW
    ///   random id) on every call, so it has no stable identity for the differ to match
    ///   against, and its cell is configured through a path `reconfigurePersistingCells`
    ///   doesn't drive
    private func applyReloadedGroups(_ newGroups: [(section: Section, items: [ReadingListItem])]) {
        let oldGroups = groups
        let hasPasteboardRow = { (groups: [(section: Section, items: [ReadingListItem])]) in
            groups.contains { $0.section == .pasteboard }
        }
        guard !oldGroups.isEmpty, !newGroups.isEmpty,
              !hasPasteboardRow(oldGroups), !hasPasteboardRow(newGroups) else {
            groups = newGroups
            tableView.reloadData()
            return
        }

        // A collapsed section renders zero rows (`numberOfRowsInSection` returns 0 for
        // it), so its items must never generate row-level diff ops — an insert/delete
        // would target a row index the table doesn't currently have and crash
        // `performBatchUpdates`. Blank out a collapsed section's item ids for the diff
        // (both sides, since collapse state can't change mid-`reload()`) so it only ever
        // contributes whole-section ops, which don't reference row counts. `groups`
        // itself still keeps the real items, so expanding it later renders correctly.
        func diffModel(_ groups: [(section: Section, items: [ReadingListItem])]) -> [ReadingListGroup] {
            groups.map { group in
                ReadingListGroup(
                    section: group.section,
                    itemIDs: isCollapsed(group.section) ? [] : group.items.map(\.id))
            }
        }
        let diff = ReadingListDiff.compute(old: diffModel(oldGroups), new: diffModel(newGroups))

        guard !diff.isEmpty else {
            // Structurally unchanged, but `.readingListChanged` fired for a reason — an
            // item's CONTENT likely changed (title/thumbnail arrived, read state
            // flipped, price updated). Reconfigure every persisting row in place;
            // nothing moved, so there's nothing to animate.
            groups = newGroups
            reconfigurePersistingCells(in: diff.persistingItemIDs)
            return
        }

        tableView.performBatchUpdates { [weak self] in
            guard let self else { return }
            self.groups = newGroups
            self.tableView.deleteSections(diff.deletedSections, with: .automatic)
            self.tableView.insertSections(diff.insertedSections, with: .automatic)
            self.tableView.deleteRows(at: diff.deletedRows, with: .automatic)
            self.tableView.insertRows(at: diff.insertedRows, with: .automatic)
        } completion: { [weak self] _ in
            self?.reconfigurePersistingCells(in: diff.persistingItemIDs)
        }
    }

    /// Show a surface-specific explanation only when that surface has no rows at all.
    /// In particular, Reader's Archive remains visible instead of being obscured by an
    /// empty state. Built once and toggled rather than rebuilt every reload — the
    /// message never changes since it's derived from the fixed `surface`.
    private lazy var emptyStateView: UIView? = {
        guard let surface else { return nil }

        let message: String
        switch surface {
        case .all:
            message = "Save articles, media, and products to see them here."
        case .reader:
            message = "Save articles, documents, and links to read them here."
        case .priceTracker:
            message = "Track a product to see its price here."
        case .downloader:
            return nil
        }

        let label = UILabel()
        label.text = message
        label.font = .preferredFont(forTextStyle: .body)
        label.textColor = LunaColors.secondaryText
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = UIView()
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.layoutMarginsGuide.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: container.layoutMarginsGuide.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }()

    private func updateEmptyState() {
        tableView.backgroundView = groups.isEmpty ? emptyStateView : nil
    }

    /// Builds the non-empty grouped model (sections × items, in display order) for the
    /// current filter and store contents — the PURE model step, split out of `reload()`
    /// so a filter change can diff the old/new models and animate only the rows that
    /// actually change (see `filterChanged`). May clear a now-saved pasteboard candidate
    /// as a side effect (mirrors the old `reload`).
    private func buildGroups() -> [(section: Section, items: [ReadingListItem])] {
        buildGroups(items: store.items())
    }

    private func buildGroups(items unfiltered: [ReadingListItem]) -> [(section: Section, items: [ReadingListItem])] {
        ReadingListGroupBuilder.buildGroups(
            items: unfiltered, filter: filter, surface: surface,
            pasteboardRow: pasteboardSuggestions.currentDisplayItem(),
            now: Self.sectioningNow())
    }

    /// The filter segments currently shown, in segment order. `.all` plus
    /// whichever of Articles / Media / Price apply to the present list. The Price
    /// segment is only included when a non-archived tracker exists.
    private func visibleFilters() -> [ListFilter] {
        visibleFilters(items: store.items())
    }

    private func visibleFilters(items: [ReadingListItem]) -> [ListFilter] {
        var filters: [ListFilter] = [.all, .articles]
        if ReadingListSectioning.hasMediaAndLinks(items: items) {
            filters.append(.mediaAndLinks)
        }
        if ReadingListSectioning.hasPriceTrackers(items: items) {
            filters.append(.priceTrackers)
        }
        return filters
    }

    /// An interactive save just became a price tracker: present its editor so the
    /// user can add more store URLs (or Cancel → save it as a normal article). Only
    /// when this list is the top of its nav stack (not over a reader/other screen).
    @objc private func priceTrackerSavedInteractively(_ note: Notification) {
        guard let itemID = note.userInfo?["itemID"] as? UUID,
              presentedViewController == nil,
              navigationController?.topViewController === self else { return }
        let isMerge = (note.userInfo?["isMerge"] as? Bool) ?? false
        let highlightedURL = note.userInfo?["highlightedURL"] as? String
        ListKindSupport.product?.presentInteractiveSaveEditor(
            itemID: itemID, isMerge: isMerge, highlightedURL: highlightedURL,
            on: navigationController)
    }

    @objc private func filterChanged(_ control: LunaSegmentedControl) {
        let filters = visibleFilters()
        let index = control.selectedSegmentIndex
        filter = (index >= 0 && index < filters.count) ? filters[index] : .all

        applyFilteredGroups()
    }

    /// Swaps `groups` to the freshly-built model with a cell-level diff.
    private func applyFilteredGroups() {
        let oldGroups = groups
        let newGroups = buildGroups()

        // Reuse the table's grouped-model diff (id-keyed) to get the row/section deltas.
        let diff = ReadingListDiff.compute(
            old: oldGroups.map { ReadingListGroup(section: $0.section, itemIDs: $0.items.map(\.id)) },
            new: newGroups.map { ReadingListGroup(section: $0.section, itemIDs: $0.items.map(\.id)) })

        // Nothing changed (e.g. the same filter re-selected) ⇒ no table churn.
        if diff.isEmpty {
            groups = newGroups
            return
        }

        tableView.performBatchUpdates { [weak self] in
            guard let self else { return }
            self.groups = newGroups
            self.tableView.deleteSections(diff.deletedSections, with: .fade)
            self.tableView.insertSections(diff.insertedSections, with: .fade)
            self.tableView.deleteRows(at: diff.deletedRows, with: .fade)
            self.tableView.insertRows(at: diff.insertedRows, with: .fade)
        } completion: { [weak self] _ in
            // Reconfigure rows whose item persists in place but whose content changed
            // (state/read-state), without animating rows that did not move.
            self?.reconfigurePersistingCells(in: diff.persistingItemIDs)
        }
    }

    /// Silently re-renders any visible cell whose item id is in `ids` — a row that stayed
    /// put across the filter swap but whose content may have changed. No animation: these
    /// rows remain in place during the batch update.
    private func reconfigurePersistingCells(in ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for indexPath in tableView.indexPathsForVisibleRows ?? [] {
            let item = item(at: indexPath)
            guard ids.contains(item.id),
                  let cell = tableView.cellForRow(at: indexPath) as? ReadingListItemCell,
                  section(at: indexPath.section) != .pasteboard else { continue }
            UIView.performWithoutAnimation { configureItemCell(cell, for: item) }
        }
    }

    /// Shows the filter control only when the list has at least two of the three
    /// kinds (reader / media / price tracker); otherwise it's meaningless. Rebuilds
    /// the segments to match the kinds present and resets a now-invalid selection.
    private func updateFilterVisibility() {
        updateFilterVisibility(items: store.items())
    }

    private func updateFilterVisibility(items: [ReadingListItem]) {
        // A concrete surface is single-category, so the filter segments are meaningless —
        // never show them. Only the combined list (surface == nil) offers the filter.
        let shouldShow = surface == nil
            && ReadingListSectioning.shouldShowFilter(items: items)
        guard shouldShow else {
            if filter != .all { filter = .all }
            if filterRowVisible {
                filterRowVisible = false
                rebuildTableHeader(showsFilter: false)
            } else if tableHeaderContainer == nil {
                rebuildTableHeader(showsFilter: false)
            }
            return
        }

        let filters = visibleFilters(items: items)
        // A selected filter no longer offered (its kind vanished) resets to All.
        if !filters.contains(filter) { filter = .all }

        filterControl.removeAllSegments()
        for (index, option) in filters.enumerated() {
            filterControl.insertSegment(withTitle: option.displayName, at: index, animated: false)
        }
        filterControl.selectedSegmentIndex = filters.firstIndex(of: filter) ?? 0
        measureFilterNaturalWidth()

        // Always keep the large-title row; include the filter row.
        if !filterRowVisible || tableHeaderContainer == nil {
            filterRowVisible = true
            rebuildTableHeader(showsFilter: true)
        }
    }

    /// Measures the segmented control's *actual* content width (with the width
    /// constraint temporarily off so it doesn't dominate the measurement) and caches
    /// it. Call only when the segments change — not every layout pass. We measure
    /// rather than estimate per-segment padding: the old estimate undershot for four
    /// content-sized segments, so the control overflowed the viewport-sized constraint
    /// and clipped on the right instead of scrolling.
    private func measureFilterNaturalWidth() {
        guard let widthConstraint = filterWidthConstraint else { return }
        let wasActive = widthConstraint.isActive
        widthConstraint.isActive = false
        filterNaturalWidth = ceil(
            filterControl.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width)
        widthConstraint.isActive = wasActive
        applyFilterWidth()
    }

    /// Sizes the control to max(viewport, natural): it fills when the row fits and
    /// scrolls when it doesn't. Cheap — only reassigns the constant when it actually
    /// changes, so it doesn't thrash layout on every `viewDidLayoutSubviews`.
    private func applyFilterWidth() {
        guard let widthConstraint = filterWidthConstraint else { return }
        let target = max(max(0, tableView.bounds.width - 32), filterNaturalWidth)
        if abs(widthConstraint.constant - target) > 0.5 { widthConstraint.constant = target }
    }

    @objc private func pulledToRefresh() {
        ReadingListIngestor.shared.ingestAllPending()
        ListKindSupport.article?.retryPendingSends()
        Task { await IncomingMailImporter.shared.importNewMail() }
        reload()
        refreshControl?.endRefreshing()
    }

    @objc func friendsTapped() {
        navigationController?.pushViewController(FriendsViewController(), animated: true)
    }

    override func scrollViewDidScroll(_ scrollView: UIScrollView) {
        header.updateScrolledAppearance(
            contentOffsetY: scrollView.contentOffset.y,
            adjustedTopInset: scrollView.adjustedContentInset.top)
    }

    // MARK: - Header controls

    /// The normal (non-editing) header: settings + friends (leading); add
    /// (trailing) in the pinned bar. The large "Reading List" title lives on the
    /// scrolling title row of the table header (`makeTableHeader`).
    private func setDefaultHeaderControls() {
        var leading = [
            NavHeaderBar.imageButton(
                systemName: "gearshape", target: self, action: #selector(settingsTapped),
                accessibilityLabel: "Settings"),
        ]
        // Friends / email sharing is available in all three apps.
        leading.append(NavHeaderBar.imageButton(
            systemName: "person.2", target: self, action: #selector(friendsTapped),
            accessibilityLabel: "Contacts"))
        header.setLeadingControls(leading)
        header.setTrailingControls([
            NavHeaderBar.imageButton(
                systemName: "plus", target: self, action: #selector(addTapped),
                accessibilityLabel: "Add"),
        ])
    }

    /// Builds the scrolling table-header content: the large "Reading List" title row
    /// — and, when applicable, the Articles / Media / Price filter row beneath it.
    /// Sized to fit and assigned as the `tableHeaderView` so it scrolls away under
    /// the pinned bar like a system large title. `showsFilter` includes the filter
    /// row.
    private func rebuildTableHeader(showsFilter: Bool) {
        guard showsLargeListHeader || showsFilter else {
            tableHeaderContainer = nil
            tableView.tableHeaderView = nil
            return
        }
        // A `tableHeaderView` is sized by its FRAME (set explicitly at the bottom of this
        // method), so the container must keep `translatesAutoresizingMaskIntoConstraints`
        // = true. With it false, UITableView auto-layouts the header and — lacking a width
        // constraint — collapses it to its compressed content width (~32pt), clipping the
        // title + filter. Its internal subview constraints still resolve against the frame.
        let container = UIView()

        var bottomAnchor = container.topAnchor
        if showsLargeListHeader {
            let titleRow = UIView()
            titleRow.translatesAutoresizingMaskIntoConstraints = false
            largeTitleLabel.text = "Reading List"
            largeTitleLabel.font = .systemFont(ofSize: 34, weight: .bold)
            largeTitleLabel.textColor = LunaColors.primaryText
            largeTitleLabel.adjustsFontForContentSizeCategory = true
            largeTitleLabel.translatesAutoresizingMaskIntoConstraints = false
            titleRow.addSubview(largeTitleLabel)
            container.addSubview(titleRow)

            NSLayoutConstraint.activate([
                titleRow.topAnchor.constraint(equalTo: container.topAnchor),
                titleRow.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                titleRow.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                titleRow.heightAnchor.constraint(equalToConstant: 52),
                largeTitleLabel.leadingAnchor.constraint(equalTo: titleRow.leadingAnchor, constant: 20),
                largeTitleLabel.bottomAnchor.constraint(equalTo: titleRow.bottomAnchor, constant: -6),
            ])
            bottomAnchor = titleRow.bottomAnchor
        }
        if showsFilter, let filterRow = filterHeaderView {
            filterRow.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(filterRow)
            NSLayoutConstraint.activate([
                filterRow.topAnchor.constraint(equalTo: bottomAnchor),
                filterRow.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                filterRow.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                filterRow.heightAnchor.constraint(equalToConstant: 44),
            ])
            bottomAnchor = filterRow.bottomAnchor
        }
        container.bottomAnchor.constraint(equalTo: bottomAnchor).isActive = true

        // Size the header to fit at the table's width and assign it (table header views
        // are laid out by their frame, so resolve the height explicitly).
        let width = max(tableView.bounds.width, 1)
        container.frame = CGRect(x: 0, y: 0, width: width, height: 0)
        let height = container.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel).height
        container.frame = CGRect(x: 0, y: 0, width: width, height: height)
        tableHeaderContainer = container
        tableView.tableHeaderView = container
        applyFilterWidth()
    }

    @objc private func doneEditing() { setEditing(false, animated: true) }

    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        tableView.dragInteractionEnabled = editing
        if isEditing {
            header.setLeadingControls([])
            // Visually (right→left): Done, Select All, Delete Selected. The trailing
            // stack lays left→right, so order it Delete, Select All, Done.
            header.setTrailingControls([
                NavHeaderBar.imageButton(
                    systemName: "trash", target: self, action: #selector(deleteSelectedTapped),
                    tint: .systemRed, accessibilityLabel: "Delete Selected"),
                NavHeaderBar.textButton(
                    title: "Select All", target: self, action: #selector(selectAllTapped)),
                NavHeaderBar.textButton(
                    title: "Done", target: self, action: #selector(doneEditing), bold: true),
            ])
        } else {
            setDefaultHeaderControls()
        }
    }

    @objc private func selectAllTapped() {
        for section in 0..<tableView.numberOfSections {
            for row in 0..<tableView.numberOfRows(inSection: section) {
                let indexPath = IndexPath(row: row, section: section)
                guard tableView(tableView, canEditRowAt: indexPath) else { continue }
                tableView.selectRow(at: indexPath, animated: false, scrollPosition: .none)
            }
        }
    }

    @objc private func deleteSelectedTapped() {
        guard let selected = tableView.indexPathsForSelectedRows, !selected.isEmpty else { return }
        let items = selected.map { item(at: $0) }   // capture before any mutation
        // One coordinated store cycle + one notification for the whole batch,
        // instead of N per-item deletes.
        store.deleteItems(ids: Set(items.map(\.id)))
        setEditing(false, animated: true)
    }

    // MARK: - Add

    @objc private func addTapped() {
        let alert = UIAlertController(
            title: "Save a Link", message: nil, preferredStyle: .alert)
        // Prefill from the already-evaluated pasteboard suggestion, never from a
        // live `UIPasteboard` read: that read is synchronous cross-process IPC and
        // raises the system paste banner, stalling the tap before the present
        // animation can start.
        let prefill = pasteboardSuggestions.pasteboardCandidate?.urlString
        alert.addTextField { field in
            field.placeholder = "https://…"
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.text = prefill
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak alert] _ in
            guard let entered = alert?.textFields?.first?.text?
                .trimmingCharacters(in: .whitespacesAndNewlines), !entered.isEmpty
            else { return }
            guard let normalized = Self.normalizedTypedURL(entered) else { return }
            Task { await ReadingListIngestor.shared.handleSavePress(urlString: normalized) }
        })
        present(alert, animated: true)
    }

    /// Validates a typed/pasted URL string before saving, replacing the old blind
    /// `https://` prefix (which mangled `mailto:`/`tel:`/bare words into
    /// `https://mailto:…`). Accepts an `http(s)` URL as-is; bare-prefixes `https://`
    /// ONLY when the entry has no scheme but looks like a host (contains a dot, no
    /// spaces); rejects everything else (a non-http scheme or junk) with nil.
    static func normalizedTypedURL(_ entered: String) -> String? {
        URLUnwrapper.ingestURL(from: entered, allowBareHost: true)?.absoluteString
    }

    @objc func settingsTapped() {
        navigationController?.pushViewController(SettingsViewController(), animated: true)
    }

    @objc private func deleteAllArchiveTapped(_ sender: UIButton) {
        let archived = groups.first { $0.section == .archive }?.items ?? []
        guard !archived.isEmpty else { return }
        let alert = UIAlertController(
            title: "Delete \(archived.count) archived item\(archived.count == 1 ? "" : "s")?",
            message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Delete All", style: .destructive) { [weak self] _ in
            self?.store.deleteItems(ids: Set(archived.map(\.id)))
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        // Anchor the sheet: all targets build for iPad too, where an
        // unanchored action sheet raises NSGenericException.
        alert.popoverPresentationController?.sourceView = sender
        alert.popoverPresentationController?.sourceRect = sender.bounds
        present(alert, animated: true)
    }

    // MARK: - Delete

    /// Removes one item with an animated row (or section) deletion instead of a
    /// full `reloadData`, so the row fades out smoothly. The triggering row is
    /// always in an expanded section (collapsed sections show no cells to
    /// long-press), so an in-place `deleteRows` is safe.
    private func deleteItemAnimated(_ item: ReadingListItem) {
        guard let sectionIndex = groups.firstIndex(where: {
            $0.items.contains(where: { $0.id == item.id })
        }), let rowIndex = groups[sectionIndex].items.firstIndex(where: { $0.id == item.id }),
            !isCollapsed(groups[sectionIndex].section) else {
            store.delete(item) // fall back to the notification-driven reload
            return
        }

        isAnimatingRowChange = true
        store.delete(item)
        groups[sectionIndex].items.remove(at: rowIndex)
        tableView.performBatchUpdates {
            if groups[sectionIndex].items.isEmpty {
                groups.remove(at: sectionIndex)
                tableView.deleteSections(IndexSet(integer: sectionIndex), with: .automatic)
            } else {
                tableView.deleteRows(
                    at: [IndexPath(row: rowIndex, section: sectionIndex)], with: .automatic)
            }
        } completion: { [weak self] _ in
            self?.isAnimatingRowChange = false
            // A delete can change whether the Articles / Media & Links filter applies
            // (a notification-driven update that a swallowed `.readingListChanged` —
            // suppressed above while isAnimatingRowChange was true — would otherwise
            // have applied).
            self?.updateFilterVisibility()
        }
    }

    // MARK: - Section / collapse helpers

    private func section(at index: Int) -> Section { groups[index].section }

    private func isCollapsed(_ section: Section) -> Bool {
        section.isCollapsible && collapsedSections.contains(section)
    }

    @objc private func headerTapped(_ gesture: UITapGestureRecognizer) {
        guard let raw = gesture.view?.tag, let section = Section(rawValue: raw),
              section.isCollapsible,
              let index = groups.firstIndex(where: { $0.section == section })
        else { return }
        var collapsed = collapsedSections
        if collapsed.contains(section) { collapsed.remove(section) } else { collapsed.insert(section) }
        collapsedSections = collapsed
        tableView.reloadSections(IndexSet(integer: index), with: .automatic)
    }

    // MARK: - Table

    private func item(at indexPath: IndexPath) -> ReadingListItem {
        groups[indexPath.section].items[indexPath.row]
    }

    override func numberOfSections(in tableView: UITableView) -> Int { groups.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        let group = groups[section]
        return isCollapsed(group.section) ? 0 : group.items.count
    }

    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let group = groups[section]
        let kind = group.section
        guard !hidesHeader(for: kind) else { return nil }

        let header = UIView()
        header.tag = kind.rawValue

        // The error section is tinted red to flag it; the rest are muted.
        let headerColor: UIColor = kind == .error ? .systemRed : LunaColors.secondaryText

        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .headline)
        label.textColor = headerColor
        label.translatesAutoresizingMaskIntoConstraints = false

        if kind.isCollapsible {
            let collapsed = isCollapsed(kind)
            let chevron = collapsed ? "chevron.right" : "chevron.down"
            let glyph = NSTextAttachment()
            glyph.image = UIImage(systemName: chevron)?
                .withConfiguration(UIImage.SymbolConfiguration(textStyle: .caption1))
                .withTintColor(headerColor, renderingMode: .alwaysOriginal)
            let title = NSMutableAttributedString(attachment: glyph)
            title.append(NSAttributedString(string: "  \(kind.title) (\(group.items.count))"))
            label.attributedText = title

            let tap = UITapGestureRecognizer(target: self, action: #selector(headerTapped(_:)))
            header.addGestureRecognizer(tap)
        } else {
            label.text = kind.title
        }

        header.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 20),
            label.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])

        if kind == .archive {
            let deleteButton = UIButton(type: .system)
            deleteButton.setTitle("Delete All", for: .normal)
            deleteButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
            deleteButton.tintColor = .systemRed
            deleteButton.addTarget(self, action: #selector(deleteAllArchiveTapped), for: .touchUpInside)
            deleteButton.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(deleteButton)
            NSLayoutConstraint.activate([
                deleteButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -20),
                deleteButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            ])
        }
        return header
    }

    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        hidesHeader(for: groups[section].section) ? .leastNormalMagnitude : 44
    }

    override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: ReadingListItemCell.reuseID, for: indexPath) as? ReadingListItemCell
            ?? ReadingListItemCell(style: .default, reuseIdentifier: ReadingListItemCell.reuseID)
        let item = item(at: indexPath)
        let isPasteboard = section(at: indexPath.section) == .pasteboard

        let titleColor: UIColor = item.state == .failed
            ? .systemRed
            : (item.readState == .unopened ? LunaColors.primaryText : LunaColors.secondaryText)

        if isPasteboard {
            // Spinner while evaluating; the candidate's preview thumbnail once
            // ready. A trailing Save button saves explicitly (tap just previews).
            let thumbnail: ReadingListItemCell.Thumbnail
            if let candidate = pasteboardSuggestions.pasteboardCandidate {
                if candidate.requiresUnlock, let image = candidate.thumbnail {
                    thumbnail = .lockedImage(image)
                } else if candidate.requiresUnlock {
                    thumbnail = .logo(assetName: nil, glyph: "lock.fill")
                } else if let image = candidate.thumbnail {
                    thumbnail = .image(image)
                } else if let platform = candidate.platform,
                        let logo = ListKindSupport.media?.logoThumbnail(for: platform) {
                    thumbnail = logo
                } else { thumbnail = .none }
            } else {
                thumbnail = .loading
            }
            cell.configure(
                title: item.title ?? item.urlString, titleColor: titleColor,
                subtitle: secondaryText(for: item), thumbnail: thumbnail,
                showsDisclosure: false,
                reuseKey: "pasteboard|\(item.urlString)|\(pasteboardSuggestions.pasteboardCandidate == nil)",
                trailingButtonSymbol: pasteboardSuggestions.pasteboardCandidate == nil ? nil : "plus.circle.fill",
                onTrailingButton: pasteboardSuggestions.pasteboardCandidate == nil ? nil : { [weak self] in
                    self?.pasteboardSuggestions.save()
                })
            cell.showsReorderControl = false
            return cell
        }

        configureItemCell(cell, for: item)
        // The simulator-only row-actions tap target overlays the leading edge of
        // thumbnail-less rows; suppress it during deterministic screenshot captures
        // so it never obscures real content. Interactive automation runs (no harness
        // launch arg) still get it.
        if AppEnvironment.isSimulator && !UITestSeeder.isUITestLaunch {
            cell.setSimulatorMenu(rowMenu(for: item, at: indexPath))
        }
        return cell
    }

    /// Configures a row cell for `item`.
    private func configureItemCell(_ cell: ReadingListItemCell, for item: ReadingListItem) {
        if let tracker = item.priceTracker {
            configurePriceTrackerCell(cell, item: item, tracker: tracker)
            return
        }
        let titleColor: UIColor = item.state == .failed
            ? .systemRed
            : (item.readState == .unopened ? LunaColors.primaryText : LunaColors.secondaryText)
        cell.configure(
            title: item.title ?? item.urlString,
            titleColor: titleColor,
            subtitle: secondaryText(for: item),
            thumbnail: thumbnail(for: item, isPasteboard: false),
            showsDisclosure: item.state == .ready,
            reuseKey: "\(item.id.uuidString)|\(item.thumbnailFileName ?? "")|\(item.state.rawValue)")
        cell.showsReorderControl = false   // reorder is drag-anywhere in edit mode, no handle
    }

    /// Price-tracker rows get their own rendering: product thumbnail, product
    /// name title, and a current-best-price subtitle. An alerting tracker (price
    /// dropped past threshold) is badged red with the discount.
    private func configurePriceTrackerCell(
        _ cell: ReadingListItemCell, item: ReadingListItem, tracker: PriceTracker
    ) {
        let alerting = tracker.isAlerting
        let priceText = PriceFormatting.string(
            amount: tracker.currentBestPrice, currency: tracker.displayCurrency)

        let baseColor: UIColor = alerting ? .systemRed : LunaColors.secondaryText
        let subtitle = NSMutableAttributedString(
            string: priceText, attributes: [.foregroundColor: baseColor])
        if alerting {
            let percent = Int((tracker.discountFraction * 100).rounded())
            subtitle.append(NSAttributedString(
                string: "  ↓\(percent)%",
                attributes: [.foregroundColor: UIColor.systemRed]))
        }

        // `.art(path:)` decodes downsampled off the main thread (with an
        // NSCache-backed synchronous path on a re-seen row) instead of the
        // full-size, main-thread `Data(contentsOf:)` + `UIImage(data:)` decode
        // this used to do per cell.
        let thumbnail: ReadingListItemCell.Thumbnail
        if let fileName = tracker.imageFileName {
            thumbnail = .art(path: store.articlesDirectory.appendingPathComponent(fileName).path)
        } else {
            thumbnail = .logo(assetName: nil, glyph: alerting ? "tag.fill" : "tag")
        }

        cell.configure(
            title: tracker.productName,
            titleColor: alerting ? .systemRed : LunaColors.primaryText,
            subtitle: subtitle,
            thumbnail: thumbnail,
            showsDisclosure: true,
            reuseKey: "pt|\(item.id.uuidString)|\(priceText)|\(alerting)")
        cell.showsReorderControl = false
    }

    /// Builds the grey metadata line, with the "from <friend>" attribution in
    /// the accent color so social shares stand out.
    private func secondaryText(for item: ReadingListItem) -> NSAttributedString {
        let baseColor: UIColor = item.readState == .unopened ? LunaColors.secondaryText : LunaColors.tertiaryText
        let host = item.url?.host ?? ""
        // Platform items show a logical container, never the bare host.
        let leadingLabel: String
        if let platform = item.contentPlatform {
            leadingLabel = ListKindSupport.media?.subtitleLeadingLabel(for: item)
                ?? platform.displayName
        } else if item.isDocument {
            leadingLabel = item.documentType?.uppercased() ?? "Document"
        } else {
            leadingLabel = item.channelName ?? host
        }
        let parts = ReadingListSubtitle.parts(
            for: item,
            leadingLabel: leadingLabel,
            formattedDate: dateFormatter.string(from: item.dateAdded),
            showReadingTime: ListKindSupport.article?.showsReadingTime ?? false,
            showReadingProgress: ListKindSupport.article?.showsReadingProgress ?? false,
            isRescuing: URLRescueCoordinator.shared.isRescuing(item.id))

        let result = NSMutableAttributedString(
            string: parts.joined(separator: " · "),
            attributes: [.foregroundColor: baseColor])
        if let sharedBy = item.sharedByUsername {
            if !result.string.isEmpty {
                result.append(NSAttributedString(
                    string: " · ", attributes: [.foregroundColor: baseColor]))
            }
            result.append(NSAttributedString(
                string: "from \(sharedBy)",
                attributes: [.foregroundColor: view.tintColor ?? .systemBlue]))
        }
        return result
    }

    /// Offers a one-shot URL-rescue with a hint picker for a `.failed` row. The
    /// surface's natural hint is listed first. Each action bypasses the auto-rescue
    /// toggle + attempt budget (a deliberate user request).
    private func presentRescueSheet(for item: ReadingListItem, presenter: UIViewController) {
        let alert = UIAlertController(
            title: "Couldn't load this page",
            message: "Luna can try harder with Apple Intelligence. Choose what this save should become.",
            preferredStyle: .actionSheet)
        let defaultHint = URLRescueWiring.defaultHint(for: AppSurfaceConfig.current)
        let ordered = [defaultHint] + RescueHint.allCases.filter { $0 != defaultHint }
        for hint in ordered {
            alert.addAction(UIAlertAction(title: "Rescue as \(hint.displayName)", style: .default) { _ in
                URLRescueCoordinator.shared.requestManualRescue(itemID: item.id, hint: hint)
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY,
                                        width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        presenter.present(alert, animated: true)
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        // In edit mode a tap toggles the selection radio (UIKit handles it) — don't
        // open the row or clear the selection.
        if isEditing { return }
        tableView.deselectRow(at: indexPath, animated: true)
        if section(at: indexPath.section) == .pasteboard {
            pasteboardSuggestions.preview()
            return
        }
        open(item(at: indexPath), presenter: self, transitionSourceView: tableView.cellForRow(at: indexPath))
    }

    /// Opens an item presenting from `presenter` (the reading list): platform/video/
    /// media via `openItem`, a hard-paywalled article via the archive web view, else
    /// the in-app reader pushed on `presenter`'s nav.
    func open(
        _ item: ReadingListItem,
        presenter: UIViewController,
        transitionSourceView: UIView? = nil
    ) {
        if item.isPriceTracker {
            // Opening an alerting tracker acknowledges its alert, so the row stops
            // floating to the top of the list and rejoins the price-tracking section.
            if var tracker = item.priceTracker, tracker.hasUnviewedAlert {
                tracker.markAlertViewed()
                store.updatePriceTracker(tracker, for: item.id)
            }
            ListKindSupport.product?.openTracker(itemID: item.id, on: presenter.navigationController)
            return
        }
        if openItem(item, presentingFrom: presenter) { return }
        // A hard-paywalled article whose archive snapshot needs a CAPTCHA: open the
        // archive.today snapshot in our WKWebView archive reader. It shows the
        // Cloudflare CAPTCHA for the user to solve, then — crucially — reads its OWN
        // DOM to extract the article and reopen it in the native reader (something
        // SFSafariViewController can't do: the host app can't read its content).
        // Real Safari is kept as an escape-hatch button for the rare case the
        // embedded web view can't clear the gate.
        if item.state == .needsCaptcha, let url = item.url,
           let article = ListKindSupport.article {
            article.presentArchiveUnlock(
                item: item, articleURL: url, presenter: presenter
            ) { [weak self] fresh, presenter in
                self?.open(fresh, presenter: presenter)   // now .ready → native reader
            }
            store.markReadState(.opened, for: item.id)
            return
        }
        // A failed save can be rescued with Apple Intelligence: offer a one-shot
        // opt-in with a hint picker (works regardless of the auto-rescue toggle —
        // the tap IS the consent). Only when a model is actually usable; otherwise
        // fall through to today's no-op tap.
        if item.state == .failed, URLRescueCoordinator.engine?.isAvailable() == true {
            presentRescueSheet(for: item, presenter: presenter)
            return
        }
        guard item.state == .ready, let content = store.content(for: item),
              let article = ListKindSupport.article else { return }
        // The eclipse transition is intentionally available only from a real Reader
        // list-row tap. Other readers (deep links, the two sibling apps) retain their
        // existing navigation treatment.
        article.openArticle(
            item, content: content, presenter: presenter,
            transitionSourceView: surface == .reader ? transitionSourceView : nil)
    }

    /// Opens a non-article item (video / platform post) the way
    /// tapping its row does, presenting any in-app viewer from `presenter`. Returns
    /// false for reader articles, so the caller can render those itself.
    @discardableResult
    func openItem(_ item: ReadingListItem, presentingFrom presenter: UIViewController) -> Bool {
        if let platform = item.contentPlatform {
            ListKindSupport.media?.openPlatformItem(item, platform: platform, from: presenter)
            return true
        }
        return false
    }

    /// Sends any reading-list item (article, media, or price tracker) to chosen
    /// recipients as a Luna email.
    private func presentSend(_ item: ReadingListItem) {
        SendToFriendSheet.present(
            from: self, item: item,
            urlString: item.urlString, title: item.title)
    }

    /// The thumbnail state for a row: cached art (aspect-fit) when present, a
    /// spinner while the item is still being fetched, or the platform-logo
    /// fallback once the fetch finished with no image. The pasteboard suggestion
    /// is transient (never ingesting) so it never spins.
    private func thumbnail(
        for item: ReadingListItem, isPasteboard: Bool
    ) -> ReadingListItemCell.Thumbnail {
        if let fileName = item.thumbnailFileName {
            let path = store.articlesDirectory.appendingPathComponent(fileName).path
            return item.state == .needsCaptcha ? .lockedArt(path: path) : .art(path: path)
        }
        // A paywalled article awaiting a user-solved CAPTCHA isn't fetching — show a
        // lock to signal it needs a tap to unlock, not a spinner.
        if item.state == .needsCaptcha {
            return .logo(assetName: nil, glyph: "lock.fill")
        }
        let fetchFinished = isPasteboard || item.state == .ready || item.state == .failed

        if let platform = item.contentPlatform,
           let logo = ListKindSupport.media?.logoThumbnail(for: platform) {
            return fetchFinished ? logo : .loading
        }
        // Plain article/document: a cover image may still be downloading. Spin
        // while pending; show nothing once finished without one.
        return fetchFinished ? .none : .loading
    }

    // MARK: - Editing rows

    /// No delete badge — the multi-select radio (left) handles selection in edit
    /// mode, and reorder is drag-and-drop (no handle).
    override func tableView(
        _ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath
    ) -> UITableViewCell.EditingStyle {
        .none
    }

    /// The pasteboard suggestion isn't a saved item — not selectable/deletable.
    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        section(at: indexPath.section) != .pasteboard
    }

    // MARK: - Long-press menu

    override func tableView(
        _ tableView: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        // The pasteboard suggestion isn't saved yet — no row actions apply.
        guard section(at: indexPath.section) != .pasteboard else { return nil }
        // Drop any action stranded by a menu that didn't route through this table's
        // dismissal (the simulator-only button menu), so it can't drain out of turn.
        pendingContextMenuAction = nil
        let item = item(at: indexPath)
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            self?.rowMenu(for: item, at: indexPath)
        })
    }

    override func tableView(
        _ tableView: UITableView,
        willEndContextMenuInteraction configuration: UIContextMenuConfiguration,
        animator: (any UIContextMenuInteractionAnimating)?
    ) {
        // Drain any presenting action AFTER the menu's dismissal animation finishes,
        // so its transition never overlaps the collapsing menu. Read the closure at
        // completion time (not now): the selected action's handler may run either side
        // of this call, but always before the animator completes. A dismissal with no
        // selection leaves `pendingContextMenuAction` nil, so this is a no-op.
        let drain = { [weak self] in
            guard let action = self?.pendingContextMenuAction else { return }
            self?.pendingContextMenuAction = nil
            action()
        }
        if let animator {
            animator.addCompletion(drain)
        } else {
            DispatchQueue.main.async(execute: drain)
        }
    }

    /// Defer a row-menu action that presents UI until the menu has fully dismissed.
    /// See `pendingContextMenuAction`.
    private func afterRowMenuDismissal(_ action: @escaping () -> Void) {
        pendingContextMenuAction = action
    }

    /// Builds the long-press row menu. Also driven by a simulator-only tap button on
    /// the cell (see `cellForRowAt`) so the menu is testable without a synthesized
    /// long-press.
    private func rowMenu(for item: ReadingListItem, at indexPath: IndexPath) -> UIMenu {
        let actions = RowMenuActions(
            isInReadingSection: section(at: indexPath.section) == .reading,
            isKindleConfigured: ListKindSupport.article?.isKindleConfigured ?? false,
            canSaveMediaToPhotos: ListKindSupport.media?
                .canSaveMediaToPhotos(urlString: item.urlString) ?? false,
            sendToFriend: { [weak self] in self?.presentSend(item) },
            sendToKindle: { ListKindSupport.article?.sendToKindle(item) },
            shareEbook: { [weak self] in
                guard let self else { return }
                let sourceView = self.tableView.cellForRow(at: indexPath) ?? self.view ?? UIView()
                ListKindSupport.article?.shareEbook(item, from: self, sourceView: sourceView)
            },
            shareLink: { [weak self] in
                guard let self else { return }
                let sourceView = self.tableView.cellForRow(at: indexPath) ?? self.view ?? UIView()
                SendToFriendSheet.shareLink(
                    urlString: item.urlString,
                    sharedURLString: self.appClipShareURLString(for: item),
                    from: self, sourceView: sourceView)
            },
            copyLink: { [weak self] in
                guard let self else { return }
                // Copy immediately (works on every menu path); defer the confirmation modal
                // until the context menu has dismissed.
                SendToFriendSheet.copyToPasteboard(urlString: item.urlString)
                self.afterRowMenuDismissal { [weak self] in
                    guard let self else { return }
                    SendToFriendSheet.presentCopiedConfirmation(from: self)
                }
            },
            saveMediaToPhotos: { [weak self] in self?.saveMediaToPhotos(item) },
            bumpToTop: { [weak self] in self?.store.bump(item.id) },
            toggleTrackerArchived: { [weak self] in
                guard let self, var updated = self.store.item(withID: item.id)?.priceTracker else { return }
                updated.isArchived.toggle()
                self.store.updatePriceTracker(updated, for: item.id)
            },
            unarchive: { [weak self] in self?.store.markUnread(item.id) },
            delete: { [weak self] in self?.deleteItemAnimated(item) },
            editList: { [weak self] in self?.setEditing(true, animated: true) },
            canRescue: URLRescueCoordinator.engine?.isAvailable() == true,
            rescue: { hint in
                URLRescueCoordinator.shared.requestManualRescue(itemID: item.id, hint: hint)
            })
        return ReadingListRowMenuFactory.menu(for: item, actions: actions)
    }

    private func appClipShareURLString(for item: ReadingListItem) -> String? {
        LunaAppClipInvocationURL.shareURL(
            for: item.urlString,
            destination: item.isPlatformItem ? .downloader : .reader
        )?.absoluteString
    }

    /// Hands the post's media to the media-kind save-to-Photos flow (background
    /// live download, or the local saved-media copy on the Downloader surface),
    /// reporting through the bottom status pill.
    private func saveMediaToPhotos(_ item: ReadingListItem) {
        ListKindSupport.media?.saveMediaToPhotos(
            item, isDownloaderSurface: surface == .downloader,
            status: mediaDownloadStatusView())
    }

    /// Lazily creates the bottom status pill, pinned above the safe area.
    private func mediaDownloadStatusView() -> MediaDownloadStatusView {
        if let existing = mediaDownloadStatus { return existing }
        let status = MediaDownloadStatusView()
        view.addSubview(status)
        NSLayoutConstraint.activate([
            status.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            status.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            status.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            status.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])
        mediaDownloadStatus = status
        return status
    }

    private func presentPendingSendFailureNoticeIfNeeded() {
        presentPendingSendFailureNoticeIfNeeded(items: store.items())
    }

    private func presentPendingSendFailureNoticeIfNeeded(items: [ReadingListItem]) {
        guard viewIfLoaded?.window != nil, !isPresentingSendFailureNotice else { return }
        guard items.contains(where: {
            $0.pendingSendFailureNotices.contains(where: { $0.value })
        }) else { return }

        isPresentingSendFailureNotice = true
        let notices = store.consumePendingSendFailureNotices()
        guard let first = notices.first else {
            isPresentingSendFailureNotice = false
            return
        }
        let name = ReadingListSubtitle.destinationNames[first.destinationID] ?? first.destinationID
        let extra = notices.count > 1 ? " (+\(notices.count - 1) more)" : ""
        mediaDownloadStatusView().showResult(
            message: "Couldn't send to \(name)\(extra)",
            success: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in
            self?.isPresentingSendFailureNotice = false
            self?.presentPendingSendFailureNoticeIfNeeded()
        }
    }

}

// MARK: - External open (deep link / notification route)

extension ReadingListViewController: ExternalItemOpening {
    func openExternally(_ item: ReadingListItem) {
        open(item, presenter: self)
    }
}

// MARK: - Pasteboard suggestion delegate

extension ReadingListViewController: PasteboardSuggestionControllerDelegate {

    func pasteboardSuggestionDidChange(_ controller: PasteboardSuggestionController) {
        reload()
    }

    func pasteboardSuggestion(
        _ controller: PasteboardSuggestionController,
        openTransient item: ReadingListItem, for candidate: PasteboardCandidate
    ) {
        if let platform = candidate.platform {
            ListKindSupport.media?.openPlatformItem(item, platform: platform, from: self)
        } else if let content = candidate.content {
            ListKindSupport.article?.openTransientArticle(
                item: item, content: content, on: navigationController)
        }
    }

    func pasteboardSuggestion(_ controller: PasteboardSuggestionController, openSaved item: ReadingListItem) {
        open(item, presenter: self)
    }
}

// MARK: - Drag-and-drop reorder (edit mode, Reading section)

/// In edit mode, a long-press on any Reading row starts a drag (no handle) and the
/// drop reorders within the Reading section, persisting the new order.
extension ReadingListViewController: UITableViewDragDelegate, UITableViewDropDelegate {

    func tableView(
        _ tableView: UITableView, itemsForBeginning session: UIDragSession, at indexPath: IndexPath
    ) -> [UIDragItem] {
        guard isEditing, section(at: indexPath.section) == .reading else { return [] }
        let dragged = item(at: indexPath)
        let item = UIDragItem(itemProvider: NSItemProvider())
        item.localObject = dragged.id
        return [item]
    }

    func tableView(
        _ tableView: UITableView, dropSessionDidUpdate session: UIDropSession,
        withDestinationIndexPath destinationIndexPath: IndexPath?
    ) -> UITableViewDropProposal {
        guard isEditing, session.localDragSession != nil,
              let destination = destinationIndexPath, section(at: destination.section) == .reading
        else { return UITableViewDropProposal(operation: .cancel) }
        return UITableViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
    }

    func tableView(_ tableView: UITableView, performDropWith coordinator: UITableViewDropCoordinator) {
        guard let dropItem = coordinator.items.first,
              let source = dropItem.sourceIndexPath,
              let groupIndex = groups.firstIndex(where: { $0.section == .reading })
        else { return }
        var reading = groups[groupIndex].items
        let readingCount = reading.count
        let destination = coordinator.destinationIndexPath
            ?? IndexPath(row: readingCount - 1, section: source.section)
        let moved = reading.remove(at: source.row)
        let destinationRow = min(max(destination.row, 0), reading.count)
        reading.insert(moved, at: destinationRow)
        groups[groupIndex].items = reading

        // Persist the full order; suppress the reload this triggers so the drop
        // animation finishes cleanly.
        isApplyingReorder = true
        store.setOrder(groups.flatMap(\.items).map(\.id))
        let destinationPath = IndexPath(row: destinationRow, section: source.section)
        tableView.performBatchUpdates {
            tableView.deleteRows(at: [source], with: .automatic)
            tableView.insertRows(at: [destinationPath], with: .automatic)
        }
        coordinator.drop(dropItem.dragItem, toRowAt: destinationPath)
        DispatchQueue.main.async { [weak self] in self?.isApplyingReorder = false }
    }
}

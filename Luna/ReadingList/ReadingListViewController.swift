//
//  ReadingListViewController.swift
//  Luna
//

import LunaReadingListUI
import LunaSocialUI
import LunaReadingList
import LunaMailAccount
import LunaYouTubeAPI
import LunaPriceUI
import LunaReaderUI
import LunaArchiveReader
import LunaSocial
import LunaTransitions
import LunaMediaDownload
import LunaPlatforms
import LunaDesignSystem
import LunaSend
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

    init(surface: AppSurface? = nil) {
        self.surface = surface
        super.init(style: .insetGrouped)
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

    /// Top-to-bottom display order: a pasteboard suggestion sits above the list,
    /// failed items in a collapsible section at the very bottom.
    private static let displayOrder: [Section] = ReadingListSectioning.displayOrder

    /// Whether the item opens in the text reader (articles, documents, emails), as
    /// opposed to media & links (YouTube, platform posts, music/podcasts) which open
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

    /// A readable URL found on the system pasteboard, shown as a one-tap "From
    /// Pasteboard" row until saved. nil when there's nothing to suggest.
    private var pasteboardCandidate: PasteboardCandidate?
    /// While set, the pasteboard URL whose preview is still being fetched — the
    /// row shows a spinner until the candidate (or nil) resolves.
    private var evaluatingPasteboardURL: String?
    /// The pasteboard `changeCount` last evaluated, so we only read its contents
    /// (which shows the system paste banner) when it has actually changed.
    private var lastCheckedPasteboardChangeCount = -1

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
    /// UINavigationController nav bar) pinned to the visible top of the table, so it's
    /// captured by the Dot Matrix push/pop wipe like the rest of the content. Holds the
    /// settings/friends (leading) + add/search (trailing) controls; in edit mode it
    /// swaps to Done / Select All / Delete.
    private let header = NavHeaderBar()

    /// The scrolling large-title row ("Reading List" + catch-up button), sitting at the
    /// top of the table's content so it scrolls away under the pinned bar just like a
    /// system large title. Combined with the filter control into the table header view.
    private let largeTitleLabel = UILabel()

    /// Non-blocking bottom pill for media-download progress/result (created lazily).
    private weak var mediaDownloadStatus: MediaDownloadStatusView?
    private var isPresentingSendFailureNotice = false

    /// The "catch up" button, on the large-title row; its red dot badge shows when there
    /// are unread items to catch up on.
    private let catchUpButton = UIButton(type: .system)
    /// The in-place search overlay cross-faded over the list, if active. Held
    /// strongly: its view is hosted directly in the nav controller's view WITHOUT
    /// VC containment — calling `addChild` on a UINavigationController corrupts its
    /// `children`/stack and makes the list show a back button on return.
    private var searchController: SearchViewController?
    private let catchUpBadge = UIView()

    /// Non-empty groups in display order; rebuilt on every `reload`.
    private var groups: [(section: Section, items: [ReadingListItem])] = []

    /// Set while persisting a manual reorder so the resulting
    /// `.readingListChanged` notification doesn't reload the table mid-drop
    /// (which mangles the layout).
    private var isApplyingReorder = false
    /// True while an animated single-row delete runs, so the `.readingListChanged`
    /// notification doesn't full-reload mid-animation (which kills the fade).
    private var isAnimatingRowChange = false

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
        configureCatchUpButton()
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
            self, selector: #selector(reload), name: .readingListChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(checkPasteboard),
            name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(priceTrackerSavedInteractively(_:)),
            name: .priceTrackerSavedInteractively, object: nil)
        reload()
        checkPasteboard()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The list now draws its OWN in-content header (pinned bar + scrolling large
        // title), captured by the Dot Matrix wipe — so keep the shared nav bar hidden.
        // Readers/pushed screens also hide it; this re-asserts it on every appearance
        // (the custom Dot Matrix pop runs viewWillAppear, so this is reliable).
        navigationController?.setNavigationBarHidden(true, animated: false)
        // The catch-up button's top inset must clear the pinned bar.
        updateHeaderInsets()
        catchUpButton.isHidden = isEditing
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

    /// If the pasteboard holds a new URL with extractable content, surface it as
    /// the top "From Pasteboard" row. Gated on `changeCount` so the system paste
    /// banner shows at most once per newly copied URL.
    @objc private func checkPasteboard() {
        let pasteboard = UIPasteboard.general
        guard pasteboard.changeCount != lastCheckedPasteboardChangeCount else { return }
        lastCheckedPasteboardChangeCount = pasteboard.changeCount

        guard pasteboard.hasURLs, let url = pasteboard.url else {
            // Pasteboard changed to something with no URL — drop any stale row.
            dropPasteboardRow()
            return
        }
        // A non-ingestable or already-saved copy also invalidates whatever the
        // row was showing — the pasteboard no longer holds that URL.
        guard let normalizedURL = URLUnwrapper.ingestURL(from: url.absoluteString) else {
            dropPasteboardRow()
            return
        }
        let urlString = normalizedURL.absoluteString
        guard store.item(forURLString: urlString) == nil else {
            dropPasteboardRow()
            return
        }
        // Show a spinner row immediately, then fill it in once the preview
        // (content + thumbnail) resolves.
        pasteboardCandidate = nil
        evaluatingPasteboardURL = urlString
        reload()
        Task { [weak self] in
            let candidate = await PasteboardSuggester.shared.evaluate(urlString: urlString)
            await MainActor.run {
                guard let self, self.evaluatingPasteboardURL == urlString else { return }
                self.evaluatingPasteboardURL = nil
                // Only suggest what THIS app's surface can show: saving an
                // article from the Price Tracker app would store it fine but
                // make it vanish from this list — a save that looks discarded.
                self.pasteboardCandidate = candidate.flatMap {
                    self.surfaceAllows($0) ? $0 : nil
                }
                self.reload()
            }
        }
    }

    /// Whether a saved `candidate` would actually appear on this app's surface.
    /// The combined list (surface == nil) shows everything.
    private func surfaceAllows(_ candidate: PasteboardCandidate) -> Bool {
        guard let surface else { return true }
        switch surface {
        case .reader: return !candidate.isVideo && candidate.platform == nil
        case .downloader: return candidate.isVideo || candidate.platform != nil
        case .priceTracker: return false // the suggester never detects products
        }
    }

    private func dropPasteboardRow() {
        if pasteboardCandidate != nil || evaluatingPasteboardURL != nil {
            pasteboardCandidate = nil
            evaluatingPasteboardURL = nil
            reload()
        }
    }

    /// The trailing Save button: persists the candidate (it then moves into the
    /// Reading section) without opening it.
    private func savePasteboardCandidate() {
        guard let candidate = pasteboardCandidate else { return }
        pasteboardCandidate = nil
        evaluatingPasteboardURL = nil
        reload() // drop the pasteboard row; the saved item arrives via the notification
        if let content = candidate.content {
            Task {
                await ReadingListIngestor.shared.saveNewWithContent(
                    urlString: candidate.urlString, content: content, source: .paste)
            }
        } else {
            Task {
                await ReadingListIngestor.shared.handleSavePress(
                    urlString: candidate.urlString, source: .paste)
            }
        }
    }

    /// Tapping the row PREVIEWS the candidate without saving it (a transient item;
    /// the row stays until the user taps Save).
    private func previewPasteboardCandidate() {
        guard let candidate = pasteboardCandidate else { return }
        var transient = ReadingListItem(urlString: candidate.urlString)
        transient.title = candidate.title
        transient.youtubeVideoID = candidate.videoID
        transient.channelName = candidate.channelName
        transient.platform = candidate.platform
        transient.state = candidate.requiresUnlock ? .needsCaptcha : .ready

        if candidate.isVideo {
            openVideo(transient, from: self)
        } else if let platform = candidate.platform {
            openPlatformItem(transient, platform: platform, from: self)
        } else if candidate.requiresUnlock {
            pasteboardCandidate = nil
            evaluatingPasteboardURL = nil
            reload()
            Task { [weak self] in
                let result = await ReadingListIngestor.shared.handleSavePress(
                    urlString: candidate.urlString, source: .paste)
                await MainActor.run {
                    guard let self else { return }
                    let resultItem: ReadingListItem?
                    switch result {
                    case .saved(let saved), .sentToEreaders(let saved): resultItem = saved
                    case .ignored: resultItem = nil
                    }
                    let item = resultItem
                        .flatMap { self.store.item(withID: $0.id) }
                        ?? self.store.item(forURLString: candidate.urlString)
                    guard let item else { return }
                    self.open(item, presenter: self)
                }
            }
        } else if let content = candidate.content {
            let reader = ReaderHostFactory.make(
                item: transient, content: content,
                shareProvider: AppReaderShareProvider.shared,
                transition: DotMatrixRabbitHoleTransition())
            navigationController?.pushViewController(reader, animated: true)
        }
    }

    @objc private func reload() {
        // A reorder we just persisted fires this notification; ignore it so the
        // drop animation isn't interrupted by a full reloadData.
        if isApplyingReorder || isAnimatingRowChange { return }

        updateFilterVisibility()
        updateCatchUpButton()
        groups = buildGroups()
        tableView.reloadData()
        presentPendingSendFailureNoticeIfNeeded()
    }

    /// Builds the non-empty grouped model (sections × items, in display order) for the
    /// current filter and store contents — the PURE model step, split out of `reload()`
    /// so a filter change can diff the old/new models and animate only the rows that
    /// actually change (see `filterChanged`). May clear a now-saved pasteboard candidate
    /// as a side effect (mirrors the old `reload`).
    private func buildGroups() -> [(section: Section, items: [ReadingListItem])] {
        let unfiltered = store.items()
        // A concrete surface restricts the whole list to its single category (other
        // categories live in the same store but surface in their own app); the combined
        // list (surface == nil) honours the user-selected filter segment.
        let all = unfiltered.filter { surface?.includes($0) ?? filter.includes($0) }
        let buckets = ReadingListSectioning.assignSections(items: all, now: Self.sectioningNow())
        var bySection: [Section: [ReadingListItem]] =
            [.reading: buckets.reading, .archive: buckets.archive, .error: buckets.failed]

        // The price-tracking section sits BELOW Reading. The single triggered-but-
        // UNVIEWED tracker floats to the very TOP of the whole list as its own
        // one-row `.priceAlert` section, badged red; it's excluded from the
        // price-tracking section body by `assignSections`. Once viewed, it rejoins
        // the price-tracking section below Reading.
        bySection[.priceTracking] = buckets.priceTracking
        if let pinned = ReadingListSectioning.topUnviewedAlertingPriceTracker(items: all) {
            bySection[.priceAlert] = [pinned]
        }

        // The pasteboard suggestion: a spinner row while evaluating, then the
        // resolved candidate (unless it's since been saved by some path).
        if let candidate = pasteboardCandidate {
            if store.item(forURLString: candidate.urlString) != nil {
                pasteboardCandidate = nil
            } else {
                bySection[.pasteboard] = [displayItem(for: candidate)]
            }
        } else if let evaluatingURL = evaluatingPasteboardURL {
            var loading = ReadingListItem(urlString: evaluatingURL)
            loading.state = .pending
            bySection[.pasteboard] = [loading]
        }

        return Self.displayOrder.compactMap { section in
            let items = bySection[section] ?? []
            return items.isEmpty ? nil : (section, items)
        }
    }

    /// A transient (unsaved) item used to render the pasteboard suggestion row.
    private func displayItem(for candidate: PasteboardCandidate) -> ReadingListItem {
        var item = ReadingListItem(urlString: candidate.urlString)
        item.title = candidate.title
        item.state = candidate.requiresUnlock ? .needsCaptcha : .ready
        item.youtubeVideoID = candidate.videoID
        item.channelName = candidate.channelName
        item.platform = candidate.platform
        return item
    }

    /// The filter segments currently shown, in segment order. `.all` plus
    /// whichever of Articles / Media / Price apply to the present list. The Price
    /// segment is only included when a non-archived tracker exists.
    private func visibleFilters() -> [ListFilter] {
        let items = store.items()
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
        let mode: PriceTrackingViewController.Mode
        if isMerge, let highlightedURL {
            mode = .merge(itemID: itemID, addedStoreURLString: highlightedURL, host: .inApp)
        } else {
            mode = .creation(itemID: itemID, host: .inApp)
        }
        let viewController = PriceTrackingViewController(mode: mode)
        navigationController?.pushViewController(viewController, animated: true)
    }

    @objc private func filterChanged(_ control: LunaSegmentedControl) {
        let filters = visibleFilters()
        let index = control.selectedSegmentIndex
        filter = (index >= 0 && index < filters.count) ? filters[index] : .all

        // The segmented control's OWN selection move uses UIKit's stock selection
        // animation — no dotmatrix pixel-wipe on the control widget itself. Only the list
        // content it filters animates (the diff-driven wipe below).

        // The list body: diff the OLD vs NEW grouped models by item id and animate ONLY
        // the rows that appear/disappear/move, pixel-wiping just the union rect of those
        // rows. Rows whose item stays in place don't move and aren't in the wipe region.
        applyFilteredGroups()
    }

    /// Swaps `groups` to the freshly-built (filtered) model with a cell-level diff: only
    /// the rows that appear/disappear/move are inserted/deleted and pixel-wiped (confined
    /// to their bounding rect); rows that persist in place are reconfigured silently. The
    /// nav bar (title + buttons) is a sibling of the table and is never snapshotted.
    private func applyFilteredGroups() {
        let oldGroups = groups
        let newGroups = buildGroups()

        // Reuse the table's grouped-model diff (id-keyed) to get the row/section deltas.
        let diff = ReadingListDiff.compute(
            old: oldGroups.map { ReadingListGroup(section: $0.section, itemIDs: $0.items.map(\.id)) },
            new: newGroups.map { ReadingListGroup(section: $0.section, itemIDs: $0.items.map(\.id)) })

        // Nothing changed (e.g. the same filter re-selected) ⇒ no wipe, no table churn.
        if diff.isEmpty {
            groups = newGroups
            return
        }

        // Build the changed REGION directly from the diff's index paths against the
        // CURRENT (old) layout — no reloads. `DotMatrixBatch.update` lays out the NEW model
        // itself and snapshots the correct "after", so the region only needs to *bound* the
        // changed area in the table's coordinate space; it never has to be exact.
        //
        // Deleted rows/sections sit at known slots in the old layout, so their `rectForRow`
        // is read straight from the live table. Insertions don't exist yet, so we span them
        // by their neighbours: per affected section we union the bounding rect from the
        // first to the last changed row in the old layout (clamped to visible), which
        // over-covers slightly but never under-covers changed content — and costs zero
        // extra reloads/layouts versus the old round-trip.
        let visible = tableView.bounds
        let region = changedRegion(for: diff, oldGroups: oldGroups, newGroups: newGroups,
                                   clampedTo: visible)

        // Apply the diff with real insert/delete ops (the correct UIKit batch shape, so
        // the disabled-wipe fallback animates rows cleanly). `groups` must already be the
        // NEW model when the batch body runs, since the table re-queries it for counts.
        DotMatrixBatch.update(tableView, direction: .random, region: region) { [weak self] in
            guard let self else { return }
            self.groups = newGroups
            self.tableView.deleteSections(diff.deletedSections, with: .fade)
            self.tableView.insertSections(diff.insertedSections, with: .fade)
            self.tableView.deleteRows(at: diff.deletedRows, with: .fade)
            self.tableView.insertRows(at: diff.insertedRows, with: .fade)
        } completion: { [weak self] _ in
            // Reconfigure rows whose item persists in place but whose content changed
            // (state/read-state), without animation — they weren't in the wipe region.
            self?.reconfigurePersistingCells(in: diff.persistingItemIDs)
        }
    }

    /// Silently re-renders any visible cell whose item id is in `ids` — a row that stayed
    /// put across the filter swap but whose content may have changed. No animation: these
    /// rows are deliberately excluded from the wipe region.
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

    /// The changed-region bounding rect (in the table's own coordinate space, clamped to
    /// `bounds`) for a filter `diff`, measured ENTIRELY against the live OLD layout — no
    /// reloadData round-trip. The table is still on `oldGroups` here, so every old-layout
    /// index path (`diff.deletedRows`, rows of `diff.deletedSections`) has a valid
    /// `rectForRow`. Insertions don't exist in the old layout, so we span them by their
    /// neighbours in the old layout: per affected section, the union from the first to the
    /// last changed row index brackets where new rows will land. This over-covers slightly
    /// but never under-covers changed content. Returns `nil` when nothing on screen
    /// changed (the wipe is then skipped / falls back to the whole visible table).
    private func changedRegion(
        for diff: ReadingListDiff,
        oldGroups: [(section: Section, items: [ReadingListItem])],
        newGroups: [(section: Section, items: [ReadingListItem])],
        clampedTo bounds: CGRect
    ) -> CGRect? {
        var union: CGRect = .null

        func add(_ rect: CGRect) {
            let clamped = rect.intersection(bounds)
            guard !clamped.isNull, !clamped.isEmpty else { return }
            union = union.union(clamped)
        }

        // Map a section kind to its index in each side, so changes in either side resolve
        // to a frame in the OLD layout (the only layout the live table currently holds).
        let oldSectionIndex = Dictionary(
            uniqueKeysWithValues: oldGroups.enumerated().map { ($0.element.section, $0.offset) })

        // Whole deleted sections: union every row they currently occupy in the old layout.
        for section in diff.deletedSections {
            let count = tableView.numberOfRows(inSection: section)
            for row in 0..<max(count, 0) {
                add(tableView.rectForRow(at: IndexPath(row: row, section: section)))
            }
        }

        // Deleted rows sit at known old-layout slots → their rects are read directly.
        for indexPath in diff.deletedRows {
            add(tableView.rectForRow(at: indexPath))
        }

        // Inserted rows/sections don't exist in the old layout. Bracket them against the
        // old layout per (new) section: span from the first to the last changed row index,
        // anchored on whatever currently occupies those slots. Clamp the index to the
        // section's existing row count so a trailing append spans the section's last row.
        var insertSpanByNewSection: [Int: (min: Int, max: Int)] = [:]
        for indexPath in diff.insertedRows {
            let existing = insertSpanByNewSection[indexPath.section]
            let lo = min(existing?.min ?? indexPath.row, indexPath.row)
            let hi = max(existing?.max ?? indexPath.row, indexPath.row)
            insertSpanByNewSection[indexPath.section] = (lo, hi)
        }
        for (newSection, span) in insertSpanByNewSection {
            // Resolve the same section in the OLD layout (a persisting section); inserts
            // into a brand-new section are already covered by `insertedSections`.
            guard newSection < newGroups.count,
                  let oldSection = oldSectionIndex[newGroups[newSection].section] else { continue }
            let oldCount = tableView.numberOfRows(inSection: oldSection)
            guard oldCount > 0 else { continue }
            for row in span.min...span.max {
                add(tableView.rectForRow(at: IndexPath(row: min(row, oldCount - 1), section: oldSection)))
            }
        }

        // Whole inserted sections: a new section lands adjacent to a persisting neighbour.
        // Anchor on the nearest persisting section's edge in the old layout so the wipe
        // reaches the strip where the section will appear.
        for newSection in diff.insertedSections {
            // The persisting section immediately before this new one (if any) gives a
            // lower anchor; otherwise the section after it. Both resolve via the old layout.
            if newSection > 0, newSection - 1 < newGroups.count,
               let oldPrev = oldSectionIndex[newGroups[newSection - 1].section] {
                let count = tableView.numberOfRows(inSection: oldPrev)
                if count > 0 { add(tableView.rectForRow(at: IndexPath(row: count - 1, section: oldPrev))) }
            } else if newSection + 1 < newGroups.count,
                      let oldNext = oldSectionIndex[newGroups[newSection + 1].section] {
                let count = tableView.numberOfRows(inSection: oldNext)
                if count > 0 { add(tableView.rectForRow(at: IndexPath(row: 0, section: oldNext))) }
            }
        }

        return union.isNull ? nil : union
    }

    /// Shows the filter control only when the list has at least two of the three
    /// kinds (reader / media / price tracker); otherwise it's meaningless. Rebuilds
    /// the segments to match the kinds present and resets a now-invalid selection.
    private func updateFilterVisibility() {
        // A concrete surface is single-category, so the filter segments are meaningless —
        // never show them. Only the combined list (surface == nil) offers the filter.
        let shouldShow = surface == nil
            && ReadingListSectioning.shouldShowFilter(items: store.items())
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

        let filters = visibleFilters()
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
        ArticleSendCoordinator.shared.retryPendingSends()
        Task { await IncomingMailImporter.shared.importNewMail() }
        reload()
        refreshControl?.endRefreshing()
    }

    @objc private func friendsTapped() {
        navigationController?.pushViewController(FriendsViewController(), animated: true)
    }

    // MARK: - Catch up

    /// Items worth catching up on: unread (incl. partially read), and renderable
    /// (ready articles, or any platform/media item), oldest first by bump/save date.
    private func catchUpQueue() -> [ReadingListItem] {
        ReadingListSectioning.catchUpQueue(items: store.items())
    }

    private func configureCatchUpButton() {
        catchUpButton.setImage(
            UIImage(systemName: "rectangle.stack",
                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)),
            for: .normal)
        // Same color as the other nav-bar buttons (white in dark, black in light);
        // only the unread dot is red.
        catchUpButton.tintColor = .label
        catchUpButton.accessibilityLabel = "Catch up"
        catchUpButton.addTarget(self, action: #selector(catchUpTapped), for: .touchUpInside)
        catchUpButton.translatesAutoresizingMaskIntoConstraints = false

        // A red "action needed" dot in the top-right corner of the icon.
        catchUpBadge.backgroundColor = .systemRed
        catchUpBadge.layer.cornerRadius = 4.5
        catchUpBadge.isUserInteractionEnabled = false
        catchUpBadge.isHidden = true
        catchUpBadge.translatesAutoresizingMaskIntoConstraints = false
        catchUpButton.addSubview(catchUpBadge)
        NSLayoutConstraint.activate([
            catchUpBadge.widthAnchor.constraint(equalToConstant: 9),
            catchUpBadge.heightAnchor.constraint(equalToConstant: 9),
            catchUpBadge.trailingAnchor.constraint(equalTo: catchUpButton.trailingAnchor, constant: 2),
            catchUpBadge.topAnchor.constraint(equalTo: catchUpButton.topAnchor, constant: -2),
        ])
    }

    /// Shows the red "action needed" dot once there are 10+ unread items, OR whenever
    /// there's an unarchived LOCKED (paywalled, awaiting unlock) save — regardless of
    /// count. Hides the whole button in edit mode.
    private func updateCatchUpButton() {
        // Badge while there's catch-up worth doing, or until the email account is set up.
        let needsEmailSetup = !EmailAccountStore.shared.isConfigured
        catchUpBadge.isHidden = !(ReadingListSectioning.shouldShowCatchUpDot(items: store.items())
            || needsEmailSetup)
        catchUpButton.isHidden = isEditing
    }

    override func scrollViewDidScroll(_ scrollView: UIScrollView) {
        header.updateScrolledAppearance(
            contentOffsetY: scrollView.contentOffset.y,
            adjustedTopInset: scrollView.adjustedContentInset.top)
    }

    @objc private func catchUpTapped() {
        let catchUp = CatchUpViewController(unread: catchUpQueue(), router: self)
        DotMatrixModal.present(catchUp, from: self)
    }

    // MARK: - Header controls

    /// The normal (non-editing) header: settings + friends (leading); add + search
    /// (trailing) in the pinned bar. The large "Reading List" title + catch-up button
    /// live on the scrolling title row of the table header (`makeTableHeader`).
    private func setDefaultHeaderControls() {
        var leading = [
            NavHeaderBar.imageButton(
                systemName: "gearshape", target: self, action: #selector(settingsTapped),
                accessibilityLabel: "Settings"),
        ]
        // Friends / email sharing is available in all three apps.
        leading.append(NavHeaderBar.imageButton(
            systemName: "person.2", target: self, action: #selector(friendsTapped),
            accessibilityLabel: "Friends"))
        header.setLeadingControls(leading)
        header.setTrailingControls([
            NavHeaderBar.imageButton(
                systemName: "plus", target: self, action: #selector(addTapped),
                accessibilityLabel: "Add"),
            NavHeaderBar.imageButton(
                systemName: "magnifyingglass", target: self, action: #selector(searchTapped),
                accessibilityLabel: "Search"),
        ])
    }

    /// Builds the scrolling table-header content: the large "Reading List" title row
    /// (with the catch-up button on its trailing edge) and — when applicable — the
    /// Articles / Media / Price filter row beneath it. Sized to fit and assigned as the
    /// `tableHeaderView` so it scrolls away under the pinned bar like a system large
    /// title. `showsFilter` includes the filter row.
    private func rebuildTableHeader(showsFilter: Bool) {
        // A `tableHeaderView` is sized by its FRAME (set explicitly at the bottom of this
        // method), so the container must keep `translatesAutoresizingMaskIntoConstraints`
        // = true. With it false, UITableView auto-layouts the header and — lacking a width
        // constraint — collapses it to its compressed content width (~32pt), clipping the
        // title + filter. Its internal subview constraints still resolve against the frame.
        let container = UIView()

        // Large-title row: "Reading List" leading, catch-up button trailing.
        let titleRow = UIView()
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        largeTitleLabel.text = "Reading List"
        largeTitleLabel.font = .systemFont(ofSize: 34, weight: .bold)
        largeTitleLabel.textColor = .label
        largeTitleLabel.adjustsFontForContentSizeCategory = true
        largeTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleRow.addSubview(largeTitleLabel)
        if catchUpButton.superview != nil { catchUpButton.removeFromSuperview() }
        titleRow.addSubview(catchUpButton)
        container.addSubview(titleRow)

        NSLayoutConstraint.activate([
            titleRow.topAnchor.constraint(equalTo: container.topAnchor),
            titleRow.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            titleRow.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            titleRow.heightAnchor.constraint(equalToConstant: 52),
            largeTitleLabel.leadingAnchor.constraint(equalTo: titleRow.leadingAnchor, constant: 20),
            largeTitleLabel.bottomAnchor.constraint(equalTo: titleRow.bottomAnchor, constant: -6),
            catchUpButton.trailingAnchor.constraint(equalTo: titleRow.trailingAnchor, constant: -16),
            catchUpButton.centerYAnchor.constraint(equalTo: largeTitleLabel.centerYAnchor),
            catchUpButton.widthAnchor.constraint(equalToConstant: 34),
            catchUpButton.heightAnchor.constraint(equalToConstant: 34),
        ])

        var bottomAnchor = titleRow.bottomAnchor
        if showsFilter, let filterRow = filterHeaderView {
            filterRow.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(filterRow)
            NSLayoutConstraint.activate([
                filterRow.topAnchor.constraint(equalTo: titleRow.bottomAnchor),
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

    /// Opens search IN PLACE over the reading list: a child VC cross-faded in (no
    /// modal page transition — the list fades out, the search field + keyboard fade
    /// in). Hosted in the navigation controller's view so it covers the nav bar too.
    @objc private func searchTapped() {
        // Host the overlay on (and parent it to) the NAVIGATION CONTROLLER: it owns
        // the view that covers the nav bar, and RLVC is a UITableViewController whose
        // own `view` is the scrolling table — not a valid host. Parenting to the same
        // VC that owns the host view avoids UIKit's appearance-forwarding assertion.
        guard searchController == nil, let nav = navigationController else { return }
        // The shared nav bar is already hidden (this screen draws its own in-content
        // header). The search overlay is added to the nav controller's view, so it
        // covers the table — including our header — for the whole search session.
        let search = SearchViewController(engine: ReadingListSearchEngine(), presenter: self)
        search.topSafeAreaInset = nav.view.safeAreaInsets.top   // status bar — correct from first layout
        search.onExit = { [weak self] in self?.dismissSearch() }
        search.onOpen = { [weak self] item in
            guard let self else { return }
            self.removeSearch()                 // drop the overlay; the open animates normally
            self.open(item, presenter: self)
        }
        searchController = search                // strong ref keeps it alive (no containment)
        let overlay = search.view!              // loads the view
        overlay.alpha = 0
        overlay.translatesAutoresizingMaskIntoConstraints = false
        nav.view.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: nav.view.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: nav.view.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: nav.view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: nav.view.trailingAnchor),
        ])
        nav.view.layoutIfNeeded()               // force a layout so its content insets resolve now
        nav.view.bringSubviewToFront(overlay)
        // Focus immediately (not in the wipe completion) so the keyboard rises in
        // parallel with the transition rather than after it.
        search.focusSearchField()
        // The overlay replaces the entire list surface (header included), so it gets
        // the full appear-in-place pixel wipe; disabled ⇒ the original cross-fade.
        DotMatrixCrossfade.run(in: nav.view, direction: .random) {
            overlay.alpha = 1
        }
    }

    /// Fades the in-place search overlay out, then removes it. The list's own
    /// in-content header is revealed intact as the overlay fades (the shared nav bar
    /// stays hidden throughout).
    private func dismissSearch() {
        guard let search = searchController else { return }
        navigationController?.view.bringSubviewToFront(search.view)
        guard let host = navigationController?.view else { removeSearch(); return }
        DotMatrixCrossfade.run(in: host, direction: .random, changes: {
            search.view.alpha = 0
        }, completion: {
            self.removeSearch()
        })
    }

    /// Tears the search overlay down immediately (no fade) — used when opening a result
    /// so the pushed reader animates over the bare list.
    private func removeSearch() {
        searchController?.view.removeFromSuperview()
        searchController = nil
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
        updateCatchUpButton()
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
        for item in items { store.delete(item) }     // each posts .readingListChanged → reload
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
        let prefill = pasteboardCandidate?.urlString
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
        DotMatrixModal.present(alert, from: self)
    }

    /// Validates a typed/pasted URL string before saving, replacing the old blind
    /// `https://` prefix (which mangled `mailto:`/`tel:`/bare words into
    /// `https://mailto:…`). Accepts an `http(s)` URL as-is; bare-prefixes `https://`
    /// ONLY when the entry has no scheme but looks like a host (contains a dot, no
    /// spaces); rejects everything else (a non-http scheme or junk) with nil.
    static func normalizedTypedURL(_ entered: String) -> String? {
        URLUnwrapper.ingestURL(from: entered, allowBareHost: true)?.absoluteString
    }

    @objc private func settingsTapped() {
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
        DotMatrixModal.present(alert, from: self)
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
            // A delete can change whether the Articles / Media & Links filter applies.
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
        // Collapsing/expanding swaps a whole section of rows at once — pixel-wipe the
        // table between the two layouts (falls back to the stock .automatic row
        // animation when the toggle is off).
        DotMatrixBatch.update(tableView, direction: .random) { [weak self] in
            self?.tableView.reloadSections(IndexSet(integer: index), with: .automatic)
        }
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

        let header = UIView()
        header.tag = kind.rawValue

        // The error section is tinted red to flag it; the rest are muted.
        let headerColor: UIColor = kind == .error ? .systemRed : .secondaryLabel

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
        44
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
            : (item.readState == .unopened ? .label : .secondaryLabel)

        if isPasteboard {
            // Spinner while evaluating; the candidate's preview thumbnail once
            // ready. A trailing Save button saves explicitly (tap just previews).
            let thumbnail: ReadingListItemCell.Thumbnail
            if let candidate = pasteboardCandidate {
                if candidate.requiresUnlock { thumbnail = .logo(assetName: nil, glyph: "lock.fill") }
                else if let image = candidate.thumbnail { thumbnail = .image(image) }
                else if let platform = candidate.platform,
                        let module = PlatformRegistry.shared.module(for: platform) {
                    thumbnail = .logo(assetName: platform.logoAssetName, glyph: module.glyphSymbolName)
                } else { thumbnail = .none }
            } else {
                thumbnail = .loading
            }
            cell.configure(
                title: item.title ?? item.urlString, titleColor: titleColor,
                subtitle: secondaryText(for: item), thumbnail: thumbnail,
                showsDisclosure: false,
                reuseKey: "pasteboard|\(item.urlString)|\(pasteboardCandidate == nil)",
                trailingButtonSymbol: pasteboardCandidate == nil ? nil : "plus.circle.fill",
                onTrailingButton: pasteboardCandidate == nil ? nil : { [weak self] in
                    self?.savePasteboardCandidate()
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

    /// Configures a row cell for `item` (shared with the search screen so its rows
    /// look identical to the list's).
    func configureItemCell(_ cell: ReadingListItemCell, for item: ReadingListItem) {
        if let tracker = item.priceTracker {
            configurePriceTrackerCell(cell, item: item, tracker: tracker)
            return
        }
        let titleColor: UIColor = item.state == .failed
            ? .systemRed
            : (item.readState == .unopened ? .label : .secondaryLabel)
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

        let baseColor: UIColor = alerting ? .systemRed : .secondaryLabel
        let subtitle = NSMutableAttributedString(
            string: priceText, attributes: [.foregroundColor: baseColor])
        if alerting {
            let percent = Int((tracker.discountFraction * 100).rounded())
            subtitle.append(NSAttributedString(
                string: "  ↓\(percent)%",
                attributes: [.foregroundColor: UIColor.systemRed]))
        }

        let thumbnail: ReadingListItemCell.Thumbnail
        if let fileName = tracker.imageFileName,
           let data = try? Data(contentsOf: store.articlesDirectory.appendingPathComponent(fileName)),
           let image = UIImage(data: data) {
            thumbnail = .image(image)
        } else {
            thumbnail = .logo(assetName: nil, glyph: alerting ? "tag.fill" : "tag")
        }

        cell.configure(
            title: tracker.productName,
            titleColor: alerting ? .systemRed : .label,
            subtitle: subtitle,
            thumbnail: thumbnail,
            showsDisclosure: true,
            reuseKey: "pt|\(item.id.uuidString)|\(priceText)|\(alerting)")
        cell.showsReorderControl = false
    }

    /// Builds the grey metadata line, with the "from <friend>" attribution in
    /// the accent color so social shares stand out.
    private func secondaryText(for item: ReadingListItem) -> NSAttributedString {
        let baseColor: UIColor = item.readState == .unopened ? .secondaryLabel : .tertiaryLabel
        let host = item.url?.host ?? ""
        // Platform items show a logical container (subreddit / author / channel /
        // artist), never the bare host. Falls back to the platform name.
        let leadingLabel: String
        if let platform = item.contentPlatform,
           let module = PlatformRegistry.shared.module(for: platform) {
            leadingLabel = module.subtitle(for: item) ?? platform.displayName
        } else if item.isDocument {
            leadingLabel = item.documentType?.uppercased() ?? "Document"
        } else {
            leadingLabel = item.channelName ?? host
        }
        let parts = ReadingListSubtitle.parts(
            for: item,
            leadingLabel: leadingLabel,
            formattedDate: dateFormatter.string(from: item.dateAdded),
            showReadingTime: ReaderSettings.showReadingTime,
            showReadingProgress: ReaderSettings.showReadingProgress)

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

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        // In edit mode a tap toggles the selection radio (UIKit handles it) — don't
        // open the row or clear the selection.
        if isEditing { return }
        tableView.deselectRow(at: indexPath, animated: true)
        if section(at: indexPath.section) == .pasteboard {
            previewPasteboardCandidate()
            return
        }
        open(item(at: indexPath), presenter: self)
    }

    /// Opens an item presenting from `presenter` (the reading list, or the search
    /// screen): platform/video/media via `openItem`, a hard-paywalled article via
    /// the archive web view, else the in-app reader pushed on `presenter`'s nav.
    func open(_ item: ReadingListItem, presenter: UIViewController) {
        if item.isPriceTracker {
            // Opening an alerting tracker acknowledges its alert, so the row stops
            // floating to the top of the list and rejoins the price-tracking section.
            if var tracker = item.priceTracker, tracker.hasUnviewedAlert {
                tracker.markAlertViewed()
                store.updatePriceTracker(tracker, for: item.id)
            }
            let viewController = PriceTrackingViewController(itemID: item.id)
            presenter.navigationController?.pushViewController(viewController, animated: true)
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
        if item.state == .needsCaptcha, let url = item.url {
            presentArchiveReader(for: item, articleURL: url, presenter: presenter)
            store.markReadState(.opened, for: item.id)
            return
        }
        guard item.state == .ready, let content = store.content(for: item) else { return }
        let reader = ReaderHostFactory.make(
            item: item, content: content,
            shareProvider: AppReaderShareProvider.shared,
            transition: DotMatrixRabbitHoleTransition())
        presenter.navigationController?.pushViewController(reader, animated: true)
    }

    /// Presents the interactive WKWebView archive reader for a `.needsCaptcha` item.
    /// On a successful extraction it dismisses and reopens the now-`.ready` item in
    /// the native reader; an "Open in Safari" button hands off to real Safari when
    /// the embedded web view can't clear archive.today's Cloudflare gate.
    private func presentArchiveReader(
        for item: ReadingListItem, articleURL: URL, presenter: UIViewController
    ) {
        let reader = ArchiveWebReaderViewController(articleURL: articleURL, itemID: item.id, store: store)
        let nav = UINavigationController(rootViewController: reader)
        nav.installDotMatrixTransitions()
        reader.onClose = { [weak nav] in
            guard let nav else { return }
            DotMatrixModal.dismiss(nav)
        }
        reader.onOpenInBrowser = { [weak nav] archiveURL in
            // This is an escape from archive.is's WKWebView-specific bot gate, so
            // it must leave Luna for the system browser — an SFSafari sheet remains
            // inside our presentation and doesn't provide the requested escape.
            guard let nav else { return }
            DotMatrixModal.dismiss(nav) {
                UIApplication.shared.open(archiveURL)
            }
        }
        reader.onExtracted = { [weak self, weak nav, weak presenter] in
            guard let nav else { return }
            DotMatrixModal.dismiss(nav) {
                guard let self, let presenter,
                      let fresh = self.store.item(withID: item.id) else { return }
                // Archive/direct-unlock extraction happens in LunaArchiveReader, below
                // the thumbnail helper's module, so it saves text first and lets the app
                // process backfill the row cover. Without this nudge, the cover appears
                // only on the next launch/foreground backfill pass.
                ReadingListIngestor.shared.backfillMissingThumbnails()
                self.open(fresh, presenter: presenter)   // now .ready → native reader
            }
        }
        DotMatrixModal.present(nav, from: presenter)
    }

    /// Opens a non-article item (video / platform post / music / podcast) the way
    /// tapping its row does, presenting any in-app viewer from `presenter` (the
    /// reading list, or the catch-up screen). Returns false for reader articles, so
    /// the caller can render those itself.
    @discardableResult
    func openItem(_ item: ReadingListItem, presentingFrom presenter: UIViewController) -> Bool {
        if item.isYouTubeVideo {
            openVideo(item, from: presenter)
            return true
        }
        if let platform = item.contentPlatform {
            switch platform {
            case .music, .podcast: openMediaItem(item, platform: platform, from: presenter)
            default: openPlatformItem(item, platform: platform, from: presenter)
            }
            return true
        }
        return false
    }

    // MARK: - Platform item playback / open

    /// The launch ladder for a non-YouTube platform item: native app → in-app
    /// embed → in-app Safari.
    private func openPlatformItem(
        _ item: ReadingListItem, platform: ContentPlatform, from presenter: UIViewController
    ) {
        guard let module = PlatformRegistry.shared.module(for: platform) else { return }

        if let appURL = module.appDeepLink(for: item), UIApplication.shared.canOpenURL(appURL) {
            UIApplication.shared.open(appURL) { [weak self] success in
                if success { self?.store.markReadState(.read, for: item.id) }
            }
            return
        }
        if let embed = module.embed(for: item) {
            DotMatrixModal.present(PlatformEmbedViewController(embed: embed, itemID: item.id), from: presenter)
            return
        }
        InAppBrowser.present(urlString: item.urlString, from: presenter)
    }

    /// Opens a music/podcast item in the user's preferred provider (exact link
    /// when same-provider, else a search). The provider defaults to Apple.
    private func openMediaItem(
        _ item: ReadingListItem, platform: ContentPlatform, from presenter: UIViewController
    ) {
        let provider = MediaProviderSettings.preferredProvider(for: platform)
        let query = [item.mediaCreatorName, item.mediaItemTitle ?? item.title]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        let markRead: (Bool) -> Void = { [weak self] success in
            if success { self?.store.markReadState(.read, for: item.id) }
        }

        if item.mediaSourceService == provider,
           let appURL = MediaLink.appSchemeURL(forWebURL: item.urlString),
           UIApplication.shared.canOpenURL(appURL) {
            UIApplication.shared.open(appURL, completionHandler: markRead)
            return
        }
        if !query.isEmpty, let appSearch = provider.appSearchURL(query: query, platform: platform),
           UIApplication.shared.canOpenURL(appSearch) {
            UIApplication.shared.open(appSearch, completionHandler: markRead)
            return
        }
        // Web fallback: the original http URL, else a web search in the provider.
        if let url = URL(string: item.urlString), let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            InAppBrowser.present(urlString: item.urlString, from: presenter)
        } else if !query.isEmpty, let webSearch = provider.webSearchURL(query: query, platform: platform) {
            InAppBrowser.present(urlString: webSearch.absoluteString, from: presenter)
        }
    }

    /// Sends any reading-list item (article, media, or price tracker) to chosen
    /// recipients as a Luna email.
    private func presentSend(_ item: ReadingListItem) {
        SendToFriendSheet.present(
            from: self, item: item,
            urlString: item.urlString, title: item.title)
    }

    // MARK: - Video playback

    /// Prefers the YouTube app (marks read on successful handoff); otherwise
    /// the in-app player (marks read when playback finishes).
    private func openVideo(_ item: ReadingListItem, from presenter: UIViewController) {
        guard let videoID = item.youtubeVideoID else { return }
        if let appURL = YouTubeURL.appURL(videoID: videoID),
           UIApplication.shared.canOpenURL(appURL) {
            UIApplication.shared.open(appURL) { [weak self] success in
                if success {
                    self?.store.markReadState(.read, for: item.id)
                }
            }
            return
        }
        DotMatrixModal.present(YouTubePlayerViewController(videoID: videoID, itemID: item.id), from: presenter)
    }

    /// The thumbnail state for a row: cached art (aspect-fit) when present, a
    /// spinner while the item is still being fetched, or the platform-logo
    /// fallback once the fetch finished with no image. The pasteboard suggestion
    /// is transient (never ingesting) so it never spins.
    private func thumbnail(
        for item: ReadingListItem, isPasteboard: Bool
    ) -> ReadingListItemCell.Thumbnail {
        if let fileName = item.thumbnailFileName {
            return .art(path: store.articlesDirectory.appendingPathComponent(fileName).path)
        }
        // A paywalled article awaiting a user-solved CAPTCHA isn't fetching — show a
        // lock to signal it needs a tap to unlock, not a spinner.
        if item.state == .needsCaptcha {
            return .logo(assetName: nil, glyph: "lock.fill")
        }
        let fetchFinished = isPasteboard || item.state == .ready || item.state == .failed

        if item.isYouTubeVideo {
            return fetchFinished
                ? .logo(assetName: ContentPlatform.youtube.logoAssetName, glyph: "play.rectangle.fill")
                : .loading
        }
        if let platform = item.contentPlatform,
           let module = PlatformRegistry.shared.module(for: platform) {
            return fetchFinished
                ? .logo(assetName: platform.logoAssetName, glyph: module.glyphSymbolName)
                : .loading
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
        let item = item(at: indexPath)
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            self?.rowMenu(for: item, at: indexPath)
        })
    }

    /// Builds the long-press row menu. Also driven by a simulator-only tap button on
    /// the cell (see `cellForRowAt`) so the menu is testable without a synthesized
    /// long-press.
    private func rowMenu(for item: ReadingListItem, at indexPath: IndexPath) -> UIMenu {
        let sendToFriend = UIAction(
            title: "Send to Friend…",
            image: UIImage(systemName: "person.2")
        ) { [weak self] _ in
            self?.presentSend(item)
        }
        let sendToKindle = UIAction(
            title: "Send to Kindle",
            image: UIImage(systemName: "paperplane")
        ) { [weak self] _ in
            self?.sendToEreader(item, destinationID: ArticleDestinationID.kindle)
        }
        let sendToBoox = UIAction(
            title: "Send to Boox",
            image: UIImage(systemName: "books.vertical")
        ) { [weak self] _ in
            self?.sendToEreader(item, destinationID: ArticleDestinationID.boox)
        }
        let shareEbook = UIAction(
            title: "Share eBook…",
            image: UIImage(systemName: "square.and.arrow.up")
        ) { [weak self] _ in
            guard let self else { return }
            let sourceView = self.tableView.cellForRow(at: indexPath) ?? self.view ?? UIView()
            self.shareEbook(item, from: sourceView)
        }
        let shareLink = UIAction(
            title: "Share Link…",
            image: UIImage(systemName: "link")
        ) { [weak self] _ in
            guard let self else { return }
            let sourceView = self.tableView.cellForRow(at: indexPath) ?? self.view ?? UIView()
            SendToFriendSheet.shareLink(
                urlString: item.urlString, from: self, sourceView: sourceView)
        }
        let copyLink = UIAction(
            title: "Copy Link",
            image: UIImage(systemName: "doc.on.doc")
        ) { [weak self] _ in
            guard let self else { return }
            SendToFriendSheet.copyLink(urlString: item.urlString, from: self)
        }
        let delete = UIAction(
            title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive
        ) { [weak self] _ in
            self?.deleteItemAnimated(item)
        }
        // Videos: share to friends + delete. Documents: ereaders + read +
        // delete. Articles: everything. Each ereader row shows only when
        // that destination is set up.

        // Price trackers get a focused menu: share the tracker to a friend,
        // archive/unarchive it (archived = hidden + excluded from refresh), delete.
        if let tracker = item.priceTracker {
            var trackerChildren: [UIAction] = []
            trackerChildren.append(sendToFriend)
            let archiveTitle = tracker.isArchived ? "Unarchive Tracker" : "Archive Tracker"
            let archiveIcon = tracker.isArchived ? "tray.and.arrow.up" : "archivebox"
            trackerChildren.append(UIAction(
                title: archiveTitle, image: UIImage(systemName: archiveIcon)
            ) { [weak self] _ in
                guard let self, var updated = self.store.item(withID: item.id)?.priceTracker else { return }
                updated.isArchived.toggle()
                self.store.updatePriceTracker(updated, for: item.id)
            })
            trackerChildren.append(delete)
            return UIMenu(title: tracker.productName, children: trackerChildren)
        }

        var children: [UIAction] = []
        // Reading-section items only: jump an item to the top of the list.
        if section(at: indexPath.section) == .reading {
            children.append(UIAction(
                title: "Bump to Top", image: UIImage(systemName: "arrow.up.to.line")
            ) { [weak self] _ in
                self?.store.bump(item.id)
            })
        }
        if item.canShareToFriends || item.isURLlessMedia {
            children.append(sendToFriend)
        }
        // Any item that kept a real web URL (articles AND platform items like
        // Reddit/Spotify/X) can share that link.
        if item.isShareable {
            children.append(shareLink)
            children.append(copyLink)
        }
        // X / Instagram / TikTok posts: download the post's media to Photos.
        if MediaDownloadablePlatform.supports(item.urlString) {
            let downloadMedia = UIAction(
                title: "Download Media to Photos",
                image: UIImage(systemName: "photo.badge.arrow.down")
            ) { [weak self] _ in
                self?.downloadMediaToPhotos(item)
            }
            children.append(downloadMedia)
        }
        // Article-only actions — ereader sends, and the eBook for text-only
        // no-url articles (email/document) that can't share a link.
        if !item.isPlatformItem {
            if ArticleSendCoordinator.shared.isConfigured(destinationID: ArticleDestinationID.kindle) {
                children.append(sendToKindle)
            }
            if ArticleSendCoordinator.shared.isConfigured(destinationID: ArticleDestinationID.boox) {
                children.append(sendToBoox)
            }
            if !item.isShareable, item.state == .ready {
                children.append(shareEbook)
            }
        }
        // Archived (read) items can be unarchived back to the Reading section.
        if item.readState == .read {
            let unarchive = UIAction(
                title: "Unarchive", image: UIImage(systemName: "tray.and.arrow.up")
            ) { [weak self] _ in
                self?.store.markUnread(item.id)
            }
            children.append(unarchive)
        }
        children.append(delete)
        // "Report a bug" marks the save's recorded replay user-reported and shares
        // its export zip — for diagnosing a bad save from the list.
        let reportBug = UIAction(
            title: "Report a bug", image: UIImage(systemName: "ladybug")
        ) { [weak self] _ in
            guard let self else { return }
            let sourceView = self.tableView.cellForRow(at: indexPath) ?? self.view ?? UIView()
            ReplayBugReporter.report(itemURLString: item.urlString, from: self, sourceView: sourceView)
        }
        children.append(reportBug)
        // "Edit List" enters multi-select / drag-reorder edit mode (bottom item).
        let editList = UIAction(
            title: "Edit List", image: UIImage(systemName: "arrow.up.arrow.down")
        ) { [weak self] _ in
            self?.setEditing(true, animated: true)
        }
        return UIMenu(children: children + [editList])
    }

    /// The long-press menu for a SEARCH result: the same actions as the list but
    /// always with "Bump to Top" (re-sorts the list for when the user returns) and
    /// never "Edit List". Excludes actions that present from / draw on the reading
    /// list itself (eBook share, media-to-Photos). `onChange` lets search refresh
    /// after a mutation. Presents sheets from `presenter` (the search screen).
    func searchResultMenu(
        for item: ReadingListItem, sourceView: UIView, presenter: UIViewController,
        onChange: @escaping () -> Void
    ) -> UIMenu {
        var children: [UIAction] = []
        children.append(UIAction(
            title: "Bump to Top", image: UIImage(systemName: "arrow.up.to.line")
        ) { [weak self] _ in
            self?.store.bump(item.id)
            onChange()
        })
        if item.canShareToFriends {
            children.append(UIAction(title: "Send to Friend…", image: UIImage(systemName: "person.2")) { _ in
                SendToFriendSheet.present(
                    from: presenter, item: item,
                    urlString: item.urlString, title: item.title)
            })
        }
        if item.isShareable {
            children.append(UIAction(title: "Share Link…", image: UIImage(systemName: "link")) { _ in
                SendToFriendSheet.shareLink(urlString: item.urlString, from: presenter, sourceView: sourceView)
            })
            children.append(UIAction(title: "Copy Link", image: UIImage(systemName: "doc.on.doc")) { _ in
                SendToFriendSheet.copyLink(urlString: item.urlString, from: presenter)
            })
        }
        if !item.isPlatformItem {
            if ArticleSendCoordinator.shared.isConfigured(destinationID: ArticleDestinationID.kindle) {
                children.append(UIAction(title: "Send to Kindle", image: UIImage(systemName: "paperplane")) {
                    [weak self] _ in self?.sendToEreader(item, destinationID: ArticleDestinationID.kindle)
                })
            }
            if ArticleSendCoordinator.shared.isConfigured(destinationID: ArticleDestinationID.boox) {
                children.append(UIAction(title: "Send to Boox", image: UIImage(systemName: "books.vertical")) {
                    [weak self] _ in self?.sendToEreader(item, destinationID: ArticleDestinationID.boox)
                })
            }
        }
        if item.readState == .read {
            children.append(UIAction(title: "Unarchive", image: UIImage(systemName: "tray.and.arrow.up")) {
                [weak self] _ in
                self?.store.markUnread(item.id)
                onChange()
            })
        }
        children.append(UIAction(
            title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive
        ) { [weak self] _ in
            self?.store.delete(item)
            onChange()
        })
        return UIMenu(children: children)
    }

    /// Hands the first media item of an X/Instagram/TikTok/Facebook post to the
    /// background media downloader. The Live Activity/background URLSession own
    /// the durable transfer; this pill is only immediate in-app feedback.
    private func downloadMediaToPhotos(_ item: ReadingListItem) {
        let status = mediaDownloadStatusView()
        status.startProgress()
        Task { [weak self] in
            let started = await LiveMediaDownloadManager.shared.start(
                urlString: item.urlString, title: item.title)
            await MainActor.run {
                if started {
                    self?.mediaDownloadStatus?.update(progress: 0.05)
                    self?.mediaDownloadStatus?.showResult(message: "Download started", success: true)
                } else {
                    self?.mediaDownloadStatus?.showResult(
                        message: "Couldn't start the media download.", success: false)
                }
            }
        }
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
        guard viewIfLoaded?.window != nil, !isPresentingSendFailureNotice else { return }
        guard store.items().contains(where: {
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

    /// Explicit send of one article to one ereader destination (the long-press
    /// menu only offers a destination when it's configured).
    private func sendToEreader(_ item: ReadingListItem, destinationID: String) {
        Task { await ArticleSendCoordinator.shared.send(item, toDestinationID: destinationID) }
    }

    /// Builds the article's EPUB off-main and presents the system share sheet so
    /// the user can send it to Apple Books, Kobo, reMarkable, Boox, Files, etc.
    private func shareEbook(_ item: ReadingListItem, from sourceView: UIView) {
        ArticleExportService().presentShareSheet(for: item, from: self, sourceView: sourceView)
    }
}

// MARK: - Drag-and-drop reorder (edit mode, Reading section)

/// In edit mode, a long-press on any Reading row starts a drag (no handle) and the
/// drop reorders within the Reading section, persisting the new order.
/// Reuse of the list's rendering, open behavior, and menu by the search screen.
/// (`configureItemCell`, `open`, and `searchResultMenu` are defined on the class.)
extension ReadingListViewController: ReadingListItemPresenting {}

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

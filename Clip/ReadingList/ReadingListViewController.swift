//
//  ReadingListViewController.swift
//  Clip
//

import ClipMediaDownload
import ClipPlatforms
import ClipDesignSystem
import ClipSend
import ClipStorage
import ClipURLClassification
import ClipModels
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

    init() {
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

    private static let filterDefaultsKey = "readingListFilter"
    private static let collapsedDefaultsKey = "readingListCollapsedSections"

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
    private let filterControl = UISegmentedControl()
    /// Holds natural-width segments so "Media & Links" is never silently clipped.
    private let filterScrollView = UIScrollView()
    private var filterWidthConstraint: NSLayoutConstraint?
    /// Cached natural (content) width of the filter control, remeasured only when the
    /// segments change — read cheaply on every layout pass by `applyFilterWidth`.
    private var filterNaturalWidth: CGFloat = 0
    private var filterHeaderView: UIView?

    /// Non-blocking bottom pill for media-download progress/result (created lazily).
    private weak var mediaDownloadStatus: MediaDownloadStatusView?

    /// The "catch up" button, pinned to the large-title row; its red dot badge
    /// shows when there are unread items to catch up on.
    private let catchUpButton = UIButton(type: .system)
    /// The in-place search overlay cross-faded over the list, if active. Held
    /// strongly: its view is hosted directly in the nav controller's view WITHOUT
    /// VC containment — calling `addChild` on a UINavigationController corrupts its
    /// `children`/stack and makes the list show a back button on return.
    private var searchController: SearchViewController?
    private let catchUpBadge = UIView()
    private var catchUpPinnedToNavBar = false
    /// The tallest the nav bar has been seen (large title expanded) — the baseline the
    /// catch-up button's scroll fade measures collapse against.
    private var expandedNavBarHeight: CGFloat = 0

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
        title = "Reading List"
        navigationController?.navigationBar.prefersLargeTitles = true
        suppressCollapsedTitle()

        tableView.register(
            ReadingListItemCell.self, forCellReuseIdentifier: ReadingListItemCell.reuseID)

        setDefaultNavItems()
        configureCatchUpButton()

        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(pulledToRefresh), for: .valueChanged)

        filterControl.addTarget(self, action: #selector(filterChanged(_:)), for: .valueChanged)
        filterControl.apportionsSegmentWidthsByContent = true
        let header = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: 44))
        filterScrollView.showsHorizontalScrollIndicator = false
        filterScrollView.alwaysBounceHorizontal = true
        filterScrollView.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(filterScrollView)
        filterControl.translatesAutoresizingMaskIntoConstraints = false
        filterScrollView.addSubview(filterControl)
        let width = filterControl.widthAnchor.constraint(equalToConstant: 0)
        filterWidthConstraint = width
        NSLayoutConstraint.activate([
            filterScrollView.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            filterScrollView.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
            filterScrollView.topAnchor.constraint(equalTo: header.topAnchor),
            filterScrollView.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            filterControl.leadingAnchor.constraint(equalTo: filterScrollView.contentLayoutGuide.leadingAnchor),
            filterControl.trailingAnchor.constraint(equalTo: filterScrollView.contentLayoutGuide.trailingAnchor),
            filterControl.centerYAnchor.constraint(equalTo: filterScrollView.frameLayoutGuide.centerYAnchor),
            filterControl.heightAnchor.constraint(equalToConstant: 32),
            width,
        ])
        filterHeaderView = header

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
        pinCatchUpButtonToNavBar()
        catchUpButton.isHidden = isEditing
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Reaching the reading list (on launch or by navigating back) clears the
        // "open the app" follow-up share notifications; first-share prompts that
        // deep-link to settings are left intact.
        NotificationManager.clearFollowupShareNotifications()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let header = filterHeaderView else { return }
        if header.frame.width != tableView.bounds.width {
            header.frame.size.width = tableView.bounds.width
            tableView.tableHeaderView = header
        }
        applyFilterWidth()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // The nav bar is shared with pushed screens — take our title-row button off.
        catchUpButton.removeFromSuperview()
        catchUpPinnedToNavBar = false
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
            if pasteboardCandidate != nil || evaluatingPasteboardURL != nil {
                pasteboardCandidate = nil
                evaluatingPasteboardURL = nil
                reload()
            }
            return
        }
        // Show a spinner row immediately, then fill it in once the preview
        // (content + thumbnail) resolves.
        guard let normalizedURL = URLUnwrapper.ingestURL(from: url.absoluteString) else { return }
        let urlString = normalizedURL.absoluteString
        guard store.item(forURLString: urlString) == nil else { return }
        pasteboardCandidate = nil
        evaluatingPasteboardURL = urlString
        reload()
        Task { [weak self] in
            let candidate = await PasteboardSuggester.shared.evaluate(urlString: urlString)
            await MainActor.run {
                guard let self, self.evaluatingPasteboardURL == urlString else { return }
                self.evaluatingPasteboardURL = nil
                self.pasteboardCandidate = candidate
                self.reload()
            }
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
        transient.state = .ready

        if candidate.isVideo {
            openVideo(transient, from: self)
        } else if let platform = candidate.platform {
            openPlatformItem(transient, platform: platform, from: self)
        } else if let content = candidate.content {
            let reader = ReaderHostFactory.make(
                item: transient, content: content,
                shareProvider: AppReaderShareProvider.shared,
                gazeTrackerFactory: AppGazeTracker.factory)
            navigationController?.pushViewController(reader, animated: true)
        }
    }

    @objc private func reload() {
        // A reorder we just persisted fires this notification; ignore it so the
        // drop animation isn't interrupted by a full reloadData.
        if isApplyingReorder || isAnimatingRowChange { return }

        updateFilterVisibility()
        updateCatchUpButton()
        let unfiltered = store.items()
        let all = unfiltered.filter { filter.includes($0) }
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

        groups = Self.displayOrder.compactMap { section in
            let items = bySection[section] ?? []
            return items.isEmpty ? nil : (section, items)
        }
        tableView.reloadData()
    }

    /// A transient (unsaved) item used to render the pasteboard suggestion row.
    private func displayItem(for candidate: PasteboardCandidate) -> ReadingListItem {
        var item = ReadingListItem(urlString: candidate.urlString)
        item.title = candidate.title
        item.state = .ready
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

    @objc private func filterChanged(_ control: UISegmentedControl) {
        let filters = visibleFilters()
        let index = control.selectedSegmentIndex
        filter = (index >= 0 && index < filters.count) ? filters[index] : .all
        reload()
    }

    /// Shows the filter control only when the list has at least two of the three
    /// kinds (reader / media / price tracker); otherwise it's meaningless. Rebuilds
    /// the segments to match the kinds present and resets a now-invalid selection.
    private func updateFilterVisibility() {
        let shouldShow = ReadingListSectioning.shouldShowFilter(items: store.items())
        guard shouldShow else {
            if filter != .all { filter = .all }
            if tableView.tableHeaderView != nil { tableView.tableHeaderView = nil }
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

        if tableView.tableHeaderView !== filterHeaderView {
            tableView.tableHeaderView = filterHeaderView
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
        Task { await SocialMessageCenter.shared.processInbox() }
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

    /// Pins the catch-up button to the bottom-right of the nav bar — i.e. the
    /// trailing edge of the large "Reading List" title row. (Re-pinned each
    /// appearance since the nav bar is shared across pushed screens.)
    private func pinCatchUpButtonToNavBar() {
        guard !catchUpPinnedToNavBar, let navBar = navigationController?.navigationBar else { return }
        catchUpPinnedToNavBar = true
        navBar.addSubview(catchUpButton)
        NSLayoutConstraint.activate([
            catchUpButton.trailingAnchor.constraint(equalTo: navBar.trailingAnchor, constant: -16),
            catchUpButton.bottomAnchor.constraint(equalTo: navBar.bottomAnchor, constant: -8),
            catchUpButton.widthAnchor.constraint(equalToConstant: 34),
            catchUpButton.heightAnchor.constraint(equalToConstant: 34),
        ])
    }

    /// Shows the red "action needed" dot once there are 10+ unread items, OR whenever
    /// there's an unarchived LOCKED (paywalled, awaiting unlock) save — regardless of
    /// count. Hides the whole button in edit mode.
    private func updateCatchUpButton() {
        catchUpBadge.isHidden = !ReadingListSectioning.shouldShowCatchUpDot(items: store.items())
        catchUpButton.isHidden = isEditing
        updateCatchUpButtonFade()
    }

    /// Fades the catch-up button out as the large-title bar collapses on scroll-up,
    /// tied DIRECTLY to how far the bar has shrunk (not an animation). The bar's own
    /// height is the right signal: during the large-title collapse the scroll view's
    /// `adjustedContentInset.top` shrinks in lock-step with `contentOffset`, so
    /// `contentOffset + inset` stays ~0 and never reflects the collapse. Fade fully out
    /// within the first ~11pt of collapse so the button is gone before it rises into
    /// the +/friends buttons.
    private func updateCatchUpButtonFade() {
        guard let navBar = navigationController?.navigationBar else { return }
        // Pulling DOWN past the top (rubber-band / pull-to-refresh) STRETCHES the
        // large-title bar taller than its resting height. Treat that as fully
        // expanded (button shown) and DON'T let it inflate the peak — otherwise the
        // bar never matches the inflated peak again and the button stays hidden
        // forever after any overscroll.
        if tableView.contentOffset.y < -tableView.adjustedContentInset.top - 1 {
            catchUpButton.alpha = 1
            return
        }
        expandedNavBarHeight = max(expandedNavBarHeight, navBar.frame.height)
        let collapsed = expandedNavBarHeight - navBar.frame.height
        catchUpButton.alpha = max(0, min(1, 1 - collapsed / 11))
    }

    override func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateCatchUpButtonFade()
    }

    // When scrolling comes to REST, settle the fade: if we're back at the top the
    // large-title bar has sprung fully open, so the button must read alpha 1 — the
    // last in-flight `scrollViewDidScroll` can fire before that spring finishes and
    // leave it < 1 with no further event to correct it.
    override func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settleCatchUpButtonFade() }
    override func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { settleCatchUpButtonFade() }
    override func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { settleCatchUpButtonFade() }
    }

    private func settleCatchUpButtonFade() {
        // At rest at (or above) the top the bar is fully expanded → always alpha 1.
        if tableView.contentOffset.y <= -tableView.adjustedContentInset.top + 1 {
            catchUpButton.alpha = 1
        } else {
            updateCatchUpButtonFade()
        }
    }

    @objc private func catchUpTapped() {
        let catchUp = CatchUpViewController(unread: catchUpQueue(), router: self)
        present(catchUp, animated: true)
    }

    // MARK: - Edit mode

    /// The normal (non-editing) nav bar: settings + friends (left); add + search
    /// (right). Plain bar items so the system styles both groups identically — a
    /// glass capsule on iOS 26+, plain icons pre-26 — instead of a custom tinted pill.
    private func setDefaultNavItems() {
        navigationItem.leftBarButtonItems = [
            UIBarButtonItem(
                image: UIImage(systemName: "gearshape"), style: .plain,
                target: self, action: #selector(settingsTapped)),
            UIBarButtonItem(
                image: UIImage(systemName: "person.2"), style: .plain,
                target: self, action: #selector(friendsTapped)),
        ]
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(addTapped)),
            UIBarButtonItem(
                image: UIImage(systemName: "magnifyingglass"), style: .plain,
                target: self, action: #selector(searchTapped)),
        ]
    }

    /// Keeps the large "Reading List" title (it scrolls away on its own) but hides
    /// the COLLAPSED inline title, so it doesn't crowd the four bar buttons once the
    /// large title has scrolled up — the title just goes offscreen with the content.
    private func suppressCollapsedTitle() {
        let largeTitle: [NSAttributedString.Key: Any] = [.foregroundColor: UIColor.label]
        let hiddenInline: [NSAttributedString.Key: Any] = [.foregroundColor: UIColor.clear]

        let atTop = UINavigationBarAppearance()
        atTop.configureWithTransparentBackground()
        atTop.largeTitleTextAttributes = largeTitle
        atTop.titleTextAttributes = hiddenInline
        navigationItem.scrollEdgeAppearance = atTop

        let scrolled = UINavigationBarAppearance()
        scrolled.configureWithDefaultBackground()
        scrolled.largeTitleTextAttributes = largeTitle
        scrolled.titleTextAttributes = hiddenInline   // collapsed title invisible
        navigationItem.standardAppearance = scrolled
        navigationItem.compactAppearance = scrolled
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
        // Hide the list's nav bar UP FRONT (not in the fade completion). The moment
        // the search field becomes first responder the keyboard rises, which triggers
        // a navigation-controller relayout that re-fronts the bar OVER our overlay —
        // a dark band across the top of the results that only clears once layout
        // settles (e.g. on the scroll that dismisses the keyboard). Hiding it before
        // the keyboard appears keeps it down for the whole search session.
        nav.setNavigationBarHidden(true, animated: false)
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
        // Focus immediately (not in the fade completion) so the keyboard rises in
        // parallel with the cross-fade rather than after it.
        search.focusSearchField()
        UIView.animate(withDuration: 0.22) { overlay.alpha = 1 }
    }

    /// Fades the in-place search overlay out, then removes it. Restores the nav bar
    /// first (kept under the still-opaque, fronted overlay) so the list reveals with
    /// its header intact.
    private func dismissSearch() {
        guard let search = searchController else { return }
        navigationController?.setNavigationBarHidden(false, animated: false)
        navigationController?.view.bringSubviewToFront(search.view)
        UIView.animate(withDuration: 0.28, animations: { search.view.alpha = 0 }) { _ in
            self.removeSearch()
        }
    }

    /// Tears the search overlay down immediately (no fade) and restores the nav bar
    /// — used when opening a result so the pushed reader animates over the bare list.
    private func removeSearch() {
        navigationController?.setNavigationBarHidden(false, animated: false)
        searchController?.view.removeFromSuperview()
        searchController = nil
    }

    @objc private func doneEditing() { setEditing(false, animated: true) }

    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        tableView.dragInteractionEnabled = editing
        if isEditing {
            navigationItem.leftBarButtonItem = nil
            let done = UIBarButtonItem(
                barButtonSystemItem: .done, target: self, action: #selector(doneEditing))
            let selectAll = UIBarButtonItem(
                title: "Select All", style: .plain, target: self, action: #selector(selectAllTapped))
            let deleteSelected = UIBarButtonItem(
                image: UIImage(systemName: "trash"), style: .plain,
                target: self, action: #selector(deleteSelectedTapped))
            deleteSelected.tintColor = .systemRed
            // Laid out right-to-left: Done, Select All, Delete Selected.
            navigationItem.rightBarButtonItems = [done, selectAll, deleteSelected]
        } else {
            setDefaultNavItems()
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
        alert.addTextField { field in
            field.placeholder = "https://…"
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.text = UIPasteboard.general.url?.absoluteString
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

    @objc private func settingsTapped() {
        navigationController?.pushViewController(SettingsViewController(), animated: true)
    }

    @objc private func deleteAllArchiveTapped() {
        let archived = groups.first { $0.section == .archive }?.items ?? []
        guard !archived.isEmpty else { return }
        let alert = UIAlertController(
            title: "Delete \(archived.count) archived item\(archived.count == 1 ? "" : "s")?",
            message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Delete All", style: .destructive) { [weak self] _ in
            self?.store.deleteItems(ids: Set(archived.map(\.id)))
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
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
                if let image = candidate.thumbnail { thumbnail = .image(image) }
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
            gazeTrackerFactory: AppGazeTracker.factory)
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
        reader.onClose = { [weak nav] in nav?.dismiss(animated: true) }
        reader.onOpenInBrowser = { [weak nav] archiveURL in
            // This is an escape from archive.is's WKWebView-specific bot gate, so
            // it must leave Queue for the system browser — an SFSafari sheet remains
            // inside our presentation and doesn't provide the requested escape.
            nav?.dismiss(animated: true) {
                UIApplication.shared.open(archiveURL)
            }
        }
        reader.onExtracted = { [weak self, weak nav, weak presenter] in
            nav?.dismiss(animated: true) {
                guard let self, let presenter,
                      let fresh = self.store.item(withID: item.id) else { return }
                self.open(fresh, presenter: presenter)   // now .ready → native reader
            }
        }
        presenter.present(nav, animated: true)
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
            presenter.present(PlatformEmbedViewController(embed: embed, itemID: item.id), animated: true)
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

    /// Sends a URL-less music/podcast item to a friend (via the CloudKit media case).
    private func sendMediaToFriend(_ item: ReadingListItem, from sourceView: UIView) {
        let friends = FriendsStore.shared.items()
        guard !friends.isEmpty else {
            presentInfoAlert(
                title: "No Friends Yet",
                message: "Add friends from the Friends screen to share directly.")
            return
        }
        let sheet = UIAlertController(
            title: item.title ?? "Share", message: nil, preferredStyle: .actionSheet)
        let kind = item.contentPlatform ?? .music
        let creator = item.mediaCreatorName ?? ""
        let title = item.mediaItemTitle ?? item.title ?? ""
        for friend in friends {
            sheet.addAction(UIAlertAction(title: "Send to \(friend.card.username)", style: .default) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    guard await ICloudGate.requireICloud(presenting: self) else { return }
                    do {
                        try await SocialMessageCenter.shared.sendMediaItem(
                            kind: kind, creator: creator, title: title, to: friend)
                        Toast.show("Sent to \(friend.card.username)", from: self)
                    } catch {
                        self.presentInfoAlert(title: "Couldn't Send", message: "\(error)")
                    }
                }
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = sourceView
        present(sheet, animated: true)
    }

    /// Shares a price tracker (all store URLs + best price + threshold) to a friend.
    private func sendTrackerToFriend(_ tracker: PriceTracker, from sourceView: UIView) {
        let friends = FriendsStore.shared.items()
        guard !friends.isEmpty else {
            presentInfoAlert(
                title: "No Friends Yet",
                message: "Add friends from the Friends screen to share directly.")
            return
        }
        let sheet = UIAlertController(
            title: tracker.productName, message: nil, preferredStyle: .actionSheet)
        for friend in friends {
            sheet.addAction(UIAlertAction(
                title: "Send to \(friend.card.username)", style: .default
            ) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    guard await ICloudGate.requireICloud(presenting: self) else { return }
                    do {
                        try await SocialMessageCenter.shared.sendPriceTracker(tracker, to: friend)
                        Toast.show("Sent to \(friend.card.username)", from: self)
                    } catch {
                        self.presentInfoAlert(title: "Couldn't Send", message: "\(error)")
                    }
                }
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = sourceView
        present(sheet, animated: true)
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
        presenter.present(YouTubePlayerViewController(videoID: videoID, itemID: item.id), animated: true)
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
            guard let self else { return }
            let sourceView = self.tableView.cellForRow(at: indexPath) ?? self.view ?? UIView()
            SendToFriendSheet.present(
                from: self, sourceView: sourceView,
                urlString: item.urlString, title: item.title)
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
        let delete = UIAction(
            title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive
        ) { [weak self] _ in
            self?.deleteItemAnimated(item)
        }
        // Videos: share to friends + delete. Documents: ereaders + read +
        // delete. Articles: everything. Each ereader row shows only when
        // that destination is set up.
        let sendMediaToFriend = UIAction(
            title: "Send to Friend…",
            image: UIImage(systemName: "person.2")
        ) { [weak self] _ in
            guard let self else { return }
            let sourceView = self.tableView.cellForRow(at: indexPath) ?? self.view ?? UIView()
            self.sendMediaToFriend(item, from: sourceView)
        }

        // Price trackers get a focused menu: share the tracker to a friend,
        // archive/unarchive it (archived = hidden + excluded from refresh), delete.
        if let tracker = item.priceTracker {
            var trackerChildren: [UIAction] = []
            if !FriendsStore.shared.items().isEmpty {
                trackerChildren.append(UIAction(
                    title: "Send to Friend…", image: UIImage(systemName: "person.2")
                ) { [weak self] _ in
                    guard let self else { return }
                    let sourceView = self.tableView.cellForRow(at: indexPath) ?? self.view ?? UIView()
                    self.sendTrackerToFriend(tracker, from: sourceView)
                })
            }
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
        if item.canShareToFriends {
            children.append(sendToFriend)
        } else if item.isURLlessMedia {
            children.append(sendMediaToFriend)
        }
        // Any item that kept a real web URL (articles AND platform items like
        // Reddit/Spotify/X) can share that link.
        if item.isShareable {
            children.append(shareLink)
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
                    from: presenter, sourceView: sourceView,
                    urlString: item.urlString, title: item.title)
            })
        }
        if item.isShareable {
            children.append(UIAction(title: "Share Link…", image: UIImage(systemName: "link")) { _ in
                SendToFriendSheet.shareLink(urlString: item.urlString, from: presenter, sourceView: sourceView)
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

    /// Downloads the first media item of an X/Instagram/TikTok post to the photo
    /// library. Progress + result show in a non-blocking bottom status pill (the
    /// list stays interactive and the pill never appears over the reader), and the
    /// work continues if the app is backgrounded (a background task assertion).
    private func downloadMediaToPhotos(_ item: ReadingListItem) {
        guard let url = URL(string: item.urlString) else { return }
        let status = mediaDownloadStatusView()
        status.startProgress()

        var backgroundTask = UIBackgroundTaskIdentifier.invalid
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "media-download") {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
        let endBackground = {
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
        }

        Task { [weak self] in
            do {
                _ = try await MediaDownloadService().downloadFirstMediaToPhotos(from: url) { progress in
                    Task { @MainActor in self?.mediaDownloadStatus?.update(progress: progress) }
                }
                await MainActor.run {
                    self?.mediaDownloadStatus?.showResult(message: "Saved to Photos", success: true)
                    endBackground()
                }
            } catch {
                let message = (error as? MediaDownloadError)?.message ?? "Couldn't save the media."
                await MainActor.run {
                    self?.mediaDownloadStatus?.showResult(message: message, success: false)
                    endBackground()
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

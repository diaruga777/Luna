//
//  ArticleCardsViewController.swift
//  Luna
//
//  The Reader's root screen: a carousel of full-height cards over the reading
//  list, one article per card, replacing the sectioned table. The generic
//  carousel machinery lives in LunaDesignSystem/CardCarousel (shared with the
//  Downloader); this controller adapts reading-list articles into cards:
//
//  - EVERY card embeds the full live reader, laid out at fullscreen size and
//    clipped by the card, so paging never shows a placeholder and expansion
//    never moves the content — only the card's edges travel.
//  - Expansion is scroll-driven and interactive: as the embedded reader
//    scrolls away from its starting position (either direction, when it
//    didn't start at the top), the card stretches over the whole screen —
//    and it settles back into place as the content returns to its top, so
//    top-of-article always shows the card. Tapping the card — links
//    included — pins it fullscreen (starting RSVP playback is such a tap);
//    the reader's root back button or pulling past the top brings it home.
//  - Long-pressing the centered card runs the link-preview RSVP experience
//    (glass card, drag gestures, haptics) for the card's article, without
//    going fullscreen.
//  - Horizontal swipes INSIDE the card page to the neighbor (readers have no
//    timeline to scrub); the scrub strip shows bigger title chips.
//

import LunaArchiveReader
import LunaDesignSystem
import LunaMailAccount
import LunaModels
import LunaReaderUI
import LunaReadingList
import LunaReadingListUI
import LunaSocialUI
import LunaStorage
import LunaTransitions
import LunaURLClassification
import UIKit

final class ArticleCardsViewController: UIViewController {

    private let header = NavHeaderBar()
    private let store = ReadingListStore.shared
    private let carousel = CardCarouselViewController()
    private let emptyView = EmptyArticlesView()
    private let catchUpButton = UIButton(type: .system)
    private let catchUpBadge = UIView()
    private var items: [ReadingListItem] = []
    private var appliedFingerprint: [String] = []
    /// The press-driven RSVP preview for the centered card, while a long-press
    /// is live (or it has locked itself into playback).
    private var rsvpSession: ArticleRSVPPreviewSession?
    private var rsvpPressStart = CGPoint.zero

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        var style = CardCarouselStyle()
        style.edgeGap = 10
        style.fillsVertically = true
        style.pagesOnInCardSwipes = true
        style.scrubberStyle = .titles
        carousel.style = style
        carousel.managesAudioSession = false   // Reader has its own audio stack.
        carousel.dataSource = self
        carousel.delegate = self
        configureExpansion()
        addChild(carousel)
        view.addSubview(carousel.view)
        carousel.view.translatesAutoresizingMaskIntoConstraints = false
        carousel.didMove(toParent: self)

        emptyView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyView)

        let headerBottom = header.mount(in: self)
        setHeaderControls()

        NSLayoutConstraint.activate([
            carousel.view.topAnchor.constraint(equalTo: view.topAnchor),
            carousel.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            carousel.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            carousel.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyView.topAnchor.constraint(equalTo: headerBottom),
            emptyView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        NotificationCenter.default.addObserver(
            self, selector: #selector(reload), name: .readingListChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(reload), name: UIApplication.didBecomeActiveNotification,
            object: nil)
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
        header.setManagedHeight(topSafeAreaInset: view.safeAreaInsets.top)
        carousel.setTopInset(view.safeAreaInsets.top + NavHeaderBar.barHeight + 8)
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        header.setManagedHeight(topSafeAreaInset: view.safeAreaInsets.top)
        carousel.setTopInset(view.safeAreaInsets.top + NavHeaderBar.barHeight + 8)
    }

    // MARK: - Header

    private func setHeaderControls() {
        configureCatchUpButton()
        header.setLeadingControls([
            NavHeaderBar.imageButton(
                systemName: "gearshape", target: self,
                action: #selector(settingsTapped), accessibilityLabel: "Settings"),
            NavHeaderBar.imageButton(
                systemName: "person.2", target: self,
                action: #selector(friendsTapped), accessibilityLabel: "Friends"),
        ])
        header.setTrailingControls([
            catchUpButton,
            NavHeaderBar.imageButton(
                systemName: "plus", target: self,
                action: #selector(addTapped), accessibilityLabel: "Add"),
        ])
    }

    /// The catch-up entry moved from the old list's scrolling header row into
    /// the pinned bar (the carousel has no scrolling header). Same icon + red
    /// "action needed" dot as before.
    private func configureCatchUpButton() {
        catchUpButton.setImage(
            UIImage(systemName: "rectangle.stack",
                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)),
            for: .normal)
        catchUpButton.tintColor = .label
        catchUpButton.accessibilityLabel = "Catch up"
        catchUpButton.addTarget(self, action: #selector(catchUpTapped), for: .touchUpInside)
        catchUpButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            catchUpButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 34),
            catchUpButton.heightAnchor.constraint(equalToConstant: NavHeaderBar.barHeight),
        ])
        catchUpBadge.backgroundColor = .systemRed
        catchUpBadge.layer.cornerRadius = 4.5
        catchUpBadge.isUserInteractionEnabled = false
        catchUpBadge.isHidden = true
        catchUpBadge.translatesAutoresizingMaskIntoConstraints = false
        catchUpButton.addSubview(catchUpBadge)
        NSLayoutConstraint.activate([
            catchUpBadge.widthAnchor.constraint(equalToConstant: 9),
            catchUpBadge.heightAnchor.constraint(equalToConstant: 9),
            catchUpBadge.trailingAnchor.constraint(equalTo: catchUpButton.trailingAnchor, constant: -2),
            catchUpBadge.topAnchor.constraint(equalTo: catchUpButton.topAnchor, constant: 8),
        ])
    }

    @objc private func settingsTapped() {
        navigationController?.pushViewController(SettingsViewController(), animated: true)
    }

    @objc private func friendsTapped() {
        navigationController?.pushViewController(FriendsViewController(), animated: true)
    }

    @objc private func addTapped() {
        let alert = UIAlertController(title: "Save Article", message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "https://..."
            field.keyboardType = .URL
            field.autocapitalizationType = .none
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak alert] _ in
            guard let entered = alert?.textFields?.first?.text?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  let normalized = URLUnwrapper.ingestURL(from: entered, allowBareHost: true)
            else { return }
            Task {
                _ = await ReadingListIngestor.shared.handleSavePress(
                    urlString: normalized.absoluteString)
            }
        })
        DotMatrixModal.present(alert, from: self)
    }

    @objc private func catchUpTapped() {
        let queue = ReadingListSectioning.catchUpQueue(items: store.items())
            .filter { ReadingListSectioning.rendersAsReader($0) }
        let catchUp = CatchUpViewController(unread: queue, router: self)
        DotMatrixModal.present(catchUp, from: self)
    }

    // MARK: - Data

    @objc private func reload() {
        let updated = store.items()
            .filter { ReadingListSectioning.rendersAsReader($0) }
            .sorted { ($0.bumpDate ?? $0.dateAdded) > ($1.bumpDate ?? $1.dateAdded) }
        let fingerprint = updated.map {
            "\($0.id)|\($0.title ?? "")|\($0.state)|\($0.thumbnailFileName ?? "")"
        }
        updateCatchUpBadge()
        guard fingerprint != appliedFingerprint else { return }
        appliedFingerprint = fingerprint

        let centeredID = items.indices.contains(carousel.currentIndex)
            ? items[carousel.currentIndex].id : nil
        items = updated
        let centeredIndex = centeredID.flatMap { id in items.firstIndex { $0.id == id } }
        carousel.reloadData(centeringAt: centeredIndex)
        emptyView.isHidden = !items.isEmpty
        carousel.view.isHidden = items.isEmpty
    }

    private func updateCatchUpBadge() {
        let needsEmailSetup = !EmailAccountStore.shared.isConfigured
        catchUpBadge.isHidden = !(ReadingListSectioning.shouldShowCatchUpDot(items: store.items())
            || needsEmailSetup)
    }

    // MARK: - Opening / expansion

    /// Expands the centered card into the fullscreen reader: the live embedded
    /// reader is detached from the card and pushed with the card-expand
    /// transition, so scroll position, rabbit-hole layers, and mode carry over.
    /// A tap pinned the card fullscreen even though the content hasn't been
    /// scrolled away from the top yet; cleared once scrolling takes over (or
    /// the user pulls back to the top / taps the reader's back button).
    private var isForcedExpanded = false

    /// Wires the scroll-driven expansion: the centered card stretches over the
    /// whole screen (header included) as its embedded reader scrolls away from
    /// the top, and settles back into place as the reader returns to it.
    private func configureExpansion() {
        carousel.expansionTargetFrameProvider = { [weak self] in
            guard let self else { return .zero }
            return self.view.convert(self.view.bounds, to: self.carousel.view)
        }
        carousel.onExpansionFractionChanged = { [weak self] fraction in
            guard let self else { return }
            // The header is PUSHED up (not faded) as the card's top edge rises.
            let travel = self.view.safeAreaInsets.top + NavHeaderBar.barHeight
            self.header.transform = CGAffineTransform(translationX: 0, y: -fraction * travel)
            self.header.alpha = 1 - fraction * 0.6
            (self.carousel.contentController(at: self.carousel.currentIndex)
                as? ReaderCardContentViewController)?.setExpansionFraction(fraction)
        }
    }

    /// Tap (anywhere on the centered card, links included): pin fullscreen.
    private func expandCurrentCard() {
        guard presentedViewController == nil else { return }
        let index = carousel.currentIndex
        guard items.indices.contains(index) else { return }
        let item = items[index]
        if item.state == .needsCaptcha, let url = item.url {
            presentArchiveReader(for: item, articleURL: url)
            store.markReadState(.opened, for: item.id)
            return
        }
        guard item.state == .ready, carousel.expansionFraction < 1 else { return }
        isForcedExpanded = true
        carousel.setExpansionFraction(1, animated: true)
    }

    /// Reader root back button / pull-past-top: settle back into the card.
    private func contractCurrentCard() {
        isForcedExpanded = false
        carousel.setExpansionFraction(0, animated: true)
    }

    /// RSVP boundary (non-interactive by design): scrubbing/rewinding to the
    /// very start shrinks the fullscreen reader back into the card; leaving
    /// the start expands it again.
    private func handleRSVPIndexChange(_ index: Int) {
        if index == 0 {
            guard carousel.expansionFraction > 0 else { return }
            contractCurrentCard()
        } else {
            guard carousel.expansionFraction < 1 else { return }
            isForcedExpanded = true
            carousel.setExpansionFraction(1, animated: true)
        }
    }

    private func makeReader(for item: ReadingListItem) -> UIViewController? {
        guard let content = store.content(for: item) else { return nil }
        return ReaderHostFactory.make(
            item: item, content: content,
            shareProvider: AppReaderShareProvider.shared,
            transition: DotMatrixRabbitHoleTransition())
    }

    /// Deep-link / external open (SceneDelegate): plain fullscreen push, no
    /// card choreography.
    func openExternally(_ item: ReadingListItem) {
        if item.state == .needsCaptcha, let url = item.url {
            presentArchiveReader(for: item, articleURL: url)
            store.markReadState(.opened, for: item.id)
            return
        }
        guard let reader = makeReader(for: item) else { return }
        navigationController?.pushViewController(reader, animated: true)
    }

    /// Same archive.today CAPTCHA flow as the old list root (see
    /// ReadingListViewController.presentArchiveReader): on successful
    /// extraction, reopen the now-.ready item fullscreen.
    private func presentArchiveReader(for item: ReadingListItem, articleURL: URL) {
        let reader = ArchiveWebReaderViewController(
            articleURL: articleURL, itemID: item.id, store: store)
        let nav = UINavigationController(rootViewController: reader)
        nav.installDotMatrixTransitions()
        reader.onClose = { [weak nav] in
            guard let nav else { return }
            DotMatrixModal.dismiss(nav)
        }
        reader.onOpenInBrowser = { [weak nav] archiveURL in
            guard let nav else { return }
            DotMatrixModal.dismiss(nav) {
                UIApplication.shared.open(archiveURL)
            }
        }
        reader.onExtracted = { [weak self, weak nav] in
            guard let nav else { return }
            DotMatrixModal.dismiss(nav) {
                guard let self, let fresh = self.store.item(withID: item.id) else { return }
                ReadingListIngestor.shared.backfillMissingThumbnails()
                self.openExternally(fresh)
            }
        }
        DotMatrixModal.present(nav, from: self)
    }

    // MARK: - Carousel data source (see CardCarouselDataSource conformance below)

    func numberOfCards(in carousel: CardCarouselViewController) -> Int {
        items.count
    }

    func carousel(
        _ carousel: CardCarouselViewController,
        contentControllerForCardAt index: Int
    ) -> CardContentViewController {
        guard items.indices.contains(index) else { return CardContentViewController() }
        let content = ReaderCardContentViewController(item: items[index])
        content.onContractRequested = { [weak self] in self?.contractCurrentCard() }
        content.onScrollBoundary = { [weak self] expands in
            guard let self else { return }
            if expands {
                guard self.carousel.expansionFraction < 1 else { return }
                self.isForcedExpanded = true
                self.carousel.setExpansionFraction(1, animated: true)
            } else {
                guard self.carousel.expansionFraction > 0 else { return }
                self.contractCurrentCard()
            }
        }
        content.onRSVPIndexChanged = { [weak self] index in
            self?.handleRSVPIndexChange(index)
        }
        content.expansionDistanceProvider = { [weak self] in
            self?.carousel.restingCardTopGap ?? 120
        }
        return content
    }

    func carousel(
        _ carousel: CardCarouselViewController,
        loadThumbnailForCardAt index: Int,
        completion: @escaping (UIImage?) -> Void
    ) {
        completion(nil)   // titles-style strip; no image chips
    }

    func carousel(
        _ carousel: CardCarouselViewController,
        titleForCardAt index: Int
    ) -> String? {
        guard items.indices.contains(index) else { return nil }
        let item = items[index]
        return item.title ?? item.url?.host ?? item.urlString
    }
}

// MARK: - Carousel delegate

extension ArticleCardsViewController: CardCarouselDataSource {}

extension ArticleCardsViewController: CardCarouselDelegate {

    func carousel(_ carousel: CardCarouselViewController, didCenterCardAt index: Int) {
        guard items.indices.contains(index) else { return }
        store.markReadState(.opened, for: items[index].id)
    }

    func carousel(_ carousel: CardCarouselViewController, didTapCenteredCardAt index: Int) {
        expandCurrentCard()
    }

    /// Long-press = the link-preview RSVP experience for the card's article:
    /// glass card with appearance animation and haptics, drag up to lock, drag
    /// left/right to pause/speed — all driven by the same press.
    func carousel(
        _ carousel: CardCarouselViewController,
        longPress gesture: UILongPressGestureRecognizer,
        onCenteredCardAt index: Int
    ) {
        switch gesture.state {
        case .began:
            guard items.indices.contains(index), presentedViewController == nil,
                  rsvpSession == nil
            else { return }
            let item = items[index]
            guard item.state == .ready, let content = store.content(for: item) else { return }
            rsvpPressStart = gesture.location(in: view)
            rsvpSession = ArticleRSVPPreviewSession(
                host: self, item: item, content: content, anchorPoint: rsvpPressStart)
        case .changed:
            let point = gesture.location(in: view)
            rsvpSession?.update(
                translation: CGPoint(
                    x: point.x - rsvpPressStart.x, y: point.y - rsvpPressStart.y),
                fingerPoint: point)
        case .ended:
            rsvpSession?.finish()
            rsvpSession = nil
        case .cancelled, .failed:
            rsvpSession?.cancel()
            rsvpSession = nil
        default:
            break
        }
    }
}

extension ArticleCardsViewController: CatchUpRouting {
    // The catch-up queue is pre-filtered to reader articles (rendered inline by
    // CatchUpViewController itself), so there is never a platform item to route.
    @discardableResult
    func openItem(_ item: ReadingListItem, presentingFrom presenter: UIViewController) -> Bool {
        false
    }
}

// MARK: - Card content

/// One article card: the FULL live reader, always embedded (side cards too, so
/// paging never shows a placeholder). The reader is laid out at fullscreen size
/// and the card just clips it — expanding/contracting moves the card's edges,
/// never the text, so nothing inside shifts relative to the screen and the
/// reader's own chrome only comes into view as the card reaches the top. A
/// pinned title bar identifies the card while its content is scrolled.
private final class ReaderCardContentViewController: CardContentViewController {

    /// The user pulled past the top (rubber band) or tapped the reader's root
    /// back button while pinned fullscreen.
    var onContractRequested: (() -> Void)?
    /// The reader scrolled across the expansion boundary: fullscreen (true)
    /// when the content moves away from its top, back to the card (false) as
    /// it returns — top-of-article ⇒ card, always.
    var onScrollBoundary: ((Bool) -> Void)?
    /// The embedded reader's RSVP position changed (0 = scrubbed to the start).
    var onRSVPIndexChanged: ((Int) -> Void)?
    /// Host-provided: distance (pt) from the resting card top to the screen
    /// top — the vertical compensation that keeps the reader screen-anchored
    /// through the expansion.
    var expansionDistanceProvider: (() -> CGFloat)?

    private let item: ReadingListItem
    private let titleBar = UIView()
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private var reader: UIViewController?
    private var scrollObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private var expansionFraction: CGFloat = 0
    private var isCentered = false

    private var expansionDistance: CGFloat {
        max(expansionDistanceProvider?() ?? 120, 1)
    }

    init(item: ReadingListItem) {
        self.item = item
        super.init()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        embedReaderIfPossible()

        // Pinned title: always identifies the card in card mode (the article's
        // own title scrolls away with the content); fades out as the card
        // expands and the reader chrome takes over.
        titleBar.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.94)
        view.addSubview(titleBar)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.text = item.title ?? item.url?.host ?? item.urlString
        titleBar.addSubview(titleLabel)

        if reader == nil {
            statusLabel.font = .preferredFont(forTextStyle: .subheadline)
            statusLabel.textColor = .secondaryLabel
            statusLabel.textAlignment = .center
            statusLabel.numberOfLines = 0
            switch item.state {
            case .pending: statusLabel.text = "Fetching…"
            case .failed: statusLabel.text = "Couldn't fetch this article"
            case .needsCaptcha: statusLabel.text = "Locked — tap to unlock"
            case .ready: statusLabel.text = nil
            }
            statusLabel.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(statusLabel)
            NSLayoutConstraint.activate([
                statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
                statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
                statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            ])
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutReader()
        let barHeight: CGFloat = 36
        titleBar.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: barHeight)
        titleLabel.frame = titleBar.bounds.insetBy(dx: 16, dy: 0)
    }

    /// The reader occupies a SCREEN-sized rect: horizontally centered on the
    /// card (the card clips a symmetric sliver each side — inside the text
    /// margins, so the text's screen insets never change), vertically anchored
    /// so its top sits `(1 - fraction) * distance` above the card — exactly the
    /// screen top at rest and at full expansion alike. The card's edges do all
    /// the moving; the content never shifts.
    private func layoutReader() {
        guard let reader, let window = view.window else { return }
        // Vertically window-anchored: computed during layout passes, so an
        // animated card move relayouts the reader reciprocally INSIDE the same
        // transaction — net zero window motion at every frame. (Applying this
        // outside the animation, or per scroll tick, shifts the scroll view
        // mid-pan and feeds back into the drag, freezing scrolling entirely.)
        // Horizontally CARD-anchored (centered): for the centered/expanded card
        // this is pixel-identical to window anchoring, but a side card — and
        // crucially a card the eclipse translates via center/transform, which
        // triggers NO layout pass — carries its content with it instead of
        // exposing the blank margin beyond a stale window-anchored frame
        // (the "gray card with only a title" during every page transition).
        var frame = view.convert(window.bounds, from: window)
        frame.origin.x = (view.bounds.width - frame.width) / 2
        reader.view.frame = frame
    }

    /// Host-fed on every carousel fraction change.
    func setExpansionFraction(_ fraction: CGFloat) {
        expansionFraction = min(max(fraction, 0), 1)
        titleBar.alpha = 1 - expansionFraction
    }

    // MARK: - Live reader lifecycle

    override func cardDidBecomeCentered() {
        super.cardDidBecomeCentered()
        isCentered = true
        // Slots moved (paging translates cards without a bounds change, which
        // wouldn't trigger layout) — re-anchor the reader to the window.
        viewIfLoaded?.setNeedsLayout()
    }

    override func cardDidLeaveCenter() {
        super.cardDidLeaveCenter()
        isCentered = false
        viewIfLoaded?.setNeedsLayout()
    }

    private func embedReaderIfPossible() {
        guard reader == nil, item.state == .ready,
              let content = ReadingListStore.shared.content(for: item)
        else { return }
        let reader = ReaderHostFactory.make(
            item: item, content: content,
            shareProvider: AppReaderShareProvider.shared,
            transition: DotMatrixRabbitHoleTransition())
        addChild(reader)
        reader.view.autoresizingMask = []
        view.insertSubview(reader.view, at: 0)
        reader.didMove(toParent: self)
        (reader as? RabbitHoleReaderViewController)?.onRootBack = { [weak self] in
            guard let self, self.isCentered else { return }
            self.onContractRequested?()
        }
        self.reader = reader
        layoutReader()

        // No push transition happens for an embedded reader — kick its Phase-2
        // full-content load explicitly (twice; it's idempotent and the second
        // covers a not-yet-laid-out first call).
        for delay in [0.05, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                ((self?.reader) as? RabbitHoleReaderViewController)?.beginEmbeddedPresentation()
            }
        }

        // The reader builds (and later swaps) its scroll views as content
        // loads, so sweep for new ones a few times after embedding.
        for delay in [0.7, 2.0, 4.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.observeReaderScrollViews()
            }
        }
    }

    /// Drives the expansion fraction from the reader's scroll position (KVO on
    /// every scroll view in the reader). `isDragging`/`isDecelerating` filters
    /// out restore-position and text-selection jitter; only the CENTERED card
    /// reports (side cards' readers are live but inert).
    private func observeReaderScrollViews() {
        guard let reader else { return }
        for rsvp in Self.rsvpControllers(of: reader) {
            rsvp.onFrameIndexChanged = { [weak self] index in
                guard let self, self.isCentered else { return }
                self.onRSVPIndexChanged?(index)
            }
        }
        for scrollView in Self.scrollViews(in: reader.view) {
            let key = ObjectIdentifier(scrollView)
            guard scrollObservations[key] == nil else { continue }
            // Synchronous on purpose: isDragging/isDecelerating must be sampled
            // at change time — deferred to the next runloop, a quick flick's
            // whole gesture reads as already-settled.
            scrollObservations[key] = scrollView.observe(\.contentOffset, options: [.new]) {
                [weak self] scrollView, _ in
                self?.handleOffsetChange(of: scrollView)
            }
        }
    }

    /// Threshold-driven (not per-frame): continuously repositioning the
    /// reader against its own live pan feeds back into the scroll and freezes
    /// it, so the card snaps between states with a short animation instead.
    private func handleOffsetChange(of scrollView: UIScrollView) {
        guard isCentered, scrollView.isDragging || scrollView.isDecelerating else { return }
        // Distance from the content's top (0 = at the top).
        let position = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        if position <= 30 {
            onScrollBoundary?(false)
        } else if position > 90 {
            onScrollBoundary?(true)
        }
    }

    private static func rsvpControllers(of root: UIViewController) -> [RSVPViewController] {
        var found: [RSVPViewController] = []
        for child in root.children {
            if let rsvp = child as? RSVPViewController { found.append(rsvp) }
            found.append(contentsOf: rsvpControllers(of: child))
        }
        return found
    }

    private static func scrollViews(in root: UIView, depth: Int = 0) -> [UIScrollView] {
        guard depth < 8 else { return [] }
        var found: [UIScrollView] = []
        for subview in root.subviews {
            if let scroll = subview as? UIScrollView { found.append(scroll) }
            found.append(contentsOf: scrollViews(in: subview, depth: depth + 1))
        }
        return found
    }
}

// MARK: - Empty state

private final class EmptyArticlesView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        let image = UIImageView(image: UIImage(systemName: "books.vertical"))
        image.tintColor = .tertiaryLabel
        image.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 44, weight: .regular)
        let title = UILabel()
        title.text = "No Saved Articles"
        title.font = .preferredFont(forTextStyle: .title3)
        title.textColor = .label
        let subtitle = UILabel()
        subtitle.text = "Articles you save appear here as cards."
        subtitle.font = .preferredFont(forTextStyle: .subheadline)
        subtitle.textColor = .secondaryLabel
        subtitle.textAlignment = .center
        subtitle.numberOfLines = 0
        let stack = UIStackView(arrangedSubviews: [image, title, subtitle])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -32),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

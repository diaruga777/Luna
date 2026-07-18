//
//  ArticleCardsViewController.swift
//  Luna
//
//  The Reader's root screen: a carousel of full-height cards over the reading
//  list, one article per card, replacing the sectioned table. The generic
//  carousel machinery lives in LunaDesignSystem/CardCarousel (shared with the
//  Downloader); this controller adapts reading-list articles into cards:
//
//  - The CENTERED card embeds a live reader (RabbitHoleReaderViewController) —
//    scrollable, links tappable. Side cards show a lightweight cover+title
//    preview (they rest under the carousel's 70% dim anyway), keeping at most
//    one live reader mounted.
//  - Expansion is scroll-driven and interactive: as the embedded reader
//    scrolls away from its starting position (either direction, when it
//    didn't start at the top), the card stretches over the whole screen —
//    and it settles back into place as the content returns to its top, so
//    top-of-article always shows the card. Tapping the card — links
//    included — pins it fullscreen (starting RSVP playback is such a tap);
//    the reader's root back button or pulling past the top brings it home.
//  - Long-pressing the centered card shows an RSVP popover without going
//    fullscreen.
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
            carousel.view.topAnchor.constraint(equalTo: headerBottom),
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
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        header.setManagedHeight(topSafeAreaInset: view.safeAreaInsets.top)
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
    /// Expansion is briefly suppressed after the RSVP popover dismisses — its
    /// dismissal tap otherwise passes through as a card tap and expands.
    private var suppressExpansionUntil = Date.distantPast
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
            self?.header.alpha = 1 - fraction
        }
    }

    /// Continuous fraction from the embedded reader's scroll position.
    private func handleScrollFraction(_ fraction: CGFloat) {
        if isForcedExpanded {
            // The scroll caught up with the pinned state — hand control back.
            if fraction >= 1 { isForcedExpanded = false }
            return
        }
        carousel.setExpansionFraction(fraction)
    }

    /// Tap (anywhere on the centered card, links included): pin fullscreen.
    private func expandCurrentCard() {
        guard presentedViewController == nil, Date() >= suppressExpansionUntil else { return }
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

    /// RSVP without leaving the carousel: a popover pinned to the card. Tapping
    /// play inside it is a card tap, so starting playback expands fullscreen.
    private func presentRSVPPopover(forCardAt index: Int) {
        guard items.indices.contains(index), presentedViewController == nil else { return }
        let item = items[index]
        guard item.state == .ready, let content = store.content(for: item) else { return }
        let rsvp = RSVPViewController(
            item: item, content: content, shareProvider: AppReaderShareProvider.shared)
        rsvp.modalPresentationStyle = .popover
        rsvp.preferredContentSize = CGSize(width: 340, height: 300)
        if let popover = rsvp.popoverPresentationController {
            let source = carousel.cardView(at: index) ?? view!
            popover.sourceView = source
            popover.sourceRect = CGRect(
                x: source.bounds.midX, y: source.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
            popover.passthroughViews = []
            popover.delegate = self
        }
        present(rsvp, animated: true)
    }
}

// MARK: - Carousel data source

extension ArticleCardsViewController: CardCarouselDataSource {

    func numberOfCards(in carousel: CardCarouselViewController) -> Int {
        items.count
    }

    func carousel(
        _ carousel: CardCarouselViewController,
        contentControllerForCardAt index: Int
    ) -> CardContentViewController {
        guard items.indices.contains(index) else { return CardContentViewController() }
        let content = ReaderCardContentViewController(item: items[index])
        content.onScrollFraction = { [weak self] fraction in
            self?.handleScrollFraction(fraction)
        }
        content.onContractRequested = { [weak self] in self?.contractCurrentCard() }
        content.onScrollSettled = { [weak self] expands in
            guard let self, !self.isForcedExpanded else { return }
            self.carousel.setExpansionFraction(expands ? 1 : 0, animated: true)
        }
        content.onRSVPIndexChanged = { [weak self] index in
            self?.handleRSVPIndexChange(index)
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

extension ArticleCardsViewController: CardCarouselDelegate {

    func carousel(_ carousel: CardCarouselViewController, didCenterCardAt index: Int) {
        guard items.indices.contains(index) else { return }
        store.markReadState(.opened, for: items[index].id)
    }

    func carousel(_ carousel: CardCarouselViewController, didTapCenteredCardAt index: Int) {
        expandCurrentCard()
    }

    func carousel(_ carousel: CardCarouselViewController, didLongPressCenteredCardAt index: Int) {
        presentRSVPPopover(forCardAt: index)
    }
}

extension ArticleCardsViewController: UIPopoverPresentationControllerDelegate {
    func adaptivePresentationStyle(
        for controller: UIPresentationController,
        traitCollection: UITraitCollection
    ) -> UIModalPresentationStyle {
        .none   // keep the RSVP popover a popover on iPhone
    }

    func presentationControllerWillDismiss(_ presentationController: UIPresentationController) {
        suppressExpansionUntil = Date().addingTimeInterval(0.4)
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

/// One article card: a cover+title preview at rest; the live embedded reader
/// while centered. The preview stays mounted beneath the reader so teardown
/// (paging away / detaching for expansion) reveals it without a flash.
private final class ReaderCardContentViewController: CardContentViewController {

    /// Continuous expansion fraction derived from the reader's scroll position:
    /// grows as the reader moves away from where it started (either direction,
    /// when it didn't start at the top), and always falls back to 0 as the
    /// content approaches its top — top-of-article ⇒ card, always.
    var onScrollFraction: ((CGFloat) -> Void)?
    /// The user pulled past the top (rubber band) or tapped the reader's root
    /// back button while pinned fullscreen.
    var onContractRequested: (() -> Void)?
    /// The scroll settled mid-expansion: snap fully open (true) or home (false).
    var onScrollSettled: ((Bool) -> Void)?
    /// The embedded reader's RSVP position changed (0 = scrubbed to the start).
    var onRSVPIndexChanged: ((Int) -> Void)?
    /// Per scroll view — an idle sibling's programmatic offset nudges must not
    /// trip the settle logic for a drag happening in another scroll view.
    private var lastReportedFractions: [ObjectIdentifier: CGFloat] = [:]

    private let item: ReadingListItem
    private let coverView = UIImageView()
    private let scrimView = UIView()
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private var reader: UIViewController?
    private var scrollObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]
    /// Where each observed scroll view rested when observation began (distance
    /// from its top), so expansion measures movement away from the STARTING
    /// point — in either direction — not from the absolute top.
    private var scrollBaselines: [ObjectIdentifier: CGFloat] = [:]
    /// Points of scroll travel that complete the card→fullscreen expansion.
    private static let expansionDistance: CGFloat = 140

    init(item: ReadingListItem) {
        self.item = item
        super.init()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        coverView.contentMode = .scaleAspectFill
        coverView.clipsToBounds = true
        coverView.frame = view.bounds
        coverView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(coverView)

        scrimView.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        scrimView.frame = view.bounds
        scrimView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrimView.isHidden = true
        view.addSubview(scrimView)

        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 0
        titleLabel.text = item.title ?? item.url?.host ?? item.urlString
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleLabel)

        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .secondaryLabel
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)
        switch item.state {
        case .pending: statusLabel.text = "Fetching…"
        case .failed: statusLabel.text = "Couldn't fetch this article"
        case .needsCaptcha: statusLabel.text = "Locked — tap to unlock"
        case .ready: statusLabel.text = nil
        }

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            titleLabel.bottomAnchor.constraint(equalTo: view.centerYAnchor, constant: 20),
            statusLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            statusLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
        ])

        if let fileName = item.thumbnailFileName {
            let path = ReadingListStore.shared.articlesDirectory
                .appendingPathComponent(fileName).path
            DownsampledImageLoader.load(
                path: path,
                pointSize: CGSize(width: 500, height: 500),
                scale: UIScreen.main.scale,
                isStale: { false }
            ) { [weak self] image in
                guard let self, let image else { return }
                self.coverView.image = image
                // Cover art behind text needs a scrim to keep the title legible.
                self.scrimView.isHidden = false
                self.titleLabel.textColor = .white
                self.statusLabel.textColor = UIColor.white.withAlphaComponent(0.8)
            }
        }
    }

    // MARK: - Live reader lifecycle

    override func cardDidBecomeCentered() {
        super.cardDidBecomeCentered()
        embedReaderIfPossible()
    }

    override func cardDidLeaveCenter() {
        super.cardDidLeaveCenter()
        tearDownReader()
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
        reader.view.frame = view.bounds
        reader.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(reader.view)
        reader.didMove(toParent: self)
        self.reader = reader
        (reader as? RabbitHoleReaderViewController)?.onRootBack = { [weak self] in
            self?.onContractRequested?()
        }

        // The reader builds (and later swaps) its scroll views as content
        // loads, so sweep for new ones a few times after embedding.
        for delay in [0.7, 2.0, 4.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.observeReaderScrollViews()
            }
        }
    }

    private func tearDownReader() {
        scrollObservations = [:]
        scrollBaselines = [:]
        guard let reader else { return }
        reader.willMove(toParent: nil)
        reader.view.removeFromSuperview()
        reader.removeFromParent()
        self.reader = nil
    }

    /// Drives the expansion fraction from the reader's scroll position (KVO on
    /// every scroll view in the reader — the text reader's UITextView or the
    /// original-mode web view). `isDragging`/`isDecelerating` filters out
    /// restore-position and text-selection jitter.
    private func observeReaderScrollViews() {
        guard let reader else { return }
        // RSVP has no scroll view; its reading index drives the same boundary
        // (0 = start of the article ⇒ card). Reassigning on every sweep is fine
        // — the closure is idempotent.
        for rsvp in Self.rsvpControllers(of: reader) {
            rsvp.onFrameIndexChanged = { [weak self] index in
                self?.onRSVPIndexChanged?(index)
            }
        }
        for scrollView in Self.scrollViews(in: reader.view) {
            let key = ObjectIdentifier(scrollView)
            guard scrollObservations[key] == nil else { continue }
            scrollBaselines[key] =
                scrollView.contentOffset.y + scrollView.adjustedContentInset.top
            // Synchronous on purpose: isDragging/isDecelerating must be sampled
            // at change time — deferred to the next runloop, a quick flick's
            // whole gesture reads as already-settled.
            scrollObservations[key] = scrollView.observe(\.contentOffset, options: [.new]) {
                [weak self] scrollView, _ in
                self?.handleOffsetChange(of: scrollView)
            }
        }
    }

    private func handleOffsetChange(of scrollView: UIScrollView) {
        // Distance from the content's top (0 = at the top; negative = rubber band).
        let position = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        let key = ObjectIdentifier(scrollView)
        let userDriven = scrollView.isDragging || scrollView.isDecelerating
        guard userDriven else {
            if let fraction = lastReportedFractions[key], fraction > 0, fraction < 1 {
                // A drag ended mid-expansion: snap to the nearer state. When
                // snapping home, re-anchor so the next scroll expands from here.
                let expands = fraction >= 0.5
                if !expands { scrollBaselines[key] = position }
                onScrollSettled?(expands)
            } else if lastReportedFractions[key] == nil {
                // Programmatic settles (restores, layout) re-anchor the baseline.
                scrollBaselines[key] = position
            }
            lastReportedFractions[key] = nil
            return
        }
        // Pulling to (or past) the top always brings the card back.
        if scrollView.isDragging, position <= 0 {
            scrollBaselines[key] = 0
            onContractRequested?()
            return
        }
        let base = scrollBaselines[key] ?? 0
        // Expansion grows with movement away from the starting point (either
        // direction — a mid-article start expands on scroll up too), but is
        // always capped by the distance to the top: reaching the top ⇒ card.
        let fraction = min(
            1,
            abs(position - base) / Self.expansionDistance,
            max(0, position) / Self.expansionDistance)
        onScrollFraction?(fraction)
        lastReportedFractions[key] = fraction
        if fraction == 0, !scrollView.isDragging {
            scrollBaselines[key] = position
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

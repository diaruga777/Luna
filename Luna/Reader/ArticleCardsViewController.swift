//
//  ArticleCardsViewController.swift
//  Luna
//
//  The Reader's root screen: a carousel of full-height cards over the reading
//  list, one article per card, replacing the sectioned table. The generic
//  carousel machinery lives in LunaDesignSystem/CardCarousel (shared with the
//  Downloader); this controller adapts reading-list articles into cards:
//
//  - EVERY card embeds the full live reader, laid out to the card's bounds
//    (side cards too, so paging never shows a placeholder). The card view IS
//    the fullscreen reader view — one header, one layout — so "fullscreen"
//    is not a separate presentation.
//  - Going fullscreen is a chrome fade, nothing more: the peeking side cards
//    and the bottom scrub strip fade away and the card's bottom edge extends
//    into the freed room. Scrolling down in the scroll reader fades them
//    out; scrolling up — from anywhere in the article — fades them back in.
//    In RSVP, playing fades them out and pausing fades them back. Neither
//    the root header nor the reader's own header moves or changes.
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
import LunaURLClassification
import UIKit

final class ArticleCardsViewController: UIViewController {

    private let header = NavHeaderBar()
    private let store = ReadingListStore.shared
    private let carousel = CardCarouselViewController()
    private let emptyView = EmptyArticlesView()
    private let catchUpButton = UIButton(type: .system)
    private let catchUpBadge = UIView()
    private let settingsButton = UIButton(type: .system)
    private let addButton = UIButton(type: .system)
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
        style.scrubberHorizontalInset = 70
        carousel.style = style
        carousel.managesAudioSession = false   // Reader has its own audio stack.
        carousel.dataSource = self
        carousel.delegate = self
        carousel.onImmersionChanged = { [weak self] immersed in
            guard let self else { return }
            // The flanking Settings/Add circles are bottom chrome — they fade
            // in step with the scrub strip they flank (this runs inside the
            // carousel's fade animation). The root header never changes.
            self.settingsButton.alpha = immersed ? 0 : 1
            self.addButton.alpha = immersed ? 0 : 1
            self.settingsButton.isUserInteractionEnabled = !immersed
            self.addButton.isUserInteractionEnabled = !immersed
        }
        addChild(carousel)
        view.addSubview(carousel.view)
        carousel.view.translatesAutoresizingMaskIntoConstraints = false
        carousel.didMove(toParent: self)

        emptyView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyView)

        let headerBottom = header.mount(in: self)
        setHeaderControls()
        mountBottomControls()

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
        carousel.setTopInset(view.safeAreaInsets.top + 8)
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        header.setManagedHeight(topSafeAreaInset: view.safeAreaInsets.top)
        carousel.setTopInset(view.safeAreaInsets.top + 8)
    }

    // MARK: - Header

    private func setHeaderControls() {
        configureCatchUpButton()
        header.setLeadingControls([])
        header.setTrailingControls([catchUpButton])
    }

    /// Flanks the title scrubber with the two root actions. The shared
    /// carousel reserves matching horizontal space only for the Reader style.
    private func mountBottomControls() {
        configureBottomButton(
            settingsButton, symbol: "gearshape", action: #selector(settingsTapped),
            accessibilityLabel: "Settings")
        configureBottomButton(
            addButton, symbol: "plus", action: #selector(addTapped),
            accessibilityLabel: "Add")

        view.addSubview(settingsButton)
        view.addSubview(addButton)
        NSLayoutConstraint.activate([
            settingsButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            settingsButton.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -26),
            settingsButton.widthAnchor.constraint(equalToConstant: 44),
            settingsButton.heightAnchor.constraint(equalToConstant: 44),
            addButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            addButton.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -26),
            addButton.widthAnchor.constraint(equalToConstant: 44),
            addButton.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    private func configureBottomButton(
        _ button: UIButton, symbol: String, action: Selector, accessibilityLabel: String
    ) {
        button.configuration = GlassStyle.circularButtonConfiguration(symbol: symbol, padding: 10)
        button.accessibilityLabel = accessibilityLabel
        button.addTarget(self, action: action, for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
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
        present(alert, animated: true)
    }

    @objc private func catchUpTapped() {
        let queue = ReadingListSectioning.catchUpQueue(items: store.items())
            .filter { ReadingListSectioning.rendersAsReader($0) }
        let catchUp = CatchUpViewController(unread: queue, router: self)
        present(catchUp, animated: true)
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

    // MARK: - Opening / immersion

    /// Tap on the centered card: the embedded reader handles its own touches
    /// (links, RSVP play/pause), so the card itself only acts on a locked
    /// save, opening the archive unlock flow.
    private func unlockCurrentCardIfNeeded() {
        guard presentedViewController == nil else { return }
        let index = carousel.currentIndex
        guard items.indices.contains(index) else { return }
        let item = items[index]
        guard item.state == .needsCaptcha, let url = item.url else { return }
        presentArchiveReader(for: item, articleURL: url)
        store.markReadState(.opened, for: item.id)
    }

    private func makeReader(for item: ReadingListItem) -> UIViewController? {
        guard let content = store.content(for: item) else { return nil }
        return ReaderHostFactory.make(
            item: item, content: content,
            shareProvider: AppReaderShareProvider.shared)
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
        reader.onClose = { [weak nav] in
            guard let nav else { return }
            nav.dismiss(animated: true)
        }
        reader.onOpenInBrowser = { [weak nav] archiveURL in
            guard let nav else { return }
            nav.dismiss(animated: true) {
                UIApplication.shared.open(archiveURL)
            }
        }
        reader.onExtracted = { [weak self, weak nav] in
            guard let nav else { return }
            nav.dismiss(animated: true) {
                guard let self, let fresh = self.store.item(withID: item.id) else { return }
                ReadingListIngestor.shared.backfillMissingThumbnails()
                self.openExternally(fresh)
            }
        }
        present(nav, animated: true)
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
        content.onImmersionChange = { [weak self] immersed in
            self?.carousel.setImmersed(immersed, animated: true)
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
        unlockCurrentCardIfNeeded()
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
/// paging never shows a placeholder), laid out to the card's bounds — the card
/// view IS the fullscreen reader view, one header and one layout for both
/// states. The card reports reading activity so the host can fade the carousel
/// chrome around it: scroll direction in the scroll reader, play state in RSVP.
private final class ReaderCardContentViewController: CardContentViewController {

    /// The reader wants the carousel chrome faded away (true — reading is
    /// under way) or back in (false — the user is surfacing).
    var onImmersionChange: ((Bool) -> Void)?

    private let item: ReadingListItem
    private let statusLabel = UILabel()
    private var reader: UIViewController?
    private var scrollObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]
    /// Per scroll view: the last seen offset and the directional run since the
    /// last direction flip (positive = scrolling down the article).
    private var scrollRuns: [ObjectIdentifier: (last: CGFloat, run: CGFloat)] = [:]
    private var isCentered = false

    /// Downward travel (pt) before the chrome fades away…
    private static let fadeOutTravel: CGFloat = 24
    /// …and upward travel before it comes back — smaller, so surfacing is easy.
    private static let fadeInTravel: CGFloat = 12

    init(item: ReadingListItem) {
        self.item = item
        super.init()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        embedReaderIfPossible()

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
        // The reader fills the card — the fade-out's bottom extension just
        // grows this frame, revealing more content; nothing inside shifts.
        reader?.view.frame = view.bounds
    }

    // MARK: - Live reader lifecycle

    // No relayout on focus change: the reader's layout is card-local and
    // focus-independent, so the state a card mounted in is its final state.

    override func cardDidBecomeCentered() {
        super.cardDidBecomeCentered()
        isCentered = true
    }

    override func cardDidLeaveCenter() {
        super.cardDidLeaveCenter()
        isCentered = false
        scrollRuns = [:]
    }

    private func embedReaderIfPossible() {
        guard reader == nil, item.state == .ready,
              let content = ReadingListStore.shared.content(for: item)
        else { return }
        // The whole article renders at embed time (`fullContentUpFront`) — the
        // card's initial state IS its final state. No Phase-2 swap arrives
        // later, so nothing relayouts or shifts when the card becomes centered.
        let reader = ReaderHostFactory.make(
            item: item, content: content,
            shareProvider: AppReaderShareProvider.shared,
            fullContentUpFront: true)
        addChild(reader)
        reader.view.autoresizingMask = []
        view.insertSubview(reader.view, at: 0)
        reader.didMove(toParent: self)
        if let rabbitHole = reader as? RabbitHoleReaderViewController {
            // Root back button: the reader has nowhere to pop to — surface,
            // bringing the carousel chrome back instead.
            rabbitHole.onRootBack = { [weak self] in
                guard let self, self.isCentered else { return }
                self.onImmersionChange?(false)
            }
            // A dive, pop, mode switch, or late article embed swaps the live
            // scroll views / RSVP controllers — re-sweep for new ones to
            // observe (idempotent; next runloop so the new child is mounted).
            rabbitHole.onContentHierarchyChanged = { [weak self] in
                DispatchQueue.main.async { self?.observeReaderScrollViews() }
            }
        }
        self.reader = reader
        reader.view.frame = view.bounds
        observeReaderScrollViews()

        // Backstop sweeps for content that mounts without a hierarchy
        // callback (a dived-into non-article page installs its web view only
        // after an async probe). KVO only — never triggers layout.
        for delay in [0.7, 2.0, 4.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.observeReaderScrollViews()
            }
        }
    }

    /// Hooks the immersion triggers onto the reader's live content (KVO on
    /// every scroll view, play-state callbacks on every RSVP controller).
    /// Idempotent — re-run whenever the reader's hierarchy changes. Only the
    /// CENTERED card reports (side cards' readers are live but inert).
    private func observeReaderScrollViews() {
        guard let reader else { return }
        for rsvp in Self.rsvpControllers(of: reader) {
            rsvp.onPlaybackStateChanged = { [weak self] playing in
                guard let self, self.isCentered else { return }
                self.onImmersionChange?(playing)
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

    /// Direction-driven, not position-driven: scrolling down (reading on)
    /// fades the carousel chrome away; scrolling up — from anywhere in the
    /// article — fades it back in. Travel accumulates per direction and
    /// resets on a flip, so line-height jitter can't toggle the state, and
    /// `isDragging`/`isDecelerating` keeps restore-position and
    /// text-selection offsets from counting as reading.
    private func handleOffsetChange(of scrollView: UIScrollView) {
        let key = ObjectIdentifier(scrollView)
        guard isCentered, scrollView.isDragging || scrollView.isDecelerating else {
            scrollRuns[key] = nil
            return
        }
        // Distance from the content's top (0 = at the top).
        let position = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        guard let previous = scrollRuns[key] else {
            scrollRuns[key] = (position, 0)
            return
        }
        let delta = position - previous.last
        let run = (delta >= 0) == (previous.run >= 0) ? previous.run + delta : delta
        scrollRuns[key] = (position, run)
        // Re-seed the runs BEFORE firing: the fade's card-bottom extension
        // resizes the scroll view synchronously, and at the article's end
        // that clamps the offset — a synthetic ~90pt "scroll up" delivered
        // re-entrantly that would immediately fade the chrome back in. With
        // the runs cleared first, that event just seeds a fresh baseline.
        if run <= -Self.fadeInTravel || position <= 0 {
            scrollRuns = [:]
            onImmersionChange?(false)
        } else if run >= Self.fadeOutTravel, position > 0 {
            scrollRuns = [:]
            onImmersionChange?(true)
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

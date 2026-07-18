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
//  - Tapping the centered card — including on a link — subtly expands it into
//    the fullscreen reader (CardExpandTransitionCenter push of the SAME live
//    reader instance, so scroll/mode state carries over). The first vertical
//    scroll inside the card does the same; so does starting RSVP playback
//    (the play tap IS a card tap).
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

    private func expandCurrentCard() {
        guard let nav = navigationController, presentedViewController == nil,
              Date() >= suppressExpansionUntil
        else { return }
        let index = carousel.currentIndex
        guard items.indices.contains(index) else { return }
        let item = items[index]
        if item.state == .needsCaptcha, let url = item.url {
            presentArchiveReader(for: item, articleURL: url)
            store.markReadState(.opened, for: item.id)
            return
        }
        guard item.state == .ready else { return }
        let content = carousel.contentController(at: index) as? ReaderCardContentViewController
        guard let reader = content?.detachLiveReader() ?? makeReader(for: item) else { return }
        CardExpandTransitionCenter.prepare(reader: reader) { [weak self] in
            guard let self,
                  let card = self.carousel.cardView(at: self.carousel.currentIndex)
            else { return nil }
            return card.convert(card.bounds, to: nil)
        }
        nav.pushViewController(reader, animated: true)
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
        content.onExpansionRequested = { [weak self] in self?.expandCurrentCard() }
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

    var onExpansionRequested: (() -> Void)?

    private let item: ReadingListItem
    private let coverView = UIImageView()
    private let scrimView = UIView()
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private var reader: UIViewController?
    private var scrollObservations: [NSKeyValueObservation] = []
    private var didRequestExpansion = false

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
        didRequestExpansion = false

        // The reader's scroll views exist only after its content lays out;
        // attach the expansion trigger a beat later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.observeReaderScrollViews()
        }
    }

    private func tearDownReader() {
        scrollObservations = []
        guard let reader else { return }
        reader.willMove(toParent: nil)
        reader.view.removeFromSuperview()
        reader.removeFromParent()
        self.reader = nil
    }

    /// Detaches and returns the live reader for a fullscreen push (nil when the
    /// card is still a preview). The card falls back to its preview.
    func detachLiveReader() -> UIViewController? {
        scrollObservations = []
        guard let reader else { return nil }
        reader.willMove(toParent: nil)
        reader.view.removeFromSuperview()
        reader.removeFromParent()
        self.reader = nil
        return reader
    }

    /// First user-driven vertical scroll anywhere in the embedded reader →
    /// expand. KVO on contentOffset, filtered to tracked (finger-down) changes
    /// so restore-position and layout scrolls don't trigger it.
    private func observeReaderScrollViews() {
        guard let reader else { return }
        scrollObservations = Self.scrollViews(in: reader.view).map { scrollView in
            scrollView.observe(\.contentOffset, options: [.old, .new]) {
                [weak self] scrollView, change in
                // isDragging (not isTracking): a held finger — text selection,
                // the RSVP long-press — jitters the offset without dragging.
                guard let self, !self.didRequestExpansion,
                      scrollView.isDragging || scrollView.isDecelerating,
                      let old = change.oldValue, let new = change.newValue,
                      abs(new.y - old.y) > 4, abs(new.y - old.y) > abs(new.x - old.x)
                else { return }
                self.didRequestExpansion = true
                DispatchQueue.main.async { self.onExpansionRequested?() }
            }
        }
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

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
//    In RSVP, playing fades them out and pausing fades them back. The
//    reader's own header never moves or changes.
//  - Long-pressing the centered card runs the link-preview RSVP experience
//    (glass card, drag gestures, haptics) for the card's article, without
//    going fullscreen.
//  - Horizontal swipes INSIDE the card page to the neighbor (readers have no
//    timeline to scrub); the scrub strip shows mini-card chips, each badged
//    with the article's source (favicon / sender initials / symbol fallback).
//

import LunaArchiveReader
import LunaDesignSystem
import LunaModels
import LunaReaderUI
import LunaReadingList
import LunaReadingListUI
import LunaSocialUI
import LunaStorage
import LunaURLClassification
import UIKit

final class ArticleCardsViewController: UIViewController {

    private static let pasteboardCardMarker = URL(string: "https://pasteboard.invalid")!

    private let store = ReadingListStore.shared
    private let carousel = CardCarouselViewController()
    private let emptyView = EmptyArticlesView()
    private let settingsButton = UIButton(type: .system)
    // Screen-level reader chrome (see mountTopChrome).
    private let readerChromeRow = UIView()
    private let readerBackButton = UIButton(type: .system)
    private let readerPasteButton = UIButton(type: .system)
    private let readerAudioButton = UIButton(type: .system)
    private let readerModeControl = LunaSegmentedControl()
    private let readerShareButton = UIButton(type: .system)
    /// A backdrop-only material: clear at rest, visible only through the
    /// distortion of reader content passing behind the status/header region.
    private let readerTopBlur = UIVisualEffectView(
        effect: UIBlurEffect(style: .systemUltraThinMaterial))
    private weak var readerForChrome: RabbitHoleReaderViewController?
    private var chromeModes: [ReadingListItem.ReaderMode] = []
    private var items: [ReadingListItem] = []
    private var appliedFingerprint: [String] = []
    private var pasteboardURL: URL?
    /// The paste item currently represented by the carousel's data source.
    /// Kept separate so adding/removing the synthetic leading card can map the
    /// previously centered article through the old index space.
    private var renderedPasteboardURL: URL?
    private var consumedPasteboardChangeCount: Int?
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
        style.scrubberStyle = .miniCards
        style.scrubberHorizontalInset = 70
        // Glass rim so the cards (and the dimmed side peeks, especially in dark
        // mode) read against a same-tone background; fades with the chrome on
        // immersion.
        style.showsCardBorder = true
        carousel.style = style
        carousel.managesAudioSession = false   // Reader has its own audio stack.
        carousel.dataSource = self
        carousel.delegate = self
        carousel.onImmersionChanged = { [weak self] immersed in
            guard let self else { return }
            // The flanking Settings/Share circles are bottom chrome — they fade
            // in step with the scrub strip they flank (this runs inside the
            // carousel's fade animation).
            self.settingsButton.alpha = immersed ? 0 : 1
            self.readerShareButton.alpha = immersed ? 0 : 1
            self.settingsButton.isUserInteractionEnabled = !immersed
            self.readerShareButton.isUserInteractionEnabled = !immersed
            self.readerChromeRow.alpha = immersed ? 0 : 1
            self.readerChromeRow.isUserInteractionEnabled = !immersed
        }
        addChild(carousel)
        view.addSubview(carousel.view)
        carousel.view.translatesAutoresizingMaskIntoConstraints = false
        carousel.didMove(toParent: self)

        emptyView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyView)

        mountBottomControls()
        mountTopChrome()

        NSLayoutConstraint.activate([
            carousel.view.topAnchor.constraint(equalTo: view.topAnchor),
            carousel.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            carousel.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            carousel.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            emptyView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        NotificationCenter.default.addObserver(
            self, selector: #selector(reload), name: .readingListChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshPasteboardURL),
            name: UIApplication.didBecomeActiveNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshPasteboardURL),
            name: UIPasteboard.changedNotification, object: nil)
        refreshPasteboardURL()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
        carousel.setTopInset(0)
        updateExternalReaderInsets()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        carousel.setTopInset(0)
        updateExternalReaderInsets()
    }

    /// Room reserved above the cards for the screen-level chrome row: the row
    /// spans safeTop+4 … safeTop+48; the carousel's own 12pt vertical padding
    /// then puts the card top 8pt below the row.
    private static let topChromeClearance: CGFloat = 44

    /// Floats the controls over the reader. The blur extends through the entire
    /// top safe area and the row; it has no fill, separator, border, or shadow,
    /// so a uniform page remains visually uniform beneath it.
    private func mountTopChrome() {
        readerTopBlur.isUserInteractionEnabled = false
        readerTopBlur.alpha = 0
        readerTopBlur.backgroundColor = .clear
        readerTopBlur.contentView.backgroundColor = .clear
        readerTopBlur.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(readerTopBlur)

        readerChromeRow.backgroundColor = .clear
        readerChromeRow.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(readerChromeRow)

        configureChromeButton(
            readerBackButton, symbol: "chevron.backward", action: #selector(readerBackTapped),
            label: "Back")
        configureChromeButton(
            readerPasteButton, symbol: "doc.on.clipboard", action: #selector(readerPasteTapped),
            label: "Add Pasted Link")
        configureChromeButton(
            readerAudioButton, symbol: "speaker.slash", action: #selector(readerAudioTapped),
            label: "Read Aloud")
        readerModeControl.addTarget(self, action: #selector(readerModeChanged), for: .valueChanged)
        readerModeControl.translatesAutoresizingMaskIntoConstraints = false

        for control in [readerBackButton, readerPasteButton, readerAudioButton, readerModeControl] {
            readerChromeRow.addSubview(control)
        }

        NSLayoutConstraint.activate([
            readerTopBlur.topAnchor.constraint(equalTo: view.topAnchor),
            readerTopBlur.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            readerTopBlur.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            readerTopBlur.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor, constant: Self.topChromeClearance + 8),

            readerChromeRow.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            readerChromeRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            readerChromeRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            readerChromeRow.heightAnchor.constraint(equalToConstant: Self.topChromeClearance),

            readerBackButton.leadingAnchor.constraint(equalTo: readerChromeRow.leadingAnchor),
            readerBackButton.centerYAnchor.constraint(equalTo: readerChromeRow.centerYAnchor),
            readerPasteButton.leadingAnchor.constraint(equalTo: readerChromeRow.leadingAnchor),
            readerPasteButton.centerYAnchor.constraint(equalTo: readerChromeRow.centerYAnchor),
            readerAudioButton.trailingAnchor.constraint(equalTo: readerChromeRow.trailingAnchor),
            readerAudioButton.centerYAnchor.constraint(equalTo: readerChromeRow.centerYAnchor),
            readerModeControl.centerXAnchor.constraint(equalTo: readerChromeRow.centerXAnchor),
            readerModeControl.centerYAnchor.constraint(equalTo: readerChromeRow.centerYAnchor),
            readerModeControl.heightAnchor.constraint(equalToConstant: 32),
        ])
        updateReaderChrome()
    }

    private func configureChromeButton(
        _ button: UIButton, symbol: String, action: Selector, label: String
    ) {
        button.configuration = GlassStyle.circularButtonConfiguration(symbol: symbol, padding: 8)
        button.tintColor = GlassStyle.readingAccent
        button.accessibilityLabel = label
        button.addTarget(self, action: action, for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 38),
            button.heightAnchor.constraint(equalToConstant: 38),
        ])
    }

    private func updateExternalReaderInsets() {
        let headerBottom = view.safeAreaInsets.top + Self.topChromeClearance + 8
        for index in [carousel.currentIndex - 1, carousel.currentIndex, carousel.currentIndex + 1] {
            (carousel.contentController(at: index) as? ReaderCardContentViewController)?
                .setExternalChromeBottom(headerBottom)
        }
    }

    private func updateReaderChrome() {
        let state = readerForChrome?.chromeState
        readerChromeRow.isHidden = state == nil && renderedPasteboardURL == nil
        readerBackButton.isHidden = state?.showsBack != true
        readerPasteButton.isHidden = state?.showsBack == true || renderedPasteboardURL == nil
        guard let state else {
            readerAudioButton.isHidden = true
            readerModeControl.isHidden = true
            readerShareButton.isHidden = true
            return
        }
        readerAudioButton.setImage(
            UIImage(systemName: state.isAudioOn ? "speaker.wave.2" : "speaker.slash"), for: .normal)
        readerAudioButton.accessibilityValue = state.isAudioOn ? "On" : "Off"

        if chromeModes != state.modes {
            chromeModes = state.modes
            readerModeControl.removeAllSegments()
            for (index, mode) in state.modes.enumerated() {
                readerModeControl.insertSegment(
                    with: ReaderModeIcons.image(for: mode), at: index, animated: false)
            }
        }
        readerModeControl.selectedSegmentIndex = state.modes.firstIndex(of: state.selectedMode) ?? 0
        readerModeControl.isHidden = !state.isArticle
        readerAudioButton.isHidden = !state.isArticle
        readerShareButton.isHidden = !state.offersSaveShare
    }

    @objc private func readerBackTapped() { readerForChrome?.chromeBack(); updateReaderChrome() }
    @objc private func readerAudioTapped() { readerForChrome?.chromeToggleAudio(); updateReaderChrome() }
    @objc private func readerShareTapped() { readerForChrome?.chromeShare(from: readerShareButton) }
    @objc private func readerPasteTapped() { addPasteboardURL() }
    @objc private func readerModeChanged() {
        guard chromeModes.indices.contains(readerModeControl.selectedSegmentIndex) else { return }
        readerForChrome?.chromeSetMode(chromeModes[readerModeControl.selectedSegmentIndex])
        updateReaderChrome()
    }

    /// Flanks the title scrubber with Settings and Share. The shared
    /// carousel reserves matching horizontal space only for the Reader style.
    private func mountBottomControls() {
        configureBottomButton(
            settingsButton, symbol: "gearshape", action: #selector(settingsTapped),
            accessibilityLabel: "Settings")
        configureBottomButton(
            readerShareButton, symbol: "square.and.arrow.up", action: #selector(readerShareTapped),
            accessibilityLabel: "Share")
        view.addSubview(settingsButton)
        view.addSubview(readerShareButton)
        NSLayoutConstraint.activate([
            settingsButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            settingsButton.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -26),
            settingsButton.widthAnchor.constraint(equalToConstant: 44),
            settingsButton.heightAnchor.constraint(equalToConstant: 44),
            readerShareButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            readerShareButton.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -26),
            readerShareButton.widthAnchor.constraint(equalToConstant: 44),
            readerShareButton.heightAnchor.constraint(equalToConstant: 44),
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

    @objc private func settingsTapped() {
        navigationController?.pushViewController(SettingsViewController(), animated: true)
    }

    // MARK: - Data

    @objc private func refreshPasteboardURL() {
        let pasteboard = UIPasteboard.general
        if consumedPasteboardChangeCount == pasteboard.changeCount {
            guard pasteboardURL != nil else { return }
            pasteboardURL = nil
            reload()
            return
        }
        let changeCount = pasteboard.changeCount
        // Pattern detection can reveal that a URL is available without reading
        // its value, so merely opening Luna never raises the system paste prompt.
        pasteboard.detectPatterns(for: [.probableWebURL]) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, UIPasteboard.general.changeCount == changeCount else { return }
                let hasLink = (try? result.get())?.contains(.probableWebURL) == true
                let candidate = hasLink ? Self.pasteboardCardMarker : nil
                guard candidate != self.pasteboardURL else {
                    self.reload()
                    return
                }
                self.pasteboardURL = candidate
                self.reload()
            }
        }
    }

    private var cardOffset: Int { renderedPasteboardURL == nil ? 0 : 1 }

    private func articleIndex(forCarouselIndex index: Int) -> Int? {
        let itemIndex = index - cardOffset
        return items.indices.contains(itemIndex) ? itemIndex : nil
    }

    private func addPasteboardURL() {
        guard renderedPasteboardURL != nil || pasteboardURL != nil else { return }
        let pasteboard = UIPasteboard.general
        guard let value = pasteboard.url?.absoluteString ?? pasteboard.string,
              let url = URLUnwrapper.ingestURL(from: value),
              store.item(forURLString: url.absoluteString) == nil
        else { return }
        consumedPasteboardChangeCount = UIPasteboard.general.changeCount
        pasteboardURL = nil
        reload()
        Task {
            _ = await ReadingListIngestor.shared.handleSavePress(
                urlString: url.absoluteString, source: .paste)
        }
    }

    @objc private func reload() {
        let updated = store.items()
            .filter { ReadingListSectioning.rendersAsReader($0) }
            .sorted { ($0.bumpDate ?? $0.dateAdded) > ($1.bumpDate ?? $1.dateAdded) }
        var fingerprint = updated.map {
            "\($0.id)|\($0.title ?? "")|\($0.state)|\($0.thumbnailFileName ?? "")"
        }
        fingerprint.insert("paste|\(pasteboardURL?.absoluteString ?? "")", at: 0)
        guard fingerprint != appliedFingerprint else { return }
        appliedFingerprint = fingerprint

        let oldItemIndex = carousel.currentIndex - cardOffset
        let centeredID = items.indices.contains(oldItemIndex) ? items[oldItemIndex].id : nil
        items = updated
        renderedPasteboardURL = pasteboardURL
        let newOffset = cardOffset
        let centeredIndex = centeredID.flatMap { id in
            items.firstIndex { $0.id == id }.map { $0 + newOffset }
        } ?? (items.isEmpty ? 0 : newOffset)
        carousel.reloadData(centeringAt: centeredIndex)
        emptyView.isHidden = !items.isEmpty || renderedPasteboardURL != nil
        carousel.view.isHidden = items.isEmpty && renderedPasteboardURL == nil
        updateReaderChrome()
    }

    // MARK: - Opening / immersion

    /// Tap on the centered card: the embedded reader handles its own touches
    /// (links, RSVP play/pause), so the card itself only acts on a locked
    /// save, opening the archive unlock flow.
    private func unlockCurrentCardIfNeeded() {
        guard presentedViewController == nil else { return }
        guard let index = articleIndex(forCarouselIndex: carousel.currentIndex) else { return }
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
        items.count + cardOffset
    }

    func carousel(
        _ carousel: CardCarouselViewController,
        contentControllerForCardAt index: Int
    ) -> CardContentViewController {
        if renderedPasteboardURL != nil, index == 0 {
            return PasteboardCardContentViewController(url: nil)
        }
        guard let itemIndex = articleIndex(forCarouselIndex: index) else {
            return CardContentViewController()
        }
        let content = ReaderCardContentViewController(item: items[itemIndex])
        content.onImmersionChange = { [weak self] immersed in
            self?.carousel.setImmersed(immersed, animated: true)
        }
        content.onTopBackdropProgress = { [weak self, weak content] progress in
            guard content?.isCentered == true else { return }
            self?.readerTopBlur.alpha = progress
        }
        content.onReaderReady = { [weak self, weak content] reader in
            guard let self, content?.isCentered == true else { return }
            self.readerForChrome = reader
            self.updateExternalReaderInsets()
            self.updateReaderChrome()
        }
        return content
    }

    func carousel(
        _ carousel: CardCarouselViewController,
        loadThumbnailForCardAt index: Int,
        completion: @escaping (UIImage?) -> Void
    ) {
        completion(nil)   // mini-card strip; no image chips
    }

    /// Chip badge: an instant fallback (initials / mail / document / globe)
    /// first, then the site's real favicon replaces it once fetched. Cached
    /// icons resolve synchronously, so a warm strip shows favicons at once.
    func carousel(
        _ carousel: CardCarouselViewController,
        loadSourceBadgeForCardAt index: Int,
        completion: @escaping (CarouselSourceBadge?) -> Void
    ) {
        if renderedPasteboardURL != nil, index == 0 {
            completion(.symbol("doc.on.clipboard"))
            return
        }
        guard let itemIndex = articleIndex(forCarouselIndex: index) else {
            completion(nil)
            return
        }
        let item = items[itemIndex]
        completion(ArticleSourceBadge.fallback(for: item))
        guard ArticleSourceBadge.wantsFavicon(item), let url = item.url else { return }
        SourceIconCache.shared.icon(forPageURL: url) { image in
            if let image { completion(.icon(image)) }
        }
    }

    func carousel(
        _ carousel: CardCarouselViewController,
        titleForCardAt index: Int
    ) -> String? {
        if renderedPasteboardURL != nil, index == 0 { return "Add Pasted Link" }
        guard let itemIndex = articleIndex(forCarouselIndex: index) else { return nil }
        let item = items[itemIndex]
        return item.title ?? item.url?.host ?? item.urlString
    }
}

// MARK: - Carousel delegate

extension ArticleCardsViewController: CardCarouselDataSource {}

extension ArticleCardsViewController: CardCarouselDelegate {

    func carousel(_ carousel: CardCarouselViewController, didCenterCardAt index: Int) {
        if renderedPasteboardURL != nil, index == 0 {
            readerForChrome = nil
            readerTopBlur.alpha = 0
            updateReaderChrome()
            // With no saved articles this card is centered by initial layout,
            // not by user intent; wait for its tap. Otherwise reaching index 0
            // is a swipe or mini-carousel selection and should add immediately.
            if !items.isEmpty { addPasteboardURL() }
            return
        }
        guard let itemIndex = articleIndex(forCarouselIndex: index) else { return }
        store.markReadState(.opened, for: items[itemIndex].id)
        readerForChrome = (carousel.contentController(at: index) as? ReaderCardContentViewController)?
            .rabbitHoleReader
        readerTopBlur.alpha = 0
        updateExternalReaderInsets()
        updateReaderChrome()
    }

    func carousel(_ carousel: CardCarouselViewController, didTapCenteredCardAt index: Int) {
        if renderedPasteboardURL != nil, index == 0 {
            addPasteboardURL()
            return
        }
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
            guard let itemIndex = articleIndex(forCarouselIndex: index),
                  presentedViewController == nil,
                  rsvpSession == nil
            else { return }
            let item = items[itemIndex]
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

// MARK: - Card content

/// The synthetic leading card for a URL waiting on the pasteboard. It is
/// intentionally a normal non-playable carousel card: tapping it, tapping its
/// mini-card chip, or paging onto it all reach the same add action in the host.
private final class PasteboardCardContentViewController: CardContentViewController {
    private let url: URL?

    init(url: URL?) {
        self.url = url
        super.init()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.isAccessibilityElement = true
        view.accessibilityLabel = "Add Pasted Link"
        view.accessibilityHint = "Adds the URL from the pasteboard"
        view.accessibilityTraits = .button

        let icon = UIImageView(image: UIImage(systemName: "doc.on.clipboard"))
        icon.tintColor = GlassStyle.readingAccent
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: 42, weight: .medium)

        let title = UILabel()
        title.text = "Add Pasted Link"
        title.font = .preferredFont(forTextStyle: .title2)
        title.textColor = .label
        title.textAlignment = .center

        let detail = UILabel()
        detail.text = url?.host ?? url?.absoluteString
        detail.font = .preferredFont(forTextStyle: .subheadline)
        detail.textColor = .secondaryLabel
        detail.textAlignment = .center
        detail.numberOfLines = 2

        let stack = UIStackView(arrangedSubviews: [icon, title, detail])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        // When this card is the left neighbor only its trailing ~14pt peeks
        // into the screen. Keep a tiny copy of the glyph inside that slice so
        // the peek reads as Pasteboard instead of an anonymous grey edge.
        let edgeIcon = UIImageView(image: UIImage(systemName: "doc.on.clipboard.fill"))
        edgeIcon.tintColor = GlassStyle.readingAccent
        edgeIcon.contentMode = .scaleAspectFit
        edgeIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: 10, weight: .semibold)
        edgeIcon.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(edgeIcon)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
            edgeIcon.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -1),
            edgeIcon.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            edgeIcon.widthAnchor.constraint(equalToConstant: 13),
            edgeIcon.heightAnchor.constraint(equalToConstant: 18),
        ])
    }
}

/// One article card: the FULL live reader, always embedded (side cards too, so
/// paging never shows a placeholder), laid out to the card's bounds — the card
/// view IS the fullscreen reader view, one header and one layout for both
/// states. The card reports reading activity so the host can fade the carousel
/// chrome around it: scroll direction in the scroll reader, play state in RSVP.
private final class ReaderCardContentViewController: CardContentViewController {

    /// The reader wants the carousel chrome faded away (true — reading is
    /// under way) or back in (false — the user is surfacing).
    var onImmersionChange: ((Bool) -> Void)?
    var onReaderReady: ((RabbitHoleReaderViewController) -> Void)?
    var onTopBackdropProgress: ((CGFloat) -> Void)?

    private let item: ReadingListItem
    private let statusLabel = UILabel()
    private var reader: UIViewController?
    private var scrollObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]
    /// Per scroll view: the last seen offset and the directional run since the
    /// last direction flip (positive = scrolling down the article).
    private var scrollRuns: [ObjectIdentifier: (last: CGFloat, run: CGFloat)] = [:]
    private(set) var isCentered = false
    var rabbitHoleReader: RabbitHoleReaderViewController? { reader as? RabbitHoleReaderViewController }

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
        if let rabbitHoleReader { onReaderReady?(rabbitHoleReader) }
    }

    override func cardDidLeaveCenter() {
        super.cardDidLeaveCenter()
        isCentered = false
        scrollRuns = [:]
        onTopBackdropProgress?(0)
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
        if let rabbitHole = reader as? RabbitHoleReaderViewController {
            rabbitHole.providesOwnChrome = false
        }
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
                DispatchQueue.main.async {
                    guard let self, self.isCentered else { return }
                    self.onReaderReady?(rabbitHole)
                }
            }
        }
        self.reader = reader
        reader.view.frame = view.bounds
        observeReaderScrollViews()
        if let rabbitHole = reader as? RabbitHoleReaderViewController {
            onReaderReady?(rabbitHole)
        }

        // Backstop sweeps for content that mounts without a hierarchy
        // callback (a dived-into non-article page installs its web view only
        // after an async probe). KVO only — never triggers layout.
        for delay in [0.7, 2.0, 4.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.observeReaderScrollViews()
            }
        }
    }

    func setExternalChromeBottom(_ screenY: CGFloat) {
        guard let rabbitHoleReader else { return }
        let localY = view.convert(CGPoint(x: 0, y: screenY), from: nil).y
        rabbitHoleReader.externalChromeContentInset = max(localY, 0)
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
        // A backdrop material always carries a slight trait-aware tint. Keep it
        // literally absent at rest, then reveal it only as content crosses into
        // the occluded header region.
        onTopBackdropProgress?(max(0, min(1, position / 12)))
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

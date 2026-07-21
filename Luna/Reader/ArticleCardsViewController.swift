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
import LunaSocial
import LunaStorage
import LunaURLClassification
import UIKit

final class ArticleCardsViewController: CardCarouselHostViewController {

    private static let pasteboardCardMarker = URL(string: "https://pasteboard.invalid")!

    private let store = ReadingListStore.shared
    private let emptyView = CardCarouselHostViewController.makeEmptyStateView(
        symbol: "books.vertical", title: "No Saved Articles",
        subtitle: "Articles you save appear here as cards.")
    private let settingsButton = UIButton(type: .system)
    // Screen-level reader chrome (see mountTopChrome).
    private let readerChromeRow = UIView()
    private let readerBackButton = UIButton(type: .system)
    private let readerPasteButton = UIButton(type: .system)
    private let readerAudioButton = UIButton(type: .system)
    private let readerModeControl = LunaSegmentedControl()
    private let readerShareButton = UIButton(type: .system)
    private let footerContentFade = ReaderFooterContentFadeView()
    private weak var readerForChrome: ReaderChromeControlling?
    /// The reader's scroll indicator, hosted here (not inside the card) so it can
    /// slide from the card's trailing edge out to the screen edge as the card
    /// immerses — the card's own clip would otherwise trap it at the card edge.
    /// (Self-installed indicators inside the card remove themselves; see
    /// `HorizonScrollIndicator`.) It tracks the ROOT card reader; a link-opened
    /// inline reader is a screen-level eclipse overlay that keeps its own
    /// self-installed indicator, so the host one steps aside for it.
    private let cardScrollIndicator = HorizonScrollIndicator.makeHosted()
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
        style.pageSwipeMovementMultiplier = 1.5
        style.scrubberStyle = .miniCards
        // The strip runs edge to edge; chips fade-blur out before they reach
        // the flanking Settings/Share circles (12pt margin + 44pt button).
        style.scrubberHorizontalInset = 0
        style.scrubberEdgeFadeWidth = 72
        // Glass rim so the cards (and the dimmed side peeks, especially in dark
        // mode) read against a same-tone background; fades with the chrome on
        // immersion.
        style.showsCardBorder = true
        // Scrolled reader content dissolves at the card's top and bottom edges
        // instead of hitting a hard clip (or any blur bar).
        style.contentEdgeFadeHeight = Self.contentEdgeFade
        carousel.style = style
        carousel.managesAudioSession = false   // Reader has its own audio stack.
        carousel.dataSource = self
        carousel.delegate = self
        // The header row and the flanking Settings/Share circles persist through
        // immersion — only the carousel's own chrome (side cards, scrub strip,
        // card rims) fades while reading.
        mountCarousel()

        emptyView.translatesAutoresizingMaskIntoConstraints = false
        // Stay hidden until the first `reload()` confirms the list is genuinely
        // empty — otherwise the "No Saved Articles" state paints for the frames
        // before the store has been read, flashing on every cold launch.
        emptyView.isHidden = true
        view.addSubview(emptyView)

        // Above the carousel (so it clears the card's clip) but below the
        // screen chrome added by the mount* calls (so the header/footer pills
        // stay on top). Host-positioned every layout — no Auto Layout.
        cardScrollIndicator.isHidden = true
        view.addSubview(cardScrollIndicator)

        // Immersion extends the reader below its resting card edge. Keep that
        // extra content from entering the footer controls' safe area: the veil
        // becomes fully opaque exactly at the buttons' top edge.
        footerContentFade.alpha = 0
        footerContentFade.isUserInteractionEnabled = false
        view.addSubview(footerContentFade)

        mountBottomControls()
        mountTopChrome()

        NSLayoutConstraint.activate([
            emptyView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            emptyView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        NotificationCenter.default.addObserver(
            self, selector: #selector(reload), name: .readingListChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(reload), name: .friendsListChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshPasteboardURL),
            name: UIApplication.didBecomeActiveNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshPasteboardURL),
            name: UIPasteboard.changedNotification, object: nil)
        // `reload()` must run synchronously here, before the async pasteboard probe:
        // `store.items()` serves an in-memory cache, so this shows saved articles
        // immediately instead of waiting on the probe's round-trip (a `detectPatterns`
        // call).
        reload()
        refreshPasteboardURL()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
        // Cards rest fully below the header row — the card frames only the
        // reader content; the buttons and controls float over the screen background.
        applyCarouselTopInset(4 + Self.topChromeClearance)
        updateExternalReaderInsets()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        applyCarouselTopInset(4 + Self.topChromeClearance)
        updateExternalReaderInsets()
    }

    /// The height of the screen-level chrome row: it spans safeTop+4 …
    /// safeTop+48; the carousel's top inset plus its own 12pt vertical padding
    /// then rest the card top 12pt below the row.
    private static let topChromeClearance: CGFloat = 44

    /// The depth of the dissolve at the card's top and bottom edges: scrolled
    /// content fades out over this run instead of hitting a hard clip. The
    /// resting scroll position sits just below the top fade so an unscrolled
    /// page starts fully legible.
    private static let contentEdgeFade: CGFloat = 28

    /// Floats the control row above the cards, over the bare screen background
    /// — no bar, fill, or blur behind it.
    private func mountTopChrome() {
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

    /// The reader's resting scroll position clears the card's top edge fade;
    /// content scrolled past it dissolves inside the fade run.
    private func updateExternalReaderInsets() {
        for index in [carousel.currentIndex - 1, carousel.currentIndex, carousel.currentIndex + 1] {
            (carousel.contentController(at: index) as? ReaderCardContentViewController)?
                .setTopContentInset(Self.contentEdgeFade)
        }
    }

    /// True only while the immersion slide is mid-flight, so routine layout
    /// passes (which the card's bottom-extension provokes) don't snap the
    /// indicator to its target and cut the animation short.
    private var isIndicatorSliding = false

    /// Places the reader's scroll indicator at the centered card's trailing edge,
    /// sliding it out to the screen edge while the card is immersed. Only the
    /// indicator moves — the reader keeps its inset, so nothing relayouts.
    /// Hidden when the centered card has no scrollable reader (no article yet,
    /// or RSVP, whose word display has nothing to scroll).
    private func layoutCardScrollIndicator(animated: Bool) {
        // Only the root card reader is host-tracked; a link-opened inline reader
        // (an over-screen eclipse overlay) keeps its own self-installed indicator.
        guard let reader = readerForChrome as? RabbitHoleReaderViewController,
              let scrollView = reader.focusedContentScrollView,
              let resting = carousel.restingCenteredCardFrame(in: view)
        else {
            cardScrollIndicator.isHidden = true
            cardScrollIndicator.track(nil)
            return
        }
        cardScrollIndicator.isHidden = false
        cardScrollIndicator.track(scrollView)

        let width = HorizonScrollIndicator.bloomDiameter
        let immersed = carousel.isImmersed
        // Trailing edge: the card's at rest, the screen's while immersed. Only
        // the card's BOTTOM extends on immersion — its top and sides hold.
        let rightEdge = immersed ? view.bounds.maxX : resting.maxX
        let top = resting.minY
        let bottom = immersed ? view.bounds.maxY : resting.maxY
        let frame = CGRect(
            x: rightEdge - width, y: top, width: width, height: max(bottom - top, 0))
        // Keep the dot inside the card's top/bottom edge dissolves.
        cardScrollIndicator.trackInsets = UIEdgeInsets(
            top: Self.contentEdgeFade, left: 0, bottom: Self.contentEdgeFade, right: 0)

        let apply = {
            self.cardScrollIndicator.frame = frame
            self.cardScrollIndicator.layoutIfNeeded()
        }
        if animated {
            isIndicatorSliding = true
            UIView.animate(
                withDuration: 0.32, delay: 0, options: [.curveEaseInOut, .allowUserInteraction],
                animations: apply, completion: { [weak self] _ in self?.isIndicatorSliding = false })
        } else {
            apply()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if !isIndicatorSliding { layoutCardScrollIndicator(animated: false) }
        let fadeStart = settingsButton.frame.minY - Self.contentEdgeFade
        footerContentFade.frame = CGRect(
            x: 0, y: fadeStart, width: view.bounds.width,
            height: max(view.bounds.maxY - fadeStart, 0))
        footerContentFade.setFadeHeight(Self.contentEdgeFade)
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

    /// Flanks the title scrubber with Settings and Share. The strip itself
    /// runs edge to edge underneath; its chips fade-blur out before reaching
    /// these buttons (`scrubberEdgeFadeWidth`).
    private func mountBottomControls() {
        configureBottomButton(
            settingsButton, symbol: "gearshape", action: #selector(settingsTapped),
            accessibilityLabel: "Settings")
        configureBottomButton(
            readerShareButton, symbol: "square.and.arrow.up", action: #selector(readerShareTapped),
            accessibilityLabel: "Share")
        mountBottomControls(leading: settingsButton, trailing: readerShareButton)
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

    override var hasLeadingPasteboardCard: Bool { renderedPasteboardURL != nil }

    private func articleIndex(forCarouselIndex index: Int) -> Int? {
        itemIndex(forCarouselIndex: index, itemCount: items.count)
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
            "\($0.id)|\($0.title ?? "")|\($0.state)|\($0.thumbnailFileName ?? "")|\(senderName(for: $0) ?? "")"
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
        ArchiveUnlockFlow.present(
            item: item, articleURL: articleURL, store: store, from: self
        ) { [weak self] fresh in
            guard let self else { return }
            ReadingListIngestor.shared.backfillMissingThumbnails()
            self.openExternally(fresh)
        }
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
        let item = items[itemIndex]
        let content = ReaderCardContentViewController(item: item, senderName: senderName(for: item))
        content.delegate = self
        return content
    }

    /// Incoming-email cards follow the contact's current name, falling back to
    /// the name captured from the original From header for legacy/unknown senders.
    private func senderName(for item: ReadingListItem) -> String? {
        Self.resolvedSenderName(for: item) { email in
            FriendsStore.shared.friend(withEmail: email)?.displayName
        }
    }

    static func resolvedSenderName(
        for item: ReadingListItem,
        contactNameForEmail: (String) -> String?
    ) -> String? {
        guard item.effectiveCaptureSource == .email else { return nil }
        if let email = item.incomingSenderEmail,
           let currentName = contactNameForEmail(email) {
            return currentName
        }
        return item.channelName
    }

    func carousel(
        _ carousel: CardCarouselViewController,
        loadThumbnailForCardAt index: Int,
        completion: @escaping (UIImage?) -> Void
    ) {
        completion(nil)   // mini-card strip; no image chips
    }

    func carousel(
        _ carousel: CardCarouselViewController,
        previewContentControllerForCardAt index: Int
    ) -> CardContentViewController? {
        if renderedPasteboardURL != nil, index == 0 {
            return PasteboardCardContentViewController(url: renderedPasteboardURL)
        }
        guard let itemIndex = articleIndex(forCarouselIndex: index) else { return nil }
        let listedItem = items[itemIndex]
        let item = store.item(withID: listedItem.id) ?? listedItem
        guard let content = store.content(for: item) else {
            return ArticleScrubPreviewViewController(
                title: item.title ?? item.url?.host ?? item.urlString,
                author: nil,
                excerpt: ArticleScrubPreviewText.unavailableText(for: item.state))
        }
        return ArticleScrubPreviewViewController(
            title: content.title,
            author: content.author,
            excerpt: ArticleScrubPreviewText.excerpt(
                from: content, aroundWordIndex: item.lastWordIndex,
                readingProgress: item.readingProgress))
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
            updateReaderChrome()
            layoutCardScrollIndicator(animated: false)
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
        updateExternalReaderInsets()
        updateReaderChrome()
        layoutCardScrollIndicator(animated: false)
    }

    func carousel(_ carousel: CardCarouselViewController, didTapCenteredCardAt index: Int) {
        if renderedPasteboardURL != nil, index == 0 {
            addPasteboardURL()
            return
        }
        guard let card = carousel.contentController(at: index) as? ReaderCardContentViewController,
              card.rabbitHoleReader != nil
        else {
            unlockCurrentCardIfNeeded()
            return
        }
        readerCard(
            card, didChangeImmersion: !carousel.isImmersed,
            extendsCard: card.rabbitHoleReader?.focusedContentScrollView != nil)
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

// MARK: - Reader card content delegate

extension ArticleCardsViewController: ReaderCardContentDelegate {

    fileprivate func readerCard(
        _ card: ReaderCardContentViewController, didChangeImmersion immersed: Bool, extendsCard: Bool
    ) {
        carousel.setImmersed(immersed, extendsCard: extendsCard, animated: true)
        UIView.animate(
            withDuration: 0.32, delay: 0,
            options: [.curveEaseInOut, .allowUserInteraction]
        ) {
            self.footerContentFade.alpha = immersed && extendsCard ? 1 : 0
        }
        // Slide the scroll indicator between the card edge and the screen
        // edge in step with the immersion (setImmersed's 0.32s ease-in-out).
        layoutCardScrollIndicator(animated: true)
    }

    fileprivate func readerCard(
        _ card: ReaderCardContentViewController, didBecomeReady reader: RabbitHoleReaderViewController
    ) {
        guard card.isCentered else { return }
        readerForChrome = reader
        updateExternalReaderInsets()
        updateReaderChrome()
        layoutCardScrollIndicator(animated: false)
    }

    fileprivate func readerCard(
        _ card: ReaderCardContentViewController, inlineReaderDidChange reader: ReaderChromeControlling?
    ) {
        guard card.isCentered else { return }
        readerForChrome = reader ?? card.rabbitHoleReader
        updateReaderChrome()
        // Step the host indicator aside for an inline reader (it keeps its
        // own), and take back over when it dismisses.
        layoutCardScrollIndicator(animated: false)
    }

    fileprivate func readerCardInlineFrameInWindow(_ card: ReaderCardContentViewController) -> CGRect? {
        guard let restingFrame = carousel.restingCenteredCardFrame(in: view) else { return nil }
        return view.convert(restingFrame, to: nil)
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

/// The push/pull contract between a `ReaderCardContentViewController` and its
/// host: three pushes (immersion changed, the reader became ready, an inline
/// reader presented/dismissed) and one pull (the card's resting frame in the
/// window, for an inline reader's presentation math). Sole conformer:
/// `ArticleCardsViewController`.
private protocol ReaderCardContentDelegate: AnyObject {
    /// The reader wants the carousel chrome faded away (true — reading is
    /// under way) or back in (false — the user is surfacing). `extendsCard`
    /// says whether the immersed card's bottom should extend into the strip's
    /// room: true for the scroll reader (more content shows), false for RSVP,
    /// whose fixed layout must not move when playback starts — only the chrome
    /// fades.
    func readerCard(
        _ card: ReaderCardContentViewController, didChangeImmersion immersed: Bool, extendsCard: Bool)
    func readerCard(
        _ card: ReaderCardContentViewController, didBecomeReady reader: RabbitHoleReaderViewController)
    func readerCard(
        _ card: ReaderCardContentViewController, inlineReaderDidChange reader: ReaderChromeControlling?)
    func readerCardInlineFrameInWindow(_ card: ReaderCardContentViewController) -> CGRect?
}

/// One article card: the FULL live reader, always embedded (side cards too, so
/// paging never shows a placeholder), laid out to the card's bounds — the card
/// view IS the fullscreen reader view, one header and one layout for both
/// states. The card reports reading activity so the host can fade the carousel
/// chrome around it: scroll direction in the scroll reader, play state in RSVP.
private final class ReaderCardContentViewController: CardContentViewController,
    InlineReaderPresentationCoordinating, RabbitHoleReaderDelegate {

    weak var delegate: ReaderCardContentDelegate?

    private let item: ReadingListItem
    private let senderName: String?
    private let statusLabel = UILabel()
    private let senderBadge = UIVisualEffectView(effect: GlassStyle.barEffect())
    private let senderLabel = UILabel()
    private var reader: UIViewController?
    private let immersionTracker = ScrollDirectionImmersionTracker()
    private(set) var isCentered = false
    var rabbitHoleReader: RabbitHoleReaderViewController? { reader as? RabbitHoleReaderViewController }

    init(item: ReadingListItem, senderName: String?) {
        self.item = item
        self.senderName = senderName
        super.init()
        immersionTracker.onImmersionChange = { [weak self] immersed, extendsCard in
            guard let self else { return }
            self.delegate?.readerCard(self, didChangeImmersion: immersed, extendsCard: extendsCard)
        }
        immersionTracker.bottomRevealDistance = { [weak self] in
            guard let self,
                  let resting = self.delegate?.readerCardInlineFrameInWindow(self)
            else { return 0 }
            return max(0, self.view.bounds.height - resting.height)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        embedReaderIfPossible()
        mountSenderBadgeIfNeeded()

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

    private func mountSenderBadgeIfNeeded() {
        guard let senderName, !senderName.isEmpty else { return }
        senderBadge.layer.cornerRadius = 14
        senderBadge.clipsToBounds = true
        senderBadge.isUserInteractionEnabled = false
        senderBadge.translatesAutoresizingMaskIntoConstraints = false
        senderLabel.text = "From \(senderName)"
        senderLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        senderLabel.textColor = .secondaryLabel
        senderLabel.lineBreakMode = .byTruncatingTail
        senderLabel.translatesAutoresizingMaskIntoConstraints = false
        senderBadge.contentView.addSubview(senderLabel)
        view.addSubview(senderBadge)
        NSLayoutConstraint.activate([
            senderBadge.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            senderBadge.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            senderBadge.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 48),
            senderBadge.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -48),
            senderBadge.heightAnchor.constraint(equalToConstant: 28),
            senderLabel.leadingAnchor.constraint(equalTo: senderBadge.contentView.leadingAnchor, constant: 11),
            senderLabel.trailingAnchor.constraint(equalTo: senderBadge.contentView.trailingAnchor, constant: -11),
            senderLabel.centerYAnchor.constraint(equalTo: senderBadge.contentView.centerYAnchor),
        ])
        senderBadge.accessibilityLabel = "From \(senderName)"
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
        immersionTracker.isActive = true
        if let rabbitHoleReader { delegate?.readerCard(self, didBecomeReady: rabbitHoleReader) }
    }

    override func cardDidLeaveCenter() {
        super.cardDidLeaveCenter()
        isCentered = false
        immersionTracker.isActive = false
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
            rabbitHole.presentsLinksAsInlineReaders = true
        }
        addChild(reader)
        reader.view.autoresizingMask = []
        view.insertSubview(reader.view, at: 0)
        reader.didMove(toParent: self)
        if let rabbitHole = reader as? RabbitHoleReaderViewController {
            rabbitHole.delegate = self
        }
        self.reader = reader
        reader.view.frame = view.bounds
        immersionTracker.observe(reader)
        if let rabbitHole = reader as? RabbitHoleReaderViewController {
            delegate?.readerCard(self, didBecomeReady: rabbitHole)
        }

        // Backstop sweeps for content that mounts without a hierarchy
        // callback (a dived-into non-article page installs its web view only
        // after an async probe). KVO only — never triggers layout.
        for delay in [0.7, 2.0, 4.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, let reader = self.reader else { return }
                self.immersionTracker.observe(reader)
            }
        }
    }

    // MARK: - RabbitHoleReaderDelegate

    func readerContentHierarchyDidChange(_ reader: RabbitHoleReaderViewController) {
        // A dive, pop, mode switch, or late article embed swaps the live scroll
        // views / RSVP controllers — re-sweep for new ones to observe (idempotent;
        // next runloop so the new child is mounted).
        DispatchQueue.main.async {
            if let root = self.reader { self.immersionTracker.observe(root) }
        }
        DispatchQueue.main.async {
            guard self.isCentered else { return }
            self.delegate?.readerCard(self, didBecomeReady: reader)
        }
    }

    func readerRequestedRootBack(_ reader: RabbitHoleReaderViewController) {
        // The reader has nowhere to pop to — surface, bringing the carousel
        // chrome back instead.
        guard isCentered else { return }
        delegate?.readerCard(self, didChangeImmersion: false, extendsCard: true)
    }

    func inlineReaderWillPresent(_ reader: ReaderChromeControlling) {
        guard isCentered else { return }
        delegate?.readerCard(
            self, didChangeImmersion: true,
            extendsCard: rabbitHoleReader?.focusedContentScrollView != nil)
        delegate?.readerCard(self, inlineReaderDidChange: reader)
    }

    func inlineReaderDidDismiss(_ reader: ReaderChromeControlling) {
        guard isCentered else { return }
        delegate?.readerCard(self, inlineReaderDidChange: rabbitHoleReader)
        if rabbitHoleReader?.shouldSurfaceAfterInlineReaderDismissal == true {
            delegate?.readerCard(self, didChangeImmersion: false, extendsCard: true)
        }
    }

    func inlineReaderWillDismiss(_ reader: ReaderChromeControlling) {
        guard isCentered,
              rabbitHoleReader?.shouldSurfaceAfterInlineReaderDismissal == true
        else { return }
        // This is visual choreography only. The chrome target remains the inline
        // reader until `inlineReaderDidDismiss` commits the successful dismissal.
        delegate?.readerCard(self, didChangeImmersion: false, extendsCard: true)
    }

    func inlineReaderDismissalDidCancel(_ reader: ReaderChromeControlling) {
        guard isCentered,
              rabbitHoleReader?.shouldSurfaceAfterInlineReaderDismissal == true
        else { return }
        delegate?.readerCard(
            self, didChangeImmersion: true,
            extendsCard: rabbitHoleReader?.focusedContentScrollView != nil)
    }

    var inlineReaderTopEdgeInWindow: CGFloat {
        guard isViewLoaded else { return 0 }
        return view.convert(view.bounds, to: nil).minY
    }

    var inlineReaderCardFrameInWindow: CGRect {
        guard isViewLoaded else { return .zero }
        // Immersion extends this content view to the bottom of the screen. The
        // nested reader must instead occupy the carousel card's stable resting
        // footprint; its own metrics reserve the tab strip within that height.
        if let restingFrame = delegate?.readerCardInlineFrameInWindow(self) {
            return restingFrame
        }
        return view.convert(view.bounds, to: nil)
    }

    var inlineReaderShowsOuterContentBelow: Bool {
        rabbitHoleReader?.focusedContentScrollView != nil
    }

    /// The resting clearance below the card's top edge — enough that an
    /// unscrolled page starts below the card's top-edge dissolve.
    func setTopContentInset(_ inset: CGFloat) {
        rabbitHoleReader?.externalChromeContentInset = max(inset, 0)
    }

    override func allowsCardTap(at point: CGPoint) -> Bool {
        !Self.readerControllers(under: reader).contains { controller in
            guard let scrollReader = controller as? ScrollReaderViewController,
                  scrollReader.isViewLoaded,
                  scrollReader.view.window != nil
            else { return false }
            return scrollReader.hasInteractiveContent(
                at: view.convert(point, to: scrollReader.view))
        }
    }

    private static func readerControllers(under root: UIViewController?) -> [UIViewController] {
        guard let root else { return [] }
        return [root] + root.children.flatMap { readerControllers(under: $0) }
    }

}

/// Screen-level footer veil used only while the scroll reader's card is
/// immersed. It dissolves content over the normal card fade depth, then paints
/// the footer safe area solid so reader content cannot bleed behind controls.
private final class ReaderFooterContentFadeView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    private var gradient: CAGradientLayer { layer as! CAGradientLayer }
    private var fadeHeight: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        updateColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
            (view: ReaderFooterContentFadeView, _: UITraitCollection) in view.updateColors()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.height > 0 else { return }
        gradient.locations = [0, NSNumber(value: min(fadeHeight / bounds.height, 1)), 1]
    }

    func setFadeHeight(_ height: CGFloat) {
        fadeHeight = max(height, 1)
        setNeedsLayout()
    }

    private func updateColors() {
        let background = UIColor.systemBackground.resolvedColor(with: traitCollection)
        gradient.colors = [
            background.withAlphaComponent(0).cgColor,
            background.cgColor,
            background.cgColor,
        ]
    }
}

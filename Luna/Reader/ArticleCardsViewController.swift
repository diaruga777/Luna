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
//  - Long-pressing a card exposes its archive action through a context menu.
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

    /// The central Luna app's card deck shows EVERY content kind, not just
    /// reader articles: media and price-tracker items get title/badge cards
    /// whose taps route through `nonArticleOpener` below.
    private let includesAllKinds = AppSurfaceConfig.current == .all

    /// Opens a non-article item (price tracker / platform post) from its card,
    /// mirroring the list rows' tap routing. Installed at launch by the app
    /// shell's kind wiring — only apps that surface those kinds install it, so
    /// the card deck stays article-only elsewhere (`includesAllKinds`).
    static var nonArticleOpener: ((ReadingListItem, UIViewController) -> Void)?

    private enum PasteboardCardState {
        case placeholder(changeCount: Int)
        case loading(changeCount: Int, urlString: String, likelyPrompted: Bool)
        case candidate(changeCount: Int, candidate: PasteboardCandidate, item: ReadingListItem)
        case invalid(changeCount: Int, showsSettingsGuidance: Bool)

        var changeCount: Int {
            switch self {
            case .placeholder(let count), .loading(let count, _, _),
                 .candidate(let count, _, _), .invalid(let count, _):
                return count
            }
        }

        var fingerprint: String {
            switch self {
            case .placeholder(let count): return "placeholder|\(count)"
            case .loading(let count, let url, _): return "loading|\(count)|\(url)"
            case .candidate(let count, let candidate, _):
                return "candidate|\(count)|\(candidate.urlString)|\(candidate.title)"
            case .invalid(let count, let guidance): return "invalid|\(count)|\(guidance)"
            }
        }
    }

    private let store = ReadingListStore.shared
    private let emptyView = CardCarouselHostViewController.makeEmptyStateView(
        symbol: "books.vertical", title: "No Saved Articles",
        subtitle: "Articles you save appear here as cards.")
    private let settingsButton = UIButton(type: .system)
    // Screen-level reader chrome (see mountTopChrome / mountBottomControls).
    private let readerChromeRow = UIView()
    private let readerBackButton = UIButton(type: .system)
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
    private var archivedItems: [ReadingListItem] = []
    private var appliedFingerprint: [String] = []
    private var pasteboardState: PasteboardCardState?
    /// Kept separate from the latest probe state so reload can map the centered
    /// saved article through the old index space when a leading card appears.
    private var renderedPasteboardState: PasteboardCardState?
    private var consumedPasteboardChangeCount: Int?
    private var pasteboardEvaluationTask: Task<Void, Never>?
    private var isCommittingPasteboardCandidate = false
    private var pendingPasteboardSavedID: UUID?
    /// One-shot centering override used by archive choreography. Store writes
    /// happen before the visual transition, then the synchronous reload places
    /// the intended successor/restored item under the animation snapshot.
    private var pendingTransitionCenteredID: UUID?
    /// An unarchive reload must not let normal pull-availability reconciliation
    /// snap the still-open tray shut before its coordinated dismissal begins.
    private var isAnimatingFromArchiveTray = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LunaColors.background

        var style = CardCarouselStyle()
        style.edgeGap = 10
        style.fillsVertically = true
        style.pagesOnInCardSwipes = true
        style.pageSwipeMovementMultiplier = 1.5
        style.scrubberStyle = .miniCards
        // The strip's actual viewport begins/ends at the inner edges of the
        // flanking 44pt Settings/Share circles (12pt outer margin). Its chips
        // alpha-fade as they approach those bounds.
        style.scrubberHorizontalInset = 56
        style.scrubberEdgeFadeWidth = 28
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
        mountArchiveTray(
            shifting: { [weak self] in
                guard let self else { return [] }
                return [self.carousel.view, self.emptyView]
            },
            canPull: { [weak self] in
                guard let self else { return false }
                let count = self.items.count + self.cardOffset
                return count == 0 || self.carousel.currentIndex == count - 1
            },
            openStateChanged: { [weak self] open in
                self?.readerAudioButton.isHidden = open
                self?.carousel.setMuteButtonOccluded(open)
            })

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
            readerAudioButton, symbol: "speaker.slash", action: #selector(readerAudioTapped),
            label: "Read Aloud")
        for control in [readerBackButton, readerAudioButton] {
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
            readerAudioButton.trailingAnchor.constraint(equalTo: readerChromeRow.trailingAnchor),
            readerAudioButton.centerYAnchor.constraint(equalTo: readerChromeRow.centerYAnchor),
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
        // Trailing edge: the card's at rest, the screen's while immersed. The
        // bar keeps its card-mode height and vertical position in both modes —
        // immersion only slides it horizontally to the screen edge.
        let rightEdge = immersed ? view.bounds.maxX : resting.maxX
        let top = resting.minY
        let bottom = resting.maxY
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
        readerChromeRow.isHidden = state == nil
        readerBackButton.isHidden = state?.showsBack != true
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
        updateBottomModeSwitcher(immersed: carousel.isImmersed, animated: false)
        readerAudioButton.isHidden = !state.isArticle
        readerShareButton.isHidden = !state.offersSaveShare
    }

    @objc private func readerBackTapped() { readerForChrome?.chromeBack(); updateReaderChrome() }
    @objc private func readerAudioTapped() { readerForChrome?.chromeToggleAudio(); updateReaderChrome() }
    @objc private func readerShareTapped() { readerForChrome?.chromeShare(from: readerShareButton) }
    @objc private func readerModeChanged() {
        guard chromeModes.indices.contains(readerModeControl.selectedSegmentIndex) else { return }
        readerForChrome?.chromeSetMode(chromeModes[readerModeControl.selectedSegmentIndex])
        updateReaderChrome()
    }

    /// Flanks the title scrubber with Settings and Share. The strip's bounds
    /// meet the buttons' inner edges and its chips fade before reaching them.
    private func mountBottomControls() {
        configureBottomButton(
            settingsButton, symbol: "gearshape", action: #selector(settingsTapped),
            accessibilityLabel: "Settings")
        configureBottomButton(
            readerShareButton, symbol: "square.and.arrow.up", action: #selector(readerShareTapped),
            accessibilityLabel: "Share")
        mountBottomControls(leading: settingsButton, trailing: readerShareButton)

        // The mode switcher owns the mini carousel's bottom-center lane only
        // while the surrounding card chrome is dismissed. It begins just below
        // its resting position so the first reveal can translate and fade in.
        readerModeControl.addTarget(self, action: #selector(readerModeChanged), for: .valueChanged)
        readerModeControl.translatesAutoresizingMaskIntoConstraints = false
        readerModeControl.alpha = 0
        readerModeControl.transform = Self.dismissedBottomControlTransform
        readerModeControl.isUserInteractionEnabled = false
        readerModeControl.accessibilityElementsHidden = true
        view.addSubview(readerModeControl)
        NSLayoutConstraint.activate([
            readerModeControl.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            readerModeControl.centerYAnchor.constraint(equalTo: settingsButton.centerYAnchor),
            readerModeControl.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    private static let dismissedBottomControlTransform = CGAffineTransform(
        translationX: 0, y: 8)

    /// Crossfades the bottom-center lane between the mini carousel and the
    /// reader modes. The carousel owns its matching scrubber animation; this
    /// half keeps the replacement control in exact visual lockstep.
    private func updateBottomModeSwitcher(immersed: Bool, animated: Bool) {
        let visible = immersed && !readerModeControl.isHidden
        readerModeControl.isUserInteractionEnabled = visible
        readerModeControl.accessibilityElementsHidden = !visible
        let changes = {
            self.readerModeControl.alpha = visible ? 1 : 0
            self.readerModeControl.transform = visible
                ? .identity
                : Self.dismissedBottomControlTransform
        }
        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            changes()
            return
        }
        UIView.animate(
            withDuration: 0.24, delay: visible ? 0.06 : 0,
            options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState],
            animations: changes)
    }

    // MARK: - Data

    @objc private func refreshPasteboardURL() {
        let pasteboard = UIPasteboard.general
        if consumedPasteboardChangeCount == pasteboard.changeCount {
            setPasteboardState(nil)
            return
        }
        guard pasteboardState?.changeCount != pasteboard.changeCount else { return }
        pasteboardEvaluationTask?.cancel()
        setPasteboardState(nil)
        let changeCount = pasteboard.changeCount
        // Pattern detection reveals only that a probable URL exists and does not
        // notify the user. The value itself is read only after this card is paged
        // onto (or tapped when it is the sole card).
        pasteboard.detectPatterns(for: [\.probableWebURL]) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, UIPasteboard.general.changeCount == changeCount else { return }
                let hasLink = (try? result.get())?.contains(\.probableWebURL) == true
                self.setPasteboardState(hasLink ? .placeholder(changeCount: changeCount) : nil)
            }
        }
    }

    private func setPasteboardState(_ state: PasteboardCardState?) {
        pasteboardState = state
        reload()
    }

    private func readPasteboardPlaceholder() {
        guard case .placeholder(let expectedChangeCount) = renderedPasteboardState else { return }
        let result = PasteboardReadTiming.readGeneralPasteboard()
        guard result.changeCount == expectedChangeCount,
              UIPasteboard.general.changeCount == expectedChangeCount,
              let value = result.value,
              let url = URLUnwrapper.ingestURL(from: value)
        else {
            setPasteboardState(.invalid(
                changeCount: expectedChangeCount,
                showsSettingsGuidance: result.likelyPresentedPermissionPrompt))
            return
        }

        let urlString = url.absoluteString
        setPasteboardState(.loading(
            changeCount: expectedChangeCount, urlString: urlString,
            likelyPrompted: result.likelyPresentedPermissionPrompt))
        pasteboardEvaluationTask?.cancel()
        pasteboardEvaluationTask = Task { [weak self] in
            let candidate = await PasteboardSuggester.shared.evaluate(urlString: urlString)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self,
                      case .loading(let count, let currentURL, let likelyPrompted) = self.pasteboardState,
                      count == expectedChangeCount, currentURL == urlString,
                      UIPasteboard.general.changeCount == expectedChangeCount
                else { return }
                guard let candidate, candidate.platform == nil,
                      candidate.content != nil || candidate.requiresUnlock
                else {
                    self.setPasteboardState(.invalid(
                        changeCount: expectedChangeCount,
                        showsSettingsGuidance: likelyPrompted))
                    return
                }
                var item = ReadingListItem(urlString: candidate.urlString)
                item.title = candidate.title
                item.channelName = candidate.channelName
                item.state = candidate.requiresUnlock ? .needsCaptcha : .ready
                self.setPasteboardState(.candidate(
                    changeCount: expectedChangeCount, candidate: candidate, item: item))
            }
        }
    }

    override var hasLeadingPasteboardCard: Bool { renderedPasteboardState != nil }

    private func articleIndex(forCarouselIndex index: Int) -> Int? {
        itemIndex(forCarouselIndex: index, itemCount: items.count)
    }

    private func commitPasteboardCandidate(openLockedAfterSave: Bool = false) {
        guard !isCommittingPasteboardCandidate,
              case .candidate(let changeCount, let candidate, _) = renderedPasteboardState
        else { return }
        isCommittingPasteboardCandidate = true
        Task { [weak self] in
            let saved: ReadingListItem?
            if let content = candidate.content {
                saved = await ReadingListIngestor.shared.saveNewWithContent(
                    urlString: candidate.urlString, content: content, source: .paste)
            } else {
                let result = await ReadingListIngestor.shared.handleSavePress(
                    urlString: candidate.urlString, source: .paste)
                switch result {
                case .saved(let item),
                     .sentToEreaders(let item), .sentToFriends(let item),
                     .friendPromptRequested(let item):
                    saved = item
                case .ignored, .unsupportedKind:
                    saved = nil
                }
            }
            await MainActor.run {
                guard let self else { return }
                self.isCommittingPasteboardCandidate = false
                guard let saved else { return }
                self.pendingPasteboardSavedID = saved.id
                self.consumedPasteboardChangeCount = changeCount
                let pasteboardChanged = UIPasteboard.general.changeCount != changeCount
                if PasteboardCommitPolicy.shouldClearCommittedCard(
                    committedChangeCount: changeCount,
                    currentPasteboardChangeCount: UIPasteboard.general.changeCount,
                    representedChangeCount: self.pasteboardState?.changeCount
                ) {
                    self.pasteboardState = nil
                }
                self.reload()
                if pasteboardChanged { self.refreshPasteboardURL() }
                if openLockedAfterSave,
                   let fresh = self.store.item(withID: saved.id), let url = fresh.url {
                    self.presentArchiveReader(for: fresh, articleURL: url)
                }
            }
        }
    }

    @objc private func reload() {
        let allReaderItems = store.items().filter {
            includesAllKinds || ReadingListSectioning.rendersAsReader($0)
        }
        var updated = Self.orderedReaderItems(allReaderItems, includesAllKinds: includesAllKinds)
        if isCommittingPasteboardCandidate,
           case .candidate(_, let candidate, _) = renderedPasteboardState {
            updated.removeAll { $0.urlString == candidate.urlString }
        }
        let updatedArchive = allReaderItems.filter(\.isArchived).sorted {
            ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast)
        }
        var fingerprint = updated.map {
            "active|\($0.id)|\($0.title ?? "")|\($0.state)|\($0.thumbnailFileName ?? "")|\(senderName(for: $0) ?? "")"
        }
        fingerprint.append(contentsOf: updatedArchive.map {
            "archive|\($0.id)|\($0.title ?? "")|\($0.archivedAt?.timeIntervalSince1970 ?? 0)"
        })
        fingerprint.insert("paste|\(pasteboardState?.fingerprint ?? "")", at: 0)
        guard fingerprint != appliedFingerprint else { return }
        appliedFingerprint = fingerprint

        let wasPasteboardCentered = renderedPasteboardState != nil && carousel.currentIndex == 0
        let oldItemIndex = carousel.currentIndex - cardOffset
        let centeredID = items.indices.contains(oldItemIndex) ? items[oldItemIndex].id : nil
        items = updated
        archivedItems = updatedArchive
        renderedPasteboardState = pasteboardState
        let newOffset = cardOffset
        let pendingIndex = pendingPasteboardSavedID.flatMap { id in
            items.firstIndex { $0.id == id }
        }
        let transitionIndex = pendingTransitionCenteredID.flatMap { id in
            items.firstIndex { $0.id == id }.map { $0 + newOffset }
        }
        let preservedIndex = wasPasteboardCentered && renderedPasteboardState != nil
            ? 0
            : centeredID.flatMap { id in
            items.firstIndex { $0.id == id }.map { $0 + newOffset }
        }
        let centeredIndex = transitionIndex ?? preservedIndex
            ?? pendingIndex.map { $0 + newOffset }
            ?? (items.isEmpty ? 0 : newOffset)
        pendingTransitionCenteredID = nil
        if pendingIndex != nil { pendingPasteboardSavedID = nil }
        carousel.reloadData(centeringAt: centeredIndex)
        emptyView.isHidden = !items.isEmpty || renderedPasteboardState != nil
        carousel.view.isHidden = items.isEmpty && renderedPasteboardState == nil
        archiveTray?.setItems(makeArchiveTrayItems())
        if !isAnimatingFromArchiveTray {
            refreshArchivePullAvailability(animated: false)
        }
        updateReaderChrome()
    }

    /// Keeps finished articles available as ordinary reader cards for now, but
    /// groups them after every unopened/in-progress article. Each group retains
    /// the carousel's newest/bumped-first ordering.
    static func orderedReaderItems(
        _ candidates: [ReadingListItem], includesAllKinds: Bool = false
    ) -> [ReadingListItem] {
        candidates
            .filter { (includesAllKinds || ReadingListSectioning.rendersAsReader($0)) && !$0.isArchived }
            .sorted { lhs, rhs in
                // A just-finished card remains in its current foreground-session
                // position until the pending archive is committed on background.
                let lhsIsRead = lhs.readState == .read && lhs.pendingArchiveAt == nil
                let rhsIsRead = rhs.readState == .read && rhs.pendingArchiveAt == nil
                if lhsIsRead != rhsIsRead { return !lhsIsRead }
                let lhsDate = lhs.bumpDate ?? lhs.dateAdded
                let rhsDate = rhs.bumpDate ?? rhs.dateAdded
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    private func makeArchiveTrayItems() -> [ArchiveTrayItem] {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return archivedItems.map { item in
            ArchiveTrayItem(
                id: item.id,
                title: item.title ?? item.url?.host ?? item.urlString,
                footer: formatter.string(from: item.dateAdded),
                showsMetadata: true,
                isAvailable: true,
                loadImage: { completion in
                    guard let url = item.url else {
                        completion(UIImage(systemName: item.isDocument ? "doc" : "globe"))
                        return
                    }
                    completion(UIImage(systemName: "globe"))
                    SourceIconCache.shared.icon(forPageURL: url) { image in
                        if let image { completion(image) }
                    }
                },
                tap: { [weak self] in self?.openExternally(item) },
                share: { [weak self] sourceView in
                    guard let self else { return }
                    AppReaderShareProvider.shared.presentShareSheet(
                        urlString: item.urlString,
                        title: item.title,
                        from: self,
                        sourceView: sourceView)
                },
                unarchive: { [weak self] sourceView in
                    self?.unarchive(item, from: sourceView)
                },
                delete: { [weak self] in self?.deleteArchived(item) })
        }
    }

    // MARK: - Archive transitions

    private func archive(_ item: ReadingListItem, fromCarouselIndex carouselIndex: Int) {
        guard let itemIndex = items.firstIndex(where: { $0.id == item.id }) else { return }
        let isCentered = carousel.currentIndex == carouselIndex
        let successor: ReadingListItem?
        let incomingDirection: CGFloat
        if itemIndex + 1 < items.count {
            successor = items[itemIndex + 1]
            incomingDirection = 1
        } else if itemIndex > 0 {
            successor = items[itemIndex - 1]
            incomingDirection = -1
        } else {
            successor = nil
            incomingDirection = 0
        }

        let sourceCard = carousel.cardView(at: carouselIndex)
        let snapshot = sourceCard.flatMap(makeTransitionSnapshot(of:))
        if isCentered { pendingTransitionCenteredID = successor?.id }

        // Persist first. The manual reload consumes the new disk/cache truth in
        // this same event turn; the queued notification becomes a no-op because
        // its fingerprint has already been applied.
        store.setArchived(true, for: item.id)
        reload()

        guard isCentered, !UIAccessibility.isReduceMotionEnabled,
              UIView.areAnimationsEnabled else {
            snapshot?.removeFromSuperview()
            return
        }

        let incoming: UIView? = successor == nil
            ? emptyView
            : carousel.cardView(at: carousel.currentIndex)
        incoming?.alpha = 0
        carousel.view.isUserInteractionEnabled = false

        let revealIncoming = { [weak self, weak incoming] in
            guard let self else { return }
            incoming?.transform = CGAffineTransform(
                translationX: incomingDirection * 28, y: 0).scaledBy(x: 0.985, y: 0.985)
            UIView.animate(
                withDuration: 0.42, delay: 0,
                usingSpringWithDamping: 0.88, initialSpringVelocity: 0.15,
                options: [.beginFromCurrentState, .allowUserInteraction]
            ) {
                incoming?.alpha = 1
                incoming?.transform = .identity
            } completion: { _ in
                incoming?.alpha = 1
                incoming?.transform = .identity
                self.carousel.view.isUserInteractionEnabled = true
            }
        }

        guard let snapshot else {
            revealIncoming()
            return
        }
        UIView.animate(
            withDuration: 0.24, delay: 0,
            options: [.curveEaseIn, .beginFromCurrentState, .allowUserInteraction]
        ) {
            snapshot.alpha = 0
            snapshot.transform = CGAffineTransform(translationX: 0, y: -20)
        } completion: { _ in
            snapshot.removeFromSuperview()
            revealIncoming()
        }
    }

    private func unarchive(_ item: ReadingListItem, from sourceView: UIView) {
        guard archivedItems.contains(where: { $0.id == item.id }) else { return }
        let snapshot = makeTransitionSnapshot(of: sourceView)
        isAnimatingFromArchiveTray = true
        pendingTransitionCenteredID = item.id

        // `markUnread` also stamps bumpDate, making this the first active
        // article. Reload synchronously so the destination exists before the
        // tray and traveling snapshot begin their coordinated animation.
        store.markUnread(item.id)
        reload()
        view.layoutIfNeeded()

        let destination = carousel.cardView(at: carousel.currentIndex)
        destination?.alpha = 0
        let shouldAnimate = !UIAccessibility.isReduceMotionEnabled
            && UIView.areAnimationsEnabled && snapshot != nil && destination != nil

        archiveTray?.dismiss(animated: shouldAnimate)

        guard shouldAnimate, let snapshot, let destination else {
            snapshot?.removeFromSuperview()
            destination?.alpha = 1
            finishUnarchiveTransition()
            return
        }

        // The tray cell and reader card have intentionally different aspect
        // ratios. Morphing one snapshot frame into the other visibly stretches
        // the archived artwork, so keep the source geometry intact and dissolve
        // it into the already-final destination content instead.
        carousel.view.isUserInteractionEnabled = false
        destination.transform = CGAffineTransform(scaleX: 0.985, y: 0.985)
        UIView.animate(
            withDuration: 0.34, delay: 0,
            options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]
        ) {
            snapshot.alpha = 0
            destination.alpha = 1
            destination.transform = .identity
        } completion: { [weak self, weak destination] _ in
            snapshot.removeFromSuperview()
            destination?.alpha = 1
            destination?.transform = .identity
            self?.finishUnarchiveTransition()
        }
    }

    private func finishUnarchiveTransition() {
        isAnimatingFromArchiveTray = false
        carousel.view.isUserInteractionEnabled = true
        refreshArchivePullAvailability(animated: false)
    }

    private func deleteArchived(_ item: ReadingListItem) {
        store.delete(item)
        reload()
    }

    private func deleteActive(_ item: ReadingListItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        if carousel.currentIndex == index + cardOffset {
            let successor = items.indices.contains(index + 1)
                ? items[index + 1]
                : (index > 0 ? items[index - 1] : nil)
            pendingTransitionCenteredID = successor?.id
        }
        store.delete(item)
        reload()
    }

    private func makeTransitionSnapshot(of sourceView: UIView) -> UIView? {
        guard let snapshot = sourceView.snapshotView(afterScreenUpdates: false) else { return nil }
        snapshot.frame = sourceView.convert(sourceView.bounds, to: view)
        if let cell = sourceView as? UICollectionViewCell {
            snapshot.layer.cornerRadius = cell.contentView.layer.cornerRadius
        } else {
            snapshot.layer.cornerRadius = sourceView.layer.cornerRadius
        }
        snapshot.layer.cornerCurve = .continuous
        snapshot.clipsToBounds = true
        view.addSubview(snapshot)
        return snapshot
    }

    private func cardContextMenu(
        for item: ReadingListItem, carouselIndex: Int
    ) -> UIMenu {
        UIMenu(children: [
            UIAction(title: "Archive", image: UIImage(systemName: "archivebox")) {
                [weak self] _ in
                self?.archive(item, fromCarouselIndex: carouselIndex)
            },
            UIAction(
                title: "Delete", image: UIImage(systemName: "trash"),
                attributes: .destructive
            ) { [weak self] _ in
                self?.deleteActive(item)
            },
        ])
    }

    #if DEBUG
    func cardContextMenuForTesting(at carouselIndex: Int) -> UIMenu? {
        guard let itemIndex = articleIndex(forCarouselIndex: carouselIndex) else { return nil }
        return cardContextMenu(for: items[itemIndex], carouselIndex: carouselIndex)
    }
    #endif

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
        if let state = renderedPasteboardState, index == 0 {
            switch state {
            case .placeholder:
                return PasteboardPlaceholderCardContentViewController(
                    title: "Paste Link", detail: "Swipe here to preview the pasted URL.")
            case .loading:
                return PasteboardPlaceholderCardContentViewController(
                    title: "Loading Paste", detail: "Preparing a temporary reader card…")
            case .invalid(_, let guidance):
                return InvalidPasteCardContentViewController(showsSettingsGuidance: guidance)
            case .candidate(_, let candidate, let item):
                let content = ReaderCardContentViewController(
                    item: item, senderName: nil, knownContent: candidate.content)
                content.setTopContentInset(Self.contentEdgeFade)
                content.delegate = self
                return content
            }
        }
        guard let itemIndex = articleIndex(forCarouselIndex: index) else {
            return CardContentViewController()
        }
        let item = items[itemIndex]
        let content = ReaderCardContentViewController(item: item, senderName: senderName(for: item))
        // Apply the title clearance as part of construction, not only after a
        // card becomes centered. A scrubber jump can stage index ±2 immediately
        // before the eclipse, and that incoming card must already have the same
        // title/header geometry as the visible window.
        content.setTopContentInset(Self.contentEdgeFade)
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
        self.carousel(carousel, contentControllerForCardAt: index)
    }

    /// Chip badge: an instant fallback (initials / mail / document / globe)
    /// first, then the site's real favicon replaces it once fetched. Cached
    /// icons resolve synchronously, so a warm strip shows favicons at once.
    func carousel(
        _ carousel: CardCarouselViewController,
        loadSourceBadgeForCardAt index: Int,
        completion: @escaping (CarouselSourceBadge?) -> Void
    ) {
        if let state = renderedPasteboardState, index == 0 {
            switch state {
            case .placeholder, .loading:
                completion(.symbol("doc.on.clipboard"))
            case .invalid:
                completion(.symbol("exclamationmark.circle"))
            case .candidate(_, _, let item):
                completion(ArticleSourceBadge.fallback(for: item))
                if ArticleSourceBadge.wantsFavicon(item), let url = item.url {
                    SourceIconCache.shared.icon(forPageURL: url) { image in
                        if let image { completion(.icon(image)) }
                    }
                }
            }
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
        if let state = renderedPasteboardState, index == 0 {
            switch state {
            case .placeholder: return "Paste Link"
            case .loading: return "Loading Paste"
            case .invalid: return "Invalid paste"
            case .candidate(_, let candidate, _): return candidate.title
            }
        }
        guard let itemIndex = articleIndex(forCarouselIndex: index) else { return nil }
        let item = items[itemIndex]
        return item.title ?? item.url?.host ?? item.urlString
    }
}

// MARK: - Carousel delegate

extension ArticleCardsViewController: CardCarouselDataSource {}

extension ArticleCardsViewController: CardCarouselDelegate {

    func carousel(
        _ carousel: CardCarouselViewController,
        navigationTargetDidChangeTo index: Int
    ) {
        updateArchivePullAvailability(
            forTargetIndex: index,
            cardCount: items.count + cardOffset,
            animated: true)
    }

    func carousel(
        _ carousel: CardCarouselViewController,
        menuForCardAt index: Int
    ) -> UIMenu? {
        guard let itemIndex = articleIndex(forCarouselIndex: index) else { return nil }
        let item = items[itemIndex]
        return cardContextMenu(for: item, carouselIndex: index)
    }

    func carouselDidSurfaceForEdgePaging(_ carousel: CardCarouselViewController) {
        // The carousel has already restored its card geometry so this same pan
        // can page. Keep the screen-level footer veil and indicator in lockstep.
        footerContentFade.alpha = 0
        (carousel.contentController(at: carousel.currentIndex) as? ReaderCardContentViewController)?
            .setCardChromeVisible(true, animated: false)
        archiveTray?.setChromeHidden(false, animated: false)
        updateBottomModeSwitcher(immersed: false, animated: false)
        layoutCardScrollIndicator(animated: false)
    }

    func carousel(_ carousel: CardCarouselViewController, didCenterCardAt index: Int) {
        refreshArchivePullAvailability(animated: true)
        if let state = renderedPasteboardState, index == 0 {
            switch state {
            case .placeholder:
                readerForChrome = nil
                updateReaderChrome()
                layoutCardScrollIndicator(animated: false)
                // When no normal cards exist, initial layout centers the
                // placeholder without user intent; a tap performs the read.
                if !items.isEmpty { readPasteboardPlaceholder() }
            case .loading, .invalid:
                readerForChrome = nil
                updateReaderChrome()
                layoutCardScrollIndicator(animated: false)
            case .candidate:
                let card = carousel.contentController(at: index) as? ReaderCardContentViewController
                card?.setCardChromeVisible(!carousel.isImmersed, animated: false)
                readerForChrome = card?.rabbitHoleReader
                updateExternalReaderInsets()
                updateReaderChrome()
                layoutCardScrollIndicator(animated: false)
            }
            return
        }
        guard let itemIndex = articleIndex(forCarouselIndex: index) else { return }
        store.markReadState(.opened, for: items[itemIndex].id)
        let card = carousel.contentController(at: index) as? ReaderCardContentViewController
        card?.setCardChromeVisible(!carousel.isImmersed, animated: false)
        readerForChrome = card?.rabbitHoleReader
        updateExternalReaderInsets()
        updateReaderChrome()
        layoutCardScrollIndicator(animated: false)
    }

    func carousel(_ carousel: CardCarouselViewController, didTapCenteredCardAt index: Int) {
        if let state = renderedPasteboardState, index == 0 {
            switch state {
            case .placeholder:
                readPasteboardPlaceholder()
            case .candidate(_, let candidate, _):
                if candidate.requiresUnlock {
                    commitPasteboardCandidate(openLockedAfterSave: true)
                } else if let card = carousel.contentController(at: index)
                            as? ReaderCardContentViewController,
                          card.rabbitHoleReader != nil {
                    readerCard(
                        card, didChangeImmersion: !carousel.isImmersed,
                        extendsCard: card.rabbitHoleReader?.focusedContentScrollView != nil)
                }
            case .loading, .invalid:
                break
            }
            return
        }
        // A non-article card (central Luna app only) routes to its own screen
        // — the price editor or the platform open ladder — never the reader.
        if let itemIndex = articleIndex(forCarouselIndex: index),
           items.indices.contains(itemIndex) {
            let item = items[itemIndex]
            if item.isPriceTracker || item.contentPlatform != nil {
                Self.nonArticleOpener?(item, self)
                return
            }
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

}

// MARK: - Reader card content delegate

extension ArticleCardsViewController: ReaderCardContentDelegate {

    fileprivate func readerCard(
        _ card: ReaderCardContentViewController, didChangeImmersion immersed: Bool, extendsCard: Bool
    ) {
        if immersed, renderedPasteboardState != nil,
           carousel.currentIndex == 0,
           carousel.contentController(at: 0) === card {
            commitPasteboardCandidate()
        }
        card.setCardChromeVisible(!immersed, animated: true)
        carousel.setImmersed(immersed, extendsCard: extendsCard, animated: true)
        // The archive peek is card chrome too: it fades away with the
        // side-card peeks and returns with them.
        archiveTray?.setChromeHidden(immersed, animated: true)
        updateBottomModeSwitcher(immersed: immersed, animated: true)
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
    private let statusLabel = UILabel()
    /// The pinned copy shown while card chrome is surfaced and the scrollable
    /// copy that permanently occupies the reader's top content inset. Keeping
    /// both copies laid out identically lets visibility change without changing
    /// the live reader's geometry or content offset.
    private let titleHeader: ReaderCardTitleHeaderView
    private let scrollTitleHeader: ReaderCardTitleHeaderView
    private let knownContent: ArticleContent?
    private var reader: UIViewController?
    private let immersionTracker = ScrollDirectionImmersionTracker()
    private var baseTopContentInset: CGFloat = 0
    private var titleHeaderHeight: CGFloat = 0
    private var cardChromeVisible = true
    private weak var titleScrollView: UIScrollView?
    private var titleScrollObservation: NSKeyValueObservation?
    /// Coalesces UIKit's intermediate programmatic offsets (notably the
    /// prefix-to-full article swap) so the pinned/scrolling title copies never
    /// trade visibility for a single frame after a card transition.
    private var pendingProgrammaticTitleUpdate: DispatchWorkItem?
    private(set) var isCentered = false
    var rabbitHoleReader: LunaReaderUI.RabbitHoleReaderViewController? {
        reader as? LunaReaderUI.RabbitHoleReaderViewController
    }

    init(item: ReadingListItem, senderName: String?, knownContent: ArticleContent? = nil) {
        self.item = item
        self.knownContent = knownContent
        let senderSubtitle = senderName.flatMap { name -> String? in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : "From \(trimmed)"
        }
        self.titleHeader = ReaderCardTitleHeaderView(
            title: item.title ?? "Untitled", subtitle: senderSubtitle)
        self.scrollTitleHeader = ReaderCardTitleHeaderView(
            title: item.title ?? "Untitled", subtitle: senderSubtitle)
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
        mountTitleHeader()

        if reader == nil {
            statusLabel.font = .preferredFont(forTextStyle: .subheadline)
            statusLabel.textColor = LunaColors.secondaryText
            statusLabel.textAlignment = .center
            statusLabel.numberOfLines = 0
            if item.isPriceTracker {
                statusLabel.text = "Tap to see price history"
            } else if item.contentPlatform != nil {
                statusLabel.text = "Tap to open"
            } else {
                switch item.state {
                case .pending: statusLabel.text = "Fetching…"
                case .failed: statusLabel.text = "Couldn't fetch this article"
                case .needsCaptcha: statusLabel.text = "Locked — tap to unlock"
                case .ready: statusLabel.text = nil
                }
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

    private func mountTitleHeader() {
        for header in [titleHeader, scrollTitleHeader] {
            header.isUserInteractionEnabled = false
        }
        view.addSubview(titleHeader)
        guard ArticleSourceBadge.wantsFavicon(item), let url = item.url else { return }
        SourceIconCache.shared.icon(forPageURL: url) { [weak self] image in
            guard let image else { return }
            self?.titleHeader.setIcon(image)
            self?.scrollTitleHeader.setIcon(image)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The reader fills the card — the fade-out's bottom extension just
        // grows this frame, revealing more content; nothing inside shifts.
        reader?.view.frame = view.bounds
        let height = titleHeader.heightThatFits(
            width: view.bounds.width, topInset: baseTopContentInset)
        _ = scrollTitleHeader.heightThatFits(
            width: view.bounds.width, topInset: baseTopContentInset)
        // The background begins at the card's top edge while the title/icon keep
        // their normal clearance below the edge dissolve.
        titleHeader.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: height)
        if abs(height - titleHeaderHeight) > 0.5 {
            titleHeaderHeight = height
            applyReaderTopInset()
        }
        synchronizeScrollableTitleHeader()
    }

    // MARK: - Live reader lifecycle

    override func cardDidBecomeCentered() {
        super.cardDidBecomeCentered()
        isCentered = true
        immersionTracker.isActive = true
        rabbitHoleReader?.activatePrimaryContent()
        if let rabbitHoleReader { delegate?.readerCard(self, didBecomeReady: rabbitHoleReader) }
    }

    override func cardDidLeaveCenter() {
        super.cardDidLeaveCenter()
        isCentered = false
        immersionTracker.isActive = false
        setCardChromeVisible(true, animated: false)
    }

    private func embedReaderIfPossible() {
        guard reader == nil, item.state == .ready,
              let content = knownContent ?? ReadingListStore.shared.content(for: item)
        else { return }
        titleHeader.setTitle(content.title)
        scrollTitleHeader.setTitle(content.title)
        // Render only the initial scroll viewport while this is a side card or
        // scrub preview. Promotion keeps this exact controller and then permits
        // its seamless Phase-2 expansion; offscreen text layout and image work
        // therefore never sits on the scrub interaction's critical path.
        let reader = ReaderHostFactory.make(
            item: item, content: content,
            shareProvider: AppReaderShareProvider.shared,
            fullContentUpFront: false,
            includesArticleTitle: false)
        if let rabbitHole = reader as? LunaReaderUI.RabbitHoleReaderViewController {
            rabbitHole.providesOwnChrome = false
            rabbitHole.presentsLinksAsInlineReaders = true
            rabbitHole.defersFullContentUntilPrimary = true
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
        synchronizeScrollableTitleHeader()
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
        // Mode switches mount their child before this callback, so retarget the
        // title synchronously as well; the async pass remains a backstop for a
        // late-loading web/article child.
        synchronizeScrollableTitleHeader()
        DispatchQueue.main.async {
            if let root = self.reader { self.immersionTracker.observe(root) }
            self.synchronizeScrollableTitleHeader()
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
        baseTopContentInset = max(inset, 0)
        view.setNeedsLayout()
        applyReaderTopInset()
    }

    /// Card immersion changes only the pinned copy's visibility. The scrollable
    /// copy and the reader's top inset never move, so scroll/RSVP/archive layouts
    /// remain stable throughout the transition. RSVP has no scroll surface and
    /// therefore keeps the pinned title visible at all times.
    func setCardChromeVisible(_ visible: Bool, animated: Bool) {
        cardChromeVisible = visible
        updatePinnedTitleVisibility(animated: animated)
    }

    /// Moves the permanent title copy into whichever scroll surface is focused
    /// (Scroll, Original/web archive, or its local article snapshot). It occupies the
    /// negative content-inset region, so at offset zero it lands pixel-for-pixel
    /// beneath the pinned copy and then naturally scrolls away with the page.
    private func synchronizeScrollableTitleHeader() {
        let focused = rabbitHoleReader?.focusedContentScrollView
        if focused !== titleScrollView {
            pendingProgrammaticTitleUpdate?.cancel()
            pendingProgrammaticTitleUpdate = nil
            titleScrollObservation = nil
            scrollTitleHeader.removeFromSuperview()
            titleScrollView = focused
            if let focused {
                focused.addSubview(scrollTitleHeader)
                focused.bringSubviewToFront(scrollTitleHeader)
                titleScrollObservation = focused.observe(\.contentOffset, options: [.new]) {
                    [weak self, weak focused] _, _ in
                    self?.scrollOffsetDidChange(in: focused)
                }
            }
        }
        guard let focused else {
            updatePinnedTitleVisibility(animated: false)
            return
        }
        // The nested reader lays out after this card. During the first visible
        // parent pass its scroll view can therefore still carry the old,
        // screen-wide bounds, even though the card already has its final width.
        // Size both title copies from the card so the scrolling copy cannot
        // paint wide and then visibly re-wrap on the reader's following pass.
        scrollTitleHeader.frame = CGRect(
            x: 0, y: -titleHeaderHeight,
            width: view.bounds.width, height: titleHeaderHeight)
        focused.bringSubviewToFront(scrollTitleHeader)
        updatePinnedTitleVisibility(animated: false)
    }

    private func scrollOffsetDidChange(in scrollView: UIScrollView?) {
        guard let scrollView, scrollView === titleScrollView else { return }
        if !ScrollPresentationState.isSuppressed(for: scrollView)
            || scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating {
            pendingProgrammaticTitleUpdate?.cancel()
            pendingProgrammaticTitleUpdate = nil
            updatePinnedTitleVisibility(animated: false)
            return
        }

        // Assigning the full attributed string can briefly clamp the offset
        // before ScrollReader restores it in the same runloop turn. Evaluate
        // only the settled value so the two identical title copies cannot
        // flicker between each other or appear to re-layout.
        pendingProgrammaticTitleUpdate?.cancel()
        let work = DispatchWorkItem { [weak self, weak scrollView] in
            guard let self, let scrollView, scrollView === self.titleScrollView else { return }
            self.pendingProgrammaticTitleUpdate = nil
            self.updatePinnedTitleVisibility(animated: false)
        }
        pendingProgrammaticTitleUpdate = work
        DispatchQueue.main.async(execute: work)
    }

    private func updatePinnedTitleVisibility(animated: Bool) {
        // With no scroll surface the active reader is RSVP (or a non-ready
        // placeholder), whose title is fixed and never follows card chrome.
        let showsPinnedTitle = titleScrollView == nil
            || (cardChromeVisible && focusedScrollIsPastTitle)
        let changes = {
            self.titleHeader.alpha = showsPinnedTitle ? 1 : 0
        }
        titleHeader.accessibilityElementsHidden = !showsPinnedTitle
        scrollTitleHeader.accessibilityElementsHidden = showsPinnedTitle
        if animated {
            UIView.animate(
                withDuration: 0.32, delay: 0,
                options: [.curveEaseInOut, .allowUserInteraction], animations: changes)
        } else {
            changes()
        }
    }

    private var focusedScrollIsPastTitle: Bool {
        guard let scroll = titleScrollView else { return false }
        let distanceFromTop = scroll.contentOffset.y + scroll.adjustedContentInset.top
        return distanceFromTop > titleHeaderHeight + 1
    }

    private func applyReaderTopInset() {
        rabbitHoleReader?.externalChromeContentInset = titleHeaderHeight
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

/// The title treatment shared by Scroll, RSVP, and Original while an article is
/// shown as a carousel card. It uses the same 30-point reader title typography,
/// now paired with the page's favicon (a globe remains visible while it loads).
private final class ReaderCardTitleHeaderView: UIView {
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private var topInset: CGFloat = 0

    init(title: String, subtitle: String?) {
        super.init(frame: .zero)
        backgroundColor = LunaColors.background

        iconView.image = UIImage(systemName: "globe")
        iconView.tintColor = LunaColors.secondaryText
        iconView.contentMode = .scaleAspectFit
        iconView.layer.cornerRadius = 6
        iconView.clipsToBounds = true

        titleLabel.text = title
        titleLabel.font = Self.readerTitleFont
        titleLabel.textColor = LunaColors.primaryText
        titleLabel.numberOfLines = 3
        titleLabel.lineBreakMode = .byTruncatingTail

        subtitleLabel.text = subtitle
        subtitleLabel.font = .preferredFont(forTextStyle: .caption1)
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textColor = LunaColors.secondaryText
        subtitleLabel.numberOfLines = 1
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.isHidden = subtitle == nil

        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(subtitleLabel)
        isAccessibilityElement = true
        accessibilityLabel = title
        accessibilityValue = subtitle
        accessibilityTraits = .header
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setIcon(_ image: UIImage) {
        iconView.image = image
        iconView.tintColor = nil
    }

    func setTitle(_ title: String) {
        titleLabel.text = title
        accessibilityLabel = title
        setNeedsLayout()
        superview?.setNeedsLayout()
    }

    func heightThatFits(width: CGFloat, topInset: CGFloat) -> CGFloat {
        self.topInset = topInset
        let titleWidth = max(width - 20 - 30 - 12 - 20, 0)
        let titleHeight = titleLabel.sizeThatFits(
            CGSize(width: titleWidth, height: .greatestFiniteMagnitude)).height
        let subtitleHeight = subtitleLabel.isHidden
            ? 0
            : subtitleLabel.sizeThatFits(
                CGSize(width: titleWidth, height: .greatestFiniteMagnitude)).height
        let textHeight = titleHeight + (subtitleHeight > 0 ? 4 + subtitleHeight : 0)
        return topInset + max(30, textHeight) + 20
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let iconSide: CGFloat = 30
        let contentHeight = max(bounds.height - topInset, 0)
        iconView.frame = CGRect(
            x: 20, y: topInset + (contentHeight - iconSide) / 2,
            width: iconSide, height: iconSide)
        let titleX = iconView.frame.maxX + 12
        let textWidth = max(bounds.width - titleX - 20, 0)
        if subtitleLabel.isHidden {
            titleLabel.frame = CGRect(
                x: titleX, y: topInset + 10,
                width: textWidth, height: max(contentHeight - 20, 0))
            subtitleLabel.frame = .zero
        } else {
            let titleHeight = titleLabel.sizeThatFits(
                CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
            titleLabel.frame = CGRect(
                x: titleX, y: topInset + 10, width: textWidth, height: titleHeight)
            subtitleLabel.frame = CGRect(
                x: titleX, y: titleLabel.frame.maxY + 4,
                width: textWidth,
                height: max(0, bounds.maxY - titleLabel.frame.maxY - 14))
        }
    }

    private static var readerTitleFont: UIFont {
        // Mirrors the article title in ArticleTextRenderer: same typeface,
        // size, and (clamped) accessibility scaling.
        ReaderSettings.font.font(size: 30 * ReaderSettings.effectiveFontScale, weight: .bold)
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
        let background = LunaColors.background.resolvedColor(with: traitCollection)
        gradient.colors = [
            background.withAlphaComponent(0).cgColor,
            background.cgColor,
            background.cgColor,
        ]
    }
}

// MARK: - External open (deep link / notification route)

/// `openExternally(_:)` itself is defined above; this just marks the deck as a
/// root `SceneDelegate` can hand items to without a kind-specific downcast.
extension ArticleCardsViewController: ExternalItemOpening {}

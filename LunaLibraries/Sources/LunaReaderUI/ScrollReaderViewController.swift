//
//  ScrollReaderViewController.swift
//  Luna
//

import LunaAudioPlayback
import LunaReaderEngine
import LunaAppConfig
import LunaDesignSystem
import LunaStorage
import LunaModels
import UIKit

/// Full-screen scrolling text reader. Tapping an inline link splits the article
/// open into the inline glass card (`SplitWebOverlayViewController`); long-press
/// offers save/share. Supports read-aloud with
/// word highlighting + follow-scroll and remembers the scroll position.
public final class ScrollReaderViewController: UIViewController, UITextViewDelegate, ReaderPositionTracking,
    UIContextMenuInteractionDelegate, UIGestureRecognizerDelegate {

    public weak var completionDelegate: ReaderCompletionDelegate?

    /// When set, a tapped inline link (with the exact text range UIKit already resolved
    /// for it) is handed to this closure instead of opening a new inline split overlay —
    /// used by the inline reader to push the link onto its own navigation stack rather
    /// than nesting another overlay. RabbitHole uses the range to avoid rescanning links
    /// on tap.
    public var onLinkActivatedWithRange: ((_ url: URL, _ range: NSRange) -> Void)?

    /// Center of UIKit's resolved link range in this reader's coordinate space.
    /// Wrapped links use the union of their glyph fragments, which is a close and
    /// stable proxy for the touch point exposed by UITextView's primary action.
    public func linkActivationPoint(forCharacterRange range: NSRange) -> CGPoint {
        let glyphRange = textView.layoutManager.glyphRange(
            forCharacterRange: range, actualCharacterRange: nil)
        var rect = textView.layoutManager.boundingRect(
            forGlyphRange: glyphRange, in: textView.textContainer)
        rect.origin.x += textView.textContainerInset.left
        rect.origin.y += textView.textContainerInset.top
        return textView.convert(
            CGPoint(x: rect.midX, y: rect.midY), to: view)
    }

    /// A word index carried in from another reader mode. When set (and this is
    /// the plain scrolling mode), the view scrolls so that word sits 25% from
    /// the top on first appearance instead of restoring the saved offset.
    private var explicitResumeWordIndex: Int?

    /// The content offset captured the moment the reader's initial position is
    /// applied — the baseline for deciding whether the user has since scrolled
    /// far enough to count as a deliberate reposition (vs. just opening/closing).
    private var openContentOffsetY: CGFloat?

    /// The last reading position that "counted" — updated only when a scroll settles
    /// somewhere the reader could have read their way to (see `handleScrollSettled`).
    /// Seeded at open so a mere open/close never moves it. This is what the shared
    /// scroll/RSVP position falls back to when a fast fling to the very start/end must
    /// be ignored (`landedGlanceFling`).
    private var committedWordIndex: Int?
    private var committedOffsetY: CGFloat = 0
    /// True when the most recent scroll settled at the very start/end after a fling
    /// faster than a human could read — a glance, not a reposition. While set, the
    /// reported shared position stays at `committedWordIndex`/`committedOffsetY`.
    /// Cleared by any scroll that counts.
    private var landedGlanceFling = false
    /// Fling speed (points/second) captured from the drag's end velocity, consumed
    /// once when the scroll settles.
    private var pendingFlingSpeedPointsPerSecond: CGFloat = 0

    private var item: ReadingListItem
    private var content: ArticleContent
    private var rendered: RenderedArticle
    private var wordMap: WordMap
    private let includesArticleTitle: Bool
    private var imageDownloadTask: Task<Void, Never>?
    /// Live animation views laid over TextKit's first-frame attachments. TextKit 1
    /// draws attachments as static bitmaps, so a real image view is required for GIF
    /// playback. Views are enabled only while visible to bound decode/CPU cost.
    private var animatedImageViews: [AnimatedArticleImageView] = []
    private let textView = QuotingTextView(usingTextLayoutManager: false)
    private let store = ReadingListStore.shared
    private var finishedReadingTracker = FinishedReadingTracker()
    private let finishedBadge = FinishedReadingBadgeView()
    private var didRestoreScroll = false

    // MARK: - Progressive (two-phase) load

    /// Phase 1 renders only this many leading characters so the first paint is a
    /// near-instant layout of one+ screen of text — the heavy whole-article glyph
    /// generation that stalled behind the entry animation is deferred to Phase 2.
    /// A few hundred characters comfortably fills a screen of serif body text while
    /// keeping the initial `UITextView` layout cheap.
    private static let prefixCharacterBudget = 700

    /// The progressive-load state: `.pending` until Phase 2 is kicked off,
    /// `.inFlight` while it's building, `.done` once the FULL article has been
    /// rendered + swapped in (or never needed because the prefix already
    /// covered the whole article). Until `.done`, `rendered`/`wordMap`
    /// describe only the prefix, so position-dependent features (RSVP/audio
    /// resume, finished-reading tracking) wait for it. Replaces two bools
    /// (`didLoadFullContent`/`didBeginFullContentLoad`) that could disagree —
    /// nothing enforced "began" implies "not yet loaded".
    private enum FullContentLoad {
        case pending
        case inFlight
        case done
    }
    private var fullContentLoad: FullContentLoad = .pending

    #if DEBUG
    /// Test hooks for the progressive load: whether the full content has been
    /// swapped in, and the rendered text length / word count currently shown.
    public var didLoadFullContentForTesting: Bool { fullContentLoad == .done }
    public var renderedTextLengthForTesting: Int { rendered.text.length }
    public var wordCountForTesting: Int { wordMap.wordCount }
    public var animatedImageViewCountForTesting: Int { animatedImageViews.count }
    #endif

    /// Host-controlled guard for embedded previews whose UIKit appearance must
    /// reveal and restore the viewport without starting whole-article Phase 2.
    /// The host explicitly calls `prepareFullContent()` when it promotes the
    /// reader to its primary surface.
    public var defersAutomaticFullContentLoad = false

    /// Read aloud (the shared audio toggle).
    private var audioEnabled: Bool
    private var didStartPlayback = false

    // Read-aloud (audio) playback, present only when audio is enabled.
    private var speech: SpeechController?
    /// Phase 6: resolves the trimmed script the LEGACY `SpeechController`
    /// path speaks (Share/Action extensions only — `ReaderAudioLauncher.center`
    /// is nil there). Created lazily on first extension-path speech start;
    /// nil for the whole lifetime of a main-app reader, where `center` is
    /// always installed and this path never runs.
    private var extensionAudioScriptResolver: ExtensionAudioScriptResolver?
    private let footer = UIVisualEffectView(effect: GlassStyle.barEffect())
    private let footerPlayButton = UIButton(type: .system)
    private let footerRateButton = UIButton(type: .system)
    private var highlightedRange: NSRange?
    private var followPlayback = true

    // MARK: - Highlight & share (text selection)

    /// A long-press adds this recognizer alongside the text view's built-in ones. It
    /// never changes the selection itself; on `.began` it only sets
    /// `expandNextSelectionToSentence` so the *next* selection change snaps to the
    /// enclosing sentence. Kept as a stored reference so the gesture delegate can tell
    /// it apart from the inline-image tap (which shares this delegate).
    private var sentenceLongPress: UILongPressGestureRecognizer?
    /// Link-only hold interaction. Retained because the source view does not retain
    /// the helper that owns its recognizer.
    private var linkPreviewInteraction: LinkRSVPPreviewInteraction?
    private var resumesAudioAfterLinkPreview = false
    /// Set by the long-press on `.began`; the first non-empty selection change that
    /// follows snaps to the enclosing sentence, then clears this so later drag-handle
    /// adjustments are left alone.
    private var expandNextSelectionToSentence = false
    /// Reentrancy guard: setting `textView.selectedRange` inside
    /// `textViewDidChangeSelection` re-enters it, so the snap is bracketed by this.
    private var isExpandingSelection = false

    /// Sharing affordances handed on to any nested reader this one opens; nil in
    /// the share sheet.
    private var shareProvider: ReaderShareProviding?
    /// The custom scroll indicator, kept so its track can be told the extent the
    /// reader actually SHOWS. Left to itself it mirrors the scroll view's content
    /// insets, and this reader's bottom inset is a reserved lane (the completion
    /// area, the read-aloud footer, the safe area) — mirroring it ends the track
    /// well over a hundred points short of the screen.
    private weak var scrollIndicator: HorizonScrollIndicator?
    private var contentSizeObservation: NSKeyValueObservation?
    /// Stable whitespace appended after the final text line. The completion pill
    /// lives inside this lane instead of being positioned from `contentSize`,
    /// which also changes when the scroll view's bottom inset changes.
    private static let completionAreaHeight: CGFloat = 88

    // Matches the RSVP reader's liquid-glass focus accent (an inline text
    // highlight, since a glass overlay would sit in front of and blur the very
    // words being read).
    private let highlightColor = GlassStyle.readingAccent.withAlphaComponent(0.28)

    /// Reserved by a screen-level reader header. Keeping this on the scroll
    /// view (instead of moving its frame) lets text travel beneath a backdrop
    /// blur while preserving a clear resting position below the controls.
    public var topChromeInset: CGFloat = 0 {
        didSet {
            guard ChromeInsetDebounce.changed(from: oldValue, to: topChromeInset) else { return }
            applyTopChromeInset(preservingVisiblePosition: isViewLoaded)
        }
    }

    public init(item: ReadingListItem, content: ArticleContent,
         audioEnabled: Bool = false,
         shareProvider: ReaderShareProviding? = nil,
         resumeWordIndex: Int? = nil,
         includesArticleTitle: Bool = true) {
        self.item = item
        // Bake in any images already cached on disk (keyed by URL hash) BEFORE the
        // first render, so they appear in the same frame as the text instead of
        // popping in later via the async downloader. Cheap (hash + fileExists); only
        // genuinely-uncached images fall through to `fetchMissingImagesIfNeeded`.
        let resolved = ArticleImageDownloader.resolveLocalImages(content, store: ReadingListStore.shared)
        self.content = resolved
        self.audioEnabled = audioEnabled
        self.shareProvider = shareProvider
        self.explicitResumeWordIndex = resumeWordIndex
        self.includesArticleTitle = includesArticleTitle
        // Phase 1: render only a leading prefix so the FIRST layout of the text view
        // is cheap (a couple hundred characters), removing the whole-article glyph
        // pass that stalled the first open behind the entry animation. Local images
        // inside that prefix are rendered immediately because they are part of the
        // first visible page and must be present in RabbitHole transition snapshots.
        // The rest of the article renders + swaps in by `prepareFullContent()` after
        // that animation.
        //
        // EXCEPTIONS where the prefix is useless, so render the whole article up front:
        //  • read-aloud (audio) — speech needs every word immediately and reads from the
        //    top, and there's no first-paint stall to hide behind an entry animation;
        //  • restoring a saved/carried position beyond the prefix (resuming a part-read
        //    article, or a position carried in from another mode) — the prefix can't show
        //    that region, and that open already hides the text until the position lands.
        // The progressive path is for the common FROM-THE-TOP, no-audio fresh open.
        let needsFullUpFront = audioEnabled || Self.openPositionLikelyBeyondPrefix(
            item: item, resumeWordIndex: resumeWordIndex, audioEnabled: audioEnabled,
            content: resolved, budget: Self.prefixCharacterBudget)
        let rendered = needsFullUpFront
            ? ArticleTextRenderer.render(resolved, includesTitle: includesArticleTitle)
            : ArticleTextRenderer.render(
                resolved, characterBudget: Self.prefixCharacterBudget,
                includesTitle: includesArticleTitle)
        self.rendered = rendered
        self.wordMap = WordMap(content: resolved, rendered: rendered)
        super.init(nibName: nil, bundle: nil)
        // If the prefix already covers the whole (short) article there's nothing to
        // swap — Phase 2 is skipped.
        if rendered.isComplete { fullContentLoad = .done }
    }

    /// Reuses an already-built scroll reader shell with new article content. RabbitHole
    /// calls this on a pre-added child so link activation does not pay the child-VC,
    /// TextKit view, gesture, footer, and constraint setup cost.
    /// - Parameter fullRenderUpFront: render the WHOLE article immediately instead
    ///   of the Phase-1 prefix + deferred Phase-2 swap, for hosts that cannot
    ///   tolerate progressive rendering.
    public func configureForReuse(
        item: ReadingListItem,
        content: ArticleContent,
        audioEnabled: Bool = false,
        shareProvider: ReaderShareProviding? = nil,
        resumeWordIndex: Int? = nil,
        fullRenderUpFront: Bool = false
    ) {
        resetTransientState()
        applyContent(
            item: item, content: content, audioEnabled: audioEnabled,
            shareProvider: shareProvider, resumeWordIndex: resumeWordIndex,
            fullRenderUpFront: fullRenderUpFront)
    }

    /// Cancels in-flight work and clears every per-session flag before a reuse
    /// swaps in new content — the part of `configureForReuse` that's about
    /// tearing down the OLD state, independent of what the new content is.
    private func resetTransientState() {
        imageDownloadTask?.cancel()
        removeAnimatedImageViews()
        speech?.stop()
        speech = nil
        removeHighlight()

        finishedReadingTracker = FinishedReadingTracker()
        didRestoreScroll = false
        fullContentLoad = .pending
        didStartPlayback = false
        // An unconsumed jump must never survive into the next article.
        pendingAnchorBlockIndex = nil
        openContentOffsetY = nil
        committedWordIndex = nil
        committedOffsetY = 0
        landedGlanceFling = false
        pendingFlingSpeedPointsPerSecond = 0
        finishedBadge.resetForReuse()
        highlightedRange = nil
        followPlayback = true
    }

    /// Resolves + renders `content`, decides the progressive-load strategy, and —
    /// once the view exists — installs it into the text view and its dependent
    /// features.
    private func applyContent(
        item: ReadingListItem,
        content: ArticleContent,
        audioEnabled: Bool,
        shareProvider: ReaderShareProviding?,
        resumeWordIndex: Int?,
        fullRenderUpFront: Bool
    ) {
        let resolved = ArticleImageDownloader.resolveLocalImages(content, store: ReadingListStore.shared)
        self.item = item
        self.content = resolved
        self.audioEnabled = audioEnabled
        self.shareProvider = shareProvider
        self.explicitResumeWordIndex = resumeWordIndex

        let needsFullUpFront = fullRenderUpFront || audioEnabled
            || Self.openPositionLikelyBeyondPrefix(
                item: item, resumeWordIndex: resumeWordIndex, audioEnabled: audioEnabled,
                content: resolved, budget: Self.prefixCharacterBudget)
        let rendered = needsFullUpFront
            ? ArticleTextRenderer.render(resolved, includesTitle: includesArticleTitle)
            : ArticleTextRenderer.render(
                resolved, characterBudget: Self.prefixCharacterBudget,
                includesTitle: includesArticleTitle)
        self.rendered = rendered
        self.wordMap = WordMap(content: resolved, rendered: rendered)
        if rendered.isComplete { fullContentLoad = .done }

        guard isViewLoaded else { return }
        UIView.performWithoutAnimation {
            textView.attributedText = rendered.text
            textView.layoutIfNeeded()
            textView.layoutManager.ensureLayout(for: textView.textContainer)
            if textView.bounds.width > 0 {
                applyInitialScrollPosition()
                didRestoreScroll = true
            } else {
                textView.contentOffset = .zero
            }
            textView.alpha = 1
            footer.isHidden = true
        }
        installAnimatedImageViews()
        if fullContentLoad == .done {
            fetchMissingImagesIfNeeded()
            installPositionDependentFeatures()
        }
        view.setNeedsLayout()
    }

    /// Whether this open will restore a position that the cheap PREFIX render almost
    /// certainly wouldn't contain — in which case the prefix is useless and we render
    /// the full article up front. Conservative on purpose: it only suppresses the
    /// progressive path for a genuine resume, never for the common top-of-article open.
    private static func openPositionLikelyBeyondPrefix(
        item: ReadingListItem, resumeWordIndex: Int?, audioEnabled: Bool,
        content: ArticleContent, budget: Int) -> Bool {
        // A non-trivial saved scroll offset (more than a screen down) resumes below
        // the prefix. A tiny offset (near the top) is fine to show against the prefix.
        if item.readState != .read,
           let saved = item.lastScrollOffset, saved > CGFloat(UIScreen.main.bounds.height) {
            return true
        }
        // The word we'll actually resume from on open: a carried-in mode-switch index
        // wins; otherwise the shared persisted word, but only when there's no exact
        // offset to restore from instead (the hybrid rule in `applyInitialScrollPosition`).
        let resumeWord: Int?
        if audioEnabled {
            resumeWord = nil
        } else if let carried = resumeWordIndex {
            resumeWord = carried
        } else if item.readState != .read, item.lastScrollOffset == nil {
            resumeWord = item.lastWordIndex
        } else {
            resumeWord = nil
        }
        if let resumeWord, resumeWord > 0 {
            // Rough word-budget: count words in the leading blocks up to the
            // character budget; a resume index past that won't be in the prefix.
            var chars = 0
            var words = 0
            for block in content.blocks {
                if chars > budget { break }
                if block.kind == .image { continue }
                words += block.text.split(whereSeparator: { $0.isWhitespace }).count
                chars += block.text.count
            }
            if resumeWord >= words { return true }
        }
        return false
    }

    /// The word currently being read, carried to other modes on a switch.
    ///
    /// During active playback this is the read-aloud position. In plain
    /// scroll, when a position was carried IN from another mode
    /// (`explicitResumeWordIndex`), it must NOT drift just from opening/closing:
    /// it only moves off that carried index when the user scrolled past a
    /// threshold (→ first fully-visible word). Otherwise it returns the carried
    /// index unchanged — a no-op. See `ReaderResumePositionResolver`.
    ///
    /// On a FRESH open (no carried index — e.g. straight from the reading list)
    /// there's no position to protect, so the first switch resumes from where
    /// the reader actually is: the first fully-visible word.
    public var currentReadingWordIndex: Int? {
        if let speech, let word = speech.currentWordIndex { return word }

        // A fast fling to the very start/end is a glance, not a reposition: keep the
        // last position that counted rather than reporting the edge.
        if landedGlanceFling { return committedWordIndex }

        guard let resumeIndex = explicitResumeWordIndex else {
            return firstFullyVisibleWordIndex()
        }

        let scrolled: Bool
        if let openContentOffsetY {
            scrolled = ReaderResumePositionResolver.scrolledPastThreshold(
                openOffsetY: openContentOffsetY, currentOffsetY: textView.contentOffset.y)
        } else {
            scrolled = false
        }
        return ReaderResumePositionResolver.reportedWordIndex(
            resumeIndex: resumeIndex,
            scrolledPastThreshold: scrolled,
            firstFullyVisibleIndex: firstFullyVisibleWordIndex())
    }

    /// The content offset paired with `currentReadingWordIndex` — pixel-exact after
    /// the title region, but normalized to zero within it so a reopen never clips
    /// the card's in-content title. Falls back to the committed offset while a
    /// glance fling is being ignored.
    public var currentReadingScrollOffsetY: CGFloat {
        let offset = landedGlanceFling ? committedOffsetY : textView.contentOffset.y
        return CGFloat(ReaderScrollPosition.normalizedForPersistence(
            Double(offset), titleHeaderHeight: Double(topChromeInset)))
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        imageDownloadTask?.cancel()
        removeAnimatedImageViews()
        speech?.stop()
        extensionAudioScriptResolver?.cancelInFlightRefinement()
        contentSizeObservation?.invalidate()
    }

    /// The bottom of TextKit's laid-out article, independent of the scroll view's
    /// content inset and any footer subviews. Unlike `contentSize.height`, this
    /// remains stable while the bottom footer geometry is being updated.
    private var articleContentBottom: CGFloat {
        textView.layoutManager.ensureLayout(for: textView.textContainer)
        let usedRect = textView.layoutManager.usedRect(for: textView.textContainer)
        return ceil(
            usedRect.maxY
                + textView.textContainerInset.top
                + textView.textContainerInset.bottom)
    }

    /// Positions the completion acknowledgement in a fixed-height lane below the
    /// text and reserves room for it.
    private func layoutCompletionArea() {
        updateScrollIndicatorTrack()
        let width = textView.bounds.width
        guard width > 0 else { return }
        finishedBadge.frame = CGRect(
            x: 0, y: articleContentBottom,
            width: width, height: Self.completionAreaHeight)
        let footerSpace = footer.isHidden ? 0 : footer.bounds.height
        // Add the bottom safe area so the last lines clear the home indicator
        // instead of sitting under it.
        let bottomInset = Self.completionAreaHeight + footerSpace
            + view.safeAreaInsets.bottom + 16
        // Avoid feeding identical inset writes back through UITextView's
        // content-size observation while the user is resting at the bottom.
        if abs(textView.contentInset.bottom - bottomInset) > 0.5 {
            textView.contentInset.bottom = bottomInset
        }
    }

    /// The track the scroll indicator runs on: from just below whatever chrome
    /// insets the top (an extension's navigation bar, a card's floating header)
    /// down to the top of the bottom safe area — plus the read-aloud footer while
    /// it is up, which is the one piece of bottom chrome the indicator would
    /// otherwise run behind. Told explicitly, because the indicator's own default
    /// is to mirror the scroll view's content insets and the bottom one here
    /// reserves the completion lane as well.
    private func updateScrollIndicatorTrack() {
        guard let scrollIndicator, scrollIndicator.superview != nil else { return }
        let footerSpace = footer.isHidden ? 0 : footer.bounds.height
        let insets = UIEdgeInsets(
            top: textView.adjustedContentInset.top, left: 0,
            bottom: view.safeAreaInsets.bottom + footerSpace, right: 0)
        if let current = scrollIndicator.trackInsets, current == insets { return }
        scrollIndicator.trackInsets = insets
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LunaColors.background
        configureTextView()
        installFinishedBadge()
        configureGestures()
        configureFooter()

        // In-app (seam installed) the center drives read-aloud: subscribe to its
        // word events for highlighting — applied only while the DISPLAYED article
        // is the playing one (see the AudioPlaybackObserver conformance below).
        // Observers are weakly held, so no teardown is needed.
        ReaderAudioLauncher.center?.addObserver(self)

        revealInitialContent()
    }

    /// Constructed with TextKit 1 so line metrics stay stable across scroll
    /// restoration and link hit-testing.
    private func configureTextView() {
        textView.isEditable = false
        textView.isSelectable = true
        textView.delegate = self
        // Copy carries the same quote-plus-URL payload the selection menu shares.
        textView.copySelectionAsQuote = { [weak self] range in
            self?.copyHighlightedText(in: range) ?? false
        }
        textView.attributedText = rendered.text
        textView.textContainerInset = UIEdgeInsets(top: 20, left: 20, bottom: 40, right: 20)
        textView.linkTextAttributes = [
            .foregroundColor: UIColor.systemBlue,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        textView.alwaysBounceVertical = true
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.topAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        scrollIndicator = HorizonScrollIndicator.install(on: textView, in: view)
        applyTopChromeInset(preservingVisiblePosition: false)
        installAnimatedImageViews()
    }

    private func installFinishedBadge() {
        textView.addSubview(finishedBadge)
        contentSizeObservation = textView.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
            self?.layoutCompletionArea()
        }
    }

    private func configureGestures() {
        let imageTap = UITapGestureRecognizer(target: self, action: #selector(imageTapped(_:)))
        imageTap.delegate = self
        imageTap.cancelsTouchesInView = false
        textView.addGestureRecognizer(imageTap)
        textView.addInteraction(UIContextMenuInteraction(delegate: self))

        // Long-press to select text snaps to the whole enclosing SENTENCE (the built-in
        // long-press selects only a word). This recognizer is non-fighting: it runs
        // simultaneously with the text view's own recognizers and never touches the
        // selection — it just flags the next selection change to expand (see
        // `handleSentenceLongPress` / `textViewDidChangeSelection`).
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleSentenceLongPress(_:)))
        longPress.delegate = self
        longPress.cancelsTouchesInView = false
        textView.addGestureRecognizer(longPress)
        sentenceLongPress = longPress

        linkPreviewInteraction = LinkRSVPPreviewInteraction(
            host: self,
            sourceView: textView,
            resolveURL: { [weak self] point in self?.previewableLinkURL(at: point) },
            sourcePlaybackChanged: { [weak self] active in self?.setLinkPreviewAudioSuspended(active) })
    }

    /// Installs the features that depend on the full article already being
    /// rendered, and reveals the text once its resting scroll position is set.
    private func revealInitialContent() {
        // Images cached on disk are baked into the prefix already; only genuinely
        // uncached ones (action/share surface) fall through here. Once the full
        // content lands this re-runs against it (see `prepareFullContent`).
        if fullContentLoad == .done { fetchMissingImagesIfNeeded() }

        addSimulatorSplitHooksIfNeeded()

        // The resume highlight needs the FULL word map (a deep resume word isn't
        // in the prefix), so install it only once the full content has landed. For
        // an already-complete prefix that's now.
        if fullContentLoad == .done { installPositionDependentFeatures() }

        // Hide the text until the saved scroll position is applied, so the
        // article never flashes at the top and then jumps. Fresh articles (no
        // saved position) start at the top and stay visible.
        if hasInitialScrollPosition { textView.alpha = 0 }
    }

    private func applyTopChromeInset(preservingVisiblePosition: Bool) {
        guard isViewLoaded else { return }
        let delta = topChromeInset - textView.contentInset.top
        textView.contentInset.top = topChromeInset
        textView.verticalScrollIndicatorInsets.top = topChromeInset
        if preservingVisiblePosition, abs(delta) > 0.5 {
            textView.contentOffset.y -= delta
        }
        updateScrollIndicatorTrack()
    }

    /// Whether there's a saved/carried position to restore before revealing.
    private var hasInitialScrollPosition: Bool {
        if let resume = explicitResumeWordIndex, !audioEnabled,
           wordMap.attributedRange(forWord: resume) != nil { return true }
        // A finished article's persisted position is normally the footer/end.
        // Until read cards get their own UI, present them like ordinary cards
        // from the top so their first viewport is never an empty trailing tail.
        guard item.readState != .read else { return false }
        if item.lastScrollOffset != nil { return true }
        if let word = item.lastWordIndex,
           wordMap.attributedRange(forWord: word) != nil { return true }
        return false
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Keep the text in a readable column on wide screens (iPad / landscape).
        let horizontal = max(20, (view.bounds.width - LunaLayout.readableWidth) / 2)
        if abs(textView.textContainerInset.left - horizontal) > 0.5 {
            textView.textContainerInset = UIEdgeInsets(
                top: 20, left: horizontal, bottom: 40, right: horizontal)
        }
        layoutCompletionArea()
        layoutAnimatedImageViews()

        // Restore the scroll position as soon as we have real bounds — BEFORE
        // the view is on screen — then reveal, so there's no top-flash + jump.
        if !didRestoreScroll, textView.bounds.width > 0 {
            didRestoreScroll = true
            applyInitialScrollPosition()
            revealContent()
        }
    }

    // MARK: - Progressive (two-phase) load

    /// Phase 2. Renders the FULL article and swaps it in for the prefix, SEAMLESSLY
    /// and preserving scroll position. Call once the entry animation has finished
    /// (the host wires this to its open-animation completion); the reader also calls
    /// it itself once it appears, so it works regardless of host. Idempotent and a
    /// no-op when the prefix already covered the whole article.
    ///
    /// Phase 2 runs AFTER the entry animation, so the article's heavy whole-text glyph
    /// generation runs off the entry animation's critical path. The attributed-string
    /// build + the forced layout both run on the main actor (the renderer touches
    /// `UIScreen`/`UIFont`, and TextKit layout must be on main anyway) — it's the TIMING,
    /// not threading, that keeps the open from stalling. Because the prefix is a
    /// STRICT prefix of the full text, the top/visible layout is identical, so restoring
    /// the captured `contentOffset` across the swap is invisible.
    public func prepareFullContent() {
        guard fullContentLoad == .pending else { return }
        fullContentLoad = .inFlight
        // Defer one runloop so a host that calls this from inside its open-animation
        // completion doesn't pay the build cost in the same commit as that completion.
        DispatchQueue.main.async { [weak self] in
            // `[weak self]` drops this if the VC deallocated. Require the view loaded
            // (it always is by the time Phase 2 is triggered) before touching it.
            guard let self, self.isViewLoaded, self.fullContentLoad != .done else { return }
            let full = ArticleTextRenderer.render(
                self.content, includesTitle: self.includesArticleTitle)
            self.applyFullContent(full)
        }
    }

    /// Swaps the freshly-built full render into the text view, preserving the reader's
    /// scroll position. Runs on the main actor.
    @MainActor
    private func applyFullContent(_ full: RenderedArticle) {
        guard fullContentLoad != .done else { return }
        // The user might have scrolled within the prefix while it was the only thing
        // laid out. Capture where they are so the swap is seamless.
        let offset = textView.contentOffset
        // First-fully-visible word BEFORE the swap, as a fallback anchor for the rare
        // case the captured offset can't be trusted (see below).
        let anchorWord = firstFullyVisibleWordIndex()

        rendered = full
        wordMap = WordMap(content: content, rendered: full)

        // Replacing attributed text can publish a transient clamped offset
        // before the captured position is restored below. Keep external scroll
        // chrome quiet until this synchronous geometry transaction settles.
        ScrollPresentationState.setSuppressed(true, for: textView)
        defer { ScrollPresentationState.setSuppressed(false, for: textView) }
        UIView.performWithoutAnimation {
            textView.attributedText = full.text
            textView.layoutManager.ensureLayout(for: textView.textContainer)
            textView.layoutIfNeeded()
            // The prefix is a strict prefix, so the leading layout is identical and the
            // captured offset still points at the same line — restore it directly.
            // (Clamp so it can't exceed the — now larger — scrollable range.)
            textView.contentOffset.y = clampedContentOffsetY(offset.y)
            // Safety net: if the offset somehow landed past the old prefix's end (e.g.
            // the user reached the bottom of the short prefix), re-anchor to the
            // first-visible word's position in the full text so nothing jumps.
            if let anchorWord, offset.y > 0,
               let range = wordMap.attributedRange(forWord: anchorWord) {
                let glyphRange = textView.layoutManager.glyphRange(
                    forCharacterRange: range, actualCharacterRange: nil)
                var rect = textView.layoutManager.boundingRect(
                    forGlyphRange: glyphRange, in: textView.textContainer)
                rect.origin.y += textView.textContainerInset.top
                // Only re-anchor if the direct restore is clearly off (the visible word
                // moved by more than a line) — otherwise the direct restore is exact.
                if abs(rect.minY - offset.y) > textView.bounds.height {
                    textView.contentOffset.y = clampedContentOffsetY(rect.minY)
                }
            }
        }
        installAnimatedImageViews()

        fullContentLoad = .done
        // A jump tapped while only the prefix was laid out: its destination exists
        // now, so honour it in place of the offset restored just above.
        if let blockIndex = pendingAnchorBlockIndex {
            pendingAnchorBlockIndex = nil
            scrollToBlock(blockIndex)
        }
        // Now that the full word map exists, wire up the position-dependent features
        // and finish the inline-image fetch against the real content.
        installPositionDependentFeatures()
        layoutCompletionArea()
        fetchMissingImagesIfNeeded()
        checkFinishedReading()
    }

    /// Installs the read-aloud resume highlight, which needs the FULL word map (a
    /// deep resume word isn't in the prefix). Called once the full content is in
    /// place.
    private func installPositionDependentFeatures() {
        if let spokenIndex = item.lastSpokenWordIndex,
           let range = wordMap.attributedRange(forWord: spokenIndex) {
            applyHighlight(range)
        }
    }

    // MARK: - Inline images

    /// The main ingestor normally downloads every extracted image before the reader
    /// opens. The action/share surface can present a reader immediately after parsing,
    /// though, so finish that same local-cache step here and redraw once it lands.
    private func fetchMissingImagesIfNeeded() {
        guard content.blocks.contains(where: { $0.kind == .image && $0.imageFileName == nil }) else { return }
        guard let refererURL = item.url ?? URL(string: item.urlString) else {
            SharedDiagnosticLog.record("reader: skipped inline image download without a valid source URL", category: "images")
            return
        }
        let source = content
        imageDownloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let updated = await ArticleImageDownloader.download(
                source, itemID: self.item.id, store: self.store,
                refererURL: refererURL)
            guard !Task.isCancelled,
                  updated.blocks.contains(where: { $0.imageFileName != nil }),
                  updated != self.content
            else { return }
            self.content = updated
            self.rendered = ArticleTextRenderer.render(
                updated, includesTitle: self.includesArticleTitle)
            self.wordMap = WordMap(content: updated, rendered: self.rendered)
            let offset = self.textView.contentOffset
            self.textView.attributedText = self.rendered.text
            self.textView.setContentOffset(offset, animated: false)
            self.textView.layoutManager.ensureLayout(for: self.textView.textContainer)
            self.textView.layoutIfNeeded()
            self.installAnimatedImageViews()
            self.layoutCompletionArea()
            self.checkFinishedReading()
            SharedDiagnosticLog.record("reader: refreshed inline image attachments", category: "images")
        }
    }

    /// Hit-tests `point` against the rendered image ranges — glyph geometry only, no
    /// disk decode. Used by `shouldReceive`, which runs on every touch during
    /// scrolling, so it must stay cheap; the actual image bytes are only decoded once
    /// a tap is confirmed (`image(at:)`).
    private func imageEntry(at point: CGPoint) -> (entry: (range: NSRange, fileURL: URL), rect: CGRect)? {
        // `point` is in the text view's (content) coordinate space — a scroll view's
        // bounds.origin already IS its contentOffset, so it must NOT be added again.
        // Only the text container inset separates content space from layoutManager
        // (glyph) space. (Adding contentOffset here was the bug that made scrolled
        // taps land a full page-offset too low.)
        let containerPoint = CGPoint(
            x: point.x - textView.textContainerInset.left,
            y: point.y - textView.textContainerInset.top)
        let index = textView.layoutManager.characterIndex(
            for: containerPoint, in: textView.textContainer, fractionOfDistanceBetweenInsertionPoints: nil)
        guard let entry = rendered.imageRanges.first(where: { NSLocationInRange(index, $0.range) })
        else { return nil }
        let glyphRect = textView.layoutManager.boundingRect(forGlyphRange: entry.range, in: textView.textContainer)
        // `characterIndex(for:)` snaps to the NEAREST glyph, so a tap on a link near an
        // image can map to the image's character. Require the tap to land INSIDE the
        // image's glyph rect, so link/text taps fall through to UITextView's link
        // handling instead of opening the image fullscreen.
        guard glyphRect.contains(containerPoint) else { return nil }
        // Glyph rect → content space (add the inset back); textView.convert handles
        // the scroll offset into view space.
        let contentRect = glyphRect.offsetBy(
            dx: textView.textContainerInset.left, dy: textView.textContainerInset.top)
        return (entry, textView.convert(contentRect, to: view))
    }

    /// Rebuilds the live overlays after any attributed-string swap. The static first
    /// frame remains in the attachment underneath, so layout, snapshots, printing,
    /// and animation startup all have a stable fallback.
    private func installAnimatedImageViews() {
        removeAnimatedImageViews()
        guard isViewLoaded else { return }
        for entry in rendered.imageRanges where AnimatedArticleImageView.canAnimate(entry.fileURL) {
            let imageView = AnimatedArticleImageView(
                fileURL: entry.fileURL, attachmentRange: entry.range)
            textView.addSubview(imageView)
            animatedImageViews.append(imageView)
        }
        layoutAnimatedImageViews()
    }

    private func removeAnimatedImageViews() {
        for imageView in animatedImageViews {
            imageView.setPlaybackEnabled(false)
            imageView.removeFromSuperview()
        }
        animatedImageViews.removeAll()
    }

    private func layoutAnimatedImageViews() {
        guard !animatedImageViews.isEmpty, textView.textStorage.length > 0 else { return }
        textView.layoutManager.ensureLayout(for: textView.textContainer)
        for imageView in animatedImageViews {
            let glyphRange = textView.layoutManager.glyphRange(
                forCharacterRange: imageView.attachmentRange, actualCharacterRange: nil)
            let glyphRect = textView.layoutManager.boundingRect(
                forGlyphRange: glyphRange, in: textView.textContainer)
            imageView.frame = glyphRect.offsetBy(
                dx: textView.textContainerInset.left,
                dy: textView.textContainerInset.top)
        }
        updateAnimatedImagePlayback()
    }

    private func updateAnimatedImagePlayback() {
        guard !animatedImageViews.isEmpty else { return }
        // `bounds` is in the text view's content coordinate system and already
        // includes its contentOffset. A small margin starts the next animation just
        // before it scrolls on screen without running the rest of the article.
        let playbackRect = textView.bounds.insetBy(dx: 0, dy: -160)
        let shouldPlay = viewIfLoaded?.window != nil
        for imageView in animatedImageViews {
            imageView.setPlaybackEnabled(shouldPlay && imageView.frame.intersects(playbackRect))
        }
    }

    /// Full hit-test + decode. Full resolution (not the reader's downsampled inline
    /// attachment) is intentional here — the lightbox is a zoom-to-inspect view — so
    /// this must only run for an actual tap/long-press, never per-touch.
    private func image(at point: CGPoint) -> (image: UIImage, frame: CGRect)? {
        guard let hit = imageEntry(at: point),
              let image = UIImage(contentsOfFile: hit.entry.fileURL.path)
        else { return nil }
        return (image, hit.rect)
    }

    @objc private func imageTapped(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended,
              let hit = image(at: gesture.location(in: textView)) else { return }
        let hitFrameOrigin = view.convert(hit.frame.origin, to: nil)
        let lightbox = ImageLightboxViewController(
            image: hit.image,
            sourceFrame:CGRect(origin: hitFrameOrigin, size: hit.frame.size)
        )
        present(lightbox, animated: false)
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // The sentence long-press listens everywhere in the text (it only sets a flag).
        // The inline-image tap keeps its existing restriction: fire only on an image so
        // link/text taps fall through to UITextView's own handling. This runs on every
        // touch during scrolling, so it hit-tests glyph geometry only — no disk decode
        // (see `imageEntry(at:)`).
        if gestureRecognizer === sentenceLongPress {
            // A link hold belongs to the miniature RSVP interaction, not sentence
            // selection. Plain-text holds retain the existing sentence expansion.
            return link(at: touch.location(in: textView)) == nil
        }
        return imageEntry(at: touch.location(in: textView)) != nil
    }

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // Only relax for the sentence long-press so it doesn't fight the text view's
        // built-in selection recognizers. Every other pairing keeps UIKit's defaults,
        // so link/image handling is unchanged.
        gestureRecognizer === sentenceLongPress || otherGestureRecognizer === sentenceLongPress
    }

    @objc private func handleSentenceLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        // Usually this fires BEFORE the text view has selected anything, so all we
        // do is arm the next selection change (never touching the selection here —
        // the text view's own long-press drives it).
        //
        // But the two recognizers' order is not guaranteed: inside a carousel card
        // the deck's own context-menu interaction competes for the same press and
        // this one can arrive AFTER the word is already selected, leaving the flag
        // waiting for a change that has been and gone — which is why the snap was
        // reliable in a full-screen reader and a coin-flip on a card. When the word
        // under the finger is already selected, expand it right here instead.
        switch Self.sentenceLongPressAction(
            caret: characterIndex(at: gesture.location(in: textView)),
            selection: textView.selectedRange)
        {
        case .expandNow(let caret):
            expandNextSelectionToSentence = !expandSelectionToSentence(around: caret)
        case .armNextSelectionChange:
            expandNextSelectionToSentence = true
        }
    }

    /// What a sentence long-press does at the instant it fires. Pure + static so the
    /// recognizer-ordering rule is unit-testable without a real press.
    public enum SentenceLongPressAction: Equatable {
        /// The word under the finger is already selected — snap it to its sentence now.
        case expandNow(caret: Int)
        /// Nothing selected here yet; the next selection change is the one to snap.
        case armNextSelectionChange
    }

    /// `caret` is the character index under the finger (nil for empty text);
    /// `selection` is the live selection. A non-empty selection that CONTAINS the
    /// caret is this press's own word-select, so it can be expanded immediately; a
    /// selection somewhere else in the article is stale and must not be touched.
    /// The end boundary counts — a press on a word's trailing half resolves to the
    /// position after its last glyph.
    public static func sentenceLongPressAction(
        caret: Int?, selection: NSRange
    ) -> SentenceLongPressAction {
        guard let caret, selection.length > 0,
              NSLocationInRange(caret, selection) || caret == NSMaxRange(selection)
        else { return .armNextSelectionChange }
        return .expandNow(caret: caret)
    }

    /// The character index under a point in the text view, or nil for empty text.
    /// `closestPosition(to:)` snaps to the nearest glyph, which is what a press
    /// just past the end of a word should resolve to.
    private func characterIndex(at point: CGPoint) -> Int? {
        guard textView.attributedText.length > 0,
              let position = textView.closestPosition(to: point)
        else { return nil }
        return textView.offset(from: textView.beginningOfDocument, to: position)
    }

    /// Snaps the selection to the sentence around `caret`. False when no sentence
    /// resolves, which leaves the selection exactly as it was.
    private func expandSelectionToSentence(around caret: Int) -> Bool {
        guard let sentence = Self.enclosingSentenceRange(in: textView.text, caret: caret)
        else { return false }
        isExpandingSelection = true
        textView.selectedRange = sentence
        isExpandingSelection = false
        return true
    }

    public func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let hit = image(at: location) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: [
                UIAction(title: L10n.string("Reader_lightbox_copyImageTitle"), image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.image = hit.image
                },
                UIAction(title: L10n.string("Reader_lightbox_saveImageTitle"), image: UIImage(systemName: "square.and.arrow.down")) { _ in
                    UIImageWriteToSavedPhotosAlbum(hit.image, nil, nil, nil)
                },
            ])
        }
    }

    private func applyInitialScrollPosition() {
        // Restore the reading position under the hybrid shared-position rule:
        //  • a word carried in from another mode this session wins outright (25% down);
        //  • else, when the scroll reader still owns the position, its exact pixels
        //    (`lastScrollOffset`) restore precisely;
        //  • else the RSVP reader last moved the shared position (it cleared the exact
        //    offset), so resume from the shared word (`lastWordIndex`) at 25% down.
        // Audio mode starts playback at the carried word and follow-scroll centers it.
        if let resume = explicitResumeWordIndex, !audioEnabled,
           wordMap.attributedRange(forWord: resume) != nil {
            scrollWord(resume, toFractionFromTop: 0.25)
        } else if item.readState != .read, let saved = item.lastScrollOffset {
            let restored = ReaderScrollPosition.contentOffsetForRestoration(
                saved, adjustedTopInset: Double(textView.adjustedContentInset.top))
            restoreScroll(to: CGFloat(restored))
        } else if item.readState != .read, let word = item.lastWordIndex,
                  wordMap.attributedRange(forWord: word) != nil {
            scrollWord(word, toFractionFromTop: 0.25)
        } else {
            // Nothing to restore, so rest at the VISUAL top — which is
            // `-adjustedContentInset.top`, not zero, whenever chrome insets the
            // content (an extension's navigation bar, a card's floating header).
            // Leaving UIKit's zero there opens the article already scrolled, with
            // its title tucked up underneath that chrome.
            textView.contentOffset.y = -textView.adjustedContentInset.top
        }
        // Baseline for "has the user scrolled since opening?" (the carried
        // position must survive a plain open/close untouched).
        openContentOffsetY = textView.contentOffset.y
        // Seed the committed reading position so a mere open/close — or a glance fling
        // before any real scroll — never moves the shared position off where we opened.
        committedWordIndex = explicitResumeWordIndex ?? firstFullyVisibleWordIndex()
        committedOffsetY = textView.contentOffset.y
        landedGlanceFling = false
    }

    private func revealContent() {
        guard textView.alpha < 1 else { return }
        UIView.animate(withDuration: 0.15) { self.textView.alpha = 1 }
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        activateVisibleReader(
            deferFullContentUntilHostCompletion: defersAutomaticFullContentLoad)
    }

    /// Called by hosts that keep this reader pre-added while hidden, then reveal it
    /// later without another UIKit appearance callback.
    public func activateVisibleReader(deferFullContentUntilHostCompletion: Bool = false) {
        // Fallback if layout hasn't run yet (shouldn't normally happen).
        if !didRestoreScroll {
            didRestoreScroll = true
            applyInitialScrollPosition()
        }
        revealContent()
        // An article that fits on one screen can never scroll — seeing it at
        // all means it's been read.
        checkFinishedReading()

        // Phase 2 of the progressive load: render the FULL article and swap it in,
        // AFTER the entry animation, so its heavy glyph generation never stalls the
        // open. Run it alongside the (push) transition's completion when there is one;
        // otherwise (no coordinator — e.g. presented without animation, or already
        // settled) kick it off on the next runloop. Hosts that drive a custom entry
        // animation (the inline split overlay, the RabbitHole stacked wipe) also call
        // `prepareFullContent()` from THEIR completion — `prepareFullContent` is
        // idempotent, so whichever fires first wins.
        if !deferFullContentUntilHostCompletion, fullContentLoad != .done {
            if let coordinator = transitionCoordinator {
                coordinator.animate(alongsideTransition: nil) { [weak self] _ in
                    self?.prepareFullContent()
                }
            } else {
                DispatchQueue.main.async { [weak self] in self?.prepareFullContent() }
            }
        }

        // Start playback once: read-aloud when audio is on; plain scroll
        // otherwise.
        if !didStartPlayback {
            didStartPlayback = true
            if audioEnabled {
                startSpeech()
            }
        }
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Progress is only meaningful against the FULL layout: during the
        // Phase-1 prefix render the content is ~one screen tall, so the ratio
        // would read ~100% and permanently mark a barely-opened article as
        // finished (same guard as checkFinishedReading). One batched write —
        // this runs on the main thread during dismissal.
        var progress: Double?
        if fullContentLoad == .done, textView.contentSize.height > 0 {
            let visibleBottom = textView.contentOffset.y + textView.bounds.height
            progress = Double(visibleBottom / textView.contentSize.height)
        }
        // Persist the SHARED reading position (word + exact pixels together, so a pure
        // scroll reopen restores precisely and a switch to RSVP resumes at the same
        // word). `currentReadingWordIndex`/`currentReadingScrollOffsetY` already fold in
        // the glance-fling guard, so a fast fling to the very start/end doesn't move it.
        store.saveReaderExitPosition(
            scrollOffset: .set(Double(currentReadingScrollOffsetY)),
            readingProgress: progress,
            lastSpokenWordIndex: speech?.currentWordIndex,
            lastWordIndex: currentReadingWordIndex,
            for: item.id)
    }

    // MARK: - Playback UI

    private func configureFooter() {
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.isHidden = true
        view.addSubview(footer)

        func footerButton(_ symbol: String, action: Selector, pointSize: CGFloat = 20) -> UIButton {
            var config = UIButton.Configuration.plain()
            config.image = UIImage(systemName: symbol)
            config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: pointSize)
            let button = UIButton(configuration: config)
            button.addTarget(self, action: action, for: .touchUpInside)
            return button
        }

        let back = footerButton("backward.frame.fill", action: #selector(skipBack))
        footerPlayButton.configuration = {
            var config = UIButton.Configuration.plain()
            config.image = UIImage(systemName: "pause.fill")
            config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 26)
            return config
        }()
        footerPlayButton.addTarget(self, action: #selector(togglePlayback), for: .touchUpInside)
        let forward = footerButton("forward.frame.fill", action: #selector(skipForward))

        footerRateButton.setTitle(L10n.string("Reader_audio_rateOneXTitle"), for: .normal)
        footerRateButton.titleLabel?.font = .monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
        footerRateButton.addTarget(self, action: #selector(cycleRate), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [back, footerPlayButton, forward, footerRateButton])
        stack.axis = .horizontal
        stack.distribution = .equalSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        footer.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 92),
            stack.leadingAnchor.constraint(equalTo: footer.contentView.leadingAnchor, constant: 40),
            stack.trailingAnchor.constraint(equalTo: footer.contentView.trailingAnchor, constant: -40),
            stack.topAnchor.constraint(equalTo: footer.contentView.topAnchor, constant: 10),
        ])
    }

    /// First word to resume from: where playback left off, else the first word
    /// currently visible on screen (so playback starts where the reader is, not
    /// the top of the article).
    private var resumeWordIndex: Int? {
        if let explicitResumeWordIndex {
            return explicitResumeWordIndex
        }
        if let resume = item.lastSpokenWordIndex {
            return resume
        }
        return firstFullyVisibleWordIndex()
    }

    /// The word index of the first word whose line is FULLY visible (not clipped
    /// by the top edge) — what a reader has actually read up to.
    private func firstFullyVisibleWordIndex() -> Int? {
        let layoutManager = textView.layoutManager
        let container = textView.textContainer
        // Visible top expressed in text-container coordinates (text is offset by
        // the container inset within the text view).
        let visibleTop = textView.contentOffset.y - textView.textContainerInset.top
        let probe = CGPoint(x: 1, y: max(0, visibleTop) + 1)
        let glyph = layoutManager.glyphIndex(for: probe, in: container)
        var lineRange = NSRange()
        let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineRange)
        // If that line is clipped at the top, advance to the next line's start.
        var firstGlyph = lineRange.location
        if lineRect.minY < visibleTop - 0.5 {
            let nextGlyph = NSMaxRange(lineRange)
            if nextGlyph < layoutManager.numberOfGlyphs { firstGlyph = nextGlyph }
        }
        let charIndex = layoutManager.characterIndexForGlyph(at: firstGlyph)
        return wordMap.wordIndex(nearCharacterIndex: charIndex)
    }

    /// Scrolls so the given word sits `fraction` of the screen height down from
    /// the top, clamped so it never overscrolls past either end.
    private func scrollWord(_ wordIndex: Int, toFractionFromTop fraction: CGFloat) {
        guard let range = wordMap.attributedRange(forWord: wordIndex) else { return }
        scrollRange(range, toFractionFromTop: fraction, animated: false)
    }

    /// Scrolls so a character range sits `fraction` of the screen height down from
    /// the top, clamped so it never overscrolls past either end.
    private func scrollRange(
        _ range: NSRange, toFractionFromTop fraction: CGFloat, animated: Bool
    ) {
        let layoutManager = textView.layoutManager
        layoutManager.ensureLayout(for: textView.textContainer)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textView.textContainer)
        rect.origin.y += textView.textContainerInset.top
        let target = clampedContentOffsetY(rect.minY - fraction * textView.bounds.height)
        guard animated else {
            textView.contentOffset.y = target
            return
        }
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
            self.textView.contentOffset.y = target
        }
    }

    /// A target content offset clamped to the scrollable range, accounting for
    /// the content insets at both ends (so the last line can still be reached).
    private func clampedContentOffsetY(_ target: CGFloat) -> CGFloat {
        let minOffset = -textView.adjustedContentInset.top
        let maxOffset = max(
            minOffset,
            textView.contentSize.height + textView.adjustedContentInset.bottom - textView.bounds.height)
        return min(max(minOffset, target), maxOffset)
    }

    private func startSpeech() {
        followPlayback = true
        // The legacy path stays for the share/action extensions, where the
        // app-wide playback center's seam is never installed.
        if let center = ReaderAudioLauncher.center {
            startSpeechViaCenter(center)
        } else {
            startSpeechViaLegacyController()
        }
    }

    /// In-app: hand off to the app-wide playback center (background audio,
    /// autoplay, the window-level mini-player replaces the private footer).
    private func startSpeechViaCenter(_ center: AudioPlaybackCenter) {
        ReaderPlaybackArbiter.claim(self)
        // Already voicing this very article (e.g. a mode switch back to
        // scroll, or reopening the playing article with audio on): keep
        // going rather than restarting — unless a position was explicitly
        // carried in from another reader mode.
        if center.currentItemInfo?.itemID == item.id,
           center.isAudiblyPlaying,
           explicitResumeWordIndex == nil {
            VoiceFirstRunPrompt.showIfNeeded(from: self)
            return
        }
        // nil resumes the center's own persisted position when it names
        // this item; a carried-over mode-switch position wins outright.
        center.play(item: item, content: content, fromWordIndex: explicitResumeWordIndex)
        VoiceFirstRunPrompt.showIfNeeded(from: self)
    }

    /// The extension-only path, driven by the private `SpeechController`
    /// (no app-wide center, no mini-player, no background audio session).
    private func startSpeechViaLegacyController() {
        if speech == nil {
            // Phase 6: the legacy extension-only path now speaks the TRIMMED
            // script (best available: cached refined > cached heuristic >
            // freshly-built heuristic — never blocks on the LLM). The VISUAL
            // reader (`content`/`rendered`/`wordMap` below) stays untrimmed;
            // only which blocks are SPOKEN is restricted.
            let resolver = extensionAudioScriptResolver ?? ExtensionAudioScriptResolver(
                articlesDirectory: store.articlesDirectory)
            extensionAudioScriptResolver = resolver
            let script = resolver.bestAvailableScriptForImmediatePlayback(item: item, content: content)
            let spokenBlockIndices = Set(script.spokenBlocks.map(\.blockIndex))
            let controller = SpeechController(
                content: content, rendered: rendered, wordMap: wordMap,
                title: content.title, spokenBlockIndices: spokenBlockIndices)
            controller.delegate = self
            speech = controller
        }
        footer.isHidden = false
        layoutCompletionArea()
        ReaderPlaybackArbiter.claim(self)
        speech?.play(fromWordIndex: resumeWordIndex)
        // First-ever read-aloud: nudge the user toward higher-quality voices.
        // Non-blocking — playback above has already begun. No-op in extensions.
        VoiceFirstRunPrompt.showIfNeeded(from: self)
    }

    @objc private func togglePlayback() {
        followPlayback = true
        speech?.togglePlayPause()
    }

    @objc private func skipBack() {
        followPlayback = true
        speech?.skipBackward()
    }

    @objc private func skipForward() {
        followPlayback = true
        speech?.skipForward()
    }

    @objc private func cycleRate() {
        speech?.cycleRate()
    }

    // MARK: - Highlighting

    private func applyHighlight(_ range: NSRange) {
        guard range.location + range.length <= textView.textStorage.length else { return }
        removeHighlight()
        textView.textStorage.addAttribute(.backgroundColor, value: highlightColor, range: range)
        highlightedRange = range
    }

    private func removeHighlight() {
        if let old = highlightedRange,
           old.location + old.length <= textView.textStorage.length {
            textView.textStorage.removeAttribute(.backgroundColor, range: old)
        }
        highlightedRange = nil
    }

    private func scrollToCenter(_ range: NSRange) {
        let layoutManager = textView.layoutManager
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textView.textContainer)
        rect.origin.y += textView.textContainerInset.top
        let target = rect.midY - textView.bounds.height / 2
        let clamped = clampedContentOffsetY(target)
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveLinear, .allowUserInteraction]) {
            self.textView.contentOffset.y = clamped
        }
    }

    // MARK: - Read tracking

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        checkFinishedReading()
        updateAnimatedImagePlayback()
        if scrollView.isTracking || scrollView.isDragging {
            // User-driven scroll: stop auto-follow; drop the resume highlight
            // only when nothing is actively playing.
            if speech?.isPlaying != true {
                removeHighlight()
            }
            followPlayback = false
        }
    }

    /// UIKit hands the fling speed here (points/ms) — capture it (as points/s) so the
    /// settle handler can tell a deliberate scroll from a glance fling.
    public func scrollViewWillEndDragging(
        _ scrollView: UIScrollView, withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        pendingFlingSpeedPointsPerSecond = abs(velocity.y) * 1000
    }

    /// A drag that ends without inertia settles immediately.
    public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { handleScrollSettled() }
    }

    /// A flung scroll settles when its inertia stops.
    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        handleScrollSettled()
    }

    /// Decide whether the position the scroll just settled at should update the shared
    /// reading position. A fast fling that lands on the very start/end is a glance and
    /// is ignored (the committed position stays put); everything else counts.
    private func handleScrollSettled() {
        let counts = ReaderResumePositionResolver.shouldCountLanding(
            atExtreme: isAtExtremeEdge(),
            speedPointsPerSecond: pendingFlingSpeedPointsPerSecond)
        pendingFlingSpeedPointsPerSecond = 0
        if counts {
            committedWordIndex = firstFullyVisibleWordIndex() ?? committedWordIndex
            committedOffsetY = textView.contentOffset.y
            landedGlanceFling = false
        } else {
            landedGlanceFling = true
        }
    }

    /// Whether the current offset sits at the very top or bottom of the scrollable
    /// range (within a hair), reusing the same clamp bounds as `clampedContentOffsetY`.
    private func isAtExtremeEdge() -> Bool {
        let minOffset = -textView.adjustedContentInset.top
        let maxOffset = max(
            minOffset,
            textView.contentSize.height + textView.adjustedContentInset.bottom - textView.bounds.height)
        let y = textView.contentOffset.y
        let tolerance: CGFloat = 8
        return y <= minOffset + tolerance || y >= maxOffset - tolerance
    }

    private func checkFinishedReading() {
        // Never decide "finished" against the PREFIX content size — a long article
        // whose prefix happens to fit one screen would be wrongly marked read before
        // Phase 2 expands it. Wait for the full content.
        guard fullContentLoad == .done, textView.contentSize.height > 0 else { return }
        let visibleBottom = textView.contentOffset.y + textView.bounds.height
        // Require the user to enter the reserved whitespace far enough for the
        // persistent glass pill to be visible when its checkmark starts drawing.
        let reachedEnd = visibleBottom >= articleContentBottom + 52
        switch finishedReadingTracker.update(reachedEnd: reachedEnd) {
        case .finished:
            finishedBadge.present()
            completionDelegate?.readerDidFinishReading(self)
        case .movedAway: completionDelegate?.readerDidMoveAwayFromEnd(self)
        case nil: break
        }
    }

    // MARK: - Link taps → split

    public func textView(
        _ textView: UITextView,
        primaryActionFor textItem: UITextItem,
        defaultAction: UIAction
    ) -> UIAction? {
        if case .link(let url) = textItem.content {
            // A table-of-contents row (or a footnote marker) points inside THIS
            // article: scroll to it rather than opening a reader on the page the
            // reader is already in.
            if let anchorID = inPageAnchorID(atCharacterRange: textItem.range) {
                return UIAction { [weak self] _ in self?.scrollToInPageAnchor(anchorID) }
            }
            return UIAction { [weak self] _ in
                guard let self else { return }
                if let onLinkActivatedWithRange = self.onLinkActivatedWithRange {
                    onLinkActivatedWithRange(url, textItem.range)
                } else {
                    self.openSplit(for: url, tappedRange: textItem.range)
                }
            }
        }
        return defaultAction
    }

    // MARK: - In-page jumps (the page's own chapter marks)

    /// Where a jump lands: near the top, with a little air above it so the target
    /// heading doesn't sit flush against the edge.
    private static let anchorScrollFractionFromTop: CGFloat = 0.08

    /// Set when a jump is requested before the whole article is laid out, and
    /// consumed by the Phase-2 swap. A table of contents sits at the very top of
    /// an article, so a tap arriving during Phase 1 is the COMMON case, not an
    /// edge case — and its destination is essentially always past the prefix.
    private var pendingAnchorBlockIndex: Int?

    /// The in-page destination the rendered text carries at this range, if any.
    private func inPageAnchorID(atCharacterRange range: NSRange) -> String? {
        guard let text = textView.attributedText,
              range.location >= 0, range.location < text.length
        else { return nil }
        return text.attribute(.lunaInPageAnchor, at: range.location, effectiveRange: nil) as? String
    }

    private func scrollToInPageAnchor(_ anchorID: String) {
        guard let blockIndex = content.blockIndex(forAnchorID: anchorID) else { return }
        guard fullContentLoad == .done else {
            pendingAnchorBlockIndex = blockIndex
            prepareFullContent()
            return
        }
        scrollToBlock(blockIndex)
    }

    /// Scrolls a block into view by its rendered range. An image block has no text
    /// range, so the nearest range after it (then before it) stands in — the jump
    /// lands on the destination's neighbour rather than doing nothing.
    private func scrollToBlock(_ blockIndex: Int) {
        let ranges = rendered.blockTextRanges
        guard !ranges.isEmpty else { return }
        // A prefix render carries fewer ranges than the article has blocks, so the
        // index is clamped rather than trusted to be in bounds.
        let start = min(max(blockIndex, 0), ranges.count - 1)
        let forward = (start..<ranges.count).lazy.compactMap { ranges[$0] }.first
        let backward = (0...start).reversed().lazy.compactMap { ranges[$0] }.first
        guard let range = forward ?? backward else { return }
        scrollRange(range, toFractionFromTop: Self.anchorScrollFractionFromTop, animated: true)
    }

    /// Inline-link holds are owned by `LinkRSVPPreviewInteraction`. Returning nil
    /// suppresses UIKit's second, duplicated link menu after our preview begins.
    public func textView(
        _ textView: UITextView,
        menuConfigurationFor textItem: UITextItem,
        defaultMenu: UIMenu
    ) -> UITextItem.MenuConfiguration? {
        guard case .link = textItem.content else {
            return UITextItem.MenuConfiguration(menu: defaultMenu)
        }
        return nil
    }

    /// Exact link hit test for the custom hold recognizer. UITextView owns the
    /// point→text-position and text-range→rect conversions so content offsets,
    /// text-container insets, line padding, and wrapped links all stay in the
    /// same coordinate space as the finger. Checking the actual selection rects
    /// prevents `closestPosition(to:)` from snapping nearby plain text to a link.
    private func link(at point: CGPoint) -> (url: URL, range: NSRange)? {
        guard let position = textView.closestPosition(to: point) else { return nil }
        let rawIndex = textView.offset(from: textView.beginningOfDocument, to: position)
        let length = textView.attributedText.length
        guard length > 0 else { return nil }

        // A touch on the trailing half of a glyph can resolve to the insertion
        // point after it, so consider that preceding character as well.
        for index in [min(rawIndex, length - 1), max(0, rawIndex - 1)] {
            var range = NSRange(location: 0, length: 0)
            let value = textView.attributedText.attribute(.link, at: index, effectiveRange: &range)
            let url: URL?
            if let resolved = value as? URL { url = resolved }
            else if let string = value as? String { url = URL(string: string) }
            else { url = nil }
            guard let url,
                  let start = textView.position(from: textView.beginningOfDocument,
                                                offset: range.location),
                  let end = textView.position(from: start, offset: range.length),
                  let textRange = textView.textRange(from: start, to: end) else { continue }
            let hit = textView.selectionRects(for: textRange).contains {
                !$0.rect.isEmpty && $0.rect.insetBy(dx: -4, dy: -4).contains(point)
            }
            if hit { return (url, range) }
        }
        return nil
    }

    /// The URL a link hold should preview. An in-page jump has none: the mini RSVP
    /// preview would load this same article, so the hold falls through to ordinary
    /// text selection instead. (`link(at:)` itself still reports the hit, so the
    /// card keeps treating a ToC row as interactive content.)
    private func previewableLinkURL(at point: CGPoint) -> URL? {
        guard let hit = link(at: point),
              inPageAnchorID(atCharacterRange: hit.range) == nil
        else { return nil }
        return hit.url
    }

    /// Whether a point in this controller's view is already owned by normal
    /// reader interaction. The outer card uses this to keep its additive
    /// show/hide-chrome tap away from links and inline images.
    public func hasInteractiveContent(at point: CGPoint) -> Bool {
        let textPoint = view.convert(point, to: textView)
        return link(at: textPoint) != nil || imageEntry(at: textPoint) != nil
    }

    /// Whether a point in this controller's view lands on a rendered glyph (as
    /// opposed to the margins, inter-paragraph gaps, or the empty space past the
    /// end of a line). The outer card uses this to let a long-press on real text
    /// begin a selection while reserving whitespace for its own context menu.
    /// `closestPosition(to:)`/`characterIndex(for:)` always snap to the nearest
    /// glyph, so we must confirm the point is actually inside that glyph's box.
    public func pointIsOverText(at point: CGPoint) -> Bool {
        let layoutManager = textView.layoutManager
        let container = textView.textContainer
        let local = CGPoint(
            x: point.x - textView.textContainerInset.left,
            y: point.y - textView.textContainerInset.top)
        guard layoutManager.numberOfGlyphs > 0 else { return false }
        let glyphIndex = layoutManager.glyphIndex(for: local, in: container)
        let glyphRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyphIndex, length: 1), in: container)
        return glyphRect.contains(local)
    }

    private func setLinkPreviewAudioSuspended(_ suspended: Bool) {
        if suspended {
            if let center = ReaderAudioLauncher.center,
               center.currentItemInfo?.itemID == item.id,
               center.isAudiblyPlaying {
                resumesAudioAfterLinkPreview = true
                center.pause()
            } else if speech?.isPlaying == true {
                resumesAudioAfterLinkPreview = true
                speech?.pause()
            }
        } else if resumesAudioAfterLinkPreview {
            resumesAudioAfterLinkPreview = false
            if let center = ReaderAudioLauncher.center,
               center.currentItemInfo?.itemID == item.id {
                center.resume()
            } else {
                speech?.resume()
            }
        }
    }

    // MARK: - Highlight & share (text selection)

    /// Adds a "Share" action to the text-SELECTION menu (the callout shown for a
    /// selected passage, distinct from the link menu above). The system's
    /// `suggestedActions` (Copy, Look Up, Translate, …) are preserved verbatim —
    /// Copy stays the system's menu item, and carries the reader's quote payload
    /// because `QuotingTextView` overrides `copy(_:)` rather than this menu.
    public func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                         suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard range.length > 0 else { return nil }
        let quote = (textView.text as NSString).substring(with: range)
        let share = UIAction(title: L10n.string("Common_share"),
                             image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
            self?.shareHighlightedText(quote, in: range)
        }
        return UIMenu(children: [share] + suggestedActions)
    }

    /// The text shared for a highlighted passage. Pure + static so it's unit-testable.
    /// With a real web URL: the quote in literal double-quotes, a blank line, then the
    /// URL. Otherwise (documents / synthetic-scheme imports): the bare trimmed quote.
    public static func makeHighlightShareText(quote: String, item: ReadingListItem) -> String {
        let q = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        return item.isShareable ? "\"\(q)\"\n\n\(item.urlString)" : q
    }

    /// Puts a highlighted passage on the pasteboard in the SAME form Share sends it
    /// (`makeHighlightShareText`) — quote, blank line, URL. Returns false when the
    /// range doesn't resolve, which hands the copy back to UIKit's plain-text one.
    private func copyHighlightedText(in range: NSRange) -> Bool {
        let text = textView.text as NSString
        guard range.location >= 0, NSMaxRange(range) <= text.length else { return false }
        UIPasteboard.general.string = Self.makeHighlightShareText(
            quote: text.substring(with: range), item: item)
        return true
    }

    /// Presents the share sheet for a highlighted passage, anchoring the iPad popover
    /// to the current selection (mirrors the link-share popover anchoring above).
    private func shareHighlightedText(_ quote: String, in range: NSRange) {
        let text = Self.makeHighlightShareText(quote: quote, item: item)
        let activity = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        if let popover = activity.popoverPresentationController {
            popover.sourceView = textView
            if let selection = textView.selectedTextRange {
                let rect = textView.firstRect(for: selection)
                popover.sourceRect = (rect.isNull || rect.isInfinite)
                    ? CGRect(x: textView.bounds.midX, y: textView.bounds.midY, width: 0, height: 0)
                    : rect
            } else {
                popover.sourceRect = CGRect(x: textView.bounds.midX, y: textView.bounds.midY, width: 0, height: 0)
            }
        }
        present(activity, animated: true)
    }

    public func textViewDidChangeSelection(_ textView: UITextView) {
        // Only the FIRST non-empty selection change after a sentence long-press snaps —
        // guarded against our own reentrant `selectedRange` write.
        guard expandNextSelectionToSentence, !isExpandingSelection else { return }
        let selected = textView.selectedRange
        guard selected.length > 0 else { return }
        // Clear immediately so drag-handle adjustments afterward are not re-snapped.
        expandNextSelectionToSentence = false
        _ = expandSelectionToSentence(around: selected.location)
    }

    /// The character range of the sentence containing (or nearest to) `caret`, scoped
    /// to its paragraph. Returns nil if no sentence can be resolved (graceful fallback:
    /// the caller leaves the selection untouched).
    private static func enclosingSentenceRange(in text: String, caret: Int) -> NSRange? {
        let ns = text as NSString
        guard ns.length > 0 else { return nil }
        let safeCaret = min(max(0, caret), ns.length - 1)
        let paragraph = ns.paragraphRange(for: NSRange(location: safeCaret, length: 0))
        var best: NSRange?
        var bestDistance = Int.max
        ns.enumerateSubstrings(in: paragraph, options: [.bySentences]) { _, substringRange, _, stop in
            if NSLocationInRange(caret, substringRange) {
                best = substringRange
                stop.pointee = true
                return
            }
            let distance = min(abs(substringRange.location - caret), abs(NSMaxRange(substringRange) - caret))
            if distance < bestDistance {
                bestDistance = distance
                best = substringRange
            }
        }
        return best
    }

    /// Opens the tapped link as a full-size nested reader. The source point is the
    /// resolved glyph center, so the black-circle phase begins at the link itself.
    private func openSplit(for url: URL, tappedRange: NSRange) {
        let sourcePoint = linkActivationPoint(forCharacterRange: tappedRange)
        let readerOffset = textView.contentOffset.y
        InlineReaderOpener.open(
            url: url,
            from: self,
            coordinator: inlineReaderPresentationCoordinator,
            shareProvider: shareProvider,
            sourcePointInWindow: view.convert(sourcePoint, to: nil),
            outerURL: item.url ?? url,
            outerTitle: content.title,
            onDismiss: { [weak self] in self?.restoreScroll(to: readerOffset) })
    }

    // MARK: - Simulator-only split hooks

    /// The blitz harness can't tap an exact inline link, so in the simulator two
    /// buttons trigger `openSplit` with the cut placed high or low on screen — the
    /// two cases that exercise the inline-reader open animation + header tucking.
    private func addSimulatorSplitHooksIfNeeded() {
        #if targetEnvironment(simulator)
        // Suppress these debug buttons during deterministic screenshot captures so
        // they don't overlay the article text; interactive automation still gets them.
        // Suppressed during a deterministic capture (see `CaptureLaunch`,
        // which lives in the app target — inlined here to avoid an upward dependency).
        if CaptureLaunch.isActive { return }
        func hookButton(_ title: String, fraction: CGFloat) -> UIButton {
            var config = UIButton.Configuration.filled()
            config.title = title
            config.baseBackgroundColor = .systemPurple
            let button = UIButton(configuration: config)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.addAction(
                UIAction { [weak self] _ in self?.simulatorOpenSplit(atScreenFraction: fraction) },
                for: .touchUpInside)
            view.addSubview(button)
            return button
        }
        let top = hookButton(L10n.string("Reader_scroll_simSplitHighButtonTitle"), fraction: 0.12)
        let bottom = hookButton(L10n.string("Reader_scroll_simSplitLowButtonTitle"), fraction: 0.82)
        NSLayoutConstraint.activate([
            top.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            top.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -24),
            bottom.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            bottom.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 12),
        ])
        #endif
    }

    #if targetEnvironment(simulator)
    private func simulatorOpenSplit(atScreenFraction fraction: CGFloat) {
        let yInTextView = textView.contentOffset.y + fraction * textView.bounds.height
        let glyph = textView.layoutManager.glyphIndex(
            for: CGPoint(x: 40, y: max(0, yInTextView)), in: textView.textContainer)
        let charIndex = textView.layoutManager.characterIndexForGlyph(at: glyph)
        guard let url = URL(string: "https://en.wikipedia.org/wiki/Swift_(programming_language)")
        else { return }
        openSplit(for: url, tappedRange: NSRange(location: charIndex, length: 1))
    }
    #endif

    /// Restores the reader to a saved content offset. Forces full text layout
    /// first — the text view lays out lazily, and clamping against a not-yet-final
    /// contentSize breaks scrolling.
    private func restoreScroll(to offset: CGFloat) {
        textView.layoutManager.ensureLayout(for: textView.textContainer)
        textView.layoutIfNeeded()
        textView.contentOffset.y = clampedContentOffsetY(offset)
    }
}

// MARK: - SpeechControllerDelegate

extension ScrollReaderViewController: ReaderPlaybackPausable {
    /// The reader beside this one started. Silence whichever voice is running:
    /// the app-wide centre when it is speaking this article, otherwise the
    /// extension-only private controller.
    public func pauseForExclusivePlayback() {
        if let center = ReaderAudioLauncher.center,
           center.currentItemInfo?.itemID == item.id,
           center.isAudiblyPlaying {
            center.pause()
            return
        }
        if speech?.isPlaying == true { speech?.pause() }
    }
}

extension ScrollReaderViewController: SpeechControllerDelegate {
    public func speech(_ controller: SpeechController, willSpeakAttributedRange range: NSRange, wordIndex: Int?) {
        applyHighlight(range)
        if followPlayback {
            scrollToCenter(range)
        }
    }

    public func speechPlaybackStateDidChange(_ controller: SpeechController) {
        let icon = controller.isPlaying ? "pause.fill" : "play.fill"
        footerPlayButton.configuration?.image = UIImage(systemName: icon)
        let factor = controller.rateFactor
        footerRateButton.setTitle(
            factor == 1.0 ? "1×" : String(format: "%.1f×", factor), for: .normal)
        if !controller.isPlaying, let word = controller.currentWordIndex {
            store.setLastSpokenWordIndex(word, for: item.id)
        }
    }

    public func speechDidFinishArticle(_ controller: SpeechController) {
        finishedReadingTracker.markFinished()
        finishedBadge.present()
        completionDelegate?.readerDidFinishReading(self)
        footerPlayButton.configuration?.image = UIImage(systemName: "play.fill")
        removeHighlight()
    }
}

// MARK: - AudioPlaybackObserver (in-app center-driven read-aloud)

extension ScrollReaderViewController: AudioPlaybackObserver {
    /// Word highlighting from the app-wide center, applied only while the
    /// DISPLAYED article is the one playing. The event's range is UTF-16 within
    /// the ORIGINAL `ArticleContent` block at `blockIndex`, so it maps into the
    /// rendered attributed string exactly the way the legacy
    /// `SpeechController` delegate path did: block range start + in-block
    /// location. A prefix-only render simply skips events for blocks beyond it
    /// (audio-enabled opens always render the full article up front).
    public func audioPlaybackCenter(_ center: AudioPlaybackCenter, didEmitWordEvent event: AudioWordEvent) {
        guard center.currentItemInfo?.itemID == item.id, isViewLoaded else { return }
        guard let blockRange = rendered.blockTextRanges[safe: event.blockIndex] ?? nil else { return }
        let attributedRange = NSRange(
            location: blockRange.location + event.rangeInBlockText.location,
            length: event.rangeInBlockText.length)
        applyHighlight(attributedRange)
        if followPlayback {
            scrollToCenter(attributedRange)
        }
    }

    /// Autoplay advanced to (or the user started) a different article: this
    /// reader's spoken-word highlight no longer describes what's audible.
    public func audioPlaybackCenter(_ center: AudioPlaybackCenter, didUpdateItem info: AudioPlaybackItemInfo?) {
        guard isViewLoaded, info?.itemID != item.id else { return }
        removeHighlight()
    }
}

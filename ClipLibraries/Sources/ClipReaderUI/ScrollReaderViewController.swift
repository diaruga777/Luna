//
//  ScrollReaderViewController.swift
//  Clip
//

import ClipReaderEngine
import ClipDesignSystem
import ClipStorage
import ClipModels
import UIKit

/// Full-screen scrolling text reader. Tapping an inline link splits the article
/// open into the inline glass card (`SplitWebOverlayViewController`); long-press
/// offers save/share. Supports read-aloud with
/// word highlighting + follow-scroll, remembers the scroll position, and
/// estimates the last-read word via eye tracking on supported devices.
public final class ScrollReaderViewController: UIViewController, UITextViewDelegate, ReaderPositionTracking,
    UIContextMenuInteractionDelegate, UIGestureRecognizerDelegate {

    /// Fired once when the user reaches the end of the article.
    public var onFinishedReading: (() -> Void)?

    /// When set, a tapped inline link is handed to this closure instead of opening
    /// a new inline split overlay — used by the inline reader to push the link onto
    /// its own navigation stack rather than nesting another overlay.
    public var onLinkActivated: ((URL) -> Void)?
    /// Visible/near-visible inline links changed. RabbitHole uses this to rotate the
    /// expensive offscreen child view controllers around what the reader can tap soon,
    /// while the cheaper content preload can stay broader.
    public var onVisibleLinkURLsChanged: (([URL]) -> Void)?

    /// Fired when the end-of-article share footer scrolls into / out of view, so the
    /// host can fade its floating share button (the footer already offers sharing).
    public var onShareFooterVisibilityChanged: ((Bool) -> Void)?
    private var shareFooterVisible = false

    /// A word index carried in from another reader mode. When set (and this is
    /// the plain scrolling mode), the view scrolls so that word sits 25% from
    /// the top on first appearance instead of restoring the saved offset.
    private let explicitResumeWordIndex: Int?

    /// The content offset captured the moment the reader's initial position is
    /// applied — the baseline for deciding whether the user has since scrolled
    /// far enough to count as a deliberate reposition (vs. just opening/closing).
    private var openContentOffsetY: CGFloat?

    /// Gates the gaze estimate so only a stable, multi-word lock — not a single
    /// noisy sample — is allowed to move the carried reading position.
    private var gazeLockGate = GazeLockGate()

    private let item: ReadingListItem
    private var content: ArticleContent
    private var rendered: RenderedArticle
    private var wordMap: WordMap
    private var imageDownloadTask: Task<Void, Never>?
    private let textView = UITextView()
    private let store = ReadingListStore.shared
    private var didFinishReading = false
    private var didRestoreScroll = false

    // MARK: - Progressive (two-phase) load

    /// Phase 1 renders only this many leading characters so the first paint is a
    /// near-instant layout of one+ screen of text — the heavy whole-article glyph
    /// generation that stalled behind the entry animation is deferred to Phase 2.
    /// A few hundred characters comfortably fills a screen of serif body text while
    /// keeping the initial `UITextView` layout cheap.
    private static let prefixCharacterBudget = 700

    /// True once the FULL article has been rendered + swapped in (Phase 2 done, or
    /// never needed because the prefix already covered the whole article). Until
    /// then `rendered`/`wordMap` describe only the prefix, so position-dependent
    /// features (RSVP/audio resume, gaze, the share footer) wait for it.
    private var didLoadFullContent = false
    /// Set once Phase 2 has been kicked off so it runs exactly once.
    private var didBeginFullContentLoad = false
    /// Set once the plain-scroll gaze carry-over observation has been wired, so it's
    /// started exactly once whether that happens in `viewDidAppear` (short article,
    /// tracker already present) or in `applyFullContent` (progressive open).
    private var didStartGazeObservation = false
    private var lastVisibleLinkKeys: Set<String> = []

    #if DEBUG
    /// Test hooks for the progressive load: whether the full content has been
    /// swapped in, and the rendered text length / word count currently shown.
    public var didLoadFullContentForTesting: Bool { didLoadFullContent }
    public var renderedTextLengthForTesting: Int { rendered.text.length }
    public var wordCountForTesting: Int { wordMap.wordCount }
    #endif

    /// Read aloud (the shared audio toggle).
    private let audioEnabled: Bool
    private var didStartPlayback = false

    // Read-aloud (audio) playback, present only when audio is enabled.
    private var speech: SpeechController?
    private let footer = UIVisualEffectView(effect: GlassStyle.barEffect())
    private let footerPlayButton = UIButton(type: .system)
    private let footerRateButton = UIButton(type: .system)
    private var highlightedRange: NSRange?
    private var followPlayback = true

    // Eye tracking (nil unless a gaze factory provided one — never in the sheet).
    private var gazeTracker: GazeTracking?
    private let gazeTrackerFactory: GazeTrackerFactory?

    /// Sharing affordances; nil → no end-of-article share footer (share sheet).
    private let shareProvider: ReaderShareProviding?
    /// End-of-article share affordance, pinned below the text content (nil when
    /// there's no share provider).
    private lazy var shareView: ArticleShareView? = makeShareView()
    private var contentSizeObservation: NSKeyValueObservation?

    // Matches the RSVP reader's liquid-glass focus accent (an inline text
    // highlight, since a glass overlay would sit in front of and blur the very
    // words being read).
    private let highlightColor = GlassStyle.readingAccent.withAlphaComponent(0.28)

    public init(item: ReadingListItem, content: ArticleContent,
         audioEnabled: Bool = false,
         shareProvider: ReaderShareProviding? = nil,
         gazeTrackerFactory: GazeTrackerFactory? = nil,
         resumeWordIndex: Int? = nil) {
        self.item = item
        // Bake in any images already cached on disk (keyed by URL hash) BEFORE the
        // first render, so they appear in the same frame as the text instead of
        // popping in later via the async downloader. Cheap (hash + fileExists); only
        // genuinely-uncached images fall through to `fetchMissingImagesIfNeeded`.
        let resolved = ArticleImageDownloader.resolveLocalImages(content, store: ReadingListStore.shared)
        self.content = resolved
        self.audioEnabled = audioEnabled
        self.shareProvider = shareProvider
        self.gazeTrackerFactory = gazeTrackerFactory
        self.explicitResumeWordIndex = resumeWordIndex
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
            ? ArticleTextRenderer.render(resolved)
            : ArticleTextRenderer.render(resolved, characterBudget: Self.prefixCharacterBudget)
        self.rendered = rendered
        self.wordMap = WordMap(content: resolved, rendered: rendered)
        super.init(nibName: nil, bundle: nil)
        // If the prefix already covers the whole (short) article there's nothing to
        // swap — Phase 2 is skipped.
        if rendered.isComplete { didLoadFullContent = true }
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
        if let saved = item.lastScrollOffset, saved > CGFloat(UIScreen.main.bounds.height) {
            return true
        }
        // A carried-in word index (mode switch) beyond the budget's worth of words.
        let carried = (!audioEnabled) ? resumeWordIndex : nil
        if let carried, carried > 0 {
            // Rough word-budget: count words in the leading blocks up to the
            // character budget; a carried index past that won't be in the prefix.
            var chars = 0
            var words = 0
            for block in content.blocks {
                if chars > budget { break }
                if block.kind == .image { continue }
                words += block.text.split(whereSeparator: { $0.isWhitespace }).count
                chars += block.text.count
            }
            if carried >= words { return true }
        }
        return false
    }

    /// The word currently being read, carried to other modes on a switch.
    ///
    /// During active playback this is the read-aloud position. In plain
    /// scroll, when a position was carried IN from another mode
    /// (`explicitResumeWordIndex`), it must NOT drift just from opening/closing:
    /// it only moves off that carried index when the user scrolled past a
    /// threshold (→ first fully-visible word) or eye tracking confirmed a
    /// multi-word lock (→ gaze word). With neither, it returns the carried index
    /// unchanged — a no-op. See `ReaderResumePositionResolver`.
    ///
    /// On a FRESH open (no carried index — e.g. straight from the reading list)
    /// there's no position to protect, so the first switch resumes from where
    /// the reader actually is: the gaze lock if confirmed, else the first
    /// fully-visible word.
    public var currentReadingWordIndex: Int? {
        if let speech, let word = speech.currentWordIndex { return word }

        guard let resumeIndex = explicitResumeWordIndex else {
            return gazeLockGate.confirmedIndex ?? firstFullyVisibleWordIndex()
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
            confirmedGazeIndex: gazeLockGate.confirmedIndex,
            firstFullyVisibleIndex: firstFullyVisibleWordIndex())
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        imageDownloadTask?.cancel()
        speech?.stop()
        gazeTracker?.stop()
        contentSizeObservation?.invalidate()
    }

    private func makeShareView() -> ArticleShareView? {
        guard let shareProvider, item.isShareable else { return nil }
        let suggestionName = shareProvider.suggestedFriendName(forURLString: item.urlString)
        return ArticleShareView(
            suggestionName: suggestionName,
            onShare: { [weak self] in
                guard let self, let shareView = self.shareView else { return }
                shareProvider.presentShareSheet(
                    urlString: self.item.urlString, title: self.content.title,
                    from: self, sourceView: shareView)
            },
            onSendSuggested: { [weak self] in
                guard let self else { return }
                shareProvider.sendToSuggestedFriend(
                    urlString: self.item.urlString, title: self.content.title, from: self)
            },
            onReportBug: { [weak self] in
                guard let self, let shareView = self.shareView else { return }
                ReplayBugReporter.report(
                    itemURLString: self.item.urlString, from: self, sourceView: shareView)
            })
    }

    /// Positions the share view just below the text content and reserves scroll
    /// room for it (and the floating footer) so it clears the controls.
    private func layoutShareView() {
        // Only once the footer is actually attached (after the full content lands).
        guard let shareView, shareView.superview != nil else { return }
        let width = textView.bounds.width
        guard width > 0 else { return }
        let height = shareView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel).height
        shareView.frame = CGRect(x: 0, y: textView.contentSize.height, width: width, height: height)
        let footerSpace = footer.isHidden ? 0 : footer.bounds.height
        // Add the bottom safe area so the last lines + share footer clear the
        // home indicator instead of sitting under it.
        textView.contentInset.bottom = height + footerSpace + view.safeAreaInsets.bottom + 16
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        // Touch layoutManager BEFORE any text is set: the view starts in
        // TextKit 1 and never flips mid-session (a later TK2→TK1 switch
        // re-breaks lines and makes the text visibly jump).
        _ = textView.layoutManager
        textView.isEditable = false
        textView.isSelectable = true
        textView.delegate = self
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

        let imageTap = UITapGestureRecognizer(target: self, action: #selector(imageTapped(_:)))
        imageTap.delegate = self
        imageTap.cancelsTouchesInView = false
        textView.addGestureRecognizer(imageTap)
        textView.addInteraction(UIContextMenuInteraction(delegate: self))

        configureFooter()

        // The end-of-article share footer is attached only once the FULL article is
        // rendered (its position is keyed off the complete content size). For a short
        // article the prefix is already complete, so attach it now; otherwise
        // `prepareFullContent()` attaches it after the swap.
        if didLoadFullContent { attachShareFooterIfNeeded() }

        // Images cached on disk are baked into the prefix already; only genuinely
        // uncached ones (action/share surface) fall through here. Once the full
        // content lands this re-runs against it (see `prepareFullContent`).
        if didLoadFullContent { fetchMissingImagesIfNeeded() }

        addSimulatorSplitHooksIfNeeded()

        // The resume highlight + gaze tracker both need the FULL word map (a deep
        // resume word / gaze estimate isn't in the prefix), so install them only once
        // the full content has landed. For an already-complete prefix that's now.
        if didLoadFullContent { installPositionDependentFeatures() }

        // Hide the text until the saved scroll position is applied, so the
        // article never flashes at the top and then jumps. Fresh articles (no
        // saved position) start at the top and stay visible.
        if hasInitialScrollPosition { textView.alpha = 0 }
    }

    /// Whether there's a saved/carried position to restore before revealing.
    private var hasInitialScrollPosition: Bool {
        if let resume = explicitResumeWordIndex, !audioEnabled,
           wordMap.attributedRange(forWord: resume) != nil { return true }
        return item.lastScrollOffset != nil
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Keep the text in a readable column on wide screens (iPad / landscape).
        let horizontal = max(20, (view.bounds.width - 680) / 2)
        if abs(textView.textContainerInset.left - horizontal) > 0.5 {
            textView.textContainerInset = UIEdgeInsets(
                top: 20, left: horizontal, bottom: 40, right: horizontal)
        }
        layoutShareView()

        // Restore the scroll position as soon as we have real bounds — BEFORE
        // the view is on screen — then reveal, so there's no top-flash + jump.
        if !didRestoreScroll, textView.bounds.width > 0 {
            didRestoreScroll = true
            applyInitialScrollPosition()
            revealContent()
        }
        publishVisibleLinkURLsIfNeeded()
    }

    // MARK: - Progressive (two-phase) load

    /// Phase 2. Renders the FULL article and swaps it in for the prefix, SEAMLESSLY
    /// and preserving scroll position. Call once the entry animation has finished
    /// (the host wires this to its open-animation completion); the reader also calls
    /// it itself once it appears, so it works regardless of host. Idempotent and a
    /// no-op when the prefix already covered the whole article.
    ///
    /// Phase 2 runs AFTER the entry animation, so the article's heavy whole-text glyph
    /// generation no longer stalls the open. The attributed-string build + the forced
    /// layout both run on the main actor (the renderer touches `UIScreen`/`UIFont`, and
    /// TextKit layout must be on main anyway) — it's the TIMING (off the animation's
    /// critical path), not threading, that removes the stall. Because the prefix is a
    /// STRICT prefix of the full text, the top/visible layout is identical, so restoring
    /// the captured `contentOffset` across the swap is invisible.
    public func prepareFullContent() {
        guard !didLoadFullContent, !didBeginFullContentLoad else { return }
        didBeginFullContentLoad = true
        // Defer one runloop so a host that calls this from inside its open-animation
        // completion doesn't pay the build cost in the same commit as that completion.
        DispatchQueue.main.async { [weak self] in
            // `[weak self]` drops this if the VC deallocated. Require the view loaded
            // (it always is by the time Phase 2 is triggered) before touching it.
            guard let self, self.isViewLoaded, !self.didLoadFullContent else { return }
            let full = ArticleTextRenderer.render(self.content)
            self.applyFullContent(full)
        }
    }

    /// Swaps the freshly-built full render into the text view, preserving the reader's
    /// scroll position. Runs on the main actor.
    @MainActor
    private func applyFullContent(_ full: RenderedArticle) {
        guard !didLoadFullContent else { return }
        // The user might have scrolled within the prefix while it was the only thing
        // laid out. Capture where they are so the swap is seamless.
        let offset = textView.contentOffset
        // First-fully-visible word BEFORE the swap, as a fallback anchor for the rare
        // case the captured offset can't be trusted (see below).
        let anchorWord = firstFullyVisibleWordIndex()

        rendered = full
        wordMap = WordMap(content: content, rendered: full)

        UIView.performWithoutAnimation {
            textView.attributedText = full.text
            textView.layoutManager.ensureLayout(for: textView.textContainer)
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

        didLoadFullContent = true
        // Now that the full word map exists, wire up the position-dependent features
        // and finish the inline-image fetch + share footer against the real content.
        installPositionDependentFeatures()
        attachShareFooterIfNeeded()
        layoutShareView()
        fetchMissingImagesIfNeeded()
        publishVisibleLinkURLsIfNeeded(force: true)
    }

    /// Installs the read-aloud resume highlight and the gaze tracker — both of which
    /// need the FULL word map (a deep resume word / gaze estimate isn't in the prefix).
    /// Called once the full content is in place; idempotent-safe via the gaze guard.
    /// If the view has already appeared in plain-scroll mode, also starts the gaze
    /// carry-over observation (which `viewDidAppear` couldn't, having had no tracker
    /// yet on a progressive open).
    private func installPositionDependentFeatures() {
        if let spokenIndex = item.lastSpokenWordIndex,
           let range = wordMap.attributedRange(forWord: spokenIndex) {
            applyHighlight(range)
        }
        if gazeTracker == nil {
            gazeTracker = gazeTrackerFactory?(textView, wordMap, item.eyeTrackedWordIndex)
        }
        // Started playback already (the view appeared) in plain scroll, but the gaze
        // observation was skipped because the tracker didn't exist yet — start it now.
        if didStartPlayback, !audioEnabled, gazeTracker != nil, !didStartGazeObservation {
            didStartGazeObservation = true
            observeGazeForCarryOver(alsoHighlight: ReaderSettings.highlightGazeWord)
        }
    }

    /// Adds the end-of-article share footer (and the content-size observer that keeps
    /// it pinned below the text). Deferred until the full content is rendered so it
    /// sits at the true bottom. Idempotent.
    private func attachShareFooterIfNeeded() {
        guard let shareView, shareView.superview == nil else { return }
        textView.addSubview(shareView)
        contentSizeObservation = textView.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
            self?.layoutShareView()
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
            self.rendered = ArticleTextRenderer.render(updated)
            self.wordMap = WordMap(content: updated, rendered: self.rendered)
            let offset = self.textView.contentOffset
            self.textView.attributedText = self.rendered.text
            self.textView.setContentOffset(offset, animated: false)
            self.textView.layoutManager.ensureLayout(for: self.textView.textContainer)
            self.layoutShareView()
            SharedDiagnosticLog.record("reader: refreshed inline image attachments", category: "images")
        }
    }

    private func image(at point: CGPoint) -> (image: UIImage, frame: CGRect)? {
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
        guard let entry = rendered.imageRanges.first(where: { NSLocationInRange(index, $0.range) }),
              let image = UIImage(contentsOfFile: entry.fileURL.path)
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
        return (image, textView.convert(contentRect, to: view))
    }

    @objc private func imageTapped(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended,
              let hit = image(at: gesture.location(in: textView)) else { return }
        let lightbox = ImageLightboxViewController(image: hit.image, sourceFrame: hit.frame)
        present(lightbox, animated: false)
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        image(at: touch.location(in: textView)) != nil
    }

    public func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let hit = image(at: location) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: [
                UIAction(title: "Copy Image", image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.image = hit.image
                },
                UIAction(title: "Save Image", image: UIImage(systemName: "square.and.arrow.down")) { _ in
                    UIImageWriteToSavedPhotosAlbum(hit.image, nil, nil, nil)
                },
            ])
        }
    }

    private func applyInitialScrollPosition() {
        // Carried in from another mode (plain scroll only): place that word 25%
        // from the top. Audio mode starts playback at the carried word and
        // follow-scroll centers it.
        if let resume = explicitResumeWordIndex, !audioEnabled,
           wordMap.attributedRange(forWord: resume) != nil {
            scrollWord(resume, toFractionFromTop: 0.25)
        } else if let saved = item.lastScrollOffset {
            restoreScroll(to: CGFloat(saved))
        }
        // Baseline for "has the user scrolled since opening?" (the carried
        // position must survive a plain open/close untouched).
        openContentOffsetY = textView.contentOffset.y
    }

    private func revealContent() {
        guard textView.alpha < 1 else { return }
        UIView.animate(withDuration: 0.15) { self.textView.alpha = 1 }
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
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
        if !didLoadFullContent {
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
            } else {
                // Plain scroll: optionally live-highlight the gaze word.
                SharedDiagnosticLog.record(
                    "reader opened (scroll): gazeTracker=\(gazeTracker != nil) highlightSetting=\(ReaderSettings.highlightGazeWord)",
                    category: "gaze")
                // On a progressive (long-article) open the tracker doesn't exist yet —
                // `installPositionDependentFeatures` starts the observation once Phase 2
                // creates it. Here we cover the short-article case (tracker already made).
                if gazeTracker != nil, !didStartGazeObservation {
                    didStartGazeObservation = true
                    observeGazeForCarryOver(alsoHighlight: ReaderSettings.highlightGazeWord)
                }
            }
        }
        publishVisibleLinkURLsIfNeeded()
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        gazeTracker?.onWordIndexChange = nil
        store.setLastScrollOffset(Double(textView.contentOffset.y), for: item.id)
        if textView.contentSize.height > 0 {
            let visibleBottom = textView.contentOffset.y + textView.bounds.height
            store.setReadingProgress(
                Double(visibleBottom / textView.contentSize.height), for: item.id)
        }
        if let position = speech?.currentWordIndex {
            store.setLastSpokenWordIndex(position, for: item.id)
        }
        if let gazeIndex = gazeTracker?.estimatedWordIndex {
            store.setEyeTrackedWordIndex(gazeIndex, for: item.id)
        }
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

        footerRateButton.setTitle("1×", for: .normal)
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

    /// First word to resume from: where playback left off, else the eye-tracked
    /// last-read word (only when a gaze tracker is active), else the first word
    /// currently visible on screen (so playback starts where the reader is
    /// looking, not the top of the article — matching behavior when eye
    /// tracking is off/unavailable or in the share sheet).
    private var resumeWordIndex: Int? {
        if let explicitResumeWordIndex {
            return explicitResumeWordIndex
        }
        if let resume = item.lastSpokenWordIndex {
            return resume
        }
        if let gazeTracker {
            return gazeTracker.estimatedWordIndex ?? item.eyeTrackedWordIndex
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
        let layoutManager = textView.layoutManager
        layoutManager.ensureLayout(for: textView.textContainer)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textView.textContainer)
        rect.origin.y += textView.textContainerInset.top
        let target = rect.minY - fraction * textView.bounds.height
        textView.contentOffset.y = clampedContentOffsetY(target)
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
        if speech == nil {
            let controller = SpeechController(
                content: content, rendered: rendered, wordMap: wordMap,
                title: content.title)
            controller.delegate = self
            speech = controller
        }
        followPlayback = true
        footer.isHidden = false
        layoutShareView()
        speech?.play(fromWordIndex: resumeWordIndex)
        // First-ever read-aloud: nudge the user toward higher-quality voices.
        // Non-blocking — playback above has already begun. No-op in extensions.
        VoiceFirstRunPrompt.showIfNeeded(from: self)
    }

    /// Observes the gaze tracker while in plain scroll mode: every estimate
    /// feeds the lock gate (so a stable multi-word lock — and only that — may
    /// move the carried reading position), and, when the live-highlight setting
    /// is on, also highlights the looked-at word (no auto-scroll — the page
    /// shouldn't jump as your eyes move).
    private var gazeHighlightLogCount = 0
    private func observeGazeForCarryOver(alsoHighlight: Bool) {
        if alsoHighlight {
            SharedDiagnosticLog.record("gaze highlight enabled", category: "gaze")
        }
        gazeTracker?.onWordIndexChange = { [weak self] index in
            guard let self else { return }
            self.gazeLockGate.record(index)
            // Throttled visibility into whether estimates are flowing.
            self.gazeHighlightLogCount += 1
            if self.gazeHighlightLogCount % 20 == 1 {
                SharedDiagnosticLog.record("gaze word index = \(index)", category: "gaze")
            }
            guard alsoHighlight,
                  let range = self.wordMap.attributedRange(forWord: index) else { return }
            self.applyHighlight(range)
        }
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
        updateShareFooterVisibility()
        publishVisibleLinkURLsIfNeeded()
        if scrollView.isTracking || scrollView.isDragging {
            // User-driven scroll: stop auto-follow; drop the resume highlight
            // only when nothing is actively playing.
            if speech?.isPlaying != true {
                removeHighlight()
            }
            followPlayback = false
        }
    }

    /// Links in and near the viewport, in document order. The rect is expanded above
    /// and below the current viewport so slow scrolls have prepared child VCs before
    /// the links enter the exact visible area, without preparing the whole article.
    private func visibleLinkURLs() -> [URL] {
        guard isViewLoaded, textView.bounds.width > 0, textView.textStorage.length > 0 else { return [] }
        textView.layoutManager.ensureLayout(for: textView.textContainer)
        let viewport = CGRect(
            x: 0,
            y: textView.contentOffset.y - textView.bounds.height,
            width: textView.bounds.width,
            height: textView.bounds.height * 3)
        var urls: [URL] = []
        var seen = Set<String>()
        let full = NSRange(location: 0, length: textView.textStorage.length)
        textView.textStorage.enumerateAttribute(.link, in: full) { value, range, _ in
            let url: URL?
            if let u = value as? URL { url = u }
            else if let s = value as? String { url = URL(string: s) }
            else { url = nil }
            guard let url else { return }
            let key = PreloadStore.key(for: url)
            guard seen.insert(key).inserted else { return }
            let glyphRange = textView.layoutManager.glyphRange(
                forCharacterRange: range, actualCharacterRange: nil)
            var rect = textView.layoutManager.boundingRect(
                forGlyphRange: glyphRange, in: textView.textContainer)
            rect.origin.x += textView.textContainerInset.left
            rect.origin.y += textView.textContainerInset.top
            if rect.intersects(viewport) { urls.append(url) }
        }
        return urls
    }

    private func publishVisibleLinkURLsIfNeeded(force: Bool = false) {
        let urls = visibleLinkURLs()
        let keys = Set(urls.map { PreloadStore.key(for: $0) })
        guard force || keys != lastVisibleLinkKeys else { return }
        lastVisibleLinkKeys = keys
        onVisibleLinkURLsChanged?(urls)
    }

    /// Notifies the host when the end-of-article share footer is at least partly
    /// scrolled into view (it sits just below the text, in the bottom inset region).
    private func updateShareFooterVisibility() {
        // The footer is only attached/positioned once the full content is in (otherwise
        // its frame is still .zero and would read as "revealed" against the prefix).
        guard didLoadFullContent, let shareView, shareView.superview != nil else { return }
        let viewportBottom = textView.contentOffset.y + textView.bounds.height
        let revealed = viewportBottom >= shareView.frame.minY + shareView.bounds.height * 0.3
        guard revealed != shareFooterVisible else { return }
        shareFooterVisible = revealed
        onShareFooterVisibilityChanged?(revealed)
    }

    private func checkFinishedReading() {
        // Never decide "finished" against the PREFIX content size — a long article
        // whose prefix happens to fit one screen would be wrongly marked read before
        // Phase 2 expands it. Wait for the full content.
        guard didLoadFullContent, !didFinishReading, textView.contentSize.height > 0 else { return }
        let visibleBottom = textView.contentOffset.y + textView.bounds.height
        if visibleBottom >= textView.contentSize.height - 40 {
            didFinishReading = true
            onFinishedReading?()
        }
    }

    // MARK: - Link taps → split

    public func textView(
        _ textView: UITextView,
        primaryActionFor textItem: UITextItem,
        defaultAction: UIAction
    ) -> UIAction? {
        if case .link(let url) = textItem.content {
            return UIAction { [weak self] _ in
                guard let self else { return }
                if let onLinkActivated = self.onLinkActivated {
                    onLinkActivated(url)
                } else {
                    self.openSplit(for: url, tappedRange: textItem.range)
                }
            }
        }
        return defaultAction
    }

    /// Long-press on an inline link → save or share that link.
    public func textView(
        _ textView: UITextView,
        menuConfigurationFor textItem: UITextItem,
        defaultMenu: UIMenu
    ) -> UITextItem.MenuConfiguration? {
        guard case .link(let url) = textItem.content else {
            return UITextItem.MenuConfiguration(menu: defaultMenu)
        }
        let save = UIAction(title: "Save to Queue", image: UIImage(systemName: "plus.circle")) { [weak self] _ in
            self?.shareProvider?.saveLink(urlString: url.absoluteString)
        }
        let share = UIAction(title: "Share Link…", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
            guard let self else { return }
            let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            activity.popoverPresentationController?.sourceView = self.textView
            self.present(activity, animated: true)
        }
        // Only offer Save when there's a provider to save through.
        let custom = shareProvider != nil ? [save, share] : [share]
        return UITextItem.MenuConfiguration(menu: UIMenu(children: custom + defaultMenu.children))
    }

    /// Opens the tapped link inline: the article splits at the link's line — the
    /// line above parks as a top peek, the link's line as a bottom peek — and an
    /// inset glass card grows between them showing the linked page.
    private func openSplit(for url: URL, tappedRange: NSRange) {
        let layoutManager = textView.layoutManager
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: tappedRange, actualCharacterRange: nil)
        var lineRect = layoutManager.lineFragmentRect(
            forGlyphAt: glyphRange.location, effectiveRange: nil)
        lineRect.origin.y += textView.textContainerInset.top

        // The cut is at the TOP of the link's line, in WINDOW coordinates (the
        // overlay is full-screen, so window y == overlay y). `lineRect.minY` is a
        // CONTENT-space y; `convert` already accounts for the scroll offset (the
        // text view's bounds origin IS its contentOffset), so pass it straight
        // through — pre-subtracting contentOffset would double-count it and push the
        // cut up the screen the more the article is scrolled.
        let rawCutY = textView.convert(CGPoint(x: 0, y: lineRect.minY), to: nil).y
        let readerOffset = textView.contentOffset.y

        // Bottom of the outer header in window coords. The cut must stay at or below
        // this so neither peek snapshot ever captures a slice of the nav bar (which
        // would show as a frozen, clipped copy of the mode header). The text view's
        // top edge in the window is its frame origin mapped through its (non-scrolling)
        // superview — `textView.convert(.zero)` would instead fold in the scroll
        // offset. Combine with the nav bar's own frame: the content can sit under a
        // translucent bar, so the frame top alone can underestimate the header.
        let contentTopY = textView.superview?.convert(textView.frame.origin, to: nil).y ?? 0
        let navBar = (parent as? ReaderViewController)?.navigationController?.navigationBar
        let navBarMaxY = navBar.map { bar in bar.convert(bar.bounds, to: nil).maxY }
        let headerBottomY = max(contentTopY, navBarMaxY ?? contentTopY)

        var topHalf: UIView?
        var bottomHalf: UIView?
        var cutY = rawCutY
        if let window = view.window {
            let bounds = window.bounds
            let safe = window.safeAreaInsets
            let lineHeight = lineRect.height
            // Clamp the cut so a full one-line peek fits below the header and above
            // the home indicator — and so the snapshots are captured AT the clamped
            // cut (no later resize/glitch when the tapped link is very high or low).
            let cutCeiling = max(headerBottomY + lineHeight, safe.top + lineHeight)
            cutY = min(max(rawCutY, cutCeiling), bounds.height - safe.bottom - lineHeight)
            // Both peeks capture ONLY the reader content (from below the header): the
            // live header is tucked / covered separately, so excluding it here avoids
            // a frozen second copy that would diverge from the animating live one.
            topHalf = window.resizableSnapshotView(
                from: CGRect(x: 0, y: headerBottomY, width: bounds.width,
                             height: max(cutY - headerBottomY, 1)),
                afterScreenUpdates: false, withCapInsets: .zero)
            bottomHalf = window.resizableSnapshotView(
                from: CGRect(x: 0, y: cutY, width: bounds.width,
                             height: max(bounds.height - cutY, 1)),
                afterScreenUpdates: false, withCapInsets: .zero)
        }

        let overlay = SplitWebOverlayViewController(
            url: url, shareProvider: shareProvider, lineHeight: lineRect.height,
            cutY: cutY, topHalf: topHalf, bottomHalf: bottomHalf)
        overlay.modalPresentationStyle = .overFullScreen
        // Slide the outer header off-screen while the inline reader is open.
        let outerReader = parent as? ReaderViewController
        overlay.onOpen = { outerReader?.setHeaderTucked(true) }
        overlay.onClose = { outerReader?.setHeaderTucked(false) }
        overlay.onDismiss = { [weak self] in self?.restoreScroll(to: readerOffset) }
        present(overlay, animated: false)
    }

    // MARK: - Simulator-only split hooks

    /// The blitz harness can't tap an exact inline link, so in the simulator two
    /// buttons trigger `openSplit` with the cut placed high or low on screen — the
    /// two cases that exercise the inline-reader open animation + header tucking.
    private func addSimulatorSplitHooksIfNeeded() {
        #if targetEnvironment(simulator)
        // Suppress these debug buttons during deterministic screenshot captures so
        // they don't overlay the article text; interactive automation still gets them.
        // Suppressed during deterministic UI-test launches (matches UITestLaunch.isActive,
        // which lives in the app target — inlined here to avoid an upward dependency).
        let uiTestArgs = ["-uiTestState", "-uiTestScreen", "-uiTestOnboardingStep"]
        if ProcessInfo.processInfo.arguments.contains(where: uiTestArgs.contains) { return }
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
        let top = hookButton("Split High", fraction: 0.12)
        let bottom = hookButton("Split Low", fraction: 0.82)
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
        didFinishReading = true
        onFinishedReading?()
        footerPlayButton.configuration?.image = UIImage(systemName: "play.fill")
        removeHighlight()
    }
}

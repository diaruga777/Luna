//
//  ScrollReaderViewController.swift
//  Clip
//

import UIKit

/// Full-screen scrolling text reader. Tapping an inline link "cuts" the text at
/// that line and parts it vertically to reveal the link inline (nested reader
/// or web frame — see SplitWebOverlayViewController). Supports read-aloud with
/// word highlighting + follow-scroll, remembers the scroll position, and
/// estimates the last-read word via eye tracking on supported devices.
final class ScrollReaderViewController: UIViewController, UITextViewDelegate, ReaderPositionTracking {

    /// Fired once when the user reaches the end of the article.
    var onFinishedReading: (() -> Void)?

    /// A word index carried in from another reader mode. When set (and this is
    /// the plain scrolling mode), the view scrolls so that word sits 25% from
    /// the top on first appearance instead of restoring the saved offset.
    private let explicitResumeWordIndex: Int?

    private let item: ReadingListItem
    private let content: ArticleContent
    private let rendered: RenderedArticle
    private let wordMap: WordMap
    private let textView = UITextView()
    private let store = ReadingListStore.shared
    private var didFinishReading = false
    private var didRestoreScroll = false

    /// Auto-advancing chunk highlight (the "highlight" reader mode).
    private let autoHighlight: Bool
    /// Read aloud while highlighting (the shared audio toggle).
    private let audioEnabled: Bool
    private var didStartPlayback = false

    // Read-aloud (audio) and chunk-highlight (silent) playback — at most one is
    // active per instance, selected by audioEnabled / autoHighlight.
    private var speech: SpeechController?
    private var chunk: ChunkHighlightController?
    private let footer = UIVisualEffectView(effect: GlassStyle.barEffect())
    private let footerPlayButton = UIButton(type: .system)
    private let footerRateButton = UIButton(type: .system)
    private var highlightedRange: NSRange?
    private var followPlayback = true

    // Eye tracking (nil unless a gaze factory provided one — never in the sheet).
    private var gazeTracker: GazeTracking?
    private let gazeTrackerFactory: GazeTrackerFactory?
    /// Live highlight of the word the gaze tracker thinks you're reading (opt-in).
    private var gazeHighlightTimer: Timer?

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

    init(item: ReadingListItem, content: ArticleContent,
         autoHighlight: Bool = false, audioEnabled: Bool = false,
         shareProvider: ReaderShareProviding? = nil,
         gazeTrackerFactory: GazeTrackerFactory? = nil,
         resumeWordIndex: Int? = nil) {
        self.item = item
        self.content = content
        self.autoHighlight = autoHighlight
        self.audioEnabled = audioEnabled
        self.shareProvider = shareProvider
        self.gazeTrackerFactory = gazeTrackerFactory
        self.explicitResumeWordIndex = resumeWordIndex
        self.rendered = ArticleTextRenderer.render(content)
        self.wordMap = WordMap(content: content, rendered: rendered)
        super.init(nibName: nil, bundle: nil)
    }

    /// The word currently being read — read-aloud / chunk position when playing,
    /// else the eye-tracked word, else the first word fully visible on screen.
    /// Carried to other modes on a switch.
    var currentReadingWordIndex: Int? {
        if let speech, let word = speech.currentWordIndex { return word }
        if let chunk, let word = chunk.currentWordIndex { return word }
        if let gaze = gazeTracker?.estimatedWordIndex { return gaze }
        return firstFullyVisibleWordIndex()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        speech?.stop()
        chunk?.stop()
        gazeTracker?.stop()
        gazeHighlightTimer?.invalidate()
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
            })
    }

    /// Positions the share view just below the text content and reserves scroll
    /// room for it (and the floating footer) so it clears the controls.
    private func layoutShareView() {
        guard let shareView else { return }
        let width = textView.bounds.width
        guard width > 0 else { return }
        let height = shareView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel).height
        shareView.frame = CGRect(x: 0, y: textView.contentSize.height, width: width, height: height)
        let footerSpace = footer.isHidden ? 0 : footer.bounds.height
        textView.contentInset.bottom = height + footerSpace
    }

    override func viewDidLoad() {
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

        configureFooter()

        if let shareView {
            textView.addSubview(shareView)
            contentSizeObservation = textView.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
                self?.layoutShareView()
            }
        }

        // Force full text layout shortly after first paint: one early hitch
        // while the user starts reading, so link taps / split dismissals later
        // never stall on a whole-article layout pass.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.textView.layoutManager.ensureLayout(for: self.textView.textContainer)
        }

        // Where read-aloud left off, shown until the user scrolls.
        if let spokenIndex = item.lastSpokenWordIndex,
           let range = wordMap.attributedRange(forWord: spokenIndex) {
            applyHighlight(range)
        }

        gazeTracker = gazeTrackerFactory?(textView, wordMap, item.eyeTrackedWordIndex)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Keep the text in a readable column on wide screens (iPad / landscape).
        let horizontal = max(20, (view.bounds.width - 680) / 2)
        if abs(textView.textContainerInset.left - horizontal) > 0.5 {
            textView.textContainerInset = UIEdgeInsets(
                top: 20, left: horizontal, bottom: 40, right: horizontal)
        }
        layoutShareView()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !didRestoreScroll {
            didRestoreScroll = true
            // Carried in from another mode (plain scroll only): place that word
            // 25% from the top. Highlight/audio modes instead start playback at
            // the carried word and follow-scroll centers it.
            if let resume = explicitResumeWordIndex, !autoHighlight, !audioEnabled,
               wordMap.attributedRange(forWord: resume) != nil {
                scrollWord(resume, toFractionFromTop: 0.25)
            } else if let saved = item.lastScrollOffset {
                restoreScroll(to: CGFloat(saved))
            }
        }
        // An article that fits on one screen can never scroll — seeing it at
        // all means it's been read.
        checkFinishedReading()

        // Start playback once: read-aloud when audio is on, otherwise the
        // chunk-highlight when this is the highlight mode. Plain scroll does
        // neither.
        if !didStartPlayback {
            didStartPlayback = true
            if audioEnabled {
                startSpeech()
            } else if autoHighlight {
                startChunkHighlight()
            } else if gazeTracker != nil, ReaderSettings.highlightGazeWord {
                // Plain scroll with eye tracking: live-highlight the gaze word.
                startGazeHighlight()
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        gazeHighlightTimer?.invalidate()
        gazeHighlightTimer = nil
        store.setLastScrollOffset(Double(textView.contentOffset.y), for: item.id)
        if textView.contentSize.height > 0 {
            let visibleBottom = textView.contentOffset.y + textView.bounds.height
            store.setReadingProgress(
                Double(visibleBottom / textView.contentSize.height), for: item.id)
        }
        if let position = speech?.currentWordIndex ?? chunk?.currentWordIndex {
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
        let minOffset = -textView.adjustedContentInset.top
        let maxOffset = max(
            minOffset,
            textView.contentSize.height + textView.adjustedContentInset.bottom - textView.bounds.height)
        textView.contentOffset.y = min(max(minOffset, target), maxOffset)
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
    }

    private func startChunkHighlight() {
        if chunk == nil {
            let controller = ChunkHighlightController(content: content, wordMap: wordMap)
            controller.delegate = self
            chunk = controller
        }
        followPlayback = true
        footer.isHidden = false
        layoutShareView()
        footerRateButton.setTitle(chunk?.speedLabel, for: .normal)
        chunk?.play(fromWordIndex: resumeWordIndex)
    }

    /// Periodically highlights the word the gaze tracker estimates you're
    /// reading. No auto-scroll — the page shouldn't jump as your eyes move.
    private func startGazeHighlight() {
        gazeHighlightTimer = Timer.scheduledTimer(
            withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self, let index = self.gazeTracker?.estimatedWordIndex,
                  let range = self.wordMap.attributedRange(forWord: index) else { return }
            self.applyHighlight(range)
        }
    }

    @objc private func togglePlayback() {
        followPlayback = true
        if let chunk { chunk.togglePlayPause() } else { speech?.togglePlayPause() }
    }

    @objc private func skipBack() {
        followPlayback = true
        if let chunk { chunk.skipBackward() } else { speech?.skipBackward() }
    }

    @objc private func skipForward() {
        followPlayback = true
        if let chunk { chunk.skipForward() } else { speech?.skipForward() }
    }

    @objc private func cycleRate() {
        if let chunk { chunk.cycleSpeed() } else { speech?.cycleRate() }
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
        let minOffset = -textView.adjustedContentInset.top
        let maxOffset = max(minOffset, textView.contentSize.height - textView.bounds.height)
        let clamped = min(max(minOffset, target), maxOffset)
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveLinear, .allowUserInteraction]) {
            self.textView.contentOffset.y = clamped
        }
    }

    // MARK: - Read tracking

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        checkFinishedReading()
        if scrollView.isTracking || scrollView.isDragging {
            // User-driven scroll: stop auto-follow; drop the resume highlight
            // only when nothing is actively playing.
            if speech?.isPlaying != true && chunk?.isPlaying != true {
                removeHighlight()
            }
            followPlayback = false
        }
    }

    private func checkFinishedReading() {
        guard !didFinishReading, textView.contentSize.height > 0 else { return }
        let visibleBottom = textView.contentOffset.y + textView.bounds.height
        if visibleBottom >= textView.contentSize.height - 40 {
            didFinishReading = true
            onFinishedReading?()
        }
    }

    // MARK: - Link taps → split

    func textView(
        _ textView: UITextView,
        primaryActionFor textItem: UITextItem,
        defaultAction: UIAction
    ) -> UIAction? {
        if case .link(let url) = textItem.content {
            return UIAction { [weak self] _ in
                self?.openSplit(for: url, tappedRange: textItem.range)
            }
        }
        return defaultAction
    }

    private func openSplit(for url: URL, tappedRange: NSRange) {
        // Geometry of the tapped link: its full line fragment (the cut happens
        // around that line) and the link text's own rect (anchors the notch),
        // both in text-view content coordinates.
        let layoutManager = textView.layoutManager
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: tappedRange, actualCharacterRange: nil)
        var lineRect = layoutManager.lineFragmentRect(
            forGlyphAt: glyphRange.location, effectiveRange: nil)
        var linkRect = layoutManager.boundingRect(
            forGlyphRange: glyphRange, in: textView.textContainer)
        lineRect.origin.y += textView.textContainerInset.top
        linkRect.origin.y += textView.textContainerInset.top
        linkRect.origin.x += textView.textContainerInset.left

        // Snapshots of the on-screen halves drive the part-open animation —
        // pixel-perfect and free of any text re-layout. Both include the
        // link's full line, so parting them replicates it on each side.
        let readerOffset = textView.contentOffset.y
        let cutBottomScreen = lineRect.maxY - readerOffset
        let cutTopScreen = lineRect.minY - readerOffset
        let width = view.bounds.width
        let height = view.bounds.height
        let topSnapshot = view.resizableSnapshotView(
            from: CGRect(x: 0, y: 0, width: width, height: max(cutBottomScreen, 1)),
            afterScreenUpdates: false, withCapInsets: .zero)
        let bottomSnapshot = view.resizableSnapshotView(
            from: CGRect(x: 0, y: cutTopScreen, width: width,
                         height: max(height - cutTopScreen, 1)),
            afterScreenUpdates: false, withCapInsets: .zero)

        textView.layoutManager.ensureLayout(for: textView.textContainer)
        let overlay = SplitWebOverlayViewController(
            url: url,
            articleText: textView.attributedText,
            lineRect: lineRect,
            linkRect: linkRect,
            linkRange: tappedRange,
            readerOffset: readerOffset,
            textHeight: textView.contentSize.height,
            topSnapshot: topSnapshot,
            bottomSnapshot: bottomSnapshot,
            depth: 0)
        overlay.modalPresentationStyle = .overFullScreen
        overlay.onDismiss = { [weak self] restoredOffset in
            self?.restoreScroll(to: restoredOffset)
        }
        present(overlay, animated: false)
    }

    /// Restores the reader to a content offset handed back by the split overlay.
    /// Forces full text layout first — the text view lays out lazily, and
    /// clamping against a not-yet-final contentSize breaks scrolling.
    private func restoreScroll(to offset: CGFloat) {
        textView.layoutManager.ensureLayout(for: textView.textContainer)
        textView.layoutIfNeeded()
        let minOffset = -textView.adjustedContentInset.top
        let maxOffset = max(
            minOffset,
            textView.contentSize.height + textView.adjustedContentInset.bottom
                - textView.bounds.height)
        textView.contentOffset.y = min(max(minOffset, offset), maxOffset)
    }
}

// MARK: - SpeechControllerDelegate

extension ScrollReaderViewController: SpeechControllerDelegate {
    func speech(_ controller: SpeechController, willSpeakAttributedRange range: NSRange, wordIndex: Int?) {
        applyHighlight(range)
        if followPlayback {
            scrollToCenter(range)
        }
    }

    func speechPlaybackStateDidChange(_ controller: SpeechController) {
        let icon = controller.isPlaying ? "pause.fill" : "play.fill"
        footerPlayButton.configuration?.image = UIImage(systemName: icon)
        let factor = controller.rateFactor
        footerRateButton.setTitle(
            factor == 1.0 ? "1×" : String(format: "%.1f×", factor), for: .normal)
        if !controller.isPlaying, let word = controller.currentWordIndex {
            store.setLastSpokenWordIndex(word, for: item.id)
        }
    }

    func speechDidFinishArticle(_ controller: SpeechController) {
        didFinishReading = true
        onFinishedReading?()
        footerPlayButton.configuration?.image = UIImage(systemName: "play.fill")
        removeHighlight()
    }
}

// MARK: - ChunkHighlightControllerDelegate

extension ScrollReaderViewController: ChunkHighlightControllerDelegate {
    func chunkHighlight(
        _ controller: ChunkHighlightController, willHighlight range: NSRange, wordIndex: Int
    ) {
        applyHighlight(range)
        if followPlayback {
            scrollToCenter(range)
        }
    }

    func chunkHighlightStateDidChange(_ controller: ChunkHighlightController) {
        let icon = controller.isPlaying ? "pause.fill" : "play.fill"
        footerPlayButton.configuration?.image = UIImage(systemName: icon)
        footerRateButton.setTitle(controller.speedLabel, for: .normal)
        if !controller.isPlaying, let word = controller.currentWordIndex {
            store.setLastSpokenWordIndex(word, for: item.id)
        }
    }

    func chunkHighlightDidFinish(_ controller: ChunkHighlightController) {
        didFinishReading = true
        onFinishedReading?()
        footerPlayButton.configuration?.image = UIImage(systemName: "play.fill")
        removeHighlight()
    }
}

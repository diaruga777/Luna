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
final class ScrollReaderViewController: UIViewController, UITextViewDelegate {

    /// Fired once when the user reaches the end of the article.
    var onFinishedReading: (() -> Void)?

    private let item: ReadingListItem
    private let content: ArticleContent
    private let rendered: RenderedArticle
    private let wordMap: WordMap
    private let textView = UITextView()
    private let store = ReadingListStore.shared
    private var didFinishReading = false
    private var didRestoreScroll = false

    // Read-aloud
    private var speech: SpeechController?
    private let speakButton = UIButton(type: .system)
    private let footer = UIVisualEffectView(effect: GlassStyle.barEffect())
    private let footerPlayButton = UIButton(type: .system)
    private let footerRateButton = UIButton(type: .system)
    private var highlightedRange: NSRange?
    private var followPlayback = true

    // Eye tracking
    private var gazeTracker: EyeGazeWordTracker?

    private let highlightColor = UIColor.systemBlue.withAlphaComponent(0.3)

    init(item: ReadingListItem, content: ArticleContent) {
        self.item = item
        self.content = content
        self.rendered = ArticleTextRenderer.render(content)
        self.wordMap = WordMap(content: content, rendered: rendered)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        speech?.stop()
        gazeTracker?.stop()
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

        configureSpeakButton()
        configureFooter()

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

        if ReaderSettings.eyeTrackingEnabled {
            gazeTracker = EyeGazeWordTracker(
                textView: textView, wordMap: wordMap, seedWordIndex: item.eyeTrackedWordIndex)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !didRestoreScroll {
            didRestoreScroll = true
            if let saved = item.lastScrollOffset {
                restoreScroll(to: CGFloat(saved))
            }
        }
        // An article that fits on one screen can never scroll — seeing it at
        // all means it's been read.
        checkFinishedReading()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        store.setLastScrollOffset(Double(textView.contentOffset.y), for: item.id)
        if textView.contentSize.height > 0 {
            let visibleBottom = textView.contentOffset.y + textView.bounds.height
            store.setReadingProgress(
                Double(visibleBottom / textView.contentSize.height), for: item.id)
        }
        if let spoken = speech?.currentWordIndex {
            store.setLastSpokenWordIndex(spoken, for: item.id)
        }
        if ReaderSettings.eyeTrackingEnabled, let gazeIndex = gazeTracker?.estimatedWordIndex {
            store.setEyeTrackedWordIndex(gazeIndex, for: item.id)
        }
    }

    // MARK: - Read-aloud UI

    private func configureSpeakButton() {
        speakButton.configuration = GlassStyle.circularButtonConfiguration(
            symbol: "speaker.wave.2.fill", padding: 12)
        speakButton.addTarget(self, action: #selector(startSpeech), for: .touchUpInside)
        speakButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(speakButton)
        NSLayoutConstraint.activate([
            speakButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            speakButton.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])
    }

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

    @objc private func startSpeech() {
        if speech == nil {
            let controller = SpeechController(
                content: content, rendered: rendered, wordMap: wordMap,
                title: content.title)
            controller.delegate = self
            speech = controller
        }
        // Resume where audio left off; on the very first playback, start from
        // the eye-tracked last-read word when available.
        let startWord: Int?
        if let resume = item.lastSpokenWordIndex {
            startWord = resume
        } else if ReaderSettings.eyeTrackingEnabled {
            startWord = gazeTracker?.estimatedWordIndex ?? item.eyeTrackedWordIndex
        } else {
            startWord = nil
        }
        followPlayback = true
        speech?.play(fromWordIndex: startWord)
        speakButton.isHidden = true
        footer.isHidden = false
    }

    @objc private func togglePlayback() {
        speech?.togglePlayPause()
        followPlayback = true
    }

    @objc private func skipBack() {
        speech?.skipBackward()
        followPlayback = true
    }

    @objc private func skipForward() {
        speech?.skipForward()
        followPlayback = true
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
            // User-driven scroll: drop the resume highlight, stop auto-follow.
            if speech?.isPlaying != true {
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

//
//  RSVPViewController.swift
//  Luna
//

import LunaAudioPlayback
import LunaReaderEngine
import LunaDesignSystem
import LunaStorage
import LunaModels
import AVFoundation
import UIKit

/// RSVP speed reader, ReadMaxx-style, with two sub-modes selectable from a
/// segmented control below the top-level reader switcher:
///
/// - **Words**: one word at a time on a fixed focal column, the ORP letter tinted
///   in the reading accent, word-length-aware timing — the classic RSVP view.
/// - **Phrases**: a whole phrase (the former chunk-highlight engine) shown over
///   two lines in a glass focus panel, with the surrounding prose always visible
///   above and below and updating as the phrase advances. The phrase boundaries
///   and per-phrase timing follow speed-reading practice (`ChunkPlanner`).
///
/// Both sub-modes share the focal-word index (so switching keeps your place),
/// the scrubber / ±25-word skip / ±25 wpm controls, and an optional read-aloud
/// mode where speech paces the display (and, in Phrases, highlights the spoken
/// word within the phrase) instead of the WPM timer.
public final class RSVPViewController: UIViewController, ReaderPositionTracking {

    public weak var completionDelegate: ReaderCompletionDelegate?

    /// When set, the link pill hands the tapped link (and the pill's center, in this
    /// reader's coordinates) to this closure instead of presenting a new inline split
    /// overlay — used by the inline reader to push the link onto its own navigation
    /// stack rather than nesting another overlay.
    public var onLinkActivatedAtPoint: ((_ url: URL, _ point: CGPoint) -> Void)?

    /// Fired whenever playback starts (true) or stops (false) — every path:
    /// tap, controls, scrubbing, read-aloud via the playback center. The
    /// Reader card carousel fades its chrome away while RSVP is playing and
    /// back in when it pauses.
    public var onPlaybackStateChanged: ((Bool) -> Void)?

    private var item: ReadingListItem
    private var engine: RSVPEngine
    /// Phrase groupings over the same word space, built once (lazily) when the
    /// reader first needs the Phrases sub-mode.
    private var chunks: [TextChunk]
    private let store = ReadingListStore.shared

    /// Words vs Phrases. Persisted in `ReaderSettings.rsvpMode`.
    private var displayMode: RSVPDisplayMode

    private var currentIndex = 0
    /// Index into `chunks` of the phrase currently shown (Phrases mode only).
    private var currentChunkIndex = 0
    public private(set) var isPlaying = false {
        didSet {
            updatePlayPauseGlyph()
            if isPlaying != oldValue { onPlaybackStateChanged?(isPlaying) }
        }
    }
    /// The Phrases sub-mode's chunk timer (`scheduleNextChunk`/`advanceChunk`).
    /// The Words sub-mode's timer is `wordClock` below — the two stay separate
    /// low-level timers because only the words-mode one is shared with the
    /// link preview.
    private var timer: Timer?
    private var intervalStart: Date?
    private var intervalDuration: TimeInterval?
    /// Drives the Words sub-mode's per-word advance — shared with
    /// `LinkRSVPPreview`'s own word timer (see `RSVPPlaybackClock`).
    private lazy var wordClock: RSVPPlaybackClock = {
        let clock = RSVPPlaybackClock()
        clock.delegate = self
        return clock
    }()
    private var wpm: Double = ReaderSettings.baseWPM

    // Read-aloud pacing: when on, whole sentences are spoken (natural prosody,
    // normal pace) and the display flashes each word as it's voiced — the WPM
    // setting is ignored.
    private var isSpeechMode: Bool

    // MARK: Center-driven read-aloud (in-app only — see ReaderAudioLauncher)

    /// The article content, retained so speech mode can hand it to the
    /// app-wide playback center (the RSVP engine consumes the content at init;
    /// the center needs the original blocks).
    private var articleContent: ArticleContent
    /// Lazily built per-block token starts, for mapping the center's word
    /// events (original block index + in-block UTF-16 range) into the engine's
    /// shared token space. Invalidated on `configureForReuse`.
    private var blockTokenStartsCache: [Int]?

    /// Non-nil when speech mode should be driven by the app-wide playback
    /// center (in-app) instead of the private per-sentence synthesizer
    /// (extensions, where the seam is never installed). Silent (timer) mode
    /// never touches either.
    private var speechCenter: AudioPlaybackCenter? {
        isSpeechMode ? ReaderAudioLauncher.center : nil
    }

    /// Whether the center currently owns playback of THIS reader's article.
    private var centerOwnsItem: Bool {
        guard let center = speechCenter else { return false }
        return center.currentItemInfo?.itemID == item.id
    }
    /// Created lazily so the SILENT speed reader never instantiates a speech
    /// synthesizer — instantiating one can claim the system audio session and
    /// interrupt other audio (e.g. Picture-in-Picture video). Only read-aloud
    /// mode ever touches it.
    private lazy var synthesizer: AVSpeechSynthesizer = {
        let synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = self
        return synthesizer
    }()
    /// First word index of the sentence currently being spoken.
    private var speechSentenceBase = 0
    /// UTF-16 offset of each word within the current utterance string.
    private var speechWordOffsets: [Int] = []

    /// Set by hosts whose chrome floats outside this reader. RSVP intentionally
    /// IGNORES it for layout: unlike the scroll reader (which scrolls content
    /// behind the floating header), the speed reader centers a single word and
    /// makes no use of the extra top space, so its layout must be identical with
    /// or without the card chrome. Kept only so the shared host wiring can set it.
    public var topContentInset: CGFloat = 0

    private let wordLabel = UILabel()
    /// Multi-line phrase text shown in the focus panel in Phrases mode.
    private let phraseLabel = UILabel()
    /// Surrounding prose. In Words mode this is only visible while paused (so the
    /// single-word focus isn't diluted during playback); in Phrases mode it's
    /// ALWAYS visible and updates as the phrase advances, so the reader keeps the
    /// thread of the sentence.
    private let previousContextLabel = UILabel()
    private let nextContextLabel = UILabel()
    /// Glass reticule marks above and below the ORP letter (Words mode) — the
    /// focal column's sights, so the eye has something to rest on between words.
    private let reticuleTop = GlassStyle.reticuleMark()
    private let reticuleBottom = GlassStyle.reticuleMark()
    /// Glass panel behind the two-line phrase (Phrases mode).
    private let phrasePanel = GlassStyle.focusPanel()
    private let playPauseButton = UIButton(type: .system)
    private let scrubber = UISlider()
    private let controlsStack = UIStackView()
    /// Sharing affordances; nil → the end-of-article share view never reveals.
    private var shareProvider: ReaderShareProviding?
    /// Revealed (above the controls) when the reader reaches the end.
    private lazy var shareView = makeShareView()
    private var didRevealShare = false
    private var finishedReadingTracker = FinishedReadingTracker()
    private let finishedBadge = FinishedReadingBadgeView()
    private let statusLabel = UILabel()
    private let wpmDownButton = UIButton(type: .system)
    private let wpmUpButton = UIButton(type: .system)
    private let skipBackButton = UIButton(type: .system)
    private let skipForwardButton = UIButton(type: .system)

    /// Words a skip button jumps from the current position.
    private static let skipWordCount = 25

    private let sentenceHaptic = UIImpactFeedbackGenerator(style: .light)

    /// A glass pill below the word showing the link of the currently-displayed
    /// linkified word; tapping it opens the inline reader. Persists while link
    /// words show, plus a short buffer afterward.
    private let linkPill = UIButton(type: .system)
    private var linkPillURL: URL?
    private var linkPillHideTimer: Timer?
    private var linkPreviewInteraction: LinkRSVPPreviewInteraction?
    private var wasPlayingBeforeLinkPreview = false
    /// Tapping anywhere pauses playback; starting again requires the explicit
    /// play button, so a stray tap can't kick the reader into motion.
    private let pauseTap = UITapGestureRecognizer()
    /// Press-and-hold on the display area halves playback speed until release;
    /// applies only to the silent WPM/chunk timer — read-aloud paces itself via TTS.
    private let pressAndHoldGesture = UILongPressGestureRecognizer()
    private var isSpeedHeld = false

    /// Horizontal position of the focal (ORP) column, as a fraction of width.
    private static let focalFraction: CGFloat = 0.4
    /// Target characters visible on one line — the font is sized so a word this
    /// long fits, and longer words split (`WordSplitter`).
    private static let targetCharactersAcross = 15
    private static let contextWordCount = 55
    /// Vertical center of the focal word / phrase. It is derived from the actual
    /// space between the title-aware mode switcher and the playback controls so a
    /// tall title header can never push the reading display over the controls.
    private var focalCenterY: CGFloat {
        let top = view.safeAreaInsets.top + 18
        let controlsTop = controlsStack.frame.minY > 0
            ? controlsStack.frame.minY
            : view.safeAreaLayoutGuide.layoutFrame.maxY - 140
        // Keep the link/completion lane below the focused content, and — in
        // Words mode — the upper reticule mark (which reaches 60pt above the
        // centre, see `layoutReticule`) clear of the title header above.
        let lowerClearance: CGFloat = displayMode == .phrases ? 104 : 106
        let upperClearance: CGFloat = displayMode == .phrases ? 54 : 66
        let minimumCenter = top + upperClearance
        let maximumCenter = controlsTop - 12 - lowerClearance
        guard maximumCenter >= minimumCenter else {
            return (top + controlsTop) / 2
        }
        return min(max(view.bounds.midY - 40, minimumCenter), maximumCenter)
    }

    /// Sized at init from the device width so `targetCharactersAcross`
    /// characters fit beside the focal column without running off-screen.
    private let wordFont: UIFont
    /// Smaller, proportional font for the two-line phrase display.
    private let phraseFont: UIFont

    public init(item: ReadingListItem, content: ArticleContent, audioEnabled: Bool = false,
         shareProvider: ReaderShareProviding? = nil, resumeWordIndex: Int? = nil,
         initialDisplayMode: RSVPDisplayMode? = nil) {
        self.item = item
        self.isSpeechMode = audioEnabled
        self.articleContent = content
        self.shareProvider = shareProvider
        self.displayMode = initialDisplayMode ?? ReaderSettings.rsvpMode
        // Cap the sizing width so the word/font stays readable on wide screens
        // (iPad / landscape) rather than scaling up to the full display width.
        let sizingWidth = min(UIScreen.main.bounds.width, 600)
        self.wordFont = Self.makeWordFont(forWidth: sizingWidth)
        self.phraseFont = Self.makePhraseFont(from: wordFont)
        self.engine = RSVPEngine(
            content: content, maxCharactersPerWord: Self.targetCharactersAcross)
        self.chunks = ChunkPlanner.chunks(words: self.engine.words)
        super.init(nibName: nil, bundle: nil)
        currentIndex = resolveResumeFrame(carriedOver: resumeWordIndex)
    }

    /// Initial frame from the shared token-space resume sources, in priority
    /// order: the position carried over from another reader mode, then the item's
    /// persisted position. Both are TOKEN indices — `frameIndex(forTokenIndex:)`
    /// converts into RSVP frame space, which gains an extra frame per long-word
    /// split part.
    private func resolveResumeFrame(carriedOver: Int?) -> Int {
        if let resume = carriedOver, let frame = engine.frameIndex(forTokenIndex: resume) {
            return frame
        }
        if let resume = item.lastWordIndex, let frame = engine.frameIndex(forTokenIndex: resume) {
            return frame
        }
        return 0
    }

    /// Reuses an already-built RSVP shell with new article content. RabbitHole calls
    /// this on a pre-added child, so activation only rebuilds the word engine and
    /// refreshes labels instead of constructing the full controls hierarchy.
    public func configureForReuse(
        item: ReadingListItem,
        content: ArticleContent,
        audioEnabled: Bool = false,
        shareProvider: ReaderShareProviding? = nil,
        resumeWordIndex: Int? = nil,
        initialDisplayMode: RSVPDisplayMode? = nil
    ) {
        resetTransientState()
        applyContent(
            item: item, content: content, audioEnabled: audioEnabled,
            shareProvider: shareProvider, resumeWordIndex: resumeWordIndex,
            initialDisplayMode: initialDisplayMode)
    }

    /// Cancels in-flight playback and the link pill's hide timer before a reuse
    /// swaps in new content — the part of `configureForReuse` that's about
    /// tearing down the OLD state, independent of what the new content is.
    private func resetTransientState() {
        pause()
        linkPillHideTimer?.invalidate()
        linkPillHideTimer = nil
        linkPillURL = nil
        linkPill.alpha = 0
        finishedBadge.resetForReuse()
    }

    /// Rebuilds the word engine/chunks for `content`, resolves the resume
    /// position, and — once the view exists — refreshes every control that
    /// depends on it.
    private func applyContent(
        item: ReadingListItem,
        content: ArticleContent,
        audioEnabled: Bool,
        shareProvider: ReaderShareProviding?,
        resumeWordIndex: Int?,
        initialDisplayMode: RSVPDisplayMode?
    ) {
        self.item = item
        self.isSpeechMode = audioEnabled
        self.articleContent = content
        self.blockTokenStartsCache = nil
        self.shareProvider = shareProvider
        self.displayMode = initialDisplayMode ?? ReaderSettings.rsvpMode
        self.engine = RSVPEngine(content: content, maxCharactersPerWord: Self.targetCharactersAcross)
        self.chunks = ChunkPlanner.chunks(words: engine.words)
        self.currentIndex = 0
        self.currentChunkIndex = 0
        self.isPlaying = false
        self.didRevealShare = false
        self.finishedReadingTracker = FinishedReadingTracker()

        currentIndex = resolveResumeFrame(carriedOver: resumeWordIndex)
        if displayMode == .phrases { currentChunkIndex = chunkIndex(forWord: currentIndex) }

        guard isViewLoaded else { return }
        updateMeldAnchor()
        scrubber.maximumValue = Float(max(engine.words.count - 1, 1))
        scrubber.value = Float(currentIndex)
        // The share view bakes in the previous item's friend suggestion —
        // rebuild it for the new item/provider.
        shareView.removeFromSuperview()
        shareView = makeShareView()
        installShareView()
        shareView.isHidden = true
        shareView.alpha = 0
        applyDisplayMode()
        refreshDisplay()
        updateStatus()
        finishIfAtEnd()
        // The app-wide center keeps voicing in the background across mode
        // switches, so a reuse that lands back on RSVP while read-aloud is
        // still playing THIS article must adopt that live state — otherwise
        // isPlaying stays false, the display never flashes (the center's word
        // events are gated on isPlaying), and the first tap pauses the audio
        // instead of resuming. See syncPlaybackStateToCenter.
        syncPlaybackStateToCenter()
        view.setNeedsLayout()
    }

    /// Re-adopt the app-wide center's playback state for THIS article. Called
    /// on reuse: `configureForReuse` resets to a paused display, but the center
    /// may already be voicing this article (returning to RSVP mid-playback), in
    /// which case the play/pause glyph, `isPlaying`, and word-flashing must
    /// reflect the ongoing playback rather than the reset defaults. A no-op in
    /// silent mode and whenever the center isn't voicing this item.
    private func syncPlaybackStateToCenter() {
        guard let center = speechCenter, isViewLoaded else { return }
        let playingMine = centerOwnsItem && center.currentSnapshot.isAudiblyPlaying
        isPlaying = playingMine
        updateContextVisibility(animated: false)
    }

    /// Keeps the play/pause button's glyph + accessibility label in lockstep
    /// with `isPlaying`, from wherever it's set.
    private func updatePlayPauseGlyph() {
        playPauseButton.configuration?.image = UIImage(systemName: isPlaying ? "pause.fill" : "play.fill")
        playPauseButton.accessibilityLabel = isPlaying ? "Pause" : "Play"
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    /// The focal word currently displayed — carried to other modes on a switch.
    public var currentReadingWordIndex: Int? {
        // Reported in the shared token space (see resolveResumeFrame).
        engine.tokenIndex(forFrameIndex: currentIndex) ?? currentIndex
    }

    /// Picks the monospaced font size so `targetCharactersAcross` characters
    /// fit beside the focal column. The right side binds: a word that long has
    /// up to `target − maxORP` characters after the ORP (ORP index caps at 3),
    /// and those must fit between the focal column and the right margin.
    private static func makeWordFont(forWidth width: CGFloat) -> UIFont {
        let probe = UIFont.monospacedSystemFont(ofSize: 100, weight: .medium)
        let advanceRatio = ("0" as NSString)
            .size(withAttributes: [.font: probe]).width / 100
        guard advanceRatio > 0, width > 0 else {
            return UIFont.monospacedSystemFont(ofSize: 30, weight: .medium)
        }
        let rightMargin: CGFloat = 20
        let rightBudget = max(120, width * (1 - focalFraction) - rightMargin)
        let suffixCharacters = CGFloat(targetCharactersAcross - 3)
        let characterWidth = rightBudget / suffixCharacters
        let size = min(44, max(20, (characterWidth / advanceRatio).rounded()))
        return UIFont.monospacedSystemFont(ofSize: size, weight: .medium)
    }

    /// A noticeably smaller proportional font than the single-word display, so a
    /// multi-word phrase fits comfortably across two lines.
    private static func makePhraseFont(from wordFont: UIFont) -> UIFont {
        let size = min(30, max(18, (wordFont.pointSize * 0.72).rounded()))
        return .systemFont(ofSize: size, weight: .semibold)
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LunaColors.background

        configureReticule()
        configureWordLabel()
        configurePhraseLabel()
        configureContext()
        configureLinkPill()
        configureLinkPreview()
        configureControls()
        configureGestures()
        configureFinishedBadge()

        // NB: the audio session is NOT touched here — only when read-aloud
        // actually starts playing (see `play()`), so opening the silent speed
        // reader never interrupts other audio / Picture-in-Picture.

        applyDisplayMode()
        if displayMode == .phrases { currentChunkIndex = chunkIndex(forWord: currentIndex) }
        refreshDisplay()
        updateStatus()
        finishIfAtEnd()

        // In-app, speech mode is driven by the app-wide playback center: the
        // circular controls become its remote and word flashing follows its
        // word events (see the AudioPlaybackObserver conformance below).
        // Observers are weakly held, so no teardown is needed.
        ReaderAudioLauncher.center?.addObserver(self)
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updateMeldAnchor()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutReticule()
        layoutPhrasePanel()
        layoutContext()
        layoutLinkPill()
        layoutFinishedBadge()
        refreshDisplay()
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // `pause()` already saves (a legitimate play→pause save point); only
        // call it — and skip the redundant extra save — when actually playing.
        // On the center path `pause()` never stops the audio itself: leaving
        // the screen is exactly when background playback should keep going.
        if isPlaying {
            pause()
        } else {
            saveProgress()
        }
        if AudioMiniPlayerMeld.anchorView === controlsStack {
            AudioMiniPlayerMeld.setAnchor(nil)
        }
    }

    /// Publishes (or clears) this reader's controls stack as the mini-player's
    /// dock anchor: set while RSVP is on screen in CENTER-driven speech mode,
    /// so the window-level bar slims down and docks above the circular
    /// controls. The mini-player host also re-validates the anchor's actual
    /// visibility itself (the RabbitHole host shows/hides pre-built children
    /// without appearance callbacks).
    private func updateMeldAnchor() {
        guard ReaderAudioLauncher.center != nil, isViewLoaded else { return }
        if isSpeechMode, view.window != nil {
            AudioMiniPlayerMeld.setAnchor(controlsStack)
        } else if AudioMiniPlayerMeld.anchorView === controlsStack {
            AudioMiniPlayerMeld.setAnchor(nil)
        }
    }

    /// Read-aloud uses a non-mixing category so it takes over playback; pairing
    /// every deactivation with `.notifyOthersOnDeactivation` lets interrupted
    /// audio (e.g. Picture-in-Picture video) RESUME rather than stay stopped.
    private func activateAudioSession() { ReaderAudioSession.activate() }
    private func deactivateAudioSession() { ReaderAudioSession.deactivate() }

    // MARK: - Setup

    private func configureReticule() {
        view.addSubview(reticuleTop)
        view.addSubview(reticuleBottom)
    }

    /// Positions the two reticule marks as short vertical bars centered on the
    /// focal column, just above and below the word band, pointing at the ORP
    /// letter. Both stay inside the band the context labels already clear
    /// (`layoutContext`'s Words-mode half-band of 84) and above the link pill's
    /// lane, so restoring them moves nothing else.
    private func layoutReticule() {
        let focalX = view.bounds.width * Self.focalFraction
        let centerY = focalCenterY
        let wordHalfHeight: CGFloat = 30
        let markWidth: CGFloat = 7
        let markHeight: CGFloat = 20
        let gap: CGFloat = 10
        reticuleTop.frame = CGRect(
            x: focalX - markWidth / 2, y: centerY - wordHalfHeight - gap - markHeight,
            width: markWidth, height: markHeight)
        reticuleBottom.frame = CGRect(
            x: focalX - markWidth / 2, y: centerY + wordHalfHeight + gap,
            width: markWidth, height: markHeight)
        if #unavailable(iOS 26.0) {
            reticuleTop.layer.cornerRadius = markWidth / 2
            reticuleBottom.layer.cornerRadius = markWidth / 2
        }
    }

    private func configureWordLabel() {
        wordLabel.font = wordFont
        wordLabel.textColor = LunaColors.primaryText
        view.addSubview(wordLabel)
    }

    private func configurePhraseLabel() {
        view.addSubview(phrasePanel)
        phraseLabel.font = phraseFont
        phraseLabel.textColor = LunaColors.primaryText
        phraseLabel.numberOfLines = 2
        phraseLabel.textAlignment = .center
        phraseLabel.lineBreakMode = .byWordWrapping
        // Shrink a rare over-long phrase rather than truncate it.
        phraseLabel.adjustsFontSizeToFitWidth = true
        phraseLabel.minimumScaleFactor = 0.7
        view.addSubview(phraseLabel)
    }

    /// Sizes the glass phrase panel around the two-line label, centered on the
    /// focal band.
    private func layoutPhrasePanel() {
        let horizontalMargin: CGFloat = 24
        let maxWidth = max(160, min(view.bounds.width, 600) - horizontalMargin * 2)
        let lineHeight = ceil(phraseFont.lineHeight)
        let labelHeight = lineHeight * 2
        let panelHeight = labelHeight + 28
        let panelWidth = maxWidth
        let centerY = focalCenterY
        phrasePanel.frame = CGRect(
            x: (view.bounds.width - panelWidth) / 2, y: centerY - panelHeight / 2,
            width: panelWidth, height: panelHeight)
        phraseLabel.frame = CGRect(
            x: phrasePanel.frame.minX + 16, y: centerY - labelHeight / 2,
            width: panelWidth - 32, height: labelHeight)
    }

    private func configureContext() {
        for label in [previousContextLabel, nextContextLabel] {
            label.font = .systemFont(ofSize: 15, weight: .regular)
            label.textColor = LunaColors.tertiaryText
            // As many lines as the (frame-clamped) height allows, so the taller
            // preceding-context lane fills with real surrounding prose.
            label.numberOfLines = 0
            label.lineBreakMode = .byTruncatingTail
            label.alpha = 1 // The reader starts paused.
            view.addSubview(label)
        }
        previousContextLabel.textAlignment = .natural
        nextContextLabel.textAlignment = .natural
        // Preceding context should keep the words closest to the focal word: when
        // it overflows the (now taller) lane, drop the oldest text off the top.
        previousContextLabel.lineBreakMode = .byTruncatingHead
    }

    /// Lays out the surrounding-prose labels above and below the focal band. In
    /// Phrases mode they hug the phrase panel (and are always shown); in Words
    /// mode they fill the space above/below the single word (shown when paused).
    private func layoutContext() {
        let centerY = focalCenterY
        let horizontalMargin: CGFloat = 28
        let width = max(0, view.bounds.width - horizontalMargin * 2)
        let topLimit = view.safeAreaInsets.top + 20

        let bandHalf: CGFloat = displayMode == .phrases
            ? phrasePanel.bounds.height / 2 + 14 : 84
        // Words mode: the removed sub-mode switcher freed the top of the screen,
        // so the preceding-context label grows upward into it (its bottom stays
        // anchored to the focal band — the word and everything below don't move).
        let upperHeight: CGFloat = displayMode == .phrases ? 120 : 220
        let upperBottom = centerY - bandHalf
        previousContextLabel.frame = CGRect(
            x: horizontalMargin,
            y: max(topLimit, upperBottom - upperHeight),
            width: width,
            height: max(0, min(upperHeight, upperBottom - topLimit)))

        let controlsTop = controlsStack.frame.minY > 0
            ? controlsStack.frame.minY
            : view.safeAreaLayoutGuide.layoutFrame.maxY - 140
        // In Phrases mode the link pill lives in the gap just below the panel, so the
        // lower context must start beneath it (panel half + pill gap + pill + 12).
        let lowerY: CGFloat = displayMode == .phrases
            ? centerY + phrasePanel.bounds.height / 2 + Self.phrasePillGap + Self.phrasePillHeight + 12
            : centerY + bandHalf + 32
        let lowerHeight: CGFloat = displayMode == .phrases ? 120 : 96
        nextContextLabel.frame = CGRect(
            x: horizontalMargin,
            y: lowerY,
            width: width,
            height: max(0, min(lowerHeight, controlsTop - lowerY - 12)))
    }

    private func configureLinkPill() {
        var config = UIButton.Configuration.gray()
        config.cornerStyle = .capsule
        config.image = UIImage(systemName: "link")
        config.imagePadding = 6
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 12)
        // Desaturated text/icon so the pill stays quiet behind the reading word.
        config.baseForegroundColor = LunaColors.secondaryText
        config.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 14, bottom: 7, trailing: 14)
        linkPill.configuration = config
        linkPill.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
        linkPill.alpha = 0
        linkPill.addTarget(self, action: #selector(linkPillTapped), for: .touchUpInside)
        view.addSubview(linkPill)
    }

    /// Centers the link pill below the focal word / phrase band. In Phrases mode it
    /// tucks into the gap JUST below the focus panel (above the lower context,
    /// which is laid out below it) rather than floating down over the context text.
    /// In Words mode it sits in the clear lane below the focused word and above
    /// the lower context text.
    private func layoutLinkPill() {
        let centerY = focalCenterY
        let maxWidth = view.bounds.width - 64
        let fitted = linkPill.systemLayoutSizeFitting(
            CGSize(width: maxWidth, height: 40),
            withHorizontalFittingPriority: .fittingSizeLevel,
            verticalFittingPriority: .required)
        let width = min(max(fitted.width, 80), maxWidth)
        let y = displayMode == .phrases
            ? centerY + phrasePanel.bounds.height / 2 + Self.phrasePillGap
            : centerY + 88 - Self.phrasePillHeight / 2
        linkPill.frame = CGRect(
            x: (view.bounds.width - width) / 2, y: y, width: width, height: Self.phrasePillHeight)
    }

    /// Link-pill geometry shared with `layoutContext` so the lower context clears it.
    private static let phrasePillGap: CGFloat = 8
    private static let phrasePillHeight: CGFloat = 36

    /// Shows/refreshes the pill for a linkified word, or starts the post-link
    /// buffer when a non-link word arrives (a new link replaces it immediately).
    private func updateLinkPill(for url: URL?) {
        if let url {
            linkPillHideTimer?.invalidate()
            linkPillHideTimer = nil
            if url != linkPillURL {
                linkPillURL = url
                let host = url.host?.replacingOccurrences(of: "www.", with: "") ?? url.absoluteString
                linkPill.configuration?.title = host
                view.setNeedsLayout()
            }
            if linkPill.alpha < 1 {
                UIView.animate(withDuration: 0.2) { self.linkPill.alpha = 1 }
            }
        } else if linkPillURL != nil, linkPillHideTimer == nil {
            linkPillHideTimer = Timer.scheduledTimer(withTimeInterval: 1.4, repeats: false) {
                [weak self] _ in self?.hideLinkPill()
            }
        }
    }

    private func hideLinkPill() {
        linkPillHideTimer?.invalidate()
        linkPillHideTimer = nil
        linkPillURL = nil
        UIView.animate(withDuration: 0.25) { self.linkPill.alpha = 0 }
    }

    @objc private func linkPillTapped() {
        guard let url = linkPillURL else { return }
        activateLink(url)
    }

    private func activateLink(_ url: URL) {
        pause()
        if let onLinkActivatedAtPoint {
            onLinkActivatedAtPoint(url, linkPill.center)
            return
        }
        let sourceInWindow = view.convert(linkPill.center, to: nil)
        let coordinator = inlineReaderPresentationCoordinator
        let inline = SplitWebOverlayViewController(
            url: url, shareProvider: shareProvider,
            sourcePoint: sourceInWindow, outerURL: item.url ?? url,
            outerTitle: articleContent.title,
            contentTop: coordinator?.inlineReaderTopEdgeInWindow ?? 0,
            cardFrame: coordinator?.inlineReaderCardFrameInWindow,
            showsOuterContentBelow: coordinator?.inlineReaderShowsOuterContentBelow ?? false)
        inline.presentationCoordinator = coordinator
        present(inline, animated: true)
    }

    private func configureLinkPreview() {
        linkPreviewInteraction = LinkRSVPPreviewInteraction(
            host: self,
            sourceView: linkPill,
            resolveURL: { [weak self] _ in self?.linkPillURL },
            sourcePlaybackChanged: { [weak self] previewIsActive in
                guard let self else { return }
                if previewIsActive {
                    self.wasPlayingBeforeLinkPreview = self.isPlaying
                    if let center = self.speechCenter, self.centerOwnsItem,
                       center.currentSnapshot.isAudiblyPlaying {
                        center.pause()
                    } else if self.isPlaying {
                        self.pause()
                    }
                } else if self.wasPlayingBeforeLinkPreview {
                    self.wasPlayingBeforeLinkPreview = false
                    self.play()
                }
            })
    }

    private func configureControls() {
        var playConfig = GlassStyle.circularButtonConfiguration(symbol: "play.fill", padding: 16)
        playConfig.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 28)
        playPauseButton.configuration = playConfig
        playPauseButton.accessibilityLabel = "Play"
        // Pin a true circle for the fixed 60×60 button: the glass/filled capsule
        // background otherwise hugs the play glyph's content width and reads as
        // an egg rather than a round button.
        playPauseButton.clipsToBounds = true
        playPauseButton.layer.cornerRadius = 30
        playPauseButton.addTarget(self, action: #selector(togglePlayPause), for: .touchUpInside)

        scrubber.minimumValue = 0
        scrubber.maximumValue = Float(max(engine.words.count - 1, 1))
        scrubber.value = Float(currentIndex)
        scrubber.minimumTrackTintColor = GlassStyle.readingAccent
        scrubber.addTarget(self, action: #selector(scrubbed), for: .valueChanged)
        scrubber.addTarget(self, action: #selector(scrubEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])

        statusLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        statusLabel.textColor = LunaColors.secondaryText
        statusLabel.textAlignment = .center

        wpmDownButton.configuration = GlassStyle.circularButtonConfiguration(symbol: "tortoise.fill", padding: 18)
        wpmUpButton.configuration = GlassStyle.circularButtonConfiguration(symbol: "hare.fill", padding: 18)
        let paceSymbolSize = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        wpmDownButton.configuration?.preferredSymbolConfigurationForImage = paceSymbolSize
        wpmUpButton.configuration?.preferredSymbolConfigurationForImage = paceSymbolSize
        wpmDownButton.accessibilityLabel = "Slow down"
        wpmDownButton.accessibilityHint = "Decreases reading speed by 25 words per minute"
        wpmUpButton.accessibilityLabel = "Speed up"
        wpmUpButton.accessibilityHint = "Increases reading speed by 25 words per minute"
        wpmDownButton.addTarget(self, action: #selector(wpmDown), for: .touchUpInside)
        wpmUpButton.addTarget(self, action: #selector(wpmUp), for: .touchUpInside)

        var skipBackConfig = GlassStyle.circularButtonConfiguration(symbol: "backward.fill", padding: 12)
        skipBackConfig.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 19)
        skipBackButton.configuration = skipBackConfig
        var skipForwardConfig = GlassStyle.circularButtonConfiguration(symbol: "forward.fill", padding: 12)
        skipForwardConfig.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 19)
        skipForwardButton.configuration = skipForwardConfig
        skipBackButton.accessibilityLabel = "Skip back 25 words"
        skipForwardButton.accessibilityLabel = "Skip forward 25 words"
        skipBackButton.addTarget(self, action: #selector(skipBack), for: .touchUpInside)
        skipForwardButton.addTarget(self, action: #selector(skipForward), for: .touchUpInside)

        // Grouped glass controls have visible, generous hit targets while the
        // adaptive stack keeps them on-screen even on narrow iPhones.
        let speedRow = UIView()
        let buttonRow = UIStackView(arrangedSubviews: [
            skipBackButton, wpmDownButton, playPauseButton, wpmUpButton, skipForwardButton,
        ])
        buttonRow.axis = .horizontal
        buttonRow.alignment = .center
        buttonRow.distribution = .equalSpacing
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        speedRow.addSubview(buttonRow)

        controlsStack.addArrangedSubview(scrubber)
        controlsStack.addArrangedSubview(statusLabel)
        controlsStack.addArrangedSubview(speedRow)
        controlsStack.axis = .vertical
        controlsStack.spacing = 12
        controlsStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controlsStack)

        // Hidden until the reader finishes; sits above the controls so it never
        // obscures them.
        installShareView()

        NSLayoutConstraint.activate([
            controlsStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            controlsStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
            controlsStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            speedRow.heightAnchor.constraint(equalToConstant: 64),
            buttonRow.leadingAnchor.constraint(greaterThanOrEqualTo: speedRow.leadingAnchor, constant: 8),
            buttonRow.trailingAnchor.constraint(lessThanOrEqualTo: speedRow.trailingAnchor, constant: -8),
            buttonRow.centerXAnchor.constraint(equalTo: speedRow.centerXAnchor),
            buttonRow.centerYAnchor.constraint(equalTo: speedRow.centerYAnchor),
            playPauseButton.widthAnchor.constraint(equalToConstant: 60),
            playPauseButton.heightAnchor.constraint(equalToConstant: 60),
            skipBackButton.widthAnchor.constraint(equalToConstant: 48),
            skipBackButton.heightAnchor.constraint(equalToConstant: 48),
            wpmDownButton.widthAnchor.constraint(equalToConstant: 48),
            wpmDownButton.heightAnchor.constraint(equalToConstant: 48),
            wpmUpButton.widthAnchor.constraint(equalToConstant: 48),
            wpmUpButton.heightAnchor.constraint(equalToConstant: 48),
            skipForwardButton.widthAnchor.constraint(equalToConstant: 48),
            skipForwardButton.heightAnchor.constraint(equalToConstant: 48),
        ])
    }

    /// The full-screen pause tap plus the slow-motion press-and-hold.
    private func configureGestures() {
        pauseTap.addTarget(self, action: #selector(surfaceTapped))
        pauseTap.delegate = self
        view.addGestureRecognizer(pauseTap)

        pressAndHoldGesture.addTarget(self, action: #selector(handlePressAndHold))
        pressAndHoldGesture.delegate = self
        // Shorter than the 0.5s default so slow-motion engages promptly for
        // RSVP's fast word cadence. `require(toFail:)` below doesn't delay a
        // genuine tap — the long-press fails the instant a touch lifts early,
        // not after this duration elapses.
        pressAndHoldGesture.minimumPressDuration = 0.35
        view.addGestureRecognizer(pressAndHoldGesture)
        pauseTap.require(toFail: pressAndHoldGesture)
    }

    // MARK: - Sub-mode

    /// Shows the view set for the active sub-mode and hides the other's.
    private func applyDisplayMode() {
        let phrases = displayMode == .phrases
        wordLabel.isHidden = phrases
        reticuleTop.isHidden = phrases
        reticuleBottom.isHidden = phrases
        phraseLabel.isHidden = !phrases
        phrasePanel.isHidden = !phrases
        // Context is always shown in Phrases; in Words it follows play/pause.
        let contextVisible = phrases || !isPlaying
        previousContextLabel.alpha = contextVisible ? 1 : 0
        nextContextLabel.alpha = contextVisible ? 1 : 0
    }

    // MARK: - Phrase helpers

    /// Index of the chunk containing `wordIndex`. Chunks tile the whole word
    /// space contiguously in sorted order, so binary search resolves any
    /// in-range word (this runs per spoken word — a linear scan made read-aloud
    /// O(words × chunks) on long articles); an out-of-range index clamps.
    private func chunkIndex(forWord wordIndex: Int) -> Int {
        guard !chunks.isEmpty else { return 0 }
        var low = 0, high = chunks.count - 1
        while low < high {
            let mid = (low + high) / 2
            if chunks[mid].wordRange.upperBound <= wordIndex {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return chunks[low].wordRange.contains(wordIndex) || wordIndex > 0 ? low : 0
    }

    // MARK: - Display

    private func refreshDisplay() {
        render(at: currentIndex, highlightWord: isSpeechMode && isPlaying ? currentIndex : nil)
    }

    /// Renders `wordIndex` via `showChunk`/`showWord` depending on the active
    /// sub-mode, keeping `currentIndex` and (in Phrases) `currentChunkIndex` in
    /// sync with it — the shared "which display primitive draws this word"
    /// routing every playback/seek/event path needs.
    private func render(at wordIndex: Int, highlightWord: Int?) {
        currentIndex = wordIndex
        if displayMode == .phrases {
            currentChunkIndex = chunkIndex(forWord: wordIndex)
            showChunk(at: currentChunkIndex, highlightWord: highlightWord)
        } else {
            showWord(at: wordIndex)
        }
    }

    /// Positions the word so the ORP letter sits exactly on the focal column,
    /// with the ORP letter tinted in the reading accent.
    private func showWord(at index: Int) {
        guard engine.words.indices.contains(index) else { return }
        let word = engine.words[index]
        wordLabel.attributedText = RSVPWordDisplay.attributedText(for: word, font: wordFont)
        wordLabel.sizeToFit()

        let (prefixWidth, orpWidth) = RSVPWordDisplay.orpOffsets(for: word, font: wordFont)
        let focalX = view.bounds.width * Self.focalFraction
        let centerY = focalCenterY
        wordLabel.frame.origin = CGPoint(
            x: focalX - prefixWidth - orpWidth / 2,
            y: centerY - wordLabel.bounds.height / 2)

        updateLinkPill(for: word.url)
        if !isPlaying { updateContextText() }
    }

    /// Shows the phrase at `index`, optionally tinting the word at
    /// `highlightWord` (used while read-aloud voices each word).
    private func showChunk(at index: Int, highlightWord: Int?) {
        guard chunks.indices.contains(index) else {
            phraseLabel.text = nil
            return
        }
        let chunk = chunks[index]
        let attributed = NSMutableAttributedString(
            string: chunk.displayText,
            attributes: [.font: phraseFont, .foregroundColor: LunaColors.primaryText])

        if let highlightWord, chunk.wordRange.contains(highlightWord) {
            // Locate the highlighted word's range within the joined phrase string.
            let wordOffset = highlightWord - chunk.wordRange.lowerBound
            var location = 0
            for index in 0..<wordOffset { location += (chunk.words[index] as NSString).length + 1 }
            let length = (chunk.words[wordOffset] as NSString).length
            if location + length <= attributed.length {
                attributed.addAttribute(
                    .foregroundColor, value: GlassStyle.readingAccent,
                    range: NSRange(location: location, length: length))
            }
        }
        phraseLabel.attributedText = attributed

        // First link found in the phrase, if any.
        let url = chunk.wordRange.compactMap { engine.words[safe: $0]?.url }.first
        updateLinkPill(for: url)
        updateContextText()
    }

    /// Fills the surrounding-prose labels for the current position. In Phrases
    /// mode the context excludes the words currently in the focus panel; in Words
    /// mode it surrounds the single focal word.
    private func updateContextText() {
        let shownRange: Range<Int> = displayMode == .phrases && chunks.indices.contains(currentChunkIndex)
            ? chunks[currentChunkIndex].wordRange
            : currentIndex..<(currentIndex + 1)
        guard let context = RSVPContextWindow.context(
            around: shownRange, words: engine.words, radius: Self.contextWordCount)
        else {
            previousContextLabel.text = nil
            nextContextLabel.text = nil
            return
        }
        previousContextLabel.text = context.preceding
        nextContextLabel.text = context.following
    }

    /// Animates the Words-mode context in/out on play/pause (Phrases keeps it on).
    private func updateContextVisibility(animated: Bool, duration: TimeInterval = 0) {
        updateContextText()
        let visible = displayMode == .phrases || !isPlaying
        let update = {
            self.previousContextLabel.alpha = visible ? 1 : 0
            self.nextContextLabel.alpha = visible ? 1 : 0
        }
        guard animated else { update(); return }
        UIView.animate(withDuration: duration, delay: 0,
                       options: [.beginFromCurrentState, .curveEaseOut], animations: update)
    }

    // MARK: - Playback

    private func play() {
        guard !engine.words.isEmpty else { return }
        // In-app speech mode: the play control drives the app-wide center
        // (resume when it owns this article, else start/switch playback to
        // it). Display state (isPlaying, button glyph, word flashing) follows
        // via the AudioPlaybackObserver conformance, not from here.
        if let center = speechCenter {
            playViaCenter(center)
            return
        }
        if currentIndex >= engine.words.count - 1 {
            currentIndex = 0
            currentChunkIndex = 0
        }
        isPlaying = true
        updateContextVisibility(animated: true, duration: 0.05)
        dispatchOnMode(
            speech: { self.activateAudioSession(); self.speakCurrentSentence() },
            phrases: { self.scheduleNextChunk() },
            words: { self.scheduleNext() })
    }

    /// Routes to whichever of the three playback engines is active — speech
    /// (read-aloud pacing), the Phrases sub-mode's chunk timer, or the default
    /// Words WPM timer. Shared by every call site that must re-derive the same
    /// `isSpeechMode` / `displayMode == .phrases` dispatch.
    private func dispatchOnMode(speech: () -> Void, phrases: () -> Void, words: () -> Void) {
        if isSpeechMode {
            speech()
        } else if displayMode == .phrases {
            phrases()
        } else {
            words()
        }
    }

    private func playViaCenter(_ center: AudioPlaybackCenter) {
        if centerOwnsItem {
            if center.currentSnapshot.isAudiblyPlaying { return }
            if case .paused = center.state { center.resume(); return }
        }
        if currentIndex >= engine.words.count - 1 {
            currentIndex = 0
            currentChunkIndex = 0
        }
        // Start (or switch) playback at the displayed focal word — this is
        // also the "explicit play switches playback to this article" path
        // when something else is playing.
        let token = engine.tokenIndex(forFrameIndex: currentIndex) ?? currentIndex
        center.play(item: item, content: articleContent, fromWordIndex: token)
    }

    private func pause() {
        // Center-driven speech mode: lifecycle pauses (reuse, disappearing,
        // sub-mode switches) must NEVER stop the app-wide playback —
        // navigating away is exactly when background audio should keep going.
        // Explicit user pauses go through `togglePlayPause`/`scrubbed`, which
        // pause the center directly; this path only settles local state.
        if speechCenter != nil {
            timer?.invalidate()
            timer = nil
            wordClock.cancel()
            saveProgress()
            return
        }
        isPlaying = false
        timer?.invalidate()
        timer = nil
        wordClock.cancel()
        isSpeedHeld = false
        intervalStart = nil
        intervalDuration = nil
        // Only touch speech/audio in read-aloud mode — the silent reader must
        // never instantiate the synthesizer or claim the audio session.
        if isSpeechMode {
            synthesizer.stopSpeaking(at: .immediate)
            deactivateAudioSession()
        }
        updateContextVisibility(animated: true, duration: 0.2)
        refreshDisplay()
        saveProgress()
    }

    // MARK: - Read-aloud pacing

    /// Speaks from the current word to the end of the sentence as ONE
    /// utterance — natural prosody at normal speech pace — and records each
    /// word's offset so the display can flash along.
    private func speakCurrentSentence() {
        guard isPlaying, engine.words.indices.contains(currentIndex) else { return }
        var end = currentIndex
        while end < engine.words.count - 1,
              !engine.words[end].endsSentence,
              !engine.words[end].endsParagraph,
              end - currentIndex < 39 {
            end += 1
        }

        var text = ""
        speechWordOffsets = []
        for word in engine.words[currentIndex...end] {
            if !text.isEmpty { text += " " }
            speechWordOffsets.append((text as NSString).length)
            text += word.text
        }
        speechSentenceBase = currentIndex

        let utterance = AVSpeechUtterance(string: text)
        // Speak with the user-selected TTS engine (falling back if unavailable);
        // all engines drive this `AVSpeechSynthesizer`, so the per-word flash
        // driven by `willSpeakRangeOfSpeechString` is unaffected.
        SpeechEngineFactory.resolveSelected().configure(
            utterance, rate: AVSpeechUtteranceDefaultSpeechRate)
        utterance.postUtteranceDelay = 0.12
        synthesizer.speak(utterance)
    }

    @objc private func togglePlayPause() {
        if let center = speechCenter {
            if centerOwnsItem, center.currentSnapshot.isAudiblyPlaying {
                center.pause()
            } else {
                play()
            }
            return
        }
        isPlaying ? pause() : play()
    }

    /// The full-screen tap: pause-only, never a toggle.
    @objc private func surfaceTapped() {
        if let center = speechCenter {
            if centerOwnsItem, center.currentSnapshot.isAudiblyPlaying { center.pause() }
            return
        }
        if isPlaying { pause() }
    }

    // MARK: - Press-and-hold slow-motion

    @objc private func handlePressAndHold(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            beginSpeedHold()
        case .ended, .cancelled, .failed:
            endSpeedHold()
        default:
            break
        }
    }

    /// Halves playback speed by doubling the REMAINING time of the in-flight
    /// word/chunk interval (rather than restarting its full duration), and
    /// marks intervals scheduled while still held as slow too.
    private func beginSpeedHold() {
        guard isPlaying, !isSpeechMode, !isSpeedHeld else { return }
        isSpeedHeld = true
        rescaleRunningInterval(by: 2)
    }

    /// Restores normal speed, again rescaling the in-flight interval's
    /// remaining time rather than jumping straight to the next word.
    private func endSpeedHold() {
        guard isSpeedHeld else { return }
        isSpeedHeld = false
        rescaleRunningInterval(by: 0.5)
    }

    /// Rescales whichever sub-mode's timer is running — the shared
    /// `wordClock` in Words, or the chunk timer below in Phrases.
    private func rescaleRunningInterval(by factor: Double) {
        if displayMode == .phrases {
            guard let start = intervalStart, let duration = intervalDuration, timer != nil else { return }
            let remaining = max(0, duration - Date().timeIntervalSince(start)) * factor
            startTimer(remaining) { [weak self] in self?.advanceChunk() }
        } else {
            wordClock.rescaleRemaining(by: factor)
        }
    }

    /// Doubles a WPM-timer duration while the display area is press-and-held.
    private func effectiveDuration(_ base: TimeInterval) -> TimeInterval {
        isSpeedHeld ? base * 2 : base
    }

    /// Schedules `handler` after `interval`, recording the interval's
    /// wall-clock start/length so a hold/release mid-word can rescale the
    /// REMAINING time (see `rescaleRunningInterval`) — the Phrases sub-mode's
    /// chunk timer only; Words uses the shared `wordClock`.
    private func startTimer(_ interval: TimeInterval, handler: @escaping () -> Void) {
        timer?.invalidate()
        intervalStart = Date()
        intervalDuration = interval
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { _ in
            handler()
        }
    }

    // MARK: Words-mode timer

    private func scheduleNext() {
        wordClock.schedule(effectiveDuration(engine.duration(at: currentIndex, wpm: wpm)))
    }

    private func advance() {
        guard isPlaying else { return }
        let word = engine.words[currentIndex]
        if word.endsSentence || word.endsParagraph {
            sentenceHaptic.impactOccurred()
        }
        guard currentIndex < engine.words.count - 1 else {
            finish()
            return
        }
        currentIndex += 1
        showWord(at: currentIndex)
        scrubber.value = Float(currentIndex)
        updateStatus()
        guard currentIndex < engine.words.count - 1 else {
            finish()
            return
        }
        scheduleNext()
    }

    // MARK: Phrases-mode timer

    private func scheduleNextChunk() {
        guard chunks.indices.contains(currentChunkIndex) else { return }
        startTimer(effectiveDuration(ChunkPlanner.duration(for: chunks[currentChunkIndex], wpm: wpm))) { [weak self] in
            self?.advanceChunk()
        }
    }

    private func advanceChunk() {
        guard isPlaying, chunks.indices.contains(currentChunkIndex) else { return }
        let chunk = chunks[currentChunkIndex]
        if chunk.endsSentence || chunk.endsParagraph {
            sentenceHaptic.impactOccurred()
        }
        guard currentChunkIndex < chunks.count - 1 else {
            currentIndex = max(0, engine.words.count - 1)
            finish()
            return
        }
        currentChunkIndex += 1
        currentIndex = chunks[currentChunkIndex].wordRange.lowerBound
        showChunk(at: currentChunkIndex, highlightWord: nil)
        scrubber.value = Float(currentIndex)
        updateStatus()
        scheduleNextChunk()
    }

    /// Common end-of-article handling for both sub-modes.
    private func finish() {
        guard finishedReadingTracker.update(reachedEnd: true) == .finished else { return }
        pause()
        revealShareView()
        hideLinkPill()
        finishedBadge.present()
        completionDelegate?.readerDidFinishReading(self)
    }

    private func configureFinishedBadge() {
        view.addSubview(finishedBadge)
    }

    /// Reuses the link-pill lane and its exact height so completion replaces,
    /// rather than competes with, a link preview at the end of the article.
    private func layoutFinishedBadge() {
        let width = min(view.bounds.width - 64, 220)
        finishedBadge.frame = CGRect(
            x: (view.bounds.width - width) / 2,
            y: linkPill.frame.minY,
            width: width, height: Self.phrasePillHeight)
    }

    // MARK: - Controls

    @objc private func scrubbed() {
        // Only pause (and its save) when playback was actually running — a scrub
        // while already paused shouldn't re-run pause's save/display work, and
        // continuous `.valueChanged` ticks must not persist at all; the scrub
        // gesture's end (`scrubEnded`) saves once.
        if isPlaying {
            if let center = speechCenter {
                if centerOwnsItem { center.pause() }
            } else {
                pause()
            }
        }
        seek(toWord: Int(scrubber.value))
    }

    /// Fires once when the scrub gesture ends (touch up/cancel) — the single
    /// persistence point for a scrubber drag, instead of every continuous tick.
    @objc private func scrubEnded() {
        saveProgress()
        // Land the center on the scrubbed position too (it stays paused;
        // resume/lock-screen then continue from here).
        syncCenterToDisplayedPosition()
    }

    @objc private func skipBack() { skip(by: -Self.skipWordCount) }
    @objc private func skipForward() { skip(by: Self.skipWordCount) }

    /// Jumps the reading position by `delta` words (clamped to the document) and
    /// PRESERVES the playback state: if RSVP was playing it resumes from the new
    /// position, if it was paused it stays paused there. Works in both sub-modes
    /// and both audio modes — the active engine (WPM/chunk timer or sentence-TTS)
    /// is torn down and (only if we were playing) restarted from the new index,
    /// so skipping never toggles play/pause, never restarts from the beginning,
    /// and never desyncs the display from the engine position.
    private func skip(by delta: Int) {
        let target = RSVPEngine.skipTarget(
            currentIndex: currentIndex, by: delta, wordCount: engine.words.count)
        guard target != currentIndex else { return }

        // Center-driven speech mode: move the display, then land the center on
        // the same word — its seek preserves the play/pause state itself.
        if speechCenter != nil {
            seek(toWord: target)
            saveProgress()
            syncCenterToDisplayedPosition()
            return
        }

        let wasPlaying = isPlaying
        // Tear down whichever engine is running without flipping the play/pause
        // glyph or saving — we restore the exact state below.
        if isSpeechMode {
            synthesizer.stopSpeaking(at: .immediate)
        } else if displayMode == .phrases {
            timer?.invalidate()
            timer = nil
        } else {
            wordClock.cancel()
        }

        seek(toWord: target)

        guard wasPlaying else {
            saveProgress()
            return
        }
        // Resume from the new position in the same mode we were playing in.
        dispatchOnMode(
            speech: { self.speakCurrentSentence() },
            phrases: { self.scheduleNextChunk() },
            words: { self.scheduleNext() })
    }

    /// Moves the focal position to `wordIndex` (clamped), snapping to the
    /// containing phrase in Phrases mode, and refreshes the display + controls.
    private func seek(toWord wordIndex: Int) {
        let clamped = min(max(0, wordIndex), max(0, engine.words.count - 1))
        currentIndex = clamped
        if displayMode == .phrases {
            currentChunkIndex = chunkIndex(forWord: clamped)
            currentIndex = chunks.indices.contains(currentChunkIndex)
                ? chunks[currentChunkIndex].wordRange.lowerBound : clamped
        }
        refreshDisplay()
        scrubber.value = Float(currentIndex)
        updateStatus()
        updateFinishedReadingState()
    }

    @objc private func wpmDown() { adjustWPM(by: -25) }
    @objc private func wpmUp() { adjustWPM(by: 25) }

    private func adjustWPM(by delta: Double) {
        wpm = min(max(wpm + delta, 100), 900)
        ReaderSettings.baseWPM = wpm
        updateStatus()
    }

    private func updateStatus() {
        let percent = engine.words.isEmpty
            ? 0 : Int((Double(currentIndex + 1) / Double(engine.words.count)) * 100)
        statusLabel.text = "\(percent)% · \(Int(wpm)) wpm"
    }

    /// Seeks the center to the currently displayed focal word — used after a
    /// scrub/skip so the audio lands where the display is. Only when the
    /// center owns THIS article; its seek preserves play/pause state.
    private func syncCenterToDisplayedPosition() {
        guard let center = speechCenter, centerOwnsItem else { return }
        let token = engine.tokenIndex(forFrameIndex: currentIndex) ?? currentIndex
        let lastFrame = max(engine.words.count - 1, 0)
        let tokenCount = (engine.tokenIndex(forFrameIndex: lastFrame) ?? token) + 1
        guard tokenCount > 1 else { return }
        center.seek(toFraction: Double(token) / Double(tokenCount - 1))
    }

    /// Token starts per ORIGINAL content block, built once per configure —
    /// the mapping table for center word events.
    private func blockTokenStarts() -> [Int] {
        if let cached = blockTokenStartsCache { return cached }
        let starts = AudioWordEventTokenMapping.blockTokenStarts(blocks: articleContent.blocks)
        blockTokenStartsCache = starts
        return starts
    }

    private func saveProgress() {
        // Persisted in the shared token space (see resolveResumeFrame), in ONE
        // coordinated store cycle instead of two back-to-back mutations. Moving the
        // shared position here (play/scrub/slip) makes the scroll reader's exact
        // pixel offset stale — it no longer corresponds to `lastWordIndex` — so clear
        // it; the scroll reader then resumes from the word instead (the hybrid rule).
        let wordIndex = engine.tokenIndex(forFrameIndex: currentIndex) ?? currentIndex
        let progress = engine.words.count > 1
            ? Double(currentIndex) / Double(engine.words.count - 1) : nil
        store.saveReaderExitPosition(
            clearScrollOffset: true,
            readingProgress: progress, lastWordIndex: wordIndex, for: item.id)
    }

    private func isAtEnd() -> Bool {
        guard !engine.words.isEmpty else { return false }
        if displayMode == .phrases, !chunks.isEmpty {
            return currentChunkIndex >= chunks.count - 1
        } else {
            return currentIndex >= engine.words.count - 1
        }
    }

    private func finishIfAtEnd() {
        guard isAtEnd() else { return }
        finish()
    }

    private func updateFinishedReadingState() {
        if isAtEnd() {
            finish()
        } else if finishedReadingTracker.update(reachedEnd: false) == .movedAway {
            didRevealShare = false
            shareView.isHidden = true
            shareView.alpha = 0
            completionDelegate?.readerDidMoveAwayFromEnd(self)
        }
    }

    // MARK: - End-of-article share

    /// Adds `shareView` to the hierarchy, hidden, pinned above the controls.
    private func installShareView() {
        shareView.isHidden = true
        shareView.alpha = 0
        shareView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(shareView)
        NSLayoutConstraint.activate([
            shareView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            shareView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            shareView.bottomAnchor.constraint(equalTo: controlsStack.topAnchor, constant: -16),
        ])
    }

    private func makeShareView() -> ArticleShareView {
        return ArticleShareView(
            onShare: { [weak self] in
                guard let self else { return }
                self.shareProvider?.presentShareSheet(
                    urlString: self.item.urlString, title: self.item.title,
                    from: self, sourceView: self.shareView)
            })
    }

    private func revealShareView() {
        // No share affordance in the share sheet or for non-shareable items.
        guard shareProvider != nil, item.isShareable, !didRevealShare else { return }
        didRevealShare = true
        shareView.isHidden = false
        UIView.animate(withDuration: 0.3) { self.shareView.alpha = 1 }
    }
}

extension RSVPViewController: RSVPPlaybackClockDelegate {
    public func playbackClockDidFire(_ clock: RSVPPlaybackClock) {
        advance()
    }
}

// MARK: - AudioPlaybackObserver (in-app center-driven speech mode)

extension RSVPViewController: AudioPlaybackObserver {
    /// Mirrors the center's state into RSVP's local play/pause display —
    /// `isPlaying` is true exactly while the center is voicing THIS article.
    public func audioPlaybackCenter(_ center: AudioPlaybackCenter, didChangeState state: AudioPlaybackState) {
        guard speechCenter != nil, isViewLoaded else { return }
        let playingMine: Bool
        if case .playing(let itemID) = state, itemID == item.id {
            playingMine = true
        } else {
            playingMine = false
        }
        guard playingMine != isPlaying else { return }
        isPlaying = playingMine
        updateContextVisibility(animated: true, duration: playingMine ? 0.05 : 0.2)
        if !playingMine {
            refreshDisplay()
            saveProgress()
        }
    }

    /// Word flashing from the center's voicing, applied only while it plays
    /// THIS article: the event's (original block index, in-block UTF-16 range)
    /// maps into the engine's shared token space, then to an RSVP frame.
    public func audioPlaybackCenter(_ center: AudioPlaybackCenter, didEmitWordEvent event: AudioWordEvent) {
        guard speechCenter != nil, isViewLoaded, isPlaying, centerOwnsItem,
              let frame = RSVPAudioWordSync.frameIndex(
                for: event, blocks: articleContent.blocks,
                blockTokenStarts: blockTokenStarts(), engine: engine),
              engine.words.indices.contains(frame)
        else { return }
        guard frame != currentIndex || displayMode == .phrases else { return }
        render(at: frame, highlightWord: frame)
        scrubber.value = Float(frame)
        updateStatus()
        if frame >= engine.words.count - 1 {
            finish()
        }
    }
}

extension RSVPViewController: AVSpeechSynthesizerDelegate {
    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        guard isSpeechMode, isPlaying else { return }
        // Map the spoken range to a word in the current sentence and flash it.
        var wordOffset = 0
        for (index, offset) in speechWordOffsets.enumerated() {
            if offset <= characterRange.location { wordOffset = index } else { break }
        }
        let wordIndex = speechSentenceBase + wordOffset
        guard wordIndex != currentIndex, engine.words.indices.contains(wordIndex) else { return }
        // Follow the spoken word with the phrase that contains it, tinting it
        // (render's Phrases branch).
        render(at: wordIndex, highlightWord: wordIndex)
        scrubber.value = Float(currentIndex)
        updateStatus()
    }

    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
    ) {
        guard isSpeechMode, isPlaying else { return }
        let sentenceEnd = speechSentenceBase + max(0, speechWordOffsets.count - 1)
        sentenceHaptic.impactOccurred()
        guard sentenceEnd < engine.words.count - 1 else {
            currentIndex = engine.words.count - 1
            finish()
            return
        }
        render(at: sentenceEnd + 1, highlightWord: sentenceEnd + 1)
        scrubber.value = Float(currentIndex)
        updateStatus()
        speakCurrentSentence()
    }
}

extension RSVPViewController: UIGestureRecognizerDelegate {
    /// The full-screen play/pause tap must ignore touches that land on any
    /// interactive control — the sub-mode switcher, the skip ±25-word buttons,
    /// the ±25 speed buttons, the play/pause button, the scrubber, and the link
    /// pill — so those taps reach the control instead of being cancelled by the
    /// full-screen tap (which `cancelsTouchesInView`).
    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch
    ) -> Bool {
        var hitView = touch.view
        while let candidate = hitView {
            if candidate is UIControl { return false }
            hitView = candidate.superview
        }
        return true
    }
}

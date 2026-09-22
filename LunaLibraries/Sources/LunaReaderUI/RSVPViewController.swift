//
//  RSVPViewController.swift
//  Luna
//

import LunaAudioPlayback
import LunaReaderEngine
import LunaDesignSystem
import LunaStorage
import LunaModels
import LunaURLClassification
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
    /// reader's coordinates) to this delegate instead of presenting a new inline split
    /// overlay — used by the inline reader to push the link onto its own navigation
    /// stack rather than nesting another overlay.
    public weak var linkActivationDelegate: ReaderLinkActivationDelegate?

    /// The host that follows this reader's play state, for chrome that fades
    /// while RSVP plays.
    public weak var playbackObserver: RSVPPlaybackObserving?

    private var item: SavedItem
    private var engine: RSVPEngine
    /// Phrase groupings over the same word space, built once (lazily) when the
    /// reader first needs the Phrases sub-mode.
    private var chunks: [TextChunk]
    private let store = SavesStore.shared

    /// Words vs Phrases. Persisted in `ReaderSettings.rsvpMode`.
    private var displayMode: RSVPDisplayMode

    private var currentIndex = 0
    /// Index into `chunks` of the phrase currently shown (Phrases mode only).
    private var currentChunkIndex = 0
    public private(set) var isPlaying = false {
        didSet {
            updatePlayPauseGlyph()
            gazeCoordinator?.setPlaying(isPlaying)
            if isPlaying != oldValue {
                playbackObserver?.rsvpReader(self, didChangePlaybackState: isPlaying)
            }
        }
    }
    /// The Phrases sub-mode's chunk timer (`scheduleNextChunk`/`advanceChunk`),
    /// bundled with the wall-clock start/length it was scheduled with — a
    /// hold/release mid-word rescales the REMAINING time
    /// (`rescaleRunningInterval`), which needs both. One optional keeps the
    /// timer and its start/duration from going stale independently:
    /// `cancelChunkTimer()` is the only place that clears any of the three.
    /// The Words sub-mode's timer is `wordClock` below — the two stay separate
    /// low-level timers because only the words-mode one is shared with the
    /// link preview.
    private struct ChunkTimer {
        let timer: Timer
        let start: Date
        let duration: TimeInterval
    }
    private var chunkTimer: ChunkTimer?
    /// Drives the Words sub-mode's per-word advance — shared with
    /// `LinkRSVPPreview`'s own word timer (see `RSVPPlaybackClock`).
    private lazy var wordClock: RSVPPlaybackClock = {
        let clock = RSVPPlaybackClock()
        clock.delegate = self
        return clock
    }()
    private var wpm: Double = ReaderSettings.baseWPM
    /// Phrases have a minimum display floor, so their remaining time cannot be
    /// derived by scaling one fixed weight. Rebuilt only when content or WPM
    /// changes, then indexed in O(1) as playback advances.
    private var phraseRemainingDurations: [TimeInterval] = []

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

    /// Set by hosts whose chrome floats outside this reader. The READING layout
    /// intentionally IGNORES it: unlike the scroll reader (which scrolls content
    /// behind the floating header), the speed reader centers a single word and
    /// makes no use of the extra top space, so the word, context lanes and
    /// controls must land identically with or without the card chrome. The one
    /// thing that does honour it is the eye-tracking toggle, which lives in the
    /// top-left corner and would otherwise sit under the floating chrome.
    public var topContentInset: CGFloat = 0 {
        didSet {
            guard isViewLoaded,
                  ChromeInsetDebounce.changed(from: oldValue, to: topContentInset)
            else { return }
            view.setNeedsLayout()
        }
    }

    /// Top of the playback controls, for a host that floats a control above them
    /// (the reader's share circle). An ANCHOR rather than a measurement: the
    /// controls now lift off the bottom safe area by an amount only this reader
    /// computes, and a host reading that distance during its own
    /// `viewDidLayoutSubviews` would be reading it a pass late. Nil until the
    /// view loads.
    public var controlsClearanceAnchor: NSLayoutYAxisAnchor? {
        isViewLoaded ? controlsStack.topAnchor : nil
    }

    /// Frame — in THIS reader's coordinate space — of a control the host floats
    /// over the reader rather than beside it: the reader's bottom-right share
    /// circle, which lands in the trailing-context lane. The lane gives up the
    /// width the control covers (see `contextWidth(forLane:fullWidth:)`) instead of
    /// running its prose underneath it. `.null` (the default) reserves nothing.
    public var hostOverlayFrame: CGRect = .null {
        didSet {
            guard isViewLoaded, !hostOverlayFrame.equalTo(oldValue) else { return }
            view.setNeedsLayout()
        }
    }

    private let wordLabel = UILabel()
    /// Multi-line phrase text shown in the focus panel in Phrases mode.
    private let phraseLabel = UILabel()
    /// Surrounding prose. In Words mode this is only visible while paused (so the
    /// single-word focus isn't diluted during playback); in Phrases mode it's
    /// ALWAYS visible and updates as the phrase advances, so the reader keeps the
    /// thread of the sentence.
    private let previousContextLabel = UILabel()
    private let nextContextLabel = UILabel()
    /// The surrounding prose for the current position as the context window
    /// produced it. The LABELS hold what fits their lanes (`layoutContext`); these
    /// hold the whole window, so a relayout can re-fit it against a lane that has
    /// changed height without going back to the engine.
    private var precedingContextText = ""
    private var followingContextText = ""
    /// A compact accent-to-neutral reticule around the ORP letter (Words mode).
    /// Its only vertical elements are two tiny inward ticks; nothing crosses
    /// behind the highlighted glyph.
    private let focusReticule = GlassStyle.rsvpFocusReticule()
    /// Glass panel behind the two-line phrase (Phrases mode).
    private let phrasePanel = GlassStyle.focusPanel()
    private let playPauseButton = UIButton(type: .system)
    private let scrubber = UISlider()
    private let controlsStack = UIStackView()
    /// Sharing affordances handed on to any nested reader this one opens; nil in
    /// the share sheet.
    private var shareProvider: ReaderShareProviding?
    private var finishedReadingTracker = FinishedReadingTracker()
    private let finishedBadge = FinishedReadingBadgeView()
    private let statusLabel = UILabel()
    private let wpmDownButton = UIButton(type: .system)
    private let wpmUpButton = UIButton(type: .system)
    private let skipBackButton = UIButton(type: .system)
    private let skipForwardButton = UIButton(type: .system)

    /// Top-left eye-tracking toggle, and the coordinator behind it. Both exist
    /// only where face tracking could actually run (see
    /// `GazeTrackingAvailability`) — on a device without a TrueDepth camera, or
    /// inside a share/action extension, the corner stays empty.
    private let eyeTrackingButton = EyeTrackingToggleButton()
    private var gazeCoordinator: RSVPGazeCoordinator?
    /// Test seam: substitutes the gaze source. Must be set before the view loads.
    var gazeTrackerOverride: GazeTracking?
    /// Test seam: substitutes the clock the gaze coordinator measures its
    /// away-threshold and resume-dwell against, so a test can prove what
    /// happens after four seconds of staring without spending four seconds.
    /// Must be set before the view loads.
    var gazeClockOverride: (() -> TimeInterval)?

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

    /// Horizontal position of the focal (ORP) column, as a fraction of the
    /// reading COLUMN (see `contentColumn`) — not of the view. On a wide screen
    /// the two differ, and a fraction of the view would fling the focal word a
    /// third of a metre from where the eye is resting.
    private static let focalFraction: CGFloat = 0.4
    /// Widest the speed reader's own column gets. Beyond it the focal word, the
    /// phrase panel and the surrounding prose would spread out far enough that
    /// a single fixation could no longer take them in — which is the entire
    /// premise of the mode.
    private static let maximumColumnWidth: CGFloat = 600
    /// Target characters visible on one line — the font is sized so a word this
    /// long fits, and longer words split (`WordSplitter`).
    private static let targetCharactersAcross = 15
    private static let contextWordCount = 55
    /// The surrounding prose's own font — also the one the lane-fitting
    /// measurements run against, so they must not drift apart.
    private static let contextFont = UIFont.systemFont(ofSize: 15, weight: .regular)
    /// First line the reader owns: below the host chrome standing over it.
    /// `topContentInset` is load-bearing — inside a card it is the (possibly
    /// multi-line) title header's real height, and a band measured from the
    /// view's own top sat under it.
    private var readingBandTop: CGFloat {
        view.safeAreaInsets.top + topContentInset + 18
    }
    /// Bottom of the reading band: the top of the playback controls.
    private var readingBandBottom: CGFloat {
        controlsStack.frame.minY > 0
            ? controlsStack.frame.minY
            : view.safeAreaLayoutGuide.layoutFrame.maxY - 140
    }
    /// Vertical center of the focal word / phrase: the MIDPOINT of the reading
    /// band — the space between the host chrome and the playback controls — so
    /// a tall title header can never cover the reticule and the controls can
    /// never be overrun.
    ///
    /// This differs from the VIEW's own midpoint whenever the chrome above and
    /// the controls below are not equally tall — the action extension's
    /// navigation bar alone takes ~140pt off the top. `focalCenterBias` adds a
    /// small downward lean, because the preceding-context lane runs taller than
    /// the trailing one, so the room above the word is worth more.
    private var focalCenterY: CGFloat {
        let top = readingBandTop
        let controlsTop = readingBandBottom
        // Keep the link/completion lane below the focused content and leave the
        // focused type clear of the title header above.
        let lowerClearance: CGFloat = displayMode == .phrases ? 104 : 106
        let upperClearance: CGFloat = displayMode == .phrases ? 54 : 42
        let minimumCenter = top + upperClearance
        let maximumCenter = controlsTop - 12 - lowerClearance
        guard maximumCenter >= minimumCenter else {
            return (top + controlsTop) / 2
        }
        let bandCenter = (top + controlsTop) / 2 + Self.focalCenterBias
        return min(max(bandCenter, minimumCenter), maximumCenter)
    }

    /// How far below the reading band's midpoint the focal word rests.
    private static let focalCenterBias: CGFloat = 16

    /// Gap the controls always keep from the bottom safe area.
    private static let controlsBaseBottomInset: CGFloat = 24
    /// Extra lift granted on a container tall enough that the reading band has
    /// height to spare — the controls unglue from the bottom edge and the whole
    /// reading group (which is centered on the band, so it follows them up)
    /// stops sitting in the lower third of an action-extension sheet.
    private static let controlsMaximumLift: CGFloat = 40
    /// Band height below which the lift is refused outright: everything from the
    /// preceding-context prose to the trailing lane already wants this much, so
    /// on a short container the controls stay put rather than crowd the word.
    private static let comfortableReadingBandHeight: CGFloat = 340
    /// Height the controls stack occupies before it has been laid out once
    /// (scrubber + status + 64pt button row + two 12pt gaps).
    private static let estimatedControlsHeight: CGFloat = 138

    private var controlsBottomConstraint: NSLayoutConstraint?

    /// Negative inset from the bottom safe area for the controls stack: the base
    /// gap, plus the lift a roomy band can afford. Measured from the UNLIFTED
    /// geometry so the result can't feed back into itself.
    private var controlsBottomInset: CGFloat {
        let controlsHeight = controlsStack.bounds.height > 0
            ? controlsStack.bounds.height
            : Self.estimatedControlsHeight
        let bandBottom = view.safeAreaLayoutGuide.layoutFrame.maxY
            - Self.controlsBaseBottomInset - controlsHeight
        let band = bandBottom - readingBandTop
        let lift = min(
            Self.controlsMaximumLift, max(0, band - Self.comfortableReadingBandHeight))
        return -(Self.controlsBaseBottomInset + lift)
    }

    private func updateControlsBottomInset() {
        guard let controlsBottomConstraint else { return }
        let target = controlsBottomInset
        guard abs(controlsBottomConstraint.constant - target) > 0.5 else { return }
        controlsBottomConstraint.constant = target
        view.layoutIfNeeded()
    }

    /// Sized at init from the device width so `targetCharactersAcross`
    /// characters fit beside the focal column without running off-screen.
    private let wordFont: UIFont
    /// Smaller, proportional font for the two-line phrase display.
    private let phraseFont: UIFont

    public init(item: SavedItem, content: ArticleContent, audioEnabled: Bool = false,
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
        rebuildPhraseRemainingDurations()
    }

    /// Initial frame from the shared token-space resume sources, in priority
    /// order: the position carried over from another reader mode, then the item's
    /// persisted position. Both are TOKEN indices — `frameIndex(forTokenIndex:)`
    /// converts into RSVP frame space, which gains extra frames for compound
    /// and length-capped token parts.
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
        item: SavedItem,
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
        item: SavedItem,
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
        rebuildPhraseRemainingDurations()
        self.currentIndex = 0
        self.currentChunkIndex = 0
        self.isPlaying = false
        self.finishedReadingTracker = FinishedReadingTracker()

        currentIndex = resolveResumeFrame(carriedOver: resumeWordIndex)
        if displayMode == .phrases { currentChunkIndex = chunkIndex(forWord: currentIndex) }

        guard isViewLoaded else { return }
        gazeCoordinator?.setAudioPlaybackOn(isSpeechMode)
        updateMeldAnchor()
        scrubber.maximumValue = Float(max(engine.words.count - 1, 1))
        scrubber.value = Float(currentIndex)
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
        let playingMine = centerOwnsItem && center.isAudiblyPlaying
        isPlaying = playingMine
        updateContextVisibility(animated: false)
    }

    /// Keeps the play/pause button's glyph + accessibility label in lockstep
    /// with `isPlaying`, from wherever it's set.
    private func updatePlayPauseGlyph() {
        playPauseButton.configuration?.image = UIImage(systemName: isPlaying ? "pause.fill" : "play.fill")
        playPauseButton.accessibilityLabel = isPlaying
            ? L10n.string("Reader_rsvp_pauseAccessibilityLabel") : L10n.string("Reader_rsvp_playAccessibilityLabel")
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    /// The centered reading column every element of the speed reader is laid out
    /// in. Identical to the view's own width on a phone; capped and centered on
    /// anything wider.
    private var contentColumn: CGRect {
        let width = min(view.bounds.width, Self.maximumColumnWidth)
        return CGRect(
            x: (view.bounds.width - width) / 2, y: 0,
            width: width, height: view.bounds.height)
    }

    /// The focal (ORP) column's x, inside the reading column.
    private var focalColumnX: CGFloat {
        let column = contentColumn
        return column.minX + column.width * Self.focalFraction
    }

    /// Where the reader's eyes are expected to be: the ORP column in Words, the
    /// centre of the phrase panel in Phrases. Published because eye tracking
    /// measures every glance against it.
    public var focalGazePoint: CGPoint {
        let x = displayMode == .phrases ? view.bounds.midX : focalColumnX
        return CGPoint(x: x, y: focalCenterY)
    }

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
        configureEyeTracking()

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
        gazeCoordinator?.setVisible(true)
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Before anything measures the reading band: the lift moves its floor.
        updateControlsBottomInset()
        layoutEyeTrackingButton()
        layoutFocusReticule()
        layoutPhrasePanel()
        layoutContext()
        layoutLinkPill()
        layoutFinishedBadge()
        refreshDisplay()
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        gazeCoordinator?.setVisible(false)
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
        view.addSubview(focusReticule)
    }

    /// Installs the top-left eye-tracking toggle — or nothing at all, where the
    /// feature could never run. The coordinator is still created so the reader
    /// has one uniform place to report playback state to.
    private func configureEyeTracking() {
        let coordinator = gazeClockOverride.map {
            RSVPGazeCoordinator(tracker: gazeTrackerOverride, now: $0)
        } ?? RSVPGazeCoordinator(tracker: gazeTrackerOverride)
        coordinator.delegate = self
        coordinator.attach(to: view)
        coordinator.setAudioPlaybackOn(isSpeechMode)
        gazeCoordinator = coordinator

        eyeTrackingButton.isHidden = !coordinator.isAvailable
        guard coordinator.isAvailable else { return }
        eyeTrackingButton.addTarget(self, action: #selector(eyeTrackingToggled), for: .touchUpInside)
        view.addSubview(eyeTrackingButton)
        refreshEyeTrackingButton()

        // The camera must not keep running behind a backgrounded app, and a
        // reader resumed from the background should start watching again
        // without waiting for an appearance callback that will never come.
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(applicationDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.addObserver(
            self, selector: #selector(applicationWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    /// The toggle's REAL seat inside a card is the host's chrome row — the
    /// card's top-left, level with the deck's read-aloud circle — reached via
    /// `hostAdoptableEyeTrackingToggle`. A toggle kept in the reader's own
    /// view cannot sit there: the card's opaque title header is a sibling
    /// ABOVE the reader, so a card-corner placement would bury the control
    /// behind it. This fallback placement (used by hosts that never adopt —
    /// standalone, extensions) therefore measures from the first line the
    /// reader owns: below `safeAreaInsets.top + topContentInset`.
    private func layoutEyeTrackingButton() {
        guard !eyeTrackingButton.isHidden else { return }
        // Released by a host that adopted it earlier: take it back.
        if eyeTrackingButton.superview == nil { view.addSubview(eyeTrackingButton) }
        // Adopted into a host's chrome row: the host frames it.
        guard eyeTrackingButton.superview === view else { return }
        let size = EyeTrackingToggleButton.diameter
        let inset = Self.eyeTrackingCornerInset
        eyeTrackingButton.frame = CGRect(
            x: inset, y: view.safeAreaInsets.top + topContentInset + inset,
            width: size, height: size)
    }

    /// The eye-tracking toggle, offered to a host that renders the reader's
    /// chrome outside the reader (the card deck's circle row). Nil where the
    /// feature can never run. The reader keeps driving the button's state and
    /// handling its taps; the host only gives it a seat beside its own
    /// circles — and must return it (remove from superview) when the reader
    /// leaves RSVP.
    public var hostAdoptableEyeTrackingToggle: UIButton? {
        guard isViewLoaded, !eyeTrackingButton.isHidden else { return nil }
        return eyeTrackingButton
    }

    /// Matches `ArticleCardsViewController.chromeCardCornerInset`.
    private static let eyeTrackingCornerInset: CGFloat = 12

    private func refreshEyeTrackingButton() {
        guard let gazeCoordinator else { return }
        eyeTrackingButton.trackingState = gazeCoordinator.displayState
        eyeTrackingButton.isEnabled = gazeCoordinator.isToggleInteractive
    }

    @objc private func eyeTrackingToggled() {
        gazeCoordinator?.toggle(presenting: self)
    }

    @objc private func applicationDidEnterBackground() {
        gazeCoordinator?.setVisible(false)
    }

    @objc private func applicationWillEnterForeground() {
        guard view.window != nil else { return }
        gazeCoordinator?.setVisible(true)
    }

    /// Spans several characters around the ORP column. The top/bottom lines sit
    /// clear of the glyph — far enough that their inward ticks stop short of the
    /// letter's cap rather than closing in on it (see `RSVPFocusReticuleMetrics`).
    private func layoutFocusReticule() {
        let centerY = focalCenterY
        let baselineY = centerY - wordFont.lineHeight / 2 + wordFont.ascender
        focusReticule.frame = RSVPFocusReticuleMetrics.frame(
            focalX: focalColumnX,
            capTop: baselineY - wordFont.capHeight,
            capHeight: wordFont.capHeight,
            characterWidth: ("0" as NSString).size(withAttributes: [.font: wordFont]).width)
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
        let maxWidth = max(160, contentColumn.width - horizontalMargin * 2)
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
            label.font = Self.contextFont
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
        // NB: the preceding lane keeps the words closest to the focal word by
        // DROPPING leading words (`fittedPrecedingProse`), not by asking UILabel
        // for head truncation. `.byTruncatingHead` ellipsises only the LAST
        // visible line, so an overlong passage rendered as "the article's oldest
        // words … the words just before the focus" — a hole cut out of the middle.
    }

    /// Lays out the surrounding-prose labels above and below the focal band. In
    /// Phrases mode they hug the phrase panel (and are always shown); in Words
    /// mode they fill the space above/below the single word (shown when paused).
    private func layoutContext() {
        let horizontalMargin: CGFloat = 28
        let column = contentColumn
        let width = max(0, column.width - horizontalMargin * 2)
        let contextX = column.minX + horizontalMargin
        // The preceding-context lane grows upward into the freed top of the
        // screen: it must clear whatever host chrome stands over the reader
        // (`topContentInset` — the card's opaque title header), and stop
        // below the eye-tracking toggle when that corner is occupied by the
        // reader's own fallback placement (a host-adopted toggle lives in the
        // host's chrome row, above the header, and takes no reader room).
        let chromeFloor = view.safeAreaInsets.top + topContentInset + 20
        let toggleInReader = !eyeTrackingButton.isHidden
            && eyeTrackingButton.superview === view
        let topLimit = toggleInReader
            ? max(chromeFloor, eyeTrackingButton.frame.maxY + 12)
            : chromeFloor

        let lanes = focalLanes
        // Words mode: the preceding-context label grows upward into the free
        // top of the screen. Its bottom stays anchored to the focal band, so
        // the word and everything below it don't move.
        let upperHeight: CGFloat = displayMode == .phrases ? 120 : 220
        let upperBottom = lanes.precedingBottom
        // Each lane is sized to the PROSE it holds, not to the lane it may grow
        // into: a label given the full lane centers a short passage inside it,
        // which reads as a hole between the chrome and the text and a second
        // hole between the text and the word. The preceding lane keeps its
        // bottom against the focal band and grows upward (truncating its oldest
        // words off the top once it fills); the trailing lane keeps its top
        // against the band and grows downward.
        let upperLaneHeight = max(0, min(upperHeight, upperBottom - topLimit))
        // The preceding lane's text is FITTED to the lane here rather than set in
        // `updateContextText`: how much of the window survives depends on the lane
        // this pass produced, and a label sized to text it can't hold truncates in
        // the wrong place (see `configureContext`).
        let upperText = precedingContextDisplayText(width: width, laneHeight: upperLaneHeight)
        previousContextLabel.attributedText = upperText
        let upperTextHeight = min(upperLaneHeight, textHeight(of: upperText, width: width))
        previousContextLabel.frame = CGRect(
            x: contextX, y: upperBottom - upperTextHeight,
            width: width, height: upperTextHeight)

        let controlsTop = readingBandBottom
        let lowerY = lanes.trailingTop
        let lowerHeight: CGFloat = displayMode == .phrases ? 120 : 96
        let lowerLaneHeight = max(0, min(lowerHeight, controlsTop - lowerY - 12))
        // A control the HOST floats over this reader (the reader's bottom-right
        // share circle) sits inside the trailing lane's rectangle. The prose
        // gives up the width the circle covers rather than running under it.
        let lowerWidth = contextWidth(
            forLane: CGRect(x: contextX, y: lowerY, width: width, height: lowerLaneHeight),
            fullWidth: width)
        // The trailing lane loses its FURTHEST words when it overflows, which is
        // exactly what UILabel's tail truncation does — so it takes the window
        // whole and lets the label ellipsise it.
        nextContextLabel.text = followingContextText
        let lowerTextHeight = min(
            lowerLaneHeight, textHeight(of: followingContextText, width: lowerWidth))
        nextContextLabel.frame = CGRect(
            x: contextX, y: lowerY, width: lowerWidth, height: lowerTextHeight)
    }

    /// The three edges everything around the focal display measures from: where
    /// the preceding prose stops, where the pill row (link preview / completion
    /// badge) sits, and where the trailing prose starts.
    private struct FocalLanes {
        let precedingBottom: CGFloat
        let pillTop: CGFloat
        let trailingTop: CGFloat
    }

    /// Half-height of the focal display measured from `focalCenterY`: in Words
    /// mode the greater of the word label's own line box and the reticule's reach
    /// (both scale with `wordFont`, which is sized from the screen width — a
    /// fixed clearance would crowd the glyph on a wide screen); in Phrases mode
    /// the glass panel's half-height.
    private var focalHalfHeight: CGFloat {
        guard displayMode != .phrases else { return phrasePanel.bounds.height / 2 }
        let lineHalf = wordFont.lineHeight / 2
        let padding = RSVPFocusReticuleMetrics.verticalPadding
        // Mirrors `layoutFocusReticule`, relative to the focal centre.
        let baseline = wordFont.ascender - lineHalf
        let reticuleAbove = wordFont.capHeight + padding - baseline
        let reticuleBelow = baseline + padding
        return max(lineHalf, max(reticuleAbove, reticuleBelow))
    }

    /// The prose lanes and the pill row, all measured off the focal display's
    /// own half-height rather than a fixed band (see `focalProseGaps`).
    ///
    /// **The pill row is only reserved while something occupies it.** Reserving
    /// an empty 36pt row under every word would hold the lower gap open for
    /// nothing, since the row is nearly always empty: a link pill shows only on
    /// a linkified word, and the completion badge only at the end of the
    /// article, where the trailing prose is empty anyway. When a pill does
    /// appear, the trailing prose steps down for it, animated with the pill's
    /// own fade (see `updateLinkPill`).
    private var focalLanes: FocalLanes {
        let centerY = focalCenterY
        let half = focalHalfHeight
        let gaps = focalProseGaps
        let pillTop = centerY + half + gaps.below
        let occupied = linkPill.alpha > 0 || !finishedBadge.isHidden
        return FocalLanes(
            precedingBottom: centerY - half - gaps.above,
            pillTop: pillTop,
            trailingTop: occupied ? pillTop + Self.phrasePillHeight + 10 : pillTop)
    }

    /// Air between the focal display and the prose above / below it. Words mode
    /// keeps a small gap, roomier below because the pill row lands there.
    /// Phrases keeps a tighter, even pair — its glass panel already separates
    /// the phrase from the prose above and below.
    private var focalProseGaps: (above: CGFloat, below: CGFloat) {
        displayMode == .phrases ? (14, 14) : (20, 31)
    }

    /// Height a plain context string needs at `width`, unbounded by lines — the
    /// caller clamps it to the lane, which is where truncation happens.
    private func textHeight(of text: String, width: CGFloat) -> CGFloat {
        guard !text.isEmpty, width > 0 else { return 0 }
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: Self.contextFont],
            context: nil)
        return ceil(bounds.height)
    }

    /// Same, for the attributed preceding lane (which carries the masthead's two
    /// fonts). The paragraph styles are re-measured as word-WRAPPING: a truncating
    /// `lineBreakMode` makes `boundingRect` report a single line's height, and the
    /// answer here has to be the height the label will actually fill.
    private func textHeight(of text: NSAttributedString, width: CGFloat) -> CGFloat {
        guard text.length > 0, width > 0 else { return 0 }
        let full = NSRange(location: 0, length: text.length)
        let measured = NSMutableAttributedString(attributedString: text)
        measured.enumerateAttribute(.paragraphStyle, in: full) { value, range, _ in
            let style = (value as? NSParagraphStyle)?
                .mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            style.lineBreakMode = .byWordWrapping
            measured.addAttribute(.paragraphStyle, value: style, range: range)
        }
        let bounds = measured.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil)
        return ceil(bounds.height)
    }

    /// The lane's width less whatever a host-floated control covers of it.
    private func contextWidth(forLane lane: CGRect, fullWidth: CGFloat) -> CGFloat {
        guard !hostOverlayFrame.isNull, hostOverlayFrame.intersects(lane) else {
            return fullWidth
        }
        return max(Self.minimumContextWidth, hostOverlayFrame.minX - 12 - lane.minX)
    }

    /// A lane never narrows past this: below it the prose would read as a column
    /// of fragments, which is worse than letting the host's circle graze it.
    private static let minimumContextWidth: CGFloat = 140

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
        let maxWidth = contentColumn.width - 64
        let fitted = linkPill.systemLayoutSizeFitting(
            CGSize(width: maxWidth, height: 40),
            withHorizontalFittingPriority: .fittingSizeLevel,
            verticalFittingPriority: .required)
        let width = min(max(fitted.width, 80), maxWidth)
        linkPill.frame = CGRect(
            x: (view.bounds.width - width) / 2, y: focalLanes.pillTop,
            width: width, height: Self.phrasePillHeight)
    }

    /// Link-pill geometry shared with `layoutContext` so the lower context clears it.
    private static let phrasePillHeight: CGFloat = 36

    /// Shows/refreshes the pill for a linkified word, or starts the post-link
    /// buffer when a non-link word arrives (a new link replaces it immediately).
    private func updateLinkPill(for url: URL?) {
        if let url {
            linkPillHideTimer?.invalidate()
            linkPillHideTimer = nil
            if url != linkPillURL {
                linkPillURL = url
                let host = url.host.map(HostMatching.normalizedHost) ?? url.absoluteString
                linkPill.configuration?.title = host
                view.setNeedsLayout()
            }
            if linkPill.alpha < 1 {
                // The trailing prose gives the pill row its 36pt back — inside the
                // same animation, so the paragraph slides rather than jumps.
                UIView.animate(withDuration: 0.2) {
                    self.linkPill.alpha = 1
                    self.view.layoutIfNeeded()
                }
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
        UIView.animate(withDuration: 0.25) {
            self.linkPill.alpha = 0
            self.view.layoutIfNeeded()
        }
    }

    @objc private func linkPillTapped() {
        guard let url = linkPillURL else { return }
        activateLink(url)
    }

    private func activateLink(_ url: URL) {
        pause()
        if let linkActivationDelegate {
            linkActivationDelegate.reader(self, didActivateLink: url, at: linkPill.center)
            return
        }
        InlineReaderOpener.open(
            url: url,
            from: self,
            coordinator: inlineReaderPresentationCoordinator,
            shareProvider: shareProvider,
            sourcePointInWindow: view.convert(linkPill.center, to: nil),
            outerURL: item.url ?? url,
            outerTitle: articleContent.title)
    }

    private func configureLinkPreview() {
        linkPreviewInteraction = LinkRSVPPreviewInteraction(
            host: self,
            sourceView: linkPill,
            resolveURL: { [weak self] _ in self?.linkPillURL },
            delegate: self)
    }

    private func configureControls() {
        var playConfig = GlassStyle.circularButtonConfiguration(symbol: "play.fill", padding: 16)
        playConfig.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 28)
        // `.capsule` can size the glass background optically around the tall,
        // narrow play glyph even when the control itself is square. A fixed
        // radius makes the configured background use the full 60×60 circle.
        playConfig.cornerStyle = .fixed
        playConfig.background.cornerRadius = 30
        playPauseButton.configuration = playConfig
        playPauseButton.accessibilityLabel = L10n.string("Reader_rsvp_playAccessibilityLabel")
        // Pin the control layer too, so both the glass and its clipping mask stay
        // circular through highlighted/disabled configuration updates.
        playPauseButton.clipsToBounds = true
        playPauseButton.layer.cornerRadius = 30
        playPauseButton.layer.cornerCurve = .circular
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
        wpmDownButton.accessibilityLabel = L10n.string("Reader_rsvp_slowDownAccessibilityLabel")
        wpmDownButton.accessibilityHint = L10n.string("Reader_rsvp_slowDownAccessibilityHint")
        wpmUpButton.accessibilityLabel = L10n.string("Reader_rsvp_speedUpAccessibilityLabel")
        wpmUpButton.accessibilityHint = L10n.string("Reader_rsvp_speedUpAccessibilityHint")
        wpmDownButton.addTarget(self, action: #selector(wpmDown), for: .touchUpInside)
        wpmUpButton.addTarget(self, action: #selector(wpmUp), for: .touchUpInside)

        var skipBackConfig = GlassStyle.circularButtonConfiguration(symbol: "backward.fill", padding: 12)
        skipBackConfig.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 19)
        skipBackButton.configuration = skipBackConfig
        var skipForwardConfig = GlassStyle.circularButtonConfiguration(symbol: "forward.fill", padding: 12)
        skipForwardConfig.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 19)
        skipForwardButton.configuration = skipForwardConfig
        skipBackButton.accessibilityLabel = L10n.string("Reader_rsvp_skipBackAccessibilityLabel")
        skipForwardButton.accessibilityLabel = L10n.string("Reader_rsvp_skipForwardAccessibilityLabel")
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

        // Prefer the roomy 32pt footer margins and 48pt secondary circles, but
        // let compact widths ease them together—symmetrically—down to 16pt /
        // 44pt. The 60pt play circle stays required and never becomes the row's
        // compression escape hatch.
        let preferredLeading = controlsStack.leadingAnchor.constraint(
            equalTo: view.leadingAnchor, constant: 32)
        let preferredTrailing = controlsStack.trailingAnchor.constraint(
            equalTo: view.trailingAnchor, constant: -32)
        preferredLeading.priority = .defaultHigh
        preferredTrailing.priority = .defaultHigh

        let secondaryButtons = [
            skipBackButton, wpmDownButton, wpmUpButton, skipForwardButton,
        ]
        let preferredSecondaryDiameter = skipBackButton.widthAnchor.constraint(equalToConstant: 48)
        preferredSecondaryDiameter.priority = .defaultHigh
        var adaptiveButtonConstraints: [NSLayoutConstraint] = [preferredSecondaryDiameter]
        for button in secondaryButtons {
            adaptiveButtonConstraints.append(contentsOf: [
                button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
                button.widthAnchor.constraint(equalTo: button.heightAnchor),
            ])
        }
        for button in secondaryButtons.dropFirst() {
            adaptiveButtonConstraints.append(
                button.widthAnchor.constraint(equalTo: skipBackButton.widthAnchor))
        }

        let controlsBottom = controlsStack.bottomAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.bottomAnchor,
            constant: -Self.controlsBaseBottomInset)
        controlsBottomConstraint = controlsBottom

        NSLayoutConstraint.activate([
            controlsStack.leadingAnchor.constraint(
                greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            controlsStack.trailingAnchor.constraint(
                lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            preferredLeading,
            preferredTrailing,
            controlsBottom,
            speedRow.heightAnchor.constraint(equalToConstant: 64),
            buttonRow.leadingAnchor.constraint(greaterThanOrEqualTo: speedRow.leadingAnchor, constant: 8),
            buttonRow.trailingAnchor.constraint(lessThanOrEqualTo: speedRow.trailingAnchor, constant: -8),
            buttonRow.centerXAnchor.constraint(equalTo: speedRow.centerXAnchor),
            buttonRow.centerYAnchor.constraint(equalTo: speedRow.centerYAnchor),
            playPauseButton.widthAnchor.constraint(equalToConstant: 60),
            playPauseButton.heightAnchor.constraint(equalToConstant: 60),
            playPauseButton.widthAnchor.constraint(equalTo: playPauseButton.heightAnchor),
        ] + adaptiveButtonConstraints)
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
        focusReticule.isHidden = phrases
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
        let focalX = focalColumnX
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

    /// Re-reads the surrounding prose for the current position. In Phrases mode
    /// the context excludes the words currently in the focus panel; in Words mode
    /// it surrounds the single focal word.
    ///
    /// This only refreshes the SOURCE text — `layoutContext` fits it to the lanes
    /// and puts it on the labels, and is called from here because a lane is sized
    /// to the prose it holds. Without that call the labels kept the frames of the
    /// text they held one word ago: the first words of an article arrived into a
    /// zero-height lane (the position before them had no preceding prose at all)
    /// and never appeared.
    private func updateContextText() {
        let shownRange: Range<Int> = displayMode == .phrases && chunks.indices.contains(currentChunkIndex)
            ? chunks[currentChunkIndex].wordRange
            : currentIndex..<(currentIndex + 1)
        let context = RSVPContextWindow.context(
            around: shownRange, words: engine.words, radius: Self.contextWordCount)
        let preceding = context?.preceding ?? ""
        let following = context?.following ?? ""
        guard preceding != precedingContextText || following != followingContextText
        else { return }
        precedingContextText = preceding
        followingContextText = following
        if isViewLoaded { layoutContext() }
    }

    /// What the preceding lane shows: the surrounding prose trimmed to the lane,
    /// or — before there is any of it — the article's own masthead, so the top of
    /// the screen carries the title and byline instead of standing empty through
    /// the opening words.
    private func precedingContextDisplayText(width: CGFloat, laneHeight: CGFloat) -> NSAttributedString {
        guard !precedingContextText.isEmpty else {
            return mastheadContextText()
        }
        return NSAttributedString(
            string: fittedPrecedingProse(width: width, laneHeight: laneHeight),
            attributes: [.font: Self.contextFont, .foregroundColor: LunaColors.tertiaryText])
    }

    /// The longest SUFFIX of the preceding prose that fits `laneHeight` — the
    /// words nearest the focal word are the ones worth keeping, and dropping the
    /// oldest ones by hand is the only way to drop them from the TOP (see
    /// `configureContext`). Never returns empty: one word over the lane is better
    /// than a blank lane, and the frame clamps it anyway.
    private func fittedPrecedingProse(width: CGFloat, laneHeight: CGFloat) -> String {
        let words = precedingContextText.split(separator: " ")
        guard words.count > 1, width > 0, laneHeight > 0 else { return precedingContextText }
        // Smallest number of leading words to drop that brings the rest into the
        // lane. Monotone in the drop count, so a binary search settles it in ~6
        // measurements rather than one per word.
        var low = 0, high = words.count - 1
        while low < high {
            let mid = (low + high) / 2
            let candidate = words[mid...].joined(separator: " ")
            if textHeight(of: candidate, width: width) <= laneHeight {
                high = mid
            } else {
                low = mid + 1
            }
        }
        return words[low...].joined(separator: " ")
    }

    /// Title over byline, in the preceding lane's own scale — the masthead shown
    /// while there is no preceding prose yet.
    private func mastheadContextText() -> NSAttributedString {
        let title = articleContent.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let author = articleContent.author?.trimmingCharacters(in: .whitespacesAndNewlines)
        let masthead = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.paragraphSpacing = 2
        if !title.isEmpty {
            masthead.append(NSAttributedString(
                string: author?.isEmpty == false ? title + "\n" : title,
                attributes: [
                    .font: UIFont.systemFont(ofSize: 17, weight: .semibold),
                    .foregroundColor: LunaColors.secondaryText,
                    .paragraphStyle: paragraph,
                ]))
        }
        if let author, !author.isEmpty {
            masthead.append(NSAttributedString(
                string: author,
                attributes: [
                    .font: Self.contextFont,
                    .foregroundColor: LunaColors.tertiaryText,
                    .paragraphStyle: paragraph,
                ]))
        }
        return masthead
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
            refreshDisplay()
            scrubber.value = 0
            updateFinishedReadingState()
            updateStatus()
        }
        // The silent reader's word timer is per-instance, so nothing else stops
        // it when the column beside this one starts playing.
        ReaderPlaybackArbiter.claim(self)
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
        ReaderPlaybackArbiter.claim(self)
        if centerOwnsItem {
            if center.isAudiblyPlaying { return }
            if case .paused = center.state { center.resume(); return }
        }
        if currentIndex >= engine.words.count - 1 {
            currentIndex = 0
            currentChunkIndex = 0
            refreshDisplay()
            scrubber.value = 0
            updateFinishedReadingState()
            updateStatus()
        }
        // Start (or switch) playback at the displayed focal word — this is
        // also the "explicit play switches playback to this article" path
        // when something else is playing.
        let token = engine.tokenIndex(forFrameIndex: currentIndex) ?? currentIndex
        center.play(item: item, content: articleContent, fromWordIndex: token)
    }

    /// Stops playback. `deliberate` is true for every route EXCEPT a
    /// gaze-triggered pause — the reader looking away is the one stop that must
    /// not count as "the user settled the question", so it leaves a
    /// play-override (if one were somehow live) alone.
    private func pause(deliberate: Bool = true) {
        if deliberate { gazeCoordinator?.notePlaybackStoppedDeliberately() }
        // Center-driven speech mode: lifecycle pauses (reuse, disappearing,
        // sub-mode switches) must NEVER stop the app-wide playback —
        // navigating away is exactly when background audio should keep going.
        // Explicit user pauses go through `togglePlayPause`/`scrubbed`, which
        // pause the center directly; this path only settles local state.
        if speechCenter != nil {
            cancelChunkTimer()
            wordClock.cancel()
            saveProgress()
            return
        }
        ReaderPlaybackArbiter.resign(self)
        isPlaying = false
        cancelChunkTimer()
        wordClock.cancel()
        isSpeedHeld = false
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
            if centerOwnsItem, center.isAudiblyPlaying {
                center.pause()
            } else {
                play()
            }
            return
        }
        if isPlaying {
            pause()
        } else {
            // Pressing play while looking away is an explicit override: it
            // wins over the setting AND stands eye tracking down, so the next
            // glance elsewhere doesn't immediately stop the reader again.
            if gazeCoordinator?.isLookingAway == true { gazeCoordinator?.notePlayOverride() }
            play()
        }
    }

    /// The full-screen tap: pause-only, never a toggle.
    @objc private func surfaceTapped() {
        if let center = speechCenter {
            if centerOwnsItem, center.isAudiblyPlaying { center.pause() }
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
            guard let chunkTimer else { return }
            let remaining = max(0, chunkTimer.duration - Date().timeIntervalSince(chunkTimer.start)) * factor
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
        chunkTimer?.timer.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { _ in
            handler()
        }
        chunkTimer = ChunkTimer(timer: timer, start: Date(), duration: interval)
    }

    /// Invalidates and clears the Phrases sub-mode's chunk timer — the ONE
    /// place that happens, so the timer and the start/duration it was
    /// scheduled with can never go out of sync.
    private func cancelChunkTimer() {
        chunkTimer?.timer.invalidate()
        chunkTimer = nil
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
        updateStatus()
        pause()
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
            cancelChunkTimer()
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
        updateFinishedReadingState()
        updateStatus()
        // Reaching for the scrubber or a skip button means looking away from
        // the word on purpose; don't spend the away allowance on it.
        gazeCoordinator?.focalPositionDidJump()
    }

    @objc private func wpmDown() { adjustWPM(by: -25) }
    @objc private func wpmUp() { adjustWPM(by: 25) }

    private func adjustWPM(by delta: Double) {
        wpm = min(max(wpm + delta, 100), 900)
        ReaderSettings.baseWPM = wpm
        rebuildPhraseRemainingDurations()
        updateStatus()
    }

    private func rebuildPhraseRemainingDurations() {
        phraseRemainingDurations = ChunkPlanner.remainingDurations(for: chunks, wpm: wpm)
    }

    private func updateStatus() {
        let duration: TimeInterval
        if finishedReadingTracker.isFinished {
            duration = 0
        } else if displayMode == .phrases,
                  phraseRemainingDurations.indices.contains(currentChunkIndex) {
            duration = phraseRemainingDurations[currentChunkIndex]
        } else {
            duration = engine.remainingDuration(from: currentIndex, wpm: wpm)
        }
        let time = RSVPTimeRemainingFormatter.string(from: duration)
        statusLabel.text = L10n.string("Reader_rsvp_statusTimeRemainingWpm", time, Int(wpm))
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
            scrollOffset: .clear,
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
            completionDelegate?.readerDidMoveAwayFromEnd(self)
        }
    }
}

extension RSVPViewController: ReaderPlaybackPausable {
    /// The reader beside this one started. Stop, whichever engine is running:
    /// the app-wide voice if it is speaking this article, otherwise the local
    /// word timer.
    public func pauseForExclusivePlayback() {
        if let center = speechCenter, centerOwnsItem,
           center.isAudiblyPlaying {
            center.pause()
        } else if isPlaying {
            pause()
        }
    }
}

extension RSVPViewController: RSVPPlaybackClockDelegate {
    public func playbackClockDidFire(_ clock: RSVPPlaybackClock) {
        advance()
    }
}

// MARK: - Eye tracking

extension RSVPViewController: RSVPGazeCoordinatorDelegate {

    func gazeCoordinatorRequestsPause(_ coordinator: RSVPGazeCoordinator) {
        guard isPlaying else { return }
        pause(deliberate: false)
    }

    func gazeCoordinatorRequestsResume(_ coordinator: RSVPGazeCoordinator) {
        guard !isPlaying, speechCenter == nil || !isSpeechMode else { return }
        play()
    }

    func gazeCoordinatorDidChangeDisplayState(_ coordinator: RSVPGazeCoordinator) {
        refreshEyeTrackingButton()
    }

    func gazeCoordinatorFocalPoint(_ coordinator: RSVPGazeCoordinator) -> CGPoint {
        focalGazePoint
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

// MARK: - Layout seam

extension RSVPViewController {

    /// Where the reader put itself: the band it lays out inside (host chrome
    /// above, playback controls below) and what landed where within it. Read by
    /// the layout tests so they assert on the geometry the reader actually
    /// computed rather than re-deriving it from private constants.
    struct LayoutGeometry {
        let bandTop: CGFloat
        let bandBottom: CGFloat
        let focalCenterY: CGFloat
        /// Half-height of the focal display (word line box / reticule reach, or
        /// the phrase panel) — the edge the prose gaps are measured from.
        let focalHalfHeight: CGFloat
        let precedingContext: CGRect
        let trailingContext: CGRect
        let pillRow: CGRect
        let controls: CGRect
        /// Midpoint of the band — where the focal word rests, plus its bias.
        var bandCenterY: CGFloat { (bandTop + bandBottom) / 2 }
        /// Air between the focal display and the prose above / below it.
        var gapAboveProse: CGFloat {
            focalCenterY - focalHalfHeight - precedingContext.maxY
        }
        var gapBelowProse: CGFloat {
            trailingContext.minY - focalCenterY - focalHalfHeight
        }
    }

    var layoutGeometryForTesting: LayoutGeometry {
        LayoutGeometry(
            bandTop: readingBandTop,
            bandBottom: readingBandBottom,
            focalCenterY: focalCenterY,
            focalHalfHeight: focalHalfHeight,
            precedingContext: previousContextLabel.frame,
            trailingContext: nextContextLabel.frame,
            pillRow: linkPill.frame,
            controls: controlsStack.frame)
    }

    /// The focal word's downward lean off the band midpoint, for the tests.
    static var focalCenterBiasForTesting: CGFloat { focalCenterBias }

    /// What the two prose lanes are actually showing — the fitted text, not the
    /// window it was cut from.
    var contextProseForTesting: (preceding: String, following: String) {
        (previousContextLabel.attributedText?.string ?? previousContextLabel.text ?? "",
         nextContextLabel.attributedText?.string ?? nextContextLabel.text ?? "")
    }
}

extension RSVPViewController: UIGestureRecognizerDelegate {
    /// The full-screen play/pause tap must ignore touches that land on any
    /// interactive control — the skip ±25-word buttons, the ±25 speed buttons,
    /// the play/pause button, the scrubber, and the link pill — so those taps
    /// reach the control instead of being cancelled by the full-screen tap
    /// (which `cancelsTouchesInView`).
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

/// A link preview owns read-aloud while it is up: the speed read stands down
/// (through the center when the center owns this item) and resumes afterwards
/// only if it was actually running.
extension RSVPViewController: LinkRSVPPreviewInteractionDelegate {
    func linkPreviewInteraction(
        _ interaction: LinkRSVPPreviewInteraction, sourcePlaybackIsSuspended: Bool
    ) {
        if sourcePlaybackIsSuspended {
            wasPlayingBeforeLinkPreview = isPlaying
            if let center = speechCenter, centerOwnsItem, center.isAudiblyPlaying {
                center.pause()
            } else if isPlaying {
                pause()
            }
        } else if wasPlayingBeforeLinkPreview {
            wasPlayingBeforeLinkPreview = false
            play()
        }
    }
}

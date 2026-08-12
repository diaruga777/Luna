//
//  OnboardingVideoDownloadLesson.swift
//  Luna
//

import AVFoundation
import LunaDesignSystem
import LunaModels
import UIKit

/// The timing of the Downloader's Safari lesson: the mock post is left alone
/// long enough to read what is wrong with it, the player arrives the way the
/// extension's own does, plays, and only then does the panel say how to get it.
enum OnboardingVideoDownloadTiming {
    /// The blocked post stands on its own before Luna answers it. Long enough
    /// to READ the wall — the lesson's premise is that this page is refusing
    /// you, and a beat that only registers as a flash states no premise at all.
    static let pageHoldDuration: TimeInterval = 3.2
    static let presentDuration: TimeInterval = 0.45
    /// A short beat confirms that the panel is a live player before the shared
    /// setup flow advances; waiting through most of the clip stalls the lesson.
    static let playbackHoldDuration: TimeInterval = 0.75
}

/// A native replica of the panel the Safari extension puts over a video post —
/// `presentVideoOverlay` in `LunaSafari/Resources/content.js` — used by the
/// Downloader's Safari lesson over the bundled InstaTok page.
///
/// Every measurement is that function's own, read straight across from its
/// inline styles: a 78%-black blurred backdrop, a `calc(100vw - 24px)` panel
/// capped at 640 in `NIGHT_SURFACE` with a 20pt radius and 10pt padding, a 34pt
/// round close button over an 8pt gap, a black stage at radius 12, and the
/// indigo full-width "Download in Luna" capsule 10pt under it. Nothing here is
/// a stylisation of that panel; a change to either one is a change to both.
/// **One deliberate deviation**: the stage is the bundled clip's own portrait
/// (9:16) aspect rather than `content.js`'s landscape 16:9 — see `stageAspect`
/// below — since the extension's real panel plays whatever aspect a post's own
/// video is, and this lesson's bundled clip is a portrait one.
///
/// The panel STAYS in this one player state for the whole lesson now — it used
/// to grow a chin of enable steps once the clip had played; that copy moved to
/// the hosted setup web page, and the panel's own job shrank to just playing
/// the clip and reporting `onDidReachSetupOffer` once it plainly has. The page
/// underneath needs no explainer of its own either way — which is why the
/// Downloader's Safari demonstration opens on InstaTok rather than on
/// `luna.app` (`OnboardingSafariLesson`). It is the media sibling of
/// `OnboardingPriceComparisonOverlayView`, and keeps that lesson's shape:
/// `begin` / `reset`, mounted with the browser and generation-guarded so a
/// rewind cancels its pending beats.
///
/// Nothing in the panel answers a tap any more — not even an activate/skip
/// pair, since those now live on the shared, window-hosted setup popup rather
/// than inside this view. The close button, the download button, the player's
/// own controls remain pictures of controls, inert by construction (no
/// target, no gesture recognizer), because a demonstration that answers a tap
/// is a demonstration that can be taken somewhere it cannot go.
@MainActor
final class OnboardingVideoDownloadOverlayView: UIView {
    /// The lesson has said everything it has to say: the panel has arrived and
    /// the clip is plainly playing. Central Luna, which plays this lesson as
    /// one of three, uses it to hand over to the next sibling; a faceted app
    /// uses it to raise the shared setup popup directly.
    var onDidReachSetupOffer: (() -> Void)?

    private enum Metrics {
        /// `padding: "12px"` on the backdrop, `calc(100vw - 24px)` on the panel.
        static let backdropPadding: CGFloat = 12
        static let panelMaxWidth: CGFloat = 640
        static let panelPadding: CGFloat = 10
        static let panelCornerRadius: CGFloat = 20
        static let closeSide: CGFloat = 34
        /// `padding: "0 0 8px 0"` under the header row.
        static let headerBottomGap: CGFloat = 8
        static let stageCornerRadius: CGFloat = 12
        /// `margin: "10px 0 0 0"`, `minHeight: "44px"`.
        static let downloadTopGap: CGFloat = 10
        static let downloadHeight: CGFloat = 44
    }

    /// Not to be confused with the `stage` view below — that name is
    /// `content.js`'s, for the black rectangle the video plays in.
    private enum LessonStage {
        /// Mounted, invisible: the blocked post is being read.
        case idle
        /// The panel is up and the clip is playing under the download button.
        /// The panel never leaves this state again — the lesson's ending is
        /// the shared popup arriving above it, not a change to the panel.
        case player
    }

    private final class PlayerLayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    /// `NIGHT_SURFACE` — the one colour the panel and the extension share by
    /// value rather than by name, since one of them is CSS.
    private static let nightSurface = UIColor(
        red: 0x0b / 255, green: 0x0b / 255, blue: 0x10 / 255, alpha: 1)
    /// `KIND_TINTS.media` — the download button's fill in the extension's own
    /// panel, which is the Downloader's identity colour because a pill there is
    /// coloured by the kind it saves. Read from `LunaSurfacePalette` rather than
    /// written out: `content.js` hand-copies the same table by value (it links no
    /// package), and `SafariSurfaceTintTests` holds the copy to this.
    private static let downloadTint = LunaSurfacePalette.baseColor(for: .downloader)
    /// Its text colour, by the same rule `tintForeground` applies in CSS.
    private static let downloadInk = LunaSurfacePalette.ink(on: downloadTint)

    /// **The one measurement the replica deliberately does not take from
    /// `content.js`.** The extension's backdrop is `rgba(0, 0, 0, 0.78)` over a
    /// 4px blur, which is right in Safari: you are the person who opened that
    /// page, and burying it is how the panel says "look here now".
    ///
    /// In the lesson the page is the SUBJECT. The blocked post and its sign-up
    /// wall are the thing the panel is an answer to, and a demonstration that
    /// blacks out the question the moment it answers it has shown the user two
    /// unrelated screens. So the two layers stay — the panel must still read as
    /// something Luna put in FRONT of the page — at roughly half the weight,
    /// and the post plays on behind them for the whole lesson.
    private static let scrimAlpha: CGFloat = 0.34
    private static let backdropBlurAlpha: CGFloat = 0.45

    private let blur = UIVisualEffectView(
        effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let scrim = UIView()
    /// The panel's geometry. Everything that DRAWS it — the night surface and
    /// the corona behind it — is a child sized to these bounds, so the growth
    /// is one animation on one view.
    private let panel = UIView()
    private let panelBody = UIView()
    private let close = UILabel()
    private let stage = UIView()
    private let playerView = PlayerLayerView()
    private let controls = OnboardingVideoDownloadControlsView()
    private let download = UILabel()
    private var panelCorona: EclipseCoronaView?

    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var timeObserver: Any?
    private var lessonStage = LessonStage.idle
    /// One report per run: the panel arriving and playing lands once, and a
    /// rewind (`reset`) arms the next run.
    private var didReportSetupOffer = false
    /// Cancels every pending beat of a run that has been rewound.
    private var generation = 0
    /// Replays under the setup popup run 30% faster than the first lesson.
    private var animationSpeedMultiplier: TimeInterval = 1

    init(configuration: OnboardingSurfaceConfiguration = .current) {
        super.init(frame: .zero)
        accessibilityIdentifier =
            OnboardingStrings.Accessibility.safariVideoOverlay.value()
        // Mounted with the browser, so the panel's first layout is paid while
        // the replica is still hidden behind the intro card. Nothing in it
        // SHOWS until the post has had its beat, and each piece hides itself
        // rather than the whole view fading: a panel arriving at partial
        // opacity reads as a page element rendering rather than as something
        // Luna put there.
        hidePanel()

        blur.isUserInteractionEnabled = false
        addSubview(blur)
        scrim.backgroundColor = UIColor.black.withAlphaComponent(Self.scrimAlpha)
        scrim.isUserInteractionEnabled = false
        addSubview(scrim)

        // The panel itself is a frame: the surface it looks like is `panelBody`,
        // and the corona goes UNDER that body inside the same panel. Both are
        // autoresizing children, so the panel's growth carries them with it in
        // its own animation — a glow positioned from the outside, in
        // `layoutSubviews`, can only ever be told the panel's FINAL frame, and
        // any layout pass during the growth put it there while the panel was
        // still travelling.
        panel.clipsToBounds = false
        addSubview(panel)

        panelBody.backgroundColor = Self.nightSurface
        panelBody.layer.cornerRadius = Metrics.panelCornerRadius
        panelBody.layer.cornerCurve = .continuous
        panelBody.layer.shadowColor = UIColor.black.cgColor
        panelBody.layer.shadowOpacity = 0.55
        panelBody.layer.shadowRadius = 30
        panelBody.layer.shadowOffset = CGSize(width: 0, height: 24)
        panelBody.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        panel.addSubview(panelBody)

        close.text = "✕"
        close.font = .systemFont(ofSize: 17, weight: .medium)
        close.textColor = .white
        close.textAlignment = .center
        close.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        close.layer.cornerRadius = Metrics.closeSide / 2
        close.clipsToBounds = true
        close.isAccessibilityElement = false
        panel.addSubview(close)

        stage.backgroundColor = .black
        stage.layer.cornerRadius = Metrics.stageCornerRadius
        stage.layer.cornerCurve = .continuous
        stage.clipsToBounds = true
        panel.addSubview(stage)

        playerView.playerLayer.videoGravity = .resizeAspect
        stage.addSubview(playerView)
        controls.alpha = 0
        stage.addSubview(controls)

        download.text = OnboardingStrings.Safari.playerDownload.value()
        download.font = .systemFont(ofSize: 16, weight: .semibold)
        download.textColor = Self.downloadInk
        download.textAlignment = .center
        download.backgroundColor = Self.downloadTint
        download.layer.cornerRadius = Metrics.downloadHeight / 2
        download.clipsToBounds = true
        download.isAccessibilityElement = false
        panel.addSubview(download)

        // Nothing in the panel answers a tap: the ask that used to live here
        // now lives on the shared, window-hosted setup popup. The panel
        // itself still takes touches so nothing behind it can be reached
        // either.
        for scenery in [blur, scrim, close, stage, download] as [UIView] {
            scenery.isUserInteractionEnabled = false
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        if let timeObserver {
            player?.removeTimeObserver(timeObserver)
        }
    }

    // MARK: - Layout

    /// What the mock browser bar covers. The panel centres in the page, not in
    /// the window, exactly as a fixed element inside Safari's viewport does.
    private var contentBounds: CGRect {
        CGRect(
            x: 0, y: 0,
            width: bounds.width,
            height: max(bounds.height - SafariBottomBar.reservedPageHeight, 0))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        blur.frame = bounds
        scrim.frame = bounds

        let page = contentBounds
        let panelWidth = min(
            page.width - Metrics.backdropPadding * 2, Metrics.panelMaxWidth)
        let contentWidth = panelWidth - Metrics.panelPadding * 2
        let available = page.height - Metrics.backdropPadding * 2

        // Everything the panel carries besides the stage itself: the header
        // row above it and the download button (plus its own trailing
        // padding) below it.
        let nonStageChrome = fixedPanelHeight(stage: 0)
            + Metrics.downloadTopGap + Metrics.downloadHeight
            + Metrics.panelPadding

        // The stage is the bundled clip's own portrait aspect until the panel
        // it has to fit inside runs out of room — on the shortest phone a
        // full-height portrait stage is taller than the page, and
        // letterboxing the clip is the one give here that costs the lesson
        // nothing. `stageAspect` is a constant rather than measured off the
        // player's `AVPlayerItem` because that would make the panel's own
        // layout depend on an asynchronous asset load; a mismatch just
        // letterboxes a little more or less inside the same box.
        let idealStageHeight = (contentWidth * Self.stageAspect).rounded()
        let stageHeight = max(
            min(idealStageHeight, available - nonStageChrome),
            idealStageHeight * 0.6)

        // The download button gets the panel's own 10pt padding under it, as it
        // does in `content.js` (`padding: "10px"` all round). Without it the
        // capsule ended flush with the panel's bottom edge and its corners were
        // cut by the panel's 20pt radius — the panel read as clipped.
        let panelHeight = fixedPanelHeight(stage: stageHeight)
            + Metrics.downloadTopGap + Metrics.downloadHeight
            + Metrics.panelPadding

        let top = max(
            Metrics.backdropPadding,
            min(
                ((page.height - panelHeight) / 2).rounded(),
                page.height - Metrics.backdropPadding - panelHeight))

        panel.bounds = CGRect(
            x: 0, y: 0, width: panelWidth, height: panelHeight)
        panel.center = CGPoint(x: page.midX, y: top + panelHeight / 2)
        layOutPanelCorona()

        let left = Metrics.panelPadding
        close.frame = CGRect(
            x: left, y: Metrics.panelPadding,
            width: Metrics.closeSide, height: Metrics.closeSide)
        stage.frame = CGRect(
            x: left,
            y: close.frame.maxY + Metrics.headerBottomGap,
            width: contentWidth,
            height: stageHeight)
        playerView.frame = stage.bounds
        controls.frame = stage.bounds
        download.frame = CGRect(
            x: left,
            y: stage.frame.maxY + Metrics.downloadTopGap,
            width: contentWidth,
            height: Metrics.downloadHeight)
    }

    /// Everything the panel carries whatever state it is in.
    private func fixedPanelHeight(stage: CGFloat) -> CGFloat {
        Metrics.panelPadding + Metrics.closeSide + Metrics.headerBottomGap
            + stage
    }

    /// Height ÷ width for the stage box. The extension's own panel
    /// (`content.js`) plays a post's video at whatever aspect that post's
    /// video is — usually landscape 16:9 — but this lesson's bundled clip
    /// (`LunaMoonPhases.mp4`) is a portrait one, so the box it plays in is
    /// portrait too: 16 (height) ÷ 9 (width), i.e. a 9:16 box.
    private static let stageAspect: CGFloat = 16.0 / 9.0

    /// The corona is built ONCE, for the panel it is first laid out in, and
    /// then rides the panel's own bounds — it is a child of the panel, under
    /// the surface it wraps.
    private func layOutPanelCorona() {
        guard panel.bounds.width > 0, panel.bounds.height > 0 else { return }
        if panelCorona == nil {
            let corona = EclipseCoronaView(
                bodySize: panel.bounds.size,
                cornerRadius: Metrics.panelCornerRadius,
                tint: LunaSurfacePalette.atmosphereTint)
            corona.alpha = lessonStage == .idle ? 0 : 1
            corona.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            panel.insertSubview(corona, belowSubview: panelBody)
            panelCorona = corona
        }
        panelCorona?.frame = panel.bounds
        panelBody.frame = panel.bounds
    }

    // MARK: - The sequence

    /// The whole lesson, on its own clock: the post is left alone, then the
    /// panel arrives playing and stays that way for the rest of the lesson.
    func begin(
        immediately: Bool = false,
        animationSpeedMultiplier: TimeInterval = 1
    ) {
        guard lessonStage == .idle else { return }
        self.animationSpeedMultiplier = animationSpeedMultiplier
        generation += 1
        setNeedsLayout()
        layoutIfNeeded()

        if immediately {
            presentPanel()
            return
        }

        after(OnboardingVideoDownloadTiming.pageHoldDuration) { view in
            view.presentPanel()
        }
    }

    /// Rewinds to the blocked post, so a second entry plays the whole sequence
    /// rather than landing on its finished last frame. Also what the host's
    /// forever-loop uses to replay this lesson under the shared popup once
    /// the freeze ends.
    func reset() {
        generation += 1
        lessonStage = .idle
        didReportSetupOffer = false
        stopPlayback()
        hidePanel()
        panel.transform = .identity
        controls.alpha = 0
        panelCorona?.alpha = 0
        download.alpha = 1
        setNeedsLayout()
    }

    /// The idle state: mounted and laid out, showing nothing.
    private func hidePanel() {
        blur.alpha = 0
        scrim.alpha = 0
        panel.alpha = 0
    }

    private func presentPanel() {
        lessonStage = .player
        startPlayback()

        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        // The panel is opaque from its first frame and arrives on its scale
        // alone; only the backdrop fades. The extension's own panel is appended
        // rather than animated, and a translucent one on the way in would show
        // the sign-up wall through the video answering it.
        panel.alpha = 1
        panelCorona?.alpha = 1
        panel.transform = reduceMotion
            ? .identity
            : CGAffineTransform(scaleX: 0.94, y: 0.94)
        UIView.animate(
            withDuration: duration(OnboardingVideoDownloadTiming.presentDuration),
            delay: 0,
            usingSpringWithDamping: 0.9,
            initialSpringVelocity: 0.2,
            options: [.curveEaseOut, .beginFromCurrentState]
        ) {
            self.blur.alpha = Self.backdropBlurAlpha
            self.scrim.alpha = 1
            self.panel.transform = .identity
        }
        UIView.animate(
            withDuration: duration(0.24),
            delay: duration(0.12),
            options: [.curveEaseOut]
        ) {
            self.controls.alpha = 1
        }
        // The hold is counted from the clip starting, not from the panel
        // finishing its arrival: what it is holding for is a video the user has
        // plainly watched play.
        after(OnboardingVideoDownloadTiming.playbackHoldDuration) { view in
            view.reportSetupOffer()
        }
    }

    /// The panel has arrived and the clip has plainly played: the setup ask
    /// fires, and the shared popup takes it from here. One report per run —
    /// a second call (a stale timer racing a rewind, or a test driving this
    /// directly) is the same run's already-made offer, not a new one.
    func reportSetupOffer() {
        guard lessonStage == .player, !didReportSetupOffer else { return }
        didReportSetupOffer = true
        onDidReachSetupOffer?()
    }

    /// Held while the lesson is off screen. The panel keeps its last frame, so
    /// there is nothing to restore but the motion.
    func setPlaying(_ playing: Bool) {
        guard let player, lessonStage != .idle else { return }
        if playing {
            player.play()
        } else {
            player.pause()
        }
    }

    private func after(
        _ delay: TimeInterval,
        _ work: @escaping (OnboardingVideoDownloadOverlayView) -> Void
    ) {
        let generation = self.generation
        DispatchQueue.main.asyncAfter(
            deadline: .now() + OnboardingAnimationClock.delay(duration(delay))
        ) { [weak self] in
            guard let self, generation == self.generation else { return }
            work(self)
        }
    }

    private func duration(_ base: TimeInterval) -> TimeInterval {
        base * animationSpeedMultiplier
    }

    private func stopPlayback() {
        player?.pause()
        if let timeObserver {
            player?.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        looper = nil
        player = nil
        playerView.playerLayer.player = nil
    }

    // MARK: - Playback

    private func startPlayback() {
        guard player == nil,
              let url = Bundle.main.url(
                forResource: Self.clipResourceName, withExtension: "mp4")
        else { return }
        let item = AVPlayerItem(url: url)
        let player = AVQueuePlayer()
        player.isMuted = true
        // The clip is short and bundled: nothing here should ever stall, and a
        // stall that waits for more buffer would freeze the lesson's one moving
        // picture.
        player.automaticallyWaitsToMinimizeStalling = false
        self.player = player
        looper = AVPlayerLooper(player: player, templateItem: item)
        playerView.playerLayer.player = player
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 4),
            queue: .main
        ) { [weak self] time in
            let elapsed = time.seconds
            Task { @MainActor in
                guard let self, let current = self.player?.currentItem else { return }
                self.controls.update(
                    elapsed: elapsed,
                    duration: current.duration.seconds)
            }
        }
        player.play()
    }

    /// The same clip the mock page itself plays, so the panel is showing the
    /// post's own video rather than a second one.
    static let clipResourceName = "LunaMoonPhases"

    #if DEBUG
    /// The panel as the player state renders it, with neither the clock nor the
    /// decoder: a test asserting on geometry has no business starting a video.
    func enterPlayerStateForTesting() {
        lessonStage = .player
        blur.alpha = Self.backdropBlurAlpha
        scrim.alpha = 1
        panel.alpha = 1
        setNeedsLayout()
        layoutIfNeeded()
    }

    var panelFrameForTesting: CGRect { panel.frame }
    /// In the overlay's own space, so the two states are directly comparable.
    var stageFrameForTesting: CGRect { convert(stage.bounds, from: stage) }
    var downloadFrameForTesting: CGRect { convert(download.bounds, from: download) }
    var downloadColourForTesting: UIColor? { download.backgroundColor }
    var downloadAlphaForTesting: CGFloat { download.alpha }
    var panelColourForTesting: UIColor? { panelBody.backgroundColor }
    var closeFrameForTesting: CGRect { close.frame }
    var panelCornerRadiusForTesting: CGFloat { panelBody.layer.cornerRadius }
    /// How much of the page behind the panel the backdrop takes: the black's
    /// own alpha times the layer's, plus the blur's weight. A test's way of
    /// asserting that the blocked post is still on screen behind the answer.
    var backdropDarknessForTesting: CGFloat { scrim.alpha * Self.scrimAlpha }
    var backdropBlurWeightForTesting: CGFloat { blur.alpha }
    #endif
}

/// The player's own controls, as iOS draws them over an inline `<video
/// controls>`: a translucent strip along the bottom of the stage carrying the
/// transport glyph, the elapsed and remaining times, and the scrubber between
/// them. It is a picture — the demonstration drives the clip, not the user.
final class OnboardingVideoDownloadControlsView: UIView {
    private static let barHeight: CGFloat = 34
    private static let barInset: CGFloat = 8
    private static let glyphSide: CGFloat = 22
    private static let timeWidth: CGFloat = 34

    private let bar = UIVisualEffectView(
        effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let transport = UIImageView()
    private let elapsedLabel = UILabel()
    private let remainingLabel = UILabel()
    private let track = UIView()
    private let progress = UIView()
    private let expand = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false

        bar.layer.cornerRadius = Self.barHeight / 2
        bar.layer.cornerCurve = .continuous
        bar.clipsToBounds = true
        addSubview(bar)

        transport.image = UIImage(
            systemName: "pause.fill",
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: 13, weight: .semibold))
        expand.image = UIImage(
            systemName: "arrow.up.left.and.arrow.down.right",
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: 12, weight: .semibold))
        for glyph in [transport, expand] {
            glyph.tintColor = .white
            glyph.contentMode = .center
            bar.contentView.addSubview(glyph)
        }

        for label in [elapsedLabel, remainingLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            label.textColor = UIColor.white.withAlphaComponent(0.9)
            label.isAccessibilityElement = false
            bar.contentView.addSubview(label)
        }
        elapsedLabel.textAlignment = .left
        remainingLabel.textAlignment = .right
        elapsedLabel.text = "0:00"
        remainingLabel.text = "-0:00"

        track.backgroundColor = UIColor.white.withAlphaComponent(0.28)
        track.layer.cornerRadius = 1.5
        bar.contentView.addSubview(track)
        progress.backgroundColor = .white
        progress.layer.cornerRadius = 1.5
        track.addSubview(progress)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var fraction: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        bar.frame = CGRect(
            x: Self.barInset,
            y: bounds.height - Self.barHeight - Self.barInset,
            width: max(bounds.width - Self.barInset * 2, 0),
            height: Self.barHeight)
        let inner = bar.bounds
        transport.frame = CGRect(
            x: 10,
            y: (inner.height - Self.glyphSide) / 2,
            width: Self.glyphSide,
            height: Self.glyphSide)
        expand.frame = CGRect(
            x: inner.width - Self.glyphSide - 10,
            y: (inner.height - Self.glyphSide) / 2,
            width: Self.glyphSide,
            height: Self.glyphSide)
        elapsedLabel.frame = CGRect(
            x: transport.frame.maxX + 6,
            y: 0, width: Self.timeWidth, height: inner.height)
        remainingLabel.frame = CGRect(
            x: expand.frame.minX - 6 - Self.timeWidth,
            y: 0, width: Self.timeWidth, height: inner.height)
        let trackX = elapsedLabel.frame.maxX + 8
        track.frame = CGRect(
            x: trackX,
            y: (inner.height - 3) / 2,
            width: max(remainingLabel.frame.minX - 8 - trackX, 0),
            height: 3)
        layOutProgress()
    }

    private func layOutProgress() {
        progress.frame = CGRect(
            x: 0, y: 0,
            width: (track.bounds.width * fraction).rounded(),
            height: track.bounds.height)
    }

    func update(elapsed: Double, duration: Double) {
        guard duration.isFinite, duration > 0 else { return }
        fraction = CGFloat(min(max(elapsed / duration, 0), 1))
        elapsedLabel.text = Self.timeLabel(elapsed)
        remainingLabel.text = "-" + Self.timeLabel(max(duration - elapsed, 0))
        layOutProgress()
    }

    private static func timeLabel(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

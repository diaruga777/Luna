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
    /// The video plays, plainly, before the panel changes underneath it. It has
    /// to read as *the post's video, playing* — the scrubber moving, the moon
    /// visibly further along than it was — which is seconds, not one.
    static let playbackHoldDuration: TimeInterval = 4.0
    /// The download button leaving and the setup block arriving, while the
    /// panel's bottom edge travels down to meet it.
    static let growDuration: TimeInterval = 0.72
}

/// A native replica of the panel the Safari extension puts over a video post —
/// `presentVideoOverlay` in `LunaSafari/Resources/content.js` — used by the
/// Downloader's Safari lesson over the bundled InstaTok page.
///
/// Every measurement is that function's own, read straight across from its
/// inline styles: a 78%-black blurred backdrop, a `calc(100vw - 24px)` panel
/// capped at 640 in `NIGHT_SURFACE` with a 20pt radius and 10pt padding, a 34pt
/// round close button over an 8pt gap, a 16:9 black stage at radius 12, and the
/// indigo full-width "Download in Luna" capsule 10pt under it. Nothing here is
/// a stylisation of that panel; a change to either one is a change to both.
///
/// What it does that the real one cannot: once the video has played, the
/// download button is REPLACED by the three steps that switch the extension on
/// plus the lesson's own actions, and the panel's bottom edge travels down to
/// fit them. The panel is the whole lesson, so the page underneath needs no
/// explainer of its own — which is why the Downloader's Safari demonstration
/// opens on InstaTok rather than on `luna.app` (`OnboardingSafariLesson`). It is
/// the media sibling of `OnboardingPriceComparisonOverlayView`, and keeps that
/// lesson's shape: `begin` / `reset` / `reactivateActions`, mounted with the
/// browser and generation-guarded so a rewind cancels its pending beats.
///
/// Only the two action buttons are live. Everything else — the close button, the
/// download button, the player's own controls — is a picture of a control, inert
/// by construction (no target, no gesture recognizer), because a demonstration
/// that answers a tap is a demonstration that can be taken somewhere it cannot
/// go.
@MainActor
final class OnboardingVideoDownloadOverlayView: UIView {
    var onActivateSafari: (() -> Void)?
    var onSkipSafariSetup: (() -> Void)?

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
        /// The setup block's own rhythm, which the web panel has no equivalent
        /// of: air under the stage, the heading, the steps, then the actions.
        static let setupTopGap: CGFloat = 16
        static let setupHeadingHeight: CGFloat = 18
        static let setupHeadingGap: CGFloat = 10
        static let setupActionsGap: CGFloat = 14
    }

    /// Not to be confused with the `stage` view below — that name is
    /// `content.js`'s, for the black rectangle the video plays in.
    private enum LessonStage {
        /// Mounted, invisible: the blocked post is being read.
        case idle
        /// The panel is up and the clip is playing under the download button.
        case player
        /// The download button has given way to the enable steps.
        case setup
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
    private let panel = UIView()
    private let close = UILabel()
    private let stage = UIView()
    private let playerView = PlayerLayerView()
    private let controls = OnboardingVideoDownloadControlsView()
    private let download = UILabel()
    private let setupContainer = UIView()
    private let setupHeading = UILabel()
    private let stepRows: [OnboardingSafariEnableStepRowView]
    private let actionsView = OnboardingSafariActionsView()

    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var timeObserver: Any?
    private var lessonStage = LessonStage.idle
    /// Cancels every pending beat of a run that has been rewound.
    private var generation = 0

    init(configuration: OnboardingSurfaceConfiguration = .current) {
        stepRows = OnboardingStrings.Safari
            .steps(appName: configuration.app.displayName)
            .map(OnboardingSafariEnableStepRowView.init(step:))
        super.init(frame: .zero)
        accessibilityIdentifier =
            OnboardingStrings.Accessibility.safariVideoOverlay.value()
        // Mounted with the browser, so the panel's first layout — three step
        // rows, two buttons and a stage — is paid while the replica is still
        // hidden behind the intro card. Nothing in it SHOWS until the post has
        // had its beat, and each piece hides itself rather than the whole view
        // fading: a panel arriving at partial opacity reads as a page element
        // rendering rather than as something Luna put there.
        hidePanel()

        blur.isUserInteractionEnabled = false
        addSubview(blur)
        scrim.backgroundColor = UIColor.black.withAlphaComponent(Self.scrimAlpha)
        scrim.isUserInteractionEnabled = false
        addSubview(scrim)

        panel.backgroundColor = Self.nightSurface
        panel.layer.cornerRadius = Metrics.panelCornerRadius
        panel.layer.cornerCurve = .continuous
        panel.layer.shadowColor = UIColor.black.cgColor
        panel.layer.shadowOpacity = 0.55
        panel.layer.shadowRadius = 30
        panel.layer.shadowOffset = CGSize(width: 0, height: 24)
        addSubview(panel)

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

        setupContainer.alpha = 0
        setupContainer.isHidden = true
        panel.addSubview(setupContainer)

        setupHeading.text = OnboardingStrings.Safari.stepsHeading.value()
        setupHeading.font = .systemFont(ofSize: 13, weight: .semibold)
        setupHeading.textColor = OnboardingSafariPagePalette.quietCopy
        setupHeading.accessibilityIdentifier =
            OnboardingStrings.Accessibility.safariStepsHeading.value()
        setupContainer.addSubview(setupHeading)
        for (index, row) in stepRows.enumerated() {
            row.accessibilityIdentifier =
                OnboardingStrings.Accessibility.safariStep(index)
            setupContainer.addSubview(row)
        }
        actionsView.onActivate = { [weak self] in self?.onActivateSafari?() }
        actionsView.onSkip = { [weak self] in self?.onSkipSafariSetup?() }
        setupContainer.addSubview(actionsView)

        // Everything but the two real buttons is scenery. The panel itself
        // still takes touches so nothing behind it can be reached either.
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

        // The stage is 16:9 until the panel it has to fit inside runs out of
        // room — on the shortest phone the setup block plus a full-height stage
        // is taller than the page, and letterboxing the clip is the one give
        // here that costs the lesson nothing.
        let idealStageHeight = (contentWidth * 9 / 16).rounded()
        let stageHeight = max(
            min(
                idealStageHeight,
                available - (fixedPanelHeight(stage: 0)
                    + setupBlockHeight(width: contentWidth))),
            idealStageHeight * 0.6)

        let playerHeight = fixedPanelHeight(stage: stageHeight)
            + Metrics.downloadTopGap + Metrics.downloadHeight
        let setupHeight = fixedPanelHeight(stage: stageHeight)
            + setupBlockHeight(width: contentWidth)
        let panelHeight = lessonStage == .setup ? setupHeight : playerHeight

        // The panel's top is the PLAYER state's top in both states, so the
        // growth is a bottom edge travelling down and the video stays exactly
        // where the user was watching it. It rises only when the taller panel
        // would otherwise leave the page.
        let restingTop = ((page.height - playerHeight) / 2).rounded()
        let top = max(
            Metrics.backdropPadding,
            min(
                restingTop,
                page.height - Metrics.backdropPadding - panelHeight))

        panel.bounds = CGRect(
            x: 0, y: 0, width: panelWidth, height: panelHeight)
        panel.center = CGPoint(x: page.midX, y: top + panelHeight / 2)

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

        setupContainer.frame = CGRect(
            x: left,
            y: stage.frame.maxY + Metrics.setupTopGap,
            width: contentWidth,
            height: setupBlockHeight(width: contentWidth) - Metrics.setupTopGap
                - Metrics.panelPadding)
        setupHeading.frame = CGRect(
            x: 0, y: 0,
            width: contentWidth, height: Metrics.setupHeadingHeight)
        var rowY = setupHeading.frame.maxY + Metrics.setupHeadingGap
        for row in stepRows {
            row.frame = CGRect(
                x: 0, y: rowY,
                width: contentWidth,
                height: OnboardingSafariEnableStepRowView.preferredHeight)
            rowY = row.frame.maxY
        }
        actionsView.frame = CGRect(
            x: 0,
            y: rowY + Metrics.setupActionsGap,
            width: contentWidth,
            height: OnboardingSafariActionsView.preferredHeight)
    }

    /// Everything the panel carries whatever state it is in.
    private func fixedPanelHeight(stage: CGFloat) -> CGFloat {
        Metrics.panelPadding + Metrics.closeSide + Metrics.headerBottomGap
            + stage
    }

    /// The setup block measured from the stage's bottom edge to the panel's.
    private func setupBlockHeight(width: CGFloat) -> CGFloat {
        Metrics.setupTopGap + Metrics.setupHeadingHeight
            + Metrics.setupHeadingGap
            + CGFloat(stepRows.count)
                * OnboardingSafariEnableStepRowView.preferredHeight
            + Metrics.setupActionsGap
            + OnboardingSafariActionsView.preferredHeight
            + Metrics.panelPadding
    }

    // MARK: - The sequence

    /// The whole lesson, on its own clock: the post is left alone, the panel
    /// arrives playing, and the setup block takes the download button's place.
    func begin() {
        guard lessonStage == .idle else { return }
        generation += 1
        setNeedsLayout()
        layoutIfNeeded()

        after(OnboardingVideoDownloadTiming.pageHoldDuration) { view in
            view.presentPanel()
        }
    }

    /// Rewinds to the blocked post, so a second entry plays the whole sequence
    /// rather than landing on its finished last frame.
    func reset() {
        generation += 1
        lessonStage = .idle
        stopPlayback()
        hidePanel()
        panel.transform = .identity
        controls.alpha = 0
        download.alpha = 1
        setupContainer.alpha = 0
        setupContainer.isHidden = true
        setupContainer.transform = .identity
        actionsView.setActionsEnabled(false)
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
        panel.transform = reduceMotion
            ? .identity
            : CGAffineTransform(scaleX: 0.94, y: 0.94)
        UIView.animate(
            withDuration: OnboardingVideoDownloadTiming.presentDuration,
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
            withDuration: 0.24,
            delay: 0.12,
            options: [.curveEaseOut]
        ) {
            self.controls.alpha = 1
        }
        // The hold is counted from the clip starting, not from the panel
        // finishing its arrival: what it is holding for is a video the user has
        // plainly watched play.
        after(OnboardingVideoDownloadTiming.playbackHoldDuration) { view in
            view.revealSetupInstructions()
        }
    }

    /// The download button goes and the three steps take its place, the panel's
    /// bottom edge travelling down to fit them.
    func revealSetupInstructions() {
        guard lessonStage == .player else { return }
        lessonStage = .setup
        setupContainer.isHidden = false
        actionsView.setActionsEnabled(true)

        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        let duration = reduceMotion
            ? 0.24
            : OnboardingVideoDownloadTiming.growDuration
        setupContainer.transform = reduceMotion
            ? .identity
            : CGAffineTransform(translationX: 0, y: -12)

        UIView.animate(
            withDuration: duration * 0.4,
            delay: 0,
            options: [.curveEaseIn, .beginFromCurrentState]
        ) {
            self.download.alpha = 0
        }
        UIView.animate(
            withDuration: duration,
            delay: 0,
            usingSpringWithDamping: reduceMotion ? 1 : 0.92,
            initialSpringVelocity: 0,
            options: [.curveEaseInOut, .beginFromCurrentState]
        ) {
            self.setNeedsLayout()
            self.layoutIfNeeded()
        }
        UIView.animate(
            withDuration: duration * 0.66,
            delay: duration * 0.34,
            options: [.curveEaseOut, .beginFromCurrentState]
        ) {
            self.setupContainer.alpha = 1
            self.setupContainer.transform = .identity
        }
    }

    /// The return leg from real Safari with nothing to show for it: the panel's
    /// actions come back.
    func reactivateActions() {
        guard lessonStage == .setup else { return }
        actionsView.setActionsEnabled(true)
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
            deadline: .now() + OnboardingAnimationClock.delay(delay)
        ) { [weak self] in
            guard let self, generation == self.generation else { return }
            work(self)
        }
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

    var isShowingSetupInstructionsForTesting: Bool { lessonStage == .setup }
    var panelFrameForTesting: CGRect { panel.frame }
    /// In the overlay's own space, so the two states are directly comparable.
    var stageFrameForTesting: CGRect { convert(stage.bounds, from: stage) }
    var downloadFrameForTesting: CGRect { convert(download.bounds, from: download) }
    var downloadColourForTesting: UIColor? { download.backgroundColor }
    var downloadAlphaForTesting: CGFloat { download.alpha }
    var panelColourForTesting: UIColor? { panel.backgroundColor }
    var closeFrameForTesting: CGRect { close.frame }
    var panelCornerRadiusForTesting: CGFloat { panel.layer.cornerRadius }
    /// How much of the page behind the panel the backdrop takes: the black's
    /// own alpha times the layer's, plus the blur's weight. A test's way of
    /// asserting that the blocked post is still on screen behind the answer.
    var backdropDarknessForTesting: CGFloat { scrim.alpha * Self.scrimAlpha }
    var backdropBlurWeightForTesting: CGFloat { blur.alpha }
    var activateButtonForTesting: UIButton { actionsView.activateButton }
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

//
//  MiniPlayerHostViewController.swift
//  Luna
//
//  Window-level container for the read-aloud mini-player (Phase 3 of
//  claudedocs/audio-playback-plan.md). `SceneDelegate` makes this the
//  `window.rootViewController`, wrapping the main `UINavigationController`:
//  the nav controller fills the view as a child, and the mini-player bar
//  floats above the bottom safe area — hidden while playback is idle,
//  animating in on first play, persisting across every push/pop. Presented
//  view controllers (modals, the inline split-web overlay) cover it, which is
//  fine: playback continues regardless, and the bar is right there when the
//  overlay closes.
//
//  While the RSVP reader is frontmost in center-driven speech mode, the bar
//  slims down and docks directly above RSVP's circular `controlsStack` (the
//  "RSVP meld" — the anchor is published via `AudioMiniPlayerMeld` and
//  re-validated for actual visibility here every update).
//

import LunaAudioPlayback
import LunaReaderUI
import LunaStorage
import LunaModels
import UIKit

final class MiniPlayerHostViewController: UIViewController {

    /// The wrapped main navigation controller — what `SceneDelegate` used to
    /// install directly as the window root (deep links, notification routes,
    /// and the Dot Matrix transitions all re-point here).
    let contentNavigationController: UINavigationController

    private let miniPlayer = AudioMiniPlayerView()
    private var barMode: AudioMiniPlayerView.BarMode = .hidden
    private var meldObserver: NSObjectProtocol?
    /// Phase 6 extension → main-app handoff: true while the bar shows a
    /// PAUSED PREVIEW of a recent extension-persisted position — the center
    /// itself is still `.idle` (no engine/session exists yet). Cleared the
    /// moment a real playback state arrives (whether via tapping play here,
    /// or any other trigger), so the normal `AudioPlaybackObserver`-driven
    /// display always wins once real state exists.
    private var isShowingHandoffPreview = false

    init(content: UINavigationController) {
        self.contentNavigationController = content
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        if let meldObserver { NotificationCenter.default.removeObserver(meldObserver) }
    }

    // The wrapped nav controller keeps owning system chrome decisions.
    override var childForStatusBarStyle: UIViewController? { contentNavigationController }
    override var childForStatusBarHidden: UIViewController? { contentNavigationController }
    override var childForHomeIndicatorAutoHidden: UIViewController? { contentNavigationController }
    override var childForScreenEdgesDeferringSystemGestures: UIViewController? { contentNavigationController }

    override func viewDidLoad() {
        super.viewDidLoad()

        addChild(contentNavigationController)
        contentNavigationController.view.frame = view.bounds
        contentNavigationController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(contentNavigationController.view)
        contentNavigationController.didMove(toParent: self)

        miniPlayer.isHidden = true
        miniPlayer.alpha = 0
        view.addSubview(miniPlayer)

        wireControls()
        AudioPlaybackCenter.shared.addObserver(self)
        meldObserver = NotificationCenter.default.addObserver(
            forName: AudioMiniPlayerMeld.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.updateBar(animated: true)
        }

        // Pull-based initial state (e.g. a cold background relaunch restored a
        // session before the window existed).
        refreshDisplay()
        updateBar(animated: false)
        showHandoffPreviewIfAvailable()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if barMode != .hidden {
            miniPlayer.frame = barFrame(for: barMode)
        }
    }

    private func wireControls() {
        let center = AudioPlaybackCenter.shared
        miniPlayer.onSkipBack = { center.skipBackwardParagraph() }
        miniPlayer.onPlayPause = { [weak self] in self?.handlePlayPauseTap() }
        miniPlayer.onSkipForward = { center.skipForwardParagraph() }
        // Rate and autoplay changes don't emit observer callbacks — refresh
        // the display directly after applying them.
        miniPlayer.onCycleRate = { [weak self] in
            center.cycleRate()
            self?.refreshDisplay()
        }
        miniPlayer.onToggleAutoplay = { [weak self] in
            AudioSettings.isAutoplayEnabled.toggle()
            self?.refreshDisplay()
        }
        miniPlayer.onTapArticle = { [weak self] in
            self?.navigateToPlayingArticle()
        }
    }

    // MARK: - Bar placement

    /// The meld anchor (RSVP's controls stack), only when genuinely visible in
    /// THIS window — the RabbitHole host shows/hides its pre-built reader
    /// children without appearance callbacks, so a published anchor can be
    /// stale and must fail this check rather than dock the bar to a hidden view.
    private var validMeldAnchor: UIView? {
        guard let anchor = AudioMiniPlayerMeld.visibleAnchorView,
              anchor.window === view.window else { return nil }
        return anchor
    }

    private func barFrame(for mode: AudioMiniPlayerView.BarMode) -> CGRect {
        if mode == .slim, let anchor = validMeldAnchor {
            let anchorFrame = anchor.convert(anchor.bounds, to: view)
            let width = min(max(anchorFrame.width, 260), view.bounds.width - 24)
            let height = AudioMiniPlayerView.slimHeight
            return CGRect(
                x: (view.bounds.width - width) / 2,
                y: anchorFrame.minY - height - 10,
                width: width, height: height)
        }
        let width = min(view.bounds.width - 20, 520)
        let height = AudioMiniPlayerView.fullHeight
        return CGRect(
            x: (view.bounds.width - width) / 2,
            y: view.bounds.height - view.safeAreaInsets.bottom - height - 8,
            width: width, height: height)
    }

    private func updateBar(animated: Bool) {
        // A handoff preview overrides the normal state-driven mode: the
        // center is genuinely `.idle` (nothing built yet), so the ordinary
        // rule below would say `.hidden` — the whole point of the preview is
        // showing the bar anyway, paused, until the user acts on it or a
        // real playback state supersedes it (see `didChangeState`, which
        // clears the flag first).
        if isShowingHandoffPreview, case .idle = AudioPlaybackCenter.shared.state {
            applyBarMode(.full, animated: animated)
            return
        }
        let newMode = AudioMiniPlayerView.barMode(
            state: AudioPlaybackCenter.shared.state,
            hasMeldAnchor: validMeldAnchor != nil)
        applyBarMode(newMode, animated: animated)
    }

    private func applyBarMode(_ newMode: AudioMiniPlayerView.BarMode, animated: Bool) {
        let targetFrame = barFrame(for: newMode)
        let frameChanged = newMode != .hidden
            && (newMode != barMode || miniPlayer.frame != targetFrame)
        guard newMode != barMode || frameChanged else { return }
        let wasHidden = barMode == .hidden
        barMode = newMode

        // Content below scrolls clear of the full-height bar (safe-area push);
        // the slim dock sits inside RSVP's own layout, so no push there.
        contentNavigationController.additionalSafeAreaInsets.bottom =
            newMode == .full ? AudioMiniPlayerView.fullHeight + 14 : 0

        switch newMode {
        case .hidden:
            let bar = miniPlayer
            guard !bar.isHidden else { return }
            UIView.animate(withDuration: animated ? 0.25 : 0, animations: {
                bar.alpha = 0
                bar.transform = CGAffineTransform(translationX: 0, y: 12)
            }, completion: { _ in
                // Only hide if no newer update re-showed it mid-animation.
                if self.barMode == .hidden {
                    bar.isHidden = true
                    bar.transform = .identity
                }
            })
        case .full, .slim:
            miniPlayer.setMode(newMode)
            if wasHidden || miniPlayer.isHidden {
                // Animate in from just below its resting place.
                miniPlayer.isHidden = false
                miniPlayer.frame = targetFrame
                miniPlayer.transform = CGAffineTransform(translationX: 0, y: 16)
                UIView.animate(
                    withDuration: animated ? 0.35 : 0, delay: 0,
                    usingSpringWithDamping: 0.85, initialSpringVelocity: 0.3
                ) {
                    self.miniPlayer.alpha = 1
                    self.miniPlayer.transform = .identity
                }
            } else {
                UIView.animate(withDuration: animated ? 0.25 : 0) {
                    self.miniPlayer.frame = targetFrame
                    self.miniPlayer.layoutIfNeeded()
                }
            }
        }
    }

    // MARK: - Display

    private func refreshDisplay() {
        let center = AudioPlaybackCenter.shared
        let snapshot = center.currentSnapshot

        // During the autoplay announcement, show the UPCOMING article.
        if case .announcing(let nextItemID) = center.state {
            let next = ReadingListStore.shared.item(withID: nextItemID)
            miniPlayer.apply(.init(
                title: next?.title ?? "Next article",
                isUpNext: true,
                thumbnailPath: thumbnailPath(fileName: next?.thumbnailFileName),
                isPlaying: snapshot.isAudiblyPlaying,
                rate: snapshot.rate,
                isAutoplayOn: AudioSettings.isAutoplayEnabled))
            miniPlayer.setProgress(0, animated: false)
            return
        }

        guard let info = snapshot.itemInfo else { return }
        miniPlayer.apply(.init(
            title: info.title,
            isUpNext: false,
            thumbnailPath: thumbnailPath(fileName: info.thumbnailFileName),
            isPlaying: snapshot.isAudiblyPlaying,
            rate: snapshot.rate,
            isAutoplayOn: AudioSettings.isAutoplayEnabled))
        miniPlayer.setProgress(snapshot.progressFraction, animated: false)
    }

    private func thumbnailPath(fileName: String?) -> String? {
        guard let fileName else { return nil }
        return ReadingListStore.shared.articlesDirectory.appendingPathComponent(fileName).path
    }

    // MARK: - Phase 6: extension → main-app handoff (launch-time paused preview)

    /// Checked once at launch (`viewDidLoad`): if a RECENT extension-persisted
    /// position exists and nothing is currently playing, shows the bar in a
    /// paused preview (title/thumbnail visible) — `AudioPlaybackCenter` stays
    /// `.idle` until the user actually taps play. Does nothing (per the
    /// product guard) when the position is stale or its item/content is
    /// gone — `restorableHandoffIfAvailable` already encodes both checks.
    private func showHandoffPreviewIfAvailable() {
        guard let handoff = AudioPlaybackCenter.shared.restorableHandoffIfAvailable() else { return }
        isShowingHandoffPreview = true
        miniPlayer.apply(.init(
            title: handoff.title, isUpNext: false,
            thumbnailPath: thumbnailPath(fileName: handoff.thumbnailFileName),
            isPlaying: false, rate: AudioSettings.preferredRate,
            isAutoplayOn: AudioSettings.isAutoplayEnabled))
        miniPlayer.setProgress(handoff.progressFraction, animated: false)
        updateBar(animated: true)
    }

    /// Routes the bar's single play/pause control: a normal toggle once real
    /// playback state exists, or — while showing the handoff preview — the
    /// EXISTING full-restore path (`restorePersistedSessionIfAvailable()`),
    /// never a bespoke "resume from preview" method. If the item/content
    /// vanished between the preview appearing and this tap (deleted
    /// meanwhile), the restore silently fails and the bar just hides.
    private func handlePlayPauseTap() {
        guard isShowingHandoffPreview else {
            AudioPlaybackCenter.shared.togglePlayPause()
            return
        }
        isShowingHandoffPreview = false
        let restored = AudioPlaybackCenter.shared.restorePersistedSessionIfAvailable()
        if !restored {
            updateBar(animated: true)
        }
    }

    // MARK: - Tap-to-return navigation

    /// Opens the playing (or announced) article: pops to an already-open
    /// reader whose trail contains it, else pushes a fresh reader the same way
    /// the reading list opens one. Resolution logic is pure —
    /// `MiniPlayerNavigation` — and unit-tested.
    private func navigateToPlayingArticle() {
        let center = AudioPlaybackCenter.shared
        let itemID: UUID
        switch center.state {
        case .playing(let id), .paused(let id): itemID = id
        case .announcing(let nextID): itemID = nextID
        case .idle: return
        }

        let nav = contentNavigationController
        let stack = nav.viewControllers
        if let index = MiniPlayerNavigation.stackIndex(
            forItemID: itemID,
            stack: stack.map { $0 as? ReaderItemContaining }
        ) {
            if nav.topViewController !== stack[index] {
                nav.popToViewController(stack[index], animated: true)
            }
            return
        }

        // Not on the stack: push a fresh reader via the same path the reading
        // list uses (readable articles only — the queue guarantees content).
        let store = ReadingListStore.shared
        guard let item = store.item(withID: itemID), item.state == .ready,
              let content = store.content(for: item) else { return }
        let reader = ReaderHostFactory.make(
            item: item, content: content,
            shareProvider: AppReaderShareProvider.shared,
            transition: DotMatrixRabbitHoleTransition())
        nav.pushViewController(reader, animated: true)
    }
}

// MARK: - AudioPlaybackObserver

extension MiniPlayerHostViewController: AudioPlaybackObserver {
    func audioPlaybackCenter(_ center: AudioPlaybackCenter, didChangeState state: AudioPlaybackState) {
        // Any real state (from tapping play on the preview, or any other
        // trigger — e.g. a remote "play" command while this preview shows)
        // supersedes the handoff preview outright.
        if isShowingHandoffPreview, state != .idle { isShowingHandoffPreview = false }
        refreshDisplay()
        updateBar(animated: true)
    }

    func audioPlaybackCenter(_ center: AudioPlaybackCenter, didUpdateItem info: AudioPlaybackItemInfo?) {
        refreshDisplay()
    }

    func audioPlaybackCenter(
        _ center: AudioPlaybackCenter, didUpdateProgress fraction: Double,
        elapsed: TimeInterval, duration: TimeInterval
    ) {
        if case .announcing = center.state {} else {
            miniPlayer.setProgress(fraction, animated: true)
        }
        // Cheap per-tick re-validation of the meld dock (the RSVP reader can
        // appear/disappear without a notification — see `validMeldAnchor`).
        updateBar(animated: true)
    }
}

// MARK: - Navigation-target resolution (pure)

/// A nav-stack entry that can say whether the playing article lives inside it.
/// `RabbitHoleReaderViewController` conforms via its `containsReaderItem` API;
/// kept as a protocol so the resolution logic is testable with plain fakes.
protocol ReaderItemContaining {
    func containsReaderItem(withID itemID: UUID) -> Bool
}

extension RabbitHoleReaderViewController: ReaderItemContaining {}

enum MiniPlayerNavigation {
    /// The index of the TOPMOST stack entry containing `itemID`, or nil when
    /// the article isn't open anywhere in the stack (→ push a fresh reader).
    /// `stack` carries nil for entries that aren't readers at all.
    static func stackIndex(forItemID itemID: UUID, stack: [ReaderItemContaining?]) -> Int? {
        stack.lastIndex { $0?.containsReaderItem(withID: itemID) ?? false }
    }
}

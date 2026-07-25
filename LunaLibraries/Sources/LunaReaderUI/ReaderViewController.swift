//
//  ReaderViewController.swift
//  Luna
//

import LunaArchiveReader
import LunaDesignSystem
import LunaStorage
import LunaModels
import UIKit

/// Hosts the reader modes — scrolling text, the RSVP speed reader (with its own
/// Words/Phrases sub-modes), and the locally saved original-page snapshot —
/// swapping them via the mode switcher, with a separate audio (read-aloud)
/// toggle that applies to whichever mode is showing. The retired standalone
/// "highlight" (chunk) mode now opens as RSVP → Phrases. Remembers the last used
/// mode per article and globally (the default for new articles), and tracks
/// opened/read state.
public final class ReaderViewController: UIViewController, InlineReaderPresentationCoordinating {

    private let item: ReadingListItem
    private let content: ArticleContent
    private let store = ReadingListStore.shared
    private var mode: ReadingListItem.ReaderMode
    private var audioOn = false
    private var currentChild: UIViewController?
    /// Reading position carried from the outgoing child to the next on a mode
    /// switch (nil on first open → each child uses its own persisted default).
    private var resumeWordIndex: Int?

    /// Child readers fill the area below the (compact) nav bar, which holds the
    /// mode switcher as its title view (between Back and the audio toggle).
    private let contentContainer = UIView()
    /// Hovering share button (de-glassed), bottom-right above the footer controls.
    private let floatingShareButton = UIButton(type: .system)
    /// Drives the share button's vertical position per mode so it clears each
    /// mode's footer: low in scroll (no footer), above the chunk footer in
    /// highlight, and above the playback controls in RSVP.
    private var floatingShareBottomConstraint: NSLayoutConstraint?

    /// Sharing affordances (nil in the share extension → no share button/footer).
    private let shareProvider: ReaderShareProviding?

    /// When false, switching modes does NOT write the shared `ReaderSettings`/
    /// per-item mode (used by the action extension, which keeps its own
    /// preference). When set, `onModeChange` is called instead.
    private let persistsModePreference: Bool
    private let onModeChange: ((ReadingListItem.ReaderMode) -> Void)?

    /// When false, opening does NOT mark the item `.opened` — for a host that just
    /// previews the article; only an explicit Mark Read changes its state.
    private let marksOpenedOnLoad: Bool

    private let modeControl = LunaSegmentedControl()
    private let audioButton = UIButton(type: .system)
    private weak var inlineReaderForChrome: ReaderChromeControlling?
    /// When true, the mode switcher + audio toggle render in an inline (de-glassed,
    /// Task 3) header embedded DIRECTLY in the view (no UINavigationController). The
    /// host sits on a solid background, so the bar uses a solid fill rather than a
    /// live blur.
    private let inlineControlsHeader: Bool
    /// Optional line shown ABOVE the controls inside the single inline header (e.g.
    /// a date/sender line) so the host needs no separate header strip.
    private let inlineHeaderSubtitle: String?
    private let inlineHeader = UIView()

    private static let baseModes: [ReadingListItem.ReaderMode] = [.scroll, .rsvp]
    private let availableModes: [ReadingListItem.ReaderMode]
    /// When the requested mode was the retired standalone "highlight" (chunking)
    /// view, the FIRST RSVP open lands directly in its Phrases sub-mode (where
    /// that engine now lives). One-shot — later RSVP entries honor the user's
    /// persisted sub-mode choice.
    private var opensRSVPInPhrases: Bool

    public init(item: ReadingListItem, content: ArticleContent,
         forceMode: ReadingListItem.ReaderMode? = nil,
         shareProvider: ReaderShareProviding? = nil,
         persistsModePreference: Bool = true,
         marksOpenedOnLoad: Bool = true,
         inlineControlsHeader: Bool = false,
         inlineHeaderSubtitle: String? = nil,
         onModeChange: ((ReadingListItem.ReaderMode) -> Void)? = nil) {
        self.item = item
        self.content = content
        self.shareProvider = shareProvider
        self.persistsModePreference = persistsModePreference
        self.marksOpenedOnLoad = marksOpenedOnLoad
        self.inlineControlsHeader = inlineControlsHeader
        self.inlineHeaderSubtitle = inlineHeaderSubtitle
        self.onModeChange = onModeChange
        self.availableModes = Self.baseModes + (ReadingListStore.shared.hasOriginalSource(for: item) ? [.original] : [])
        // First time on this article, fall back to the global last-used mode.
        let requestedMode = forceMode ?? item.lastReaderMode ?? ReaderSettings.lastReaderMode
        // The retired "highlight" mode is now RSVP → Phrases.
        self.opensRSVPInPhrases = (requestedMode == .highlight)
        let resolvedMode: ReadingListItem.ReaderMode = requestedMode == .highlight ? .rsvp : requestedMode
        self.mode = self.availableModes.contains(resolvedMode) ? resolvedMode : .scroll
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Restore any header tuck before this reader becomes visible again.
        if let bar = navigationController?.navigationBar {
            bar.transform = .identity
            bar.alpha = 1
        }
        navigationController?.setNavigationBarHidden(false, animated: false)
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LunaColors.background
        navigationItem.largeTitleDisplayMode = .never

        for (index, mode) in availableModes.enumerated() {
            modeControl.insertSegment(
                with: ReaderModeIcons.image(for: mode), at: index, animated: false)
        }
        modeControl.selectedSegmentIndex = availableModes.firstIndex(of: mode) ?? 0
        modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        audioButton.addTarget(self, action: #selector(audioToggled), for: .touchUpInside)
        updateAudioButton()

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentContainer)

        let contentTop: NSLayoutYAxisAnchor
        if inlineControlsHeader {
            // Inline (de-glassed) header on a solid card background — a solid fill,
            inlineHeader.translatesAutoresizingMaskIntoConstraints = false
            inlineHeader.backgroundColor = GlassStyle.solidBarColor
            view.addSubview(inlineHeader)
            audioButton.configuration = GlassStyle.solidCircularButtonConfiguration(
                symbol: audioOn ? "speaker.wave.2.fill" : "speaker.slash", padding: 8)
            audioButton.tintColor = GlassStyle.readingAccent
            modeControl.translatesAutoresizingMaskIntoConstraints = false
            audioButton.translatesAutoresizingMaskIntoConstraints = false
            inlineHeader.addSubview(modeControl)
            inlineHeader.addSubview(audioButton)
            var headerConstraints = [
                inlineHeader.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                inlineHeader.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                inlineHeader.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                modeControl.centerXAnchor.constraint(equalTo: inlineHeader.centerXAnchor),
                audioButton.trailingAnchor.constraint(equalTo: inlineHeader.trailingAnchor, constant: -12),
                audioButton.centerYAnchor.constraint(equalTo: modeControl.centerYAnchor),
            ]
            if let subtitle = inlineHeaderSubtitle {
                // One continuous glass header: the date/sender on top, controls below
                // — no separate strip, no divider seam.
                let subtitleLabel = UILabel()
                subtitleLabel.text = subtitle
                subtitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
                subtitleLabel.textColor = LunaColors.secondaryText
                subtitleLabel.textAlignment = .center
                subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
                inlineHeader.addSubview(subtitleLabel)
                headerConstraints += [
                    inlineHeader.heightAnchor.constraint(equalToConstant: 80),
                    // Inset from the corners so it clears the card's Bump/Read pills.
                    subtitleLabel.leadingAnchor.constraint(equalTo: inlineHeader.leadingAnchor, constant: 96),
                    subtitleLabel.trailingAnchor.constraint(equalTo: inlineHeader.trailingAnchor, constant: -96),
                    subtitleLabel.topAnchor.constraint(equalTo: inlineHeader.topAnchor, constant: 14),
                    modeControl.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 8),
                ]
            } else {
                headerConstraints += [
                    inlineHeader.heightAnchor.constraint(equalToConstant: 52),
                    modeControl.centerYAnchor.constraint(equalTo: inlineHeader.centerYAnchor),
                ]
            }
            NSLayoutConstraint.activate(headerConstraints)
            contentTop = inlineHeader.bottomAnchor
        } else {
            // Compact header: the mode switcher tucks into the nav bar between the
            // Back button and the audio toggle.
            navigationItem.titleView = modeControl
            // Opaque solid background (not translucent) so the bar reads consistently
            // against the solid reader background.
            let appearance = UINavigationBarAppearance()
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = LunaColors.background
            navigationItem.standardAppearance = appearance
            navigationItem.scrollEdgeAppearance = appearance
            navigationItem.rightBarButtonItems = [UIBarButtonItem(customView: audioButton)]
            contentTop = view.safeAreaLayoutGuide.topAnchor
        }

        NSLayoutConstraint.activate([
            contentContainer.topAnchor.constraint(equalTo: contentTop),
            contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // Share moved to a hovering circle (de-glassed), bottom-right (above the footer
        // controls). Shown whenever sharing is available (not in the share sheet).
        if shareProvider != nil {
            setUpFloatingShareButton()
        }

        if marksOpenedOnLoad {
            store.markReadState(.opened, for: item.id)
        }
        showCurrentMode()
    }

    private func setUpFloatingShareButton() {
        floatingShareButton.configuration = GlassStyle.solidCircularButtonConfiguration(
            symbol: "square.and.arrow.up", padding: 14)
        floatingShareButton.tintColor = GlassStyle.readingAccent
        ReaderShareMenu.install(
            on: floatingShareButton,
            providesMenu: shareProvider?.providesShareMenu == true,
            build: { [weak self] in self?.shareMenu() },
            fallback: { [weak self] in self?.shareTapped() })
        floatingShareButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(floatingShareButton)
        let bottom = floatingShareButton.bottomAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.bottomAnchor,
            constant: Self.floatingShareBottomInset(for: mode, audioOn: audioOn))
        floatingShareBottomConstraint = bottom
        NSLayoutConstraint.activate([
            floatingShareButton.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            bottom,
        ])
    }

    /// Vertical inset (from the bottom safe area) for the floating share button in
    /// each mode, so it never overlaps that mode's footer controls. Scroll mode only
    /// grows a playback footer when read-aloud is on, so the button sits low until
    /// then and lifts to clear the controls once they appear.
    private static func floatingShareBottomInset(
        for mode: ReadingListItem.ReaderMode, audioOn: Bool) -> CGFloat {
        switch mode {
        case .scroll:
            // The in-reader read-aloud footer only exists on the LEGACY path
            // (extensions). In-app the window-level mini-player replaces it,
            // so the share button stays low.
            return (audioOn && ReaderAudioLauncher.center == nil) ? -92 : -24
        case .rsvp: return -168                     // clear the scrubber + playback controls
        default: return -24                         // .original
        }
    }

    /// Fades the floating share button out when the end-of-article share footer
    /// scrolls into view (it already offers sharing), and back in otherwise.
    private func setFloatingShareHidden(_ hidden: Bool) {
        UIView.animate(withDuration: 0.2) {
            self.floatingShareButton.alpha = hidden ? 0 : 1
        }
    }

    // MARK: - Mode & audio switching

    @objc private func modeChanged() {
        if let inlineReaderForChrome, let state = inlineReaderForChrome.chromeState {
            let index = max(0, min(modeControl.selectedSegmentIndex, state.modes.count - 1))
            inlineReaderForChrome.chromeSetMode(state.modes[index])
            syncControlsToCurrentReader()
            return
        }
        let newMode = availableModes[
            max(0, min(modeControl.selectedSegmentIndex, availableModes.count - 1))]
        guard newMode != mode else { return }
        mode = newMode
        if persistsModePreference {
            store.setReaderMode(newMode, for: item.id)
            ReaderSettings.lastReaderMode = newMode
        }
        onModeChange?(newMode)
        showCurrentMode()
    }

    @objc private func audioToggled() {
        if let inlineReaderForChrome {
            inlineReaderForChrome.chromeToggleAudio()
            syncControlsToCurrentReader()
            return
        }
        audioOn.toggle()
        updateAudioButton()
        // Toggling OFF while the app-wide center is voicing THIS article pauses
        // it (the rebuilt child then renders silently). Playback of a different
        // article is deliberately untouched, and this is a no-op on the legacy
        // (extension) path where no center is installed.
        if !audioOn {
            ReaderAudioLauncher.pauseIfPlaying(itemID: item.id)
        }
        // Read-aloud grows a playback footer in scroll mode — lift the share button.
        floatingShareBottomConstraint?.constant = Self.floatingShareBottomInset(for: mode, audioOn: audioOn)
        showCurrentMode()
    }

    private func updateAudioButton() {
        let activeAudio = inlineReaderForChrome?.chromeState?.isAudioOn ?? audioOn
        let symbol = UIImage(systemName: activeAudio ? "speaker.wave.2.fill" : "speaker.slash")
        // The inline header uses a filled `Configuration` button; the nav-bar header a
        // plain system button. Update whichever this instance has.
        if audioButton.configuration != nil {
            audioButton.configuration?.image = symbol
        } else {
            audioButton.setImage(symbol, for: .normal)
        }
        audioButton.accessibilityLabel = activeAudio ? "Turn off read aloud" : "Read aloud"
    }

    private func syncControlsToCurrentReader() {
        let modes = inlineReaderForChrome?.chromeState?.modes ?? availableModes
        modeControl.removeAllSegments()
        for (index, candidate) in modes.enumerated() {
            modeControl.insertSegment(
                with: ReaderModeIcons.image(for: candidate), at: index, animated: false)
        }
        let selected = inlineReaderForChrome?.chromeState?.selectedMode ?? mode
        modeControl.selectedSegmentIndex = modes.firstIndex(of: selected) ?? 0
        updateAudioButton()
    }

    public func inlineReaderWillPresent(_ reader: ReaderChromeControlling) {
        inlineReaderForChrome = reader
        syncControlsToCurrentReader()
    }

    public func inlineReaderDidDismiss(_ reader: ReaderChromeControlling) {
        guard inlineReaderForChrome === reader else { return }
        inlineReaderForChrome = nil
        syncControlsToCurrentReader()
    }

    public var inlineReaderTopEdgeInWindow: CGFloat {
        guard isViewLoaded else { return 0 }
        return contentContainer.convert(contentContainer.bounds, to: nil).minY
    }

    public var inlineReaderCardFrameInWindow: CGRect {
        guard isViewLoaded else { return .zero }
        return contentContainer.convert(contentContainer.bounds, to: nil)
    }

    public var inlineReaderShowsOuterContentBelow: Bool {
        guard let currentChild else { return false }
        return Self.firstScrollView(in: currentChild.view) != nil
    }

    private static func firstScrollView(in view: UIView) -> UIScrollView? {
        if let scrollView = view as? UIScrollView { return scrollView }
        for subview in view.subviews {
            if let match = firstScrollView(in: subview) { return match }
        }
        return nil
    }

    private func showCurrentMode() {
        if let old = currentChild {
            // Carry the reading position forward before tearing the child down.
            if let position = (old as? ReaderPositionTracking)?.currentReadingWordIndex {
                resumeWordIndex = position
            }
            old.willMove(toParent: nil)
            old.view.removeFromSuperview()
            old.removeFromParent()
        }

        let child: UIViewController
        switch mode {
        case .rsvp:
            let rsvp = RSVPViewController(
                item: item, content: content, audioEnabled: audioOn,
                shareProvider: shareProvider, resumeWordIndex: resumeWordIndex,
                initialDisplayMode: opensRSVPInPhrases ? .phrases : nil)
            opensRSVPInPhrases = false
            rsvp.completionDelegate = self
            child = rsvp
        case .original:
            // The archive keeps its OWN scroll place, disjoint from the shared
            // scroll/RSVP reading position carried between the text modes.
            child = OriginalPageViewController(item: item, store: store, persistsScrollOffset: true)
        default:
            child = makeScrollReader()
        }

        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            child.view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            child.view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
        child.didMove(toParent: self)
        currentChild = child

        floatingShareBottomConstraint?.constant = Self.floatingShareBottomInset(for: mode, audioOn: audioOn)
        // A freshly shown mode starts with the share button visible.
        floatingShareButton.alpha = 1
        // Keep the share button above the freshly added child content.
        view.bringSubviewToFront(floatingShareButton)
    }

    private func makeScrollReader() -> ScrollReaderViewController {
        let scroll = ScrollReaderViewController(
            item: item, content: content, audioEnabled: audioOn,
            shareProvider: shareProvider,
            resumeWordIndex: resumeWordIndex)
        scroll.completionDelegate = self
        scroll.onShareFooterVisibilityChanged = { [weak self] visible in
            self?.setFloatingShareHidden(visible)
        }
        return scroll
    }

    /// The share options for whatever the button currently points at: an inline
    /// reader opened on top of this one, else this reader's own article.
    private func shareMenu() -> UIMenu? {
        if let inlineReaderForChrome {
            return inlineReaderForChrome.chromeShareMenu(from: floatingShareButton)
        }
        return shareProvider?.shareMenu(
            urlString: item.urlString, title: item.title ?? content.title,
            from: self, sourceView: floatingShareButton)
    }

    private func shareTapped() {
        if let inlineReaderForChrome {
            inlineReaderForChrome.chromeShare(from: floatingShareButton)
            return
        }
        shareProvider?.presentShareSheet(
            urlString: item.urlString, title: item.title ?? content.title,
            from: self, sourceView: view)
    }

    private func markRead() {
        store.markFinishedReading(item.id)
    }
}

extension ReaderViewController: ReaderCompletionDelegate {
    public func readerDidFinishReading(_ reader: UIViewController) {
        markRead()
    }
    public func readerDidMoveAwayFromEnd(_ reader: UIViewController) {
        // Completion remains durable while the user revisits earlier content.
    }
}

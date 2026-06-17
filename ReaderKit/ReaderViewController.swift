//
//  ReaderViewController.swift
//  Clip
//

import UIKit

/// Hosts the three reading modes — scrolling text, chunk-highlight, and RSVP —
/// swapping them via a three-way switcher, with a separate audio (read-aloud)
/// toggle that applies to whichever mode is showing. Remembers the last used
/// mode per article and globally (the default for new articles), and tracks
/// opened/read state.
final class ReaderViewController: UIViewController {

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
    /// Hovering glass share button, bottom-right above the footer controls.
    private let floatingShareButton = UIButton(type: .system)
    /// Drives the share button's vertical position per mode so it clears each
    /// mode's footer: low in scroll (no footer), above the chunk footer in
    /// highlight, and above the playback controls in RSVP.
    private var floatingShareBottomConstraint: NSLayoutConstraint?

    /// Sharing affordances (nil in the share extension → no share button/footer).
    private let shareProvider: ReaderShareProviding?
    /// Gaze-tracker factory (nil in the share extension → no eye tracking).
    private let gazeTrackerFactory: GazeTrackerFactory?

    /// When false, switching modes does NOT write the shared `ReaderSettings`/
    /// per-item mode (used by the action extension, which keeps its own
    /// preference). When set, `onModeChange` is called instead.
    private let persistsModePreference: Bool
    private let onModeChange: ((ReadingListItem.ReaderMode) -> Void)?

    private let modeControl = UISegmentedControl()
    private let audioButton = UIButton(type: .system)

    private static let orderedModes: [ReadingListItem.ReaderMode] = [.scroll, .highlight, .rsvp]
    private static let modeSymbols = ["text.alignleft", "highlighter", "bolt.fill"]

    init(item: ReadingListItem, content: ArticleContent,
         forceMode: ReadingListItem.ReaderMode? = nil,
         shareProvider: ReaderShareProviding? = nil,
         gazeTrackerFactory: GazeTrackerFactory? = nil,
         persistsModePreference: Bool = true,
         onModeChange: ((ReadingListItem.ReaderMode) -> Void)? = nil) {
        self.item = item
        self.content = content
        self.shareProvider = shareProvider
        self.gazeTrackerFactory = gazeTrackerFactory
        self.persistsModePreference = persistsModePreference
        self.onModeChange = onModeChange
        // First time on this article, fall back to the global last-used mode.
        self.mode = forceMode ?? item.lastReaderMode ?? ReaderSettings.lastReaderMode
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .never

        for (index, symbol) in Self.modeSymbols.enumerated() {
            modeControl.insertSegment(
                with: UIImage(systemName: symbol), at: index, animated: false)
        }
        modeControl.selectedSegmentIndex = Self.orderedModes.firstIndex(of: mode) ?? 0
        modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        // Compact header: the mode switcher tucks into the nav bar between the
        // Back button and the audio toggle.
        navigationItem.titleView = modeControl

        // The nav bar keeps a blurred material background even at the scroll edge,
        // so content reads under a frosted header as it scrolls.
        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        navigationItem.standardAppearance = appearance
        navigationItem.scrollEdgeAppearance = appearance

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentContainer)
        NSLayoutConstraint.activate([
            contentContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        updateAudioButton()
        audioButton.addTarget(self, action: #selector(audioToggled), for: .touchUpInside)
        navigationItem.rightBarButtonItems = [UIBarButtonItem(customView: audioButton)]

        // Share moved to a hovering glass circle, bottom-right (above the footer
        // controls). Shown whenever sharing is available (not in the share sheet).
        if shareProvider != nil {
            setUpFloatingShareButton()
        }

        store.markReadState(.opened, for: item.id)
        showCurrentMode()
    }

    private func setUpFloatingShareButton() {
        floatingShareButton.configuration = GlassStyle.circularButtonConfiguration(
            symbol: "square.and.arrow.up", padding: 14)
        floatingShareButton.tintColor = GlassStyle.readingAccent
        floatingShareButton.addTarget(self, action: #selector(shareTapped), for: .touchUpInside)
        floatingShareButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(floatingShareButton)
        let bottom = floatingShareButton.bottomAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.bottomAnchor,
            constant: Self.floatingShareBottomInset(for: mode))
        floatingShareBottomConstraint = bottom
        NSLayoutConstraint.activate([
            floatingShareButton.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            bottom,
        ])
    }

    /// Vertical inset (from the bottom safe area) for the floating share button
    /// in each mode, so it never overlaps that mode's footer controls.
    private static func floatingShareBottomInset(for mode: ReadingListItem.ReaderMode) -> CGFloat {
        switch mode {
        case .scroll: return -24       // no footer — sit near the bottom edge
        case .highlight: return -92    // clear the chunk-navigation footer
        case .rsvp: return -168        // clear the scrubber + playback controls
        }
    }

    // MARK: - Mode & audio switching

    @objc private func modeChanged() {
        let newMode = Self.orderedModes[
            max(0, min(modeControl.selectedSegmentIndex, Self.orderedModes.count - 1))]
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
        audioOn.toggle()
        updateAudioButton()
        showCurrentMode()
    }

    private func updateAudioButton() {
        audioButton.setImage(
            UIImage(systemName: audioOn ? "speaker.wave.2.fill" : "speaker.slash"), for: .normal)
        audioButton.accessibilityLabel = audioOn ? "Turn off read aloud" : "Read aloud"
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
        case .scroll:
            child = makeScrollReader(autoHighlight: false)
        case .highlight:
            child = makeScrollReader(autoHighlight: true)
        case .rsvp:
            let rsvp = RSVPViewController(
                item: item, content: content, audioEnabled: audioOn,
                shareProvider: shareProvider, resumeWordIndex: resumeWordIndex)
            rsvp.onFinishedReading = { [weak self] in self?.markRead() }
            child = rsvp
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

        floatingShareBottomConstraint?.constant = Self.floatingShareBottomInset(for: mode)
        // Keep the share button above the freshly added child content.
        view.bringSubviewToFront(floatingShareButton)
    }

    private func makeScrollReader(autoHighlight: Bool) -> ScrollReaderViewController {
        let scroll = ScrollReaderViewController(
            item: item, content: content, autoHighlight: autoHighlight, audioEnabled: audioOn,
            shareProvider: shareProvider, gazeTrackerFactory: gazeTrackerFactory,
            resumeWordIndex: resumeWordIndex)
        scroll.onFinishedReading = { [weak self] in self?.markRead() }
        return scroll
    }

    @objc private func shareTapped() {
        shareProvider?.presentShareSheet(
            urlString: item.urlString, title: item.title ?? content.title,
            from: self, sourceView: view)
    }

    private func markRead() {
        store.markReadState(.read, for: item.id)
    }
}

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

    /// The mode switcher lives in an inline header bar (not the nav title) so it
    /// doesn't slide during push/pop transitions. Child readers fill the area
    /// below it.
    private let headerBar = UIView()
    private let contentContainer = UIView()

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

        // Inline header bar with the mode switcher, then the child reader below.
        headerBar.translatesAutoresizingMaskIntoConstraints = false
        modeControl.translatesAutoresizingMaskIntoConstraints = false
        headerBar.addSubview(modeControl)
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerBar)
        view.addSubview(contentContainer)
        NSLayoutConstraint.activate([
            headerBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            headerBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            modeControl.centerXAnchor.constraint(equalTo: headerBar.centerXAnchor),
            modeControl.topAnchor.constraint(equalTo: headerBar.topAnchor, constant: 6),
            modeControl.bottomAnchor.constraint(equalTo: headerBar.bottomAnchor, constant: -6),
            modeControl.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            contentContainer.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        updateAudioButton()
        audioButton.addTarget(self, action: #selector(audioToggled), for: .touchUpInside)
        let audioItem = UIBarButtonItem(customView: audioButton)
        // Share button only when sharing is available (not in the share sheet)
        // and there's a real web URL (documents/emails have none).
        if shareProvider != nil, item.isShareable {
            let shareButton = UIBarButtonItem(
                image: UIImage(systemName: "square.and.arrow.up"), style: .plain,
                target: self, action: #selector(shareTapped))
            navigationItem.rightBarButtonItems = [shareButton, audioItem]
        } else {
            navigationItem.rightBarButtonItems = [audioItem]
        }

        store.markReadState(.opened, for: item.id)
        showCurrentMode()
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

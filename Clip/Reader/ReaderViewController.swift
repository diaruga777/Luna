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

    private let modeControl = UISegmentedControl()
    private let audioButton = UIButton(type: .system)

    private static let orderedModes: [ReadingListItem.ReaderMode] = [.scroll, .highlight, .rsvp]
    private static let modeSymbols = ["text.alignleft", "highlighter", "bolt.fill"]

    init(item: ReadingListItem, content: ArticleContent,
         forceMode: ReadingListItem.ReaderMode? = nil) {
        self.item = item
        self.content = content
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
        navigationItem.titleView = modeControl

        updateAudioButton()
        audioButton.addTarget(self, action: #selector(audioToggled), for: .touchUpInside)
        let shareButton = UIBarButtonItem(
            image: UIImage(systemName: "square.and.arrow.up"), style: .plain,
            target: self, action: #selector(shareTapped))
        let audioItem = UIBarButtonItem(customView: audioButton)
        // Documents have no URL to share.
        navigationItem.rightBarButtonItems = item.isDocument ? [audioItem] : [shareButton, audioItem]

        store.markReadState(.opened, for: item.id)
        showCurrentMode()
    }

    // MARK: - Mode & audio switching

    @objc private func modeChanged() {
        let newMode = Self.orderedModes[
            max(0, min(modeControl.selectedSegmentIndex, Self.orderedModes.count - 1))]
        guard newMode != mode else { return }
        mode = newMode
        store.setReaderMode(newMode, for: item.id)
        ReaderSettings.lastReaderMode = newMode
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
            let rsvp = RSVPViewController(item: item, content: content, audioEnabled: audioOn)
            rsvp.onFinishedReading = { [weak self] in self?.markRead() }
            child = rsvp
        }

        addChild(child)
        child.view.frame = view.bounds
        child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(child.view)
        child.didMove(toParent: self)
        currentChild = child
    }

    private func makeScrollReader(autoHighlight: Bool) -> ScrollReaderViewController {
        let scroll = ScrollReaderViewController(
            item: item, content: content, autoHighlight: autoHighlight, audioEnabled: audioOn)
        scroll.onFinishedReading = { [weak self] in self?.markRead() }
        return scroll
    }

    @objc private func shareTapped() {
        SendToFriendSheet.present(
            from: self, sourceView: view,
            urlString: item.urlString, title: item.title ?? content.title)
    }

    private func markRead() {
        store.markReadState(.read, for: item.id)
    }
}

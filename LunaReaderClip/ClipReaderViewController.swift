//
//  ClipReaderViewController.swift
//  LunaReaderClip
//

import LunaArchiveReader
import LunaDesignSystem
import LunaIngest
import LunaModels
import LunaReaderUI
import LunaStorage
import LunaURLClassification
import UIKit

@MainActor
final class ClipReaderViewController: UIViewController {
    private enum State {
        case waiting
        case loading(URL)
        case failed(String)
    }

    private var state: State = .waiting
    private var task: Task<Void, Never>?
    /// The clip's OWN saves store, in the clip's own container — never the
    /// App Group one the full app reads.
    ///
    /// `ArchiveWebReaderViewController` extracts THROUGH a store (it saves the
    /// unlocked article to an item, then hands the item back), and the clip stays
    /// read-only with respect to the user's saved list: no clip save may show up in
    /// Luna Reader later. A private container satisfies both — the unlock writes
    /// somewhere real, and that somewhere is thrown away with the clip.
    private lazy var scratchStore: SavesStore = {
        let directory = URL.cachesDirectory.appendingPathComponent(
            "ClipArchiveUnlock", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return SavesStore(containerURL: directory)
    }()
    private let spinner = HorizonSpinnerView(side: 36)
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private var lastSourceURL: URL?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.string("AppClip_reader_navigationTitle")
        // Same appearance the host app pins: the clip pushes LunaReaderUI /
        // LunaMediaDownload screens that are light-on-dark in both appearances.
        AppearanceSettings.apply(to: self)
        view.backgroundColor = LunaColors.background
        configureLayout()
        render()
    }

    deinit {
        task?.cancel()
    }

    func handleLaunchURL(_ launchURL: URL) {
        guard let sourceURL = LunaAppClipInvocationURL.sourceURL(from: launchURL, for: .reader)
        else {
            update(.failed(L10n.string("AppClip_reader_missingURLMessage")))
            return
        }
        load(sourceURL)
    }

    private func load(_ sourceURL: URL) {
        task?.cancel()
        lastSourceURL = sourceURL
        update(.loading(sourceURL))

        task = Task {
            let result = await IngestPipeline.processResolved(IngestInput(url: sourceURL, source: .manual))
            guard !Task.isCancelled else { return }
            await present(result)
        }
    }

    private func present(_ result: IngestResult) async {
        switch ClipReaderRoute.route(for: result.outcome) {
        case .reader:
            guard case let .article(content, _) = result.outcome else { return }
            var item = SavedItem(urlString: result.url.absoluteString)
            item.title = content.title
            item.state = .ready
            item.wordCount = content.wholeText.split(whereSeparator: \.isWhitespace).count
            presentReader(item: item, content: content)

        case .archiveUnlock:
            guard case let .needsArchive(title) = result.outcome else { return }
            presentArchiveUnlock(for: result.url, fallbackTitle: title)

        case .notReadable:
            update(.failed(L10n.string("AppClip_reader_notReadableArticleMessage")))

        case .failed:
            update(.failed(L10n.string("Common_couldntLoadThisArticle")))
        }
    }

    fileprivate func presentReader(item: SavedItem, content: ArticleContent) {
        let reader = ReaderViewController(
            item: item,
            content: content,
            forceMode: .scroll,
            shareProvider: nil,
            persistsModePreference: false,
            marksOpenedOnLoad: false)
        navigationController?.setViewControllers([reader], animated: false)
    }

    /// A hard paywall or a bot wall the silent tier couldn't pass: resolve it right
    /// here, exactly as the app and both share-sheet extensions do. Nothing about
    /// the unlock needs the full app — an App Clip may run a `WKWebView`, keep
    /// cookies, and open Safari — so parking the user on "download the app" was
    /// throwing away an article the clip can read.
    private func presentArchiveUnlock(for url: URL, fallbackTitle: String) {
        let item = scratchStore.add(urlString: url.absoluteString)
        scratchStore.markNeedsCaptcha(item.id, title: fallbackTitle)

        let archive = ArchiveWebReaderViewController(
            articleURL: url, itemID: item.id, store: scratchStore)
        // A clip lives in a window it doesn't own the root of, so — like the
        // extensions — each screen pins the appearance itself.
        AppearanceSettings.apply(to: archive)
        archive.delegate = ClipUnlockLegs(host: self, itemID: item.id, store: scratchStore)
        navigationController?.setViewControllers([archive], animated: false)
    }

    /// The clip's answer to a closed unlock: there is nowhere to go back to, so it
    /// returns to this screen with the full app offered as the remaining route, and
    /// the unlock one tap away again via Retry.
    fileprivate func returnFromUnlock() {
        navigationController?.setViewControllers([self], animated: false)
        update(.failed(L10n.string("AppClip_reader_needsArchiveUnlockMessage")))
    }

    private func configureLayout() {
        titleLabel.font = .preferredFont(forTextStyle: .largeTitle)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0

        detailLabel.font = .preferredFont(forTextStyle: .body)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = LunaColors.secondaryText
        detailLabel.numberOfLines = 0

        spinner.translatesAutoresizingMaskIntoConstraints = false

        var retryConfiguration = UIButton.Configuration.gray()
        retryConfiguration.image = UIImage(systemName: "arrow.clockwise")
        retryConfiguration.imagePadding = 8
        retryButton.configuration = retryConfiguration
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [
            spinner,
            titleLabel,
            detailLabel,
            retryButton,
        ])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.leadingAnchor.constraint(
                greaterThanOrEqualTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(
                lessThanOrEqualTo: view.layoutMarginsGuide.trailingAnchor),
            // A clip opens full screen, so on an iPad this waiting state would
            // otherwise be one line of copy stretched across thirteen inches.
            stack.widthAnchor.constraint(
                lessThanOrEqualToConstant: LunaLayout.readableWidth),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            retryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    private func update(_ state: State) {
        self.state = state
        render()
    }

    private func render() {
        switch state {
        case .waiting:
            spinner.stopAnimating()
            titleLabel.text = L10n.string("AppClip_reader_waitingHeadline")
            detailLabel.text = L10n.string("AppClip_reader_waitingSubtitle")
            retryButton.isHidden = true

        case let .loading(url):
            spinner.startAnimating()
            titleLabel.text = L10n.string("Common_loading")
            detailLabel.text = url.host ?? url.absoluteString
            retryButton.isHidden = true

        case let .failed(message):
            spinner.stopAnimating()
            titleLabel.text = L10n.string("AppClip_reader_failedHeadline")
            detailLabel.text = message
            retryButton.configuration?.title = L10n.string("AppClip_reader_retryButtonTitle")
            retryButton.isHidden = lastSourceURL == nil
        }
    }

    @objc private func retryTapped() {
        guard let lastSourceURL else { return }
        load(lastSourceURL)
    }
}

/// The clip's legs for the archive unlock. The reader retains this; it holds the
/// clip screen weakly, the same lifetime rule the extensions' own legs follow.
///
/// It is the one host that ANSWERS the Safari escape: a clip is an app, so
/// `UIApplication` is there to leave with, where an `.appex` has nothing to open a
/// URL through and takes the protocol's `false`.
@MainActor
private final class ClipUnlockLegs: ArchiveUnlockDelegate {
    private weak var host: ClipReaderViewController?
    private let itemID: UUID
    private let store: SavesStore

    init(host: ClipReaderViewController, itemID: UUID, store: SavesStore) {
        self.host = host
        self.itemID = itemID
        self.store = store
    }

    var offersSystemBrowserEscape: Bool { true }

    func archiveReader(
        _ reader: ArchiveWebReaderViewController, openInSystemBrowser url: URL
    ) {
        UIApplication.shared.open(url)
    }

    func archiveReaderDidClose(_ reader: ArchiveWebReaderViewController) {
        host?.returnFromUnlock()
    }

    func archiveReaderDidUnlockArticle(_ reader: ArchiveWebReaderViewController) {
        guard let host,
              let unlocked = store.item(withID: itemID),
              let content = store.content(for: unlocked) else { return }
        host.presentReader(item: unlocked, content: content)
    }
}

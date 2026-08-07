//
//  ShareReaderViewController.swift
//  LunaReaderUI
//

import LunaArchiveReader
import LunaDesignSystem
import LunaStorage
import LunaIngest
import LunaHTMLClassification
import LunaModels
import UIKit

/// Presents the shared article in the EXACT same reader as the main app
/// (`ReaderViewController` from the shared ReaderKit), scoped to that one
/// article. It fetches + extracts the page, then shows the chosen mode with no
/// share affordance (nil provider). Inline link tapping,
/// mode switching, and audio all work; Done exits the extension.
public final class ShareReaderViewController: UIViewController {

    public enum Mode: String {
        case reader, rsvp, chunk

        var readerMode: ReadingListItem.ReaderMode {
            switch self {
            case .reader: return .scroll
            case .rsvp: return .rsvp
            case .chunk: return .highlight
            }
        }

        init(readerMode: ReadingListItem.ReaderMode) {
            switch readerMode {
            case .scroll: self = .reader
            case .rsvp: self = .rsvp
            case .highlight: self = .chunk
            // The action extension never persists a page archive, so its closest
            // equivalent is the standard local reader.
            case .original: self = .reader
            }
        }
    }

    private let url: URL
    private let mode: Mode
    private let onDone: () -> Void
    /// Persists the surface's last-used reader mode (the action extension's own
    /// `ActionReaderMode`, injected by the composition root — this article-kind
    /// module doesn't see the surface's preference store). Nil when the host
    /// surface keeps no mode preference (e.g. the UI-test harness).
    private let onModeChange: ((Mode) -> Void)?
    /// A pre-computed `Outcome` to present (the action extension already ran the
    /// shared `IngestPipeline`), or nil to run the pipeline itself on `viewDidLoad`.
    private let precomputedOutcome: Outcome?
    private let spinner = HorizonSpinnerView(side: 36)
    private let loadingStatus = EclipseBloomStatusLabel()
    private var articleLoadingStatus: ArticleLoadingStatusCycler?

    public init(
        url: URL, mode: Mode, outcome: Outcome? = nil,
        onModeChange: ((Mode) -> Void)? = nil, onDone: @escaping () -> Void
    ) {
        self.url = url
        self.mode = mode
        self.precomputedOutcome = outcome
        self.onModeChange = onModeChange
        self.onDone = onDone
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Prepared presentation (no intermediate loading screen)

    /// How long a surface holds its loading state waiting for the images whose
    /// size the page never declared. Bounded because an unreachable image CDN
    /// must not strand the sheet on a spinner; whatever landed by the deadline is
    /// still baked in. A `var` only so a test can prove the bound holds without
    /// spending eight seconds proving it; nothing in the app writes it.
    public static var imagePreparationTimeout: TimeInterval = 8

    /// Replaces the blocking half of the image settling. Nil (production) runs
    /// the real bounded downloader; a test surface substitutes it so a fixture's
    /// `<img>` tags don't pull a unit test onto the network.
    public static var settleImagesOverride: ((
        _ content: ArticleContent, _ itemID: UUID, _ url: URL, _ store: ReadingListStore
    ) async -> ArticleContent)?

    /// Builds the finished reader for an already-extracted article: persists the
    /// content, settles the image layout, and hands back a reader whose FIRST
    /// frame is final.
    ///
    /// The caller keeps its own loading UI up until this returns, which is the
    /// point — the action extension used to tear its spinner down, install this
    /// screen's second spinner (in a different place, under a Done button that
    /// appeared a beat early), and only then swap in the reader. One prepared
    /// hand-off replaces all three steps.
    public static func preparedReader(
        url: URL, mode: Mode, content: ArticleContent, store: ReadingListStore = .shared,
        onModeChange: ((Mode) -> Void)?, onDone: @escaping () -> Void
    ) async -> UIViewController {
        // Reuse the row the extension already appended (`add` is idempotent), so
        // the reader marks the same shared item opened/read.
        let item = store.add(urlString: url.absoluteString)
        let settled = await settledImageLayout(for: content, item: item, url: url, store: store)
        let saved = store.saveContent(settled, for: item)
        return makeReader(
            item: saved, content: settled, mode: mode,
            onModeChange: onModeChange, onDone: onDone)
    }

    /// Resolves the images already on disk, then downloads the ones the page gave
    /// no dimensions for — those are exactly the images with no placeholder to
    /// land in, so they are the ones whose late arrival shoves the text around.
    /// Images with declared sizes keep their reserved space and are left to load
    /// in behind it.
    ///
    /// On timeout the local resolve runs again, so files that did arrive before
    /// the deadline are still baked into the first render.
    public static func settledImageLayout(
        for content: ArticleContent, item: ReadingListItem, url: URL, store: ReadingListStore
    ) async -> ArticleContent {
        let local = ArticleImageDownloader.resolveLocalImages(content, store: store)
        let needsSettling = local.blocks.contains { block in
            block.kind == .image && block.imageFileName == nil
                && (block.imageWidth == nil || block.imageHeight == nil)
        }
        guard needsSettling else { return local }

        let itemID = item.id
        let timeout = imagePreparationTimeout
        let settle = settleImagesOverride
        let downloaded: ArticleContent? = await withTaskGroup(
            of: ArticleContent?.self
        ) { group in
            group.addTask {
                if let settle { return await settle(local, itemID, url, store) }
                return await ArticleImageDownloader.downloadUnknownSizeImages(
                    local, itemID: itemID, store: store, refererURL: url)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        return downloaded ?? ArticleImageDownloader.resolveLocalImages(local, store: store)
    }

    private static func makeReader(
        item: ReadingListItem, content: ArticleContent, mode: Mode,
        onModeChange: ((Mode) -> Void)?, onDone: @escaping () -> Void
    ) -> ReaderViewController {
        // A lightweight share provider (friend-share via the App Group queue +
        // link share — no CloudKit in the extension) so the reader's own share
        // button works. The reader marks the (real, shared) item opened/read
        // via ReadingListStore.
        let reader = ReaderViewController(
            item: item, content: content, forceMode: mode.readerMode,
            shareProvider: ExtensionReaderShareProvider(),
            // The action extension keeps its OWN last-used mode, separate from
            // the main app — persist switches locally (via the injected
            // `onModeChange`), don't touch the shared ReaderSettings.
            persistsModePreference: false,
            onModeChange: { onModeChange?(Mode(readerMode: $0)) })
        reader.navigationItem.leftBarButtonItem = doneButton(onDone)
        return reader
    }

    /// A Done item whose action lives in the closure (retained by the bar item),
    /// so it still works after its view controller leaves the nav stack.
    ///
    /// The READER keeps its exit in the navigation bar: its own bottom-right
    /// corner is already taken by the floating share control, and two hovering
    /// circles in one corner is worse than one bar button. Every screen that
    /// doesn't have that conflict — this one's loading / saved / failure states,
    /// and the other extension surfaces — uses `ExtensionExitButton` instead.
    private static func doneButton(_ onDone: @escaping () -> Void) -> UIBarButtonItem {
        UIBarButtonItem(systemItem: .done, primaryAction: UIAction { _ in onDone() })
    }

    /// This screen's own exit: the shared floating glass button, bottom-right.
    private lazy var exitButton = ExtensionExitButton.make { [weak self] in self?.onDone() }

    /// The loading / saved / failure states carry the floating exit instead of a
    /// navigation bar holding nothing else. The reader that replaces this screen
    /// puts the bar back itself (`ReaderViewController.viewWillAppear`).
    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LunaColors.background

        spinner.translatesAutoresizingMaskIntoConstraints = false
        loadingStatus.translatesAutoresizingMaskIntoConstraints = false
        loadingStatus.textColor = LunaColors.secondaryText
        loadingStatus.font = .preferredFont(forTextStyle: .body)
        loadingStatus.textAlignment = .center
        loadingStatus.numberOfLines = 0
        view.addSubview(spinner)
        view.addSubview(loadingStatus)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -16),
            loadingStatus.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 16),
            loadingStatus.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingStatus.leadingAnchor.constraint(
                greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            loadingStatus.trailingAnchor.constraint(
                lessThanOrEqualTo: view.trailingAnchor, constant: -32),
            loadingStatus.widthAnchor.constraint(
                lessThanOrEqualToConstant: LunaLayout.readableWidth),
        ])
        spinner.startAnimating()
        articleLoadingStatus = ArticleLoadingStatusCycler(
            label: loadingStatus, initialText: L10n.string("Common_openingInLuna"))
        articleLoadingStatus?.start()
        installExitButton()

        Task { await ingestAndPresent() }
    }

    private func installExitButton() {
        view.addSubview(exitButton)
        NSLayoutConstraint.activate([
            exitButton.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor,
                constant: -ExtensionExitButton.edgeInset),
            exitButton.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                constant: -ExtensionExitButton.edgeInset),
        ])
    }

    private func ingestAndPresent() async {
        // Save immediately (shared storage) so the article is captured even if
        // the user exits mid-read; reuse the item the extension just appended.
        let item = ReadingListStore.shared.add(urlString: url.absoluteString)

        // Use the action extension's already-computed `Outcome` (the ONE shared
        // `IngestPipeline` ran upstream — bounded, classified video/social before any
        // extraction), or run the pipeline here if presented standalone. Either way
        // it's the SAME pipeline as every other surface.
        let outcome: Outcome
        if let precomputedOutcome {
            outcome = precomputedOutcome
        } else {
            outcome = await IngestPipeline.process(IngestInput(url: url, source: .shareSheet))
        }

        switch outcome {
        case .article(let content, _):
            // Settle the image layout BEFORE leaving the loading state, so the
            // article's first frame is its final one. Persist the parsed content
            // (with whatever images resolved) so the main app has it too.
            let settled = await Self.settledImageLayout(
                for: content, item: item, url: url, store: ReadingListStore.shared)
            let saved = ReadingListStore.shared.saveContent(settled, for: item)
            presentReader(item: saved, content: settled)
        case let .product(product, _):
            // A product page: save it as a price tracker silently (the reader can't
            // present the main-app price UI) and confirm — never paywall-treated.
            ReadingListStore.shared.savePriceTracker(
                product.makeTracker(
                    fallbackURL: url,
                    alertThresholdFraction: PriceAlertThresholdPolicy.initialThresholdFraction),
                forURLString: url.absoluteString)
            presentSavedConfirmation(productName: product.name)
        case .needsArchive(let title):
            // A genuine paywall (WSJ/FT/…): resolve its archive.today CAPTCHA right
            // here in the extension's own UI — the URL is pre-filled.
            presentArchiveReader(for: item, fallbackTitle: title)
        case .video, .social, .document:
            // A video/post/document reached the reader VC (shouldn't, since the
            // host routes those to SavedNonTextualViewController) — never extract it;
            // confirm the save and let the app render it.
            presentSavedConfirmation(productName: url.host ?? L10n.string("Common_saved"))
        case .failed, .unsupported:
            // .unsupported can't genuinely occur here (the driver gates and
            // discards before presenting a reader), so treat it as a failure.
            presentFailure()
        }
    }

    /// Loads the article's archive.today snapshot in a web view so the user can
    /// solve any CAPTCHA inline. Marks the item `.needsCaptcha` first, so that if
    /// the user exits before solving it stays unlockable from the main app; once
    /// the snapshot loads, the web reader extracts the article and flips it to
    /// `.ready`.
    private func presentArchiveReader(for item: ReadingListItem, fallbackTitle: String) {
        articleLoadingStatus?.stop()
        spinner.stopAnimating()
        ReadingListStore.shared.markNeedsCaptcha(item.id, title: fallbackTitle)
        // The archive reader keeps its Done (and "open in Safari") in the bar this
        // screen hid — put it back before handing the stack over.
        navigationController?.setNavigationBarHidden(false, animated: false)
        let archive = ArchiveWebReaderViewController(articleURL: url, itemID: item.id)
        let onDone = self.onDone
        archive.onClose = { onDone() }
        // Once the CAPTCHA is solved and the snapshot's article is extracted, swap
        // the web view out for the native reader showing the captured content —
        // the user reads in-app, not the raw archive page.
        archive.onExtracted = { [weak self] in
            guard let self,
                  let fresh = ReadingListStore.shared.item(withID: item.id),
                  let content = ReadingListStore.shared.content(for: fresh) else { return }
            Task { @MainActor in
                let settled = await Self.settledImageLayout(
                    for: content, item: fresh, url: self.url, store: ReadingListStore.shared)
                let saved = ReadingListStore.shared.saveContent(settled, for: fresh)
                self.presentReader(item: saved, content: settled)
            }
        }
        navigationController?.setViewControllers([archive], animated: false)
    }

    private func presentReader(item: ReadingListItem, content: ArticleContent) {
        articleLoadingStatus?.stop()
        spinner.stopAnimating()
        let reader = Self.makeReader(
            item: item, content: content, mode: mode,
            onModeChange: onModeChange, onDone: onDone)
        // Replace this loading screen with the reader as the sole VC (no back).
        navigationController?.setViewControllers([reader], animated: false)
    }

    /// A saved-confirmation state for a product page captured as a price tracker:
    /// a checkmark + the product name. The user edits the tracker in the main app.
    private func presentSavedConfirmation(productName: String) {
        articleLoadingStatus?.stop()
        spinner.stopAnimating()

        let icon = UIImageView(image: UIImage(
            systemName: "checkmark.circle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 44, weight: .semibold)))
        icon.tintColor = GlassStyle.readingAccent
        icon.contentMode = .center

        let label = UILabel()
        label.text = L10n.string("Reader_share_trackingPriceMessage", productName)
        label.textColor = LunaColors.primaryText
        label.font = .preferredFont(forTextStyle: .headline)
        label.textAlignment = .center
        label.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
        ])
    }

    private func presentFailure() {
        articleLoadingStatus?.stop()
        spinner.stopAnimating()
        // Nothing was read — the exit stops claiming otherwise.
        exitButton.configuration?.image = UIImage(systemName: "xmark")
        exitButton.accessibilityLabel = L10n.string("Common_close")

        let icon = UIImageView(image: UIImage(
            systemName: "exclamationmark.triangle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 40, weight: .semibold)))
        icon.tintColor = .systemRed
        icon.contentMode = .center

        let label = UILabel()
        label.text = L10n.string("Common_couldntLoadThisArticle")
        label.textColor = .systemRed
        label.font = .preferredFont(forTextStyle: .headline)
        label.textAlignment = .center
        label.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
        ])
    }
}

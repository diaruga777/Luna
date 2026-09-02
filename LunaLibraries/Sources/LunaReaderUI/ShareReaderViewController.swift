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

        var readerMode: SavedItem.ReaderMode {
            switch self {
            case .reader: return .scroll
            case .rsvp: return .rsvp
            case .chunk: return .highlight
            }
        }

        init(readerMode: SavedItem.ReaderMode) {
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

    /// `fileprivate` for the unlock coordinator below, which settles the extracted
    /// article against the SAME page URL this screen was opened for.
    fileprivate let url: URL
    private let mode: Mode
    /// The surface's exit. Held strongly: the conformer is a small coordinator the
    /// composition root made for this presentation, and the Done item it ends up on
    /// has to outlive this screen (see `doneButton`).
    private let completionDelegate: any ShareReaderCompletionDelegate
    /// Persists the surface's last-used reader mode (the action extension's own
    /// `ActionReaderMode`, injected by the composition root — this article-kind
    /// module doesn't see the surface's preference store). Nil when the host
    /// surface keeps no mode preference (e.g. the UI-test harness). Passed straight
    /// through to the reader this screen builds, which is what emits the switches.
    private let modePreferenceDelegate: (any ReaderModePreferenceDelegate)?
    /// A pre-computed `Outcome` to present (the action extension already ran the
    /// shared `IngestPipeline`), or nil to run the pipeline itself on `viewDidLoad`.
    private let precomputedOutcome: Outcome?
    private let spinner = HorizonSpinnerView(side: 36)
    private let loadingStatus = EclipseBloomStatusLabel()
    private var articleLoadingStatus: ArticleLoadingStatusCycler?

    public init(
        url: URL, mode: Mode, outcome: Outcome? = nil,
        modePreferenceDelegate: (any ReaderModePreferenceDelegate)? = nil,
        completionDelegate: any ShareReaderCompletionDelegate
    ) {
        self.url = url
        self.mode = mode
        self.precomputedOutcome = outcome
        self.modePreferenceDelegate = modePreferenceDelegate
        self.completionDelegate = completionDelegate
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Prepared presentation (no intermediate loading screen)

    /// How long a surface holds its loading state waiting for the images whose
    /// size the page never declared. Bounded because an unreachable image CDN
    /// must not strand the sheet on a spinner; whatever landed by the deadline is
    /// still baked in. A `var` only so a test can prove the bound holds without
    /// spending eight seconds proving it; nothing in the app writes it.
    static var imagePreparationTimeout: TimeInterval = 8

    /// Replaces the blocking half of the image settling. Nil (production) runs
    /// the real bounded downloader; a test surface substitutes it so a fixture's
    /// `<img>` tags don't pull a unit test onto the network.
    static var settleImagesOverride: ((
        _ content: ArticleContent, _ itemID: UUID, _ url: URL, _ store: SavesStore
    ) async -> ArticleContent)?

    /// Builds the finished reader for an already-extracted article: persists the
    /// content, settles the image layout, and hands back a reader whose FIRST
    /// frame is final.
    ///
    /// The caller keeps its own loading UI up until this returns, which is the
    /// point: one prepared hand-off swaps straight to the finished reader,
    /// with no second spinner and no Done button that appears a beat early.
    public static func preparedReader(
        url: URL, mode: Mode, content: ArticleContent, store: SavesStore = .shared,
        modePreferenceDelegate: (any ReaderModePreferenceDelegate)?,
        completionDelegate: any ShareReaderCompletionDelegate
    ) async -> UIViewController {
        // Reuse the row the extension already appended (`add` is idempotent), so
        // the reader marks the same shared item opened/read.
        let item = store.add(urlString: url.absoluteString)
        let settled = await settledImageLayout(for: content, item: item, url: url, store: store)
        let saved = store.saveContent(settled, for: item)
        return makeReader(
            item: saved, content: settled, mode: mode,
            modePreferenceDelegate: modePreferenceDelegate,
            completionDelegate: completionDelegate)
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
        for content: ArticleContent, item: SavedItem, url: URL, store: SavesStore
    ) async -> ArticleContent {
        let local = ArticleImageDownloader.resolveLocalImages(content, store: store)
        let needsSettling = local.blocks.contains { block in
            block.kind == .image && block.imageFileName == nil
                && block.imageSize == nil
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
        item: SavedItem, content: ArticleContent, mode: Mode,
        modePreferenceDelegate: (any ReaderModePreferenceDelegate)?,
        completionDelegate: any ShareReaderCompletionDelegate
    ) -> ReaderViewController {
        // A lightweight share provider (friend-share via the App Group queue +
        // link share — no CloudKit in the extension) so the reader's own share
        // button works. The reader marks the (real, shared) item opened/read
        // via SavesStore.
        let reader = ReaderViewController(
            item: item, content: content, forceMode: mode.readerMode,
            shareProvider: ExtensionReaderShareProvider(),
            // The action extension keeps its OWN last-used mode, separate from
            // the main app — persist switches locally (via the injected
            // delegate), don't touch the shared ReaderSettings.
            persistsModePreference: false,
            modePreferenceDelegate: modePreferenceDelegate)
        reader.navigationItem.leftBarButtonItem = doneButton(completionDelegate)
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
    private static func doneButton(
        _ delegate: any ShareReaderCompletionDelegate
    ) -> UIBarButtonItem {
        UIBarButtonItem(
            systemItem: .done,
            primaryAction: UIAction { _ in delegate.shareReaderDidFinish() })
    }

    /// This screen's own exit: the shared floating glass button, bottom-right.
    private lazy var exitButton = ExtensionExitButton.make {
        [weak self] in self?.completionDelegate.shareReaderDidFinish()
    }

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
        let item = SavesStore.shared.add(urlString: url.absoluteString)

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
                for: content, item: item, url: url, store: SavesStore.shared)
            let saved = SavesStore.shared.saveContent(settled, for: item)
            presentReader(item: saved, content: settled, in: navigationController)
        case let .product(product, _):
            // A product page: save it as a price tracker silently (the reader can't
            // present the main-app price UI) and confirm — never paywall-treated.
            SavesStore.shared.savePriceTracker(
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
        case .failed, .unsupported, .locked:
            // Neither .unsupported nor .locked can genuinely occur here: the
            // driver gates and discards before presenting a reader, and this
            // Reader-side screen never runs a plugin stage. Treat both as a
            // failure.
            presentFailure()
        }
    }

    /// Loads the article's archive.today snapshot in a web view so the user can
    /// solve any CAPTCHA inline. Marks the item `.needsCaptcha` first, so that if
    /// the user exits before solving it stays unlockable from the main app; once
    /// the snapshot loads, the web reader extracts the article and flips it to
    /// `.ready`.
    private func presentArchiveReader(for item: SavedItem, fallbackTitle: String) {
        articleLoadingStatus?.stop()
        spinner.stopAnimating()
        SavesStore.shared.markNeedsCaptcha(item.id, title: fallbackTitle)
        // The archive reader keeps its Done (and "open in Safari") in the bar this
        // screen hid — put it back before handing the stack over.
        navigationController?.setNavigationBarHidden(false, animated: false)
        let archive = ArchiveWebReaderViewController(articleURL: url, itemID: item.id)
        // Once the CAPTCHA is solved and the snapshot's article is extracted, swap
        // the web view out for the native reader showing the captured content —
        // the user reads in-app, not the raw archive page.
        archive.delegate = InSheetUnlockLegs(
            screen: self, itemID: item.id, completionDelegate: completionDelegate)
        navigationController?.setViewControllers([archive], animated: false)
    }

    /// `fileprivate` for the unlock coordinator below, which is what re-enters this
    /// screen once the archive CAPTCHA is solved. Takes the nav controller to swap
    /// into explicitly: by the time the archive unlock fires, this screen was
    /// already replaced on the stack by the archive reader, so `self
    /// .navigationController` is nil — the caller passes the archive reader's own.
    fileprivate func presentReader(
        item: SavedItem, content: ArticleContent, in navigationController: UINavigationController?
    ) {
        articleLoadingStatus?.stop()
        spinner.stopAnimating()
        let reader = Self.makeReader(
            item: item, content: content, mode: mode,
            modePreferenceDelegate: modePreferenceDelegate,
            completionDelegate: completionDelegate)
        // Replace the archive screen with the reader as the sole VC (no back).
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

/// The in-sheet archive unlock's two legs, kept together for the life of the card.
///
/// A small coordinator rather than the screen itself, and for a reason the closures
/// it replaces had built in: handing the archive reader the nav stack REMOVES this
/// screen from it (`setViewControllers([archive])`), so nothing else retains the
/// screen past that moment. Held STRONGLY here instead, so its stored state (`url`,
/// `mode`, `modePreferenceDelegate`) survives to build the reader — the swap itself
/// then targets the archive reader's own `navigationController`, since the screen's
/// was cleared the moment it left the stack.
///
/// It declares no Safari escape and takes the protocol's `false`: an extension has no
/// `UIApplication` to leave Luna with.
@MainActor
private final class InSheetUnlockLegs: ArchiveUnlockDelegate {
    private let screen: ShareReaderViewController
    private let itemID: UUID
    private let completionDelegate: any ShareReaderCompletionDelegate

    init(
        screen: ShareReaderViewController, itemID: UUID,
        completionDelegate: any ShareReaderCompletionDelegate
    ) {
        self.screen = screen
        self.itemID = itemID
        self.completionDelegate = completionDelegate
    }

    func archiveReaderDidUnlockArticle(_ reader: ArchiveWebReaderViewController) {
        guard let fresh = SavesStore.shared.item(withID: itemID),
              let content = SavesStore.shared.content(for: fresh) else { return }
        Task { @MainActor in
            let settled = await ShareReaderViewController.settledImageLayout(
                for: content, item: fresh, url: screen.url, store: SavesStore.shared)
            let saved = SavesStore.shared.saveContent(settled, for: fresh)
            screen.presentReader(item: saved, content: settled, in: reader.navigationController)
        }
    }

    func archiveReaderDidClose(_ reader: ArchiveWebReaderViewController) {
        completionDelegate.shareReaderDidFinish()
    }
}

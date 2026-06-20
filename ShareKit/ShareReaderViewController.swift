//
//  ShareReaderViewController.swift
//  ClipShare
//

import UIKit

/// Presents the shared article in the EXACT same reader as the main app
/// (`ReaderViewController` from the shared ReaderKit), scoped to that one
/// article. It fetches + extracts the page, then shows the chosen mode with no
/// share affordance and no eye tracking (nil providers). Inline link tapping,
/// mode switching, and audio all work; Done exits the extension.
final class ShareReaderViewController: UIViewController {

    enum Mode: String {
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
            }
        }
    }

    private let url: URL
    private let mode: Mode
    private let onDone: () -> Void
    private let spinner = UIActivityIndicatorView(style: .large)

    init(url: URL, mode: Mode, onDone: @escaping () -> Void) {
        self.url = url
        self.mode = mode
        self.onDone = onDone
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        spinner.startAnimating()
        navigationItem.leftBarButtonItem = doneButton()

        Task { await ingestAndPresent() }
    }

    /// A Done item whose action lives in the closure (retained by the bar item),
    /// so it still works after this VC is removed from the nav stack.
    private func doneButton() -> UIBarButtonItem {
        let onDone = self.onDone
        return UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { _ in onDone() })
    }

    private func ingestAndPresent() async {
        // Save immediately (shared storage) so the article is captured even if
        // the user exits mid-read; reuse the item the extension just appended.
        let item = ReadingListStore.shared.add(urlString: url.absoluteString)

        // The SAME shared decision routine the main app + share extension use: it
        // runs product detection AND the bypass gate, which the action-extension
        // reader previously SKIPPED entirely (calling ArticleResolver.resolve
        // directly) — the divergence this unification removes.
        switch await ArticleIngestDecider.decide(url: url) {
        case .article(let content, _):
            // Persist the parsed content so the main app has it too.
            let saved = ReadingListStore.shared.saveContent(content, for: item)
            presentReader(item: saved, content: content)
        case let .priceTracker(product, _):
            // A product page: save it as a price tracker silently (the reader can't
            // present the main-app price UI) and confirm, exactly as the share
            // extension does — never paywall-treated, never a failure screen.
            let tracker = PriceTracker(
                productName: product.name, firstStoreURL: url.absoluteString,
                price: product.priceAmount, currency: product.priceCurrency,
                brand: product.brand, productID: product.productID)
            ReadingListStore.shared.savePriceTracker(tracker, for: item.id)
            presentSavedConfirmation(productName: product.name)
        case .needsArchive(let title):
            // A genuine paywall (WSJ/FT/…): resolve its archive.today CAPTCHA right
            // here in the extension's own UI — the user never types the URL (it's
            // pre-filled), at most they solve a CAPTCHA.
            presentArchiveReader(for: item, fallbackTitle: title)
        case .failed:
            presentFailure()
        }
    }

    /// Loads the article's archive.today snapshot in a web view so the user can
    /// solve any CAPTCHA inline. Marks the item `.needsCaptcha` first, so that if
    /// the user exits before solving it stays unlockable from the main app; once
    /// the snapshot loads, the web reader extracts the article and flips it to
    /// `.ready`.
    private func presentArchiveReader(for item: ReadingListItem, fallbackTitle: String) {
        spinner.stopAnimating()
        ReadingListStore.shared.markNeedsCaptcha(item.id, title: fallbackTitle)
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
            self.presentReader(item: fresh, content: content)
        }
        navigationController?.setViewControllers([archive], animated: false)
    }

    private func presentReader(item: ReadingListItem, content: ArticleContent) {
        spinner.stopAnimating()
        // A lightweight share provider (friend-share via the App Group queue +
        // link share — no CloudKit in the extension) so the end-of-article share
        // affordance works; still no eye tracking (nil gaze factory). The reader
        // marks the (real, shared) item opened/read via ReadingListStore.
        let reader = ReaderViewController(
            item: item, content: content, forceMode: mode.readerMode,
            shareProvider: ExtensionReaderShareProvider(), gazeTrackerFactory: nil,
            // The action extension keeps its OWN last-used mode, separate from
            // the main app — persist switches locally, don't touch the shared
            // ReaderSettings.
            persistsModePreference: false,
            onModeChange: { ActionReaderMode.last = ShareReaderViewController.Mode(readerMode: $0) })
        reader.navigationItem.leftBarButtonItem = doneButton()
        // Replace this loading screen with the reader as the sole VC (no back).
        navigationController?.setViewControllers([reader], animated: false)
    }

    /// A saved-confirmation state for a product page captured as a price tracker:
    /// a checkmark + the product name. The user edits the tracker in the main app.
    private func presentSavedConfirmation(productName: String) {
        spinner.stopAnimating()

        let icon = UIImageView(image: UIImage(
            systemName: "checkmark.circle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 44, weight: .semibold)))
        icon.tintColor = GlassStyle.readingAccent
        icon.contentMode = .center

        let label = UILabel()
        label.text = "Tracking price for \(productName)"
        label.textColor = .label
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
        spinner.stopAnimating()

        let icon = UIImageView(image: UIImage(
            systemName: "exclamationmark.triangle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 40, weight: .semibold)))
        icon.tintColor = .systemRed
        icon.contentMode = .center

        let label = UILabel()
        label.text = "Couldn't load this article."
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

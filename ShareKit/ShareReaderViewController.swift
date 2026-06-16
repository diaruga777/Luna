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
        do {
            let html = try await ArticleFetcher().fetchHTML(from: url)
            let content = try ArticleExtractor().extract(html: html, baseURL: url)
            // Persist the parsed content so the main app has it too.
            let saved = ReadingListStore.shared.saveContent(content, for: item)
            presentReader(item: saved, content: content)
        } catch {
            presentFailure()
        }
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

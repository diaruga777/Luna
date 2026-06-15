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

        // A Done button visible during loading too.
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(doneTapped))

        Task { await ingestAndPresent() }
    }

    @objc private func doneTapped() { onDone() }

    private func ingestAndPresent() async {
        do {
            let html = try await ArticleFetcher().fetchHTML(from: url)
            let content = try ArticleExtractor().extract(html: html, baseURL: url)
            presentReader(content: content)
        } catch {
            presentFailure()
        }
    }

    private func presentReader(content: ArticleContent) {
        spinner.stopAnimating()
        let item = ReadingListItem(urlString: url.absoluteString)
        // nil providers: no share button/footer, no eye tracking — the rest of
        // the reader (modes, audio, inline link viewer) is the real thing.
        let reader = ReaderViewController(
            item: item, content: content, forceMode: mode.readerMode,
            shareProvider: nil, gazeTrackerFactory: nil)
        reader.navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(doneTapped))
        // Replace this loading screen with the reader as the sole VC (no back).
        navigationController?.setViewControllers([reader], animated: false)
    }

    private func presentFailure() {
        spinner.stopAnimating()
        let label = UILabel()
        label.text = "Couldn't load this article."
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }
}

//
//  ClipReaderViewController.swift
//  LunaReaderClip
//

import LunaDesignSystem
import LunaIngest
import LunaModels
import LunaReaderUI
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
    private let spinner = DotMatrixSpinnerView(side: 36)
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private var lastSourceURL: URL?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Luna"
        view.backgroundColor = .systemBackground
        configureLayout()
        render()
    }

    deinit {
        task?.cancel()
    }

    func handleLaunchURL(_ launchURL: URL) {
        guard let sourceURL = LunaAppClipInvocationURL.sourceURL(from: launchURL) else {
            update(.failed("This Luna link is missing a readable URL."))
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
        switch result.outcome {
        case let .article(content, _):
            var item = ReadingListItem(urlString: result.url.absoluteString)
            item.title = content.title
            item.state = .ready
            item.wordCount = content.wholeText.split(whereSeparator: \.isWhitespace).count

            let reader = ReaderViewController(
                item: item,
                content: content,
                forceMode: .scroll,
                shareProvider: nil,
                persistsModePreference: false,
                marksOpenedOnLoad: false)
            navigationController?.setViewControllers([reader], animated: false)

        case .needsArchive(_):
            update(.failed("This article needs an archive unlock. Open it in Luna Reader to finish loading it."))

        case .product(_, _), .video(_, _), .social(_, _), .document:
            update(.failed("This Luna link is not a readable article."))

        case .failed:
            update(.failed("Couldn't load this article."))
        }
    }

    private func configureLayout() {
        titleLabel.font = .preferredFont(forTextStyle: .largeTitle)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0

        detailLabel.font = .preferredFont(forTextStyle: .body)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = .secondaryLabel
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
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
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
            titleLabel.text = "Ready to read"
            detailLabel.text = "Open a Luna reader link to start."
            retryButton.isHidden = true

        case let .loading(url):
            spinner.startAnimating()
            titleLabel.text = "Loading"
            detailLabel.text = url.host ?? url.absoluteString
            retryButton.isHidden = true

        case let .failed(message):
            spinner.stopAnimating()
            titleLabel.text = "Couldn't open"
            detailLabel.text = message
            retryButton.configuration?.title = "Try Again"
            retryButton.isHidden = lastSourceURL == nil
        }
    }

    @objc private func retryTapped() {
        guard let lastSourceURL else { return }
        load(lastSourceURL)
    }
}

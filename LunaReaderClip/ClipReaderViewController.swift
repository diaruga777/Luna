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
        guard let sourceURL = LunaAppClipInvocationURL.sourceURL(from: launchURL) else {
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
            update(.failed(L10n.string("AppClip_reader_needsArchiveUnlockMessage")))

        case .product(_, _), .video(_, _), .social(_, _), .document, .unsupported:
            update(.failed(L10n.string("AppClip_reader_notReadableArticleMessage")))

        case .failed:
            update(.failed(L10n.string("Common_couldntLoadThisArticle")))
        }
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

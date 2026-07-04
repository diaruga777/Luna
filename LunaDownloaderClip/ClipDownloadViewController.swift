//
//  ClipDownloadViewController.swift
//  LunaDownloaderClip
//

import LunaMediaDownload
import UIKit

@MainActor
final class ClipDownloadViewController: UIViewController {
    private enum State {
        case waiting
        case downloading(URL)
        case ready(DownloadedMedia)
        case failed(String)
    }

    private let service: MediaDownloading = MediaDownloadService()
    private var state: State = .waiting
    private var task: Task<Void, Never>?
    private var pendingShare = false

    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let actionButton = UIButton(type: .system)
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
        if case let .ready(media) = state {
            try? FileManager.default.removeItem(at: media.fileURL)
        }
    }

    func handleLaunchURL(_ launchURL: URL) {
        guard let sourceURL = ClipLaunchURL.sourceURL(from: launchURL) else {
            update(.failed("This Luna link is missing a downloadable URL."))
            return
        }
        startDownload(sourceURL)
    }

    private func startDownload(_ sourceURL: URL) {
        task?.cancel()
        lastSourceURL = sourceURL
        progressView.progress = 0
        update(.downloading(sourceURL))

        task = Task { [service] in
            do {
                let media = try await service.downloadFirstMediaToFile(from: sourceURL) { [weak self] progress in
                    Task { @MainActor in
                        self?.progressView.setProgress(Float(progress), animated: true)
                    }
                }
                guard !Task.isCancelled else { return }
                update(.ready(media))
                presentShareSheetWhenPossible()
            } catch {
                guard !Task.isCancelled else { return }
                update(.failed(message(for: error)))
            }
        }
    }

    private func update(_ state: State) {
        self.state = state
        render()
    }

    private func configureLayout() {
        titleLabel.font = .preferredFont(forTextStyle: .largeTitle)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0

        detailLabel.font = .preferredFont(forTextStyle: .body)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = .secondaryLabel
        detailLabel.numberOfLines = 0

        progressView.observedProgress = nil

        var actionConfiguration = UIButton.Configuration.filled()
        actionConfiguration.image = UIImage(systemName: "square.and.arrow.up")
        actionConfiguration.imagePadding = 8
        actionButton.configuration = actionConfiguration
        actionButton.addTarget(self, action: #selector(shareTapped), for: .touchUpInside)

        var retryConfiguration = UIButton.Configuration.gray()
        retryConfiguration.image = UIImage(systemName: "arrow.clockwise")
        retryConfiguration.imagePadding = 8
        retryButton.configuration = retryConfiguration
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [
            titleLabel,
            detailLabel,
            progressView,
            actionButton,
            retryButton,
        ])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            actionButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 50),
            retryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    private func render() {
        switch state {
        case .waiting:
            titleLabel.text = "Ready to download"
            detailLabel.text = "Open a Luna download link to start."
            progressView.isHidden = true
            actionButton.isHidden = true
            retryButton.isHidden = true
        case let .downloading(url):
            titleLabel.text = "Downloading"
            detailLabel.text = url.host ?? url.absoluteString
            progressView.isHidden = false
            actionButton.isHidden = true
            retryButton.isHidden = true
        case .ready:
            titleLabel.text = "Download complete"
            detailLabel.text = "Choose where to save or send it."
            progressView.isHidden = true
            actionButton.isHidden = false
            retryButton.isHidden = true
            actionButton.configuration?.title = "Share"
        case let .failed(message):
            titleLabel.text = "Couldn't download"
            detailLabel.text = message
            progressView.isHidden = true
            actionButton.isHidden = true
            retryButton.isHidden = lastSourceURL == nil
            retryButton.configuration?.title = "Try Again"
        }
    }

    private func presentShareSheetWhenPossible() {
        guard view.window != nil else {
            pendingShare = true
            return
        }
        presentShareSheet()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if pendingShare {
            pendingShare = false
            presentShareSheet()
        }
    }

    @objc private func shareTapped() {
        presentShareSheet()
    }

    @objc private func retryTapped() {
        guard let lastSourceURL else { return }
        startDownload(lastSourceURL)
    }

    private func presentShareSheet() {
        guard case let .ready(media) = state, presentedViewController == nil else { return }
        let activity = UIActivityViewController(activityItems: [media.fileURL], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = actionButton
        activity.popoverPresentationController?.sourceRect = actionButton.bounds
        present(activity, animated: true)
    }

    private func message(for error: Error) -> String {
        if let mediaError = error as? MediaDownloadError {
            switch mediaError {
            case .permissionDenied, .saveFailed:
                return "The media downloaded, but iOS could not open the save sheet."
            default:
                return mediaError.message
            }
        }
        return "Check the link and try again."
    }
}

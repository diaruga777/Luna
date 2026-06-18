//
//  SavedNonTextualViewController.swift
//  ClipShare
//

import UIKit
import WebKit

/// Shown by the action extension for non-textual content (a video, post, etc.):
/// the URL is already saved, so this confirms the save and — for shareable links,
/// when there are friends — shows a scrolling friend list; tapping a friend QUEUES
/// the send to the App Group (the app delivers it on next launch). The confirmation
/// content sits near the top to leave room for the friend list. No eBook / system
/// share. YouTube embeds play inline. Done dismisses the extension.
final class SavedNonTextualViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    private let articleURLString: String
    private let content: NonTextualContent
    private let onDone: () -> Void
    private var webView: WKWebView?

    private let friends = ExtensionFriendsReader.friends()
    private let friendsTable = UITableView(frame: .zero, style: .plain)
    private let savedLabel = UILabel()

    // A fixed-height static preview of the media that would be saved (the poster for
    // a video). Space is reserved from load and a spinner shows while it's fetched,
    // so the layout never shifts as the media state resolves.
    private let previewContainer = UIView()
    private let previewImageView = UIImageView()
    private let previewSpinner = UIActivityIndicatorView(style: .medium)
    private static let previewHeight: CGFloat = 200

    // "Download media to photo roll" affordance (X / Instagram / TikTok only): a
    // button that becomes a progress bar while downloading, then a checkmark. Hidden
    // (but holding its space) until the preview confirms downloadable media exists.
    private let downloadButton = UIButton(type: .system)
    private let downloadProgress = UIProgressView(progressViewStyle: .default)
    private let downloadStatus = UILabel()

    init(articleURLString: String, content: NonTextualContent, onDone: @escaping () -> Void) {
        self.articleURLString = articleURLString
        self.content = content
        self.onDone = onDone
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { webView?.stopLoading() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "Saved to Queue"

        let onDone = self.onDone
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { _ in onDone() })

        let badge = UIImageView(image: UIImage(
            systemName: "checkmark.circle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 44, weight: .semibold)))
        badge.tintColor = GlassStyle.readingAccent
        badge.contentMode = .center

        savedLabel.text = "Saved to your reading list."
        savedLabel.font = .preferredFont(forTextStyle: .body)
        savedLabel.textColor = .secondaryLabel
        savedLabel.textAlignment = .center
        savedLabel.numberOfLines = 0

        // YouTube embeds play inline; other platforms show the confirmation badge.
        let topView: UIView
        if let embedURL = content.embedURL {
            let configuration = WKWebViewConfiguration()
            configuration.allowsInlineMediaPlayback = true
            configuration.allowsPictureInPictureMediaPlayback = true
            configuration.mediaTypesRequiringUserActionForPlayback = []
            let webView = WKWebView(frame: .zero, configuration: configuration)
            webView.isOpaque = false
            webView.backgroundColor = .black
            webView.scrollView.isScrollEnabled = false
            webView.layer.cornerRadius = 12
            webView.clipsToBounds = true
            webView.heightAnchor.constraint(equalTo: webView.widthAnchor, multiplier: 9.0 / 16.0).isActive = true
            self.webView = webView
            topView = webView
            var request = URLRequest(url: embedURL)
            request.setValue(content.embedReferer, forHTTPHeaderField: "Referer")
            webView.load(request)
        } else {
            topView = badge
        }

        // Confirmation + download controls sit at the TOP.
        let topStack = UIStackView(arrangedSubviews: [topView, savedLabel] + mediaDownloadViews())
        topStack.axis = .vertical
        topStack.spacing = 16
        topStack.setCustomSpacing(24, after: savedLabel)
        topStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topStack)
        NSLayoutConstraint.activate([
            topStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            topStack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            topStack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
        ])

        loadMediaPreview()

        // A scrolling friend list fills the rest — tapping one shares instantly.
        guard articleURLString.hasPrefix("http"), !friends.isEmpty else { return }
        let friendsHeader = UILabel()
        friendsHeader.text = "Send to a Friend"
        friendsHeader.font = .systemFont(ofSize: 15, weight: .semibold)
        friendsHeader.textColor = .secondaryLabel
        friendsHeader.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(friendsHeader)

        friendsTable.dataSource = self
        friendsTable.delegate = self
        friendsTable.rowHeight = 52
        friendsTable.register(UITableViewCell.self, forCellReuseIdentifier: "friend")
        friendsTable.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(friendsTable)

        NSLayoutConstraint.activate([
            friendsHeader.topAnchor.constraint(equalTo: topStack.bottomAnchor, constant: 28),
            friendsHeader.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            friendsHeader.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            friendsTable.topAnchor.constraint(equalTo: friendsHeader.bottomAnchor, constant: 6),
            friendsTable.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            friendsTable.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            friendsTable.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// The media preview + the "Download media to photo roll" button + (hidden)
    /// progress bar/status, shown only for platforms whose posts expose downloadable
    /// media. The preview reserves fixed space and the button starts invisible (but
    /// space-holding), so neither the elements above nor the friend list below move
    /// as the media state resolves.
    private func mediaDownloadViews() -> [UIView] {
        guard MediaDownloadablePlatform.supports(articleURLString) else { return [] }

        previewContainer.translatesAutoresizingMaskIntoConstraints = false
        // Fill the fixed-height well (cropping) rather than aspect-fit — a tall
        // poster aspect-fit into this wide box renders as a thin centered strip with
        // big blank margins, which reads as "no preview".
        previewImageView.contentMode = .scaleAspectFill
        previewImageView.clipsToBounds = true
        previewImageView.backgroundColor = .secondarySystemBackground
        previewImageView.layer.cornerRadius = 12
        previewImageView.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(previewImageView)
        previewSpinner.hidesWhenStopped = true
        previewSpinner.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(previewSpinner)
        NSLayoutConstraint.activate([
            previewContainer.heightAnchor.constraint(equalToConstant: Self.previewHeight),
            previewImageView.topAnchor.constraint(equalTo: previewContainer.topAnchor),
            previewImageView.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),
            previewImageView.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
            previewImageView.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
            previewSpinner.centerXAnchor.constraint(equalTo: previewContainer.centerXAnchor),
            previewSpinner.centerYAnchor.constraint(equalTo: previewContainer.centerYAnchor),
        ])
        previewSpinner.startAnimating()

        var config = UIButton.Configuration.filled()
        config.title = "Download media to photo roll"
        config.image = UIImage(systemName: "photo.badge.arrow.down")
        config.imagePadding = 8
        config.baseBackgroundColor = GlassStyle.readingAccent
        downloadButton.configuration = config
        downloadButton.addAction(UIAction { [weak self] _ in self?.startMediaDownload() }, for: .touchUpInside)
        // Invisible but holding its layout space until the preview confirms media.
        downloadButton.alpha = 0
        downloadButton.isUserInteractionEnabled = false

        downloadProgress.isHidden = true
        downloadProgress.progressTintColor = GlassStyle.readingAccent

        downloadStatus.isHidden = true
        downloadStatus.font = .preferredFont(forTextStyle: .subheadline)
        downloadStatus.textColor = .secondaryLabel
        downloadStatus.textAlignment = .center
        downloadStatus.numberOfLines = 0

        return [previewContainer, downloadButton, downloadProgress, downloadStatus]
    }

    /// Fetches the static media preview off-main; reveals the download button only
    /// once media is confirmed to exist. Always stops the spinner when done.
    private func loadMediaPreview() {
        guard MediaDownloadablePlatform.supports(articleURLString),
              let url = URL(string: articleURLString) else { return }
        let maxPixelSize = max(Self.previewHeight * 3, 600)
        Task { [weak self] in
            let result = await MediaPreviewFetcher.fetchPreview(for: url, maxPixelSize: maxPixelSize)
            await MainActor.run { self?.applyMediaPreview(result) }
        }
    }

    @MainActor
    private func applyMediaPreview(_ result: MediaPreviewFetcher.Result) {
        previewSpinner.stopAnimating()
        switch result {
        case .noMedia:
            // No download to offer; the reserved space simply stays empty.
            break
        case .media(let image):
            previewImageView.image = image
            downloadButton.alpha = 1
            downloadButton.isUserInteractionEnabled = true
        }
    }

    private func startMediaDownload() {
        guard let url = URL(string: articleURLString) else { return }
        downloadButton.isHidden = true
        downloadProgress.progress = 0
        downloadProgress.isHidden = false
        downloadStatus.text = "Downloading…"
        downloadStatus.textColor = .secondaryLabel
        downloadStatus.isHidden = false

        Task { [weak self] in
            do {
                _ = try await MediaDownloadService().downloadFirstMediaToPhotos(from: url) { progress in
                    Task { @MainActor in self?.downloadProgress.setProgress(Float(progress), animated: true) }
                }
                await MainActor.run { self?.finishMediaDownload(message: "Saved to Photos", success: true) }
            } catch {
                let message = (error as? MediaDownloadError)?.message ?? "Couldn't save the media."
                await MainActor.run { self?.finishMediaDownload(message: message, success: false) }
            }
        }
    }

    /// On success show a checkmark + message (user exits via Done); on failure show
    /// the error and re-enable the button to retry.
    private func finishMediaDownload(message: String, success: Bool) {
        downloadProgress.isHidden = true
        downloadStatus.text = message
        downloadStatus.isHidden = false
        if success {
            var config = downloadButton.configuration
            config?.title = "Saved to Photos"
            config?.image = UIImage(systemName: "checkmark.circle.fill")
            config?.baseBackgroundColor = .systemGreen
            downloadButton.configuration = config
            downloadButton.isEnabled = false
            downloadButton.isHidden = false
            downloadStatus.textColor = .secondaryLabel
        } else {
            downloadStatus.textColor = .systemRed
            downloadButton.isHidden = false
        }
    }

    // MARK: - Friend list

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        friends.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "friend", for: indexPath)
        var config = cell.defaultContentConfiguration()
        config.text = friends[indexPath.row].username
        config.image = UIImage(systemName: "person.crop.circle.fill")
        config.imageProperties.tintColor = GlassStyle.readingAccent
        cell.contentConfiguration = config
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    /// Tapping a friend queues the send instantly, confirms briefly, then dismisses.
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let friend = friends[indexPath.row]
        PendingFriendShareWriter.enqueue(friendUUID: friend.uuid, urlString: articleURLString)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        savedLabel.text = "Will send to \(friend.username)."
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.onDone() }
    }
}

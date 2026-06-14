//
//  ReadingListViewController.swift
//  Clip
//

import UIKit

/// The home screen. Two sections: unread articles (unopened bright, opened
/// dimmed, intermingled chronologically) and finished articles below, with a
/// delete-all button. Tap to read; swipe to delete or jump into RSVP.
final class ReadingListViewController: UITableViewController {

    init() {
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// What the list shows: everything, only articles, or only videos.
    private enum ListFilter: Int, CaseIterable {
        case all
        case articles
        case videos

        var displayName: String {
            switch self {
            case .all: return "All"
            case .articles: return "Articles"
            case .videos: return "Videos"
            }
        }

        func includes(_ item: ReadingListItem) -> Bool {
            switch self {
            case .all: return true
            case .articles: return !item.isYouTubeVideo
            case .videos: return item.isYouTubeVideo
            }
        }
    }

    private static let filterDefaultsKey = "readingListFilter"

    private var filter: ListFilter {
        get {
            ListFilter(rawValue: UserDefaults.standard.integer(forKey: Self.filterDefaultsKey))
                ?? .all
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.filterDefaultsKey) }
    }

    private let store = ReadingListStore.shared
    private var unreadItems: [ReadingListItem] = []
    private var readItems: [ReadingListItem] = []

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Reading List"
        navigationController?.navigationBar.prefersLargeTitles = true

        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")

        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(
                barButtonSystemItem: .add, target: self, action: #selector(addTapped)),
            UIBarButtonItem(
                image: UIImage(systemName: "person.2"), style: .plain,
                target: self, action: #selector(friendsTapped)),
        ]
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "gearshape"), style: .plain,
            target: self, action: #selector(settingsTapped))

        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(pulledToRefresh), for: .valueChanged)

        let filterControl = UISegmentedControl(
            items: ListFilter.allCases.map(\.displayName))
        filterControl.selectedSegmentIndex = filter.rawValue
        filterControl.addTarget(self, action: #selector(filterChanged(_:)), for: .valueChanged)
        let header = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: 44))
        filterControl.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(filterControl)
        NSLayoutConstraint.activate([
            filterControl.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 20),
            filterControl.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -20),
            filterControl.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])
        tableView.tableHeaderView = header

        NotificationCenter.default.addObserver(
            self, selector: #selector(reload), name: .readingListChanged, object: nil)
        reload()
    }

    @objc private func reload() {
        let all = store.items().filter { filter.includes($0) }
        unreadItems = all.filter { $0.readState != .read }
        readItems = all.filter { $0.readState == .read }
        tableView.reloadData()
    }

    @objc private func filterChanged(_ control: UISegmentedControl) {
        filter = ListFilter(rawValue: control.selectedSegmentIndex) ?? .all
        reload()
    }

    @objc private func pulledToRefresh() {
        ReadingListIngestor.shared.ingestAllPending()
        ArticleSendCoordinator.shared.retryPendingSends()
        Task { await SocialMessageCenter.shared.processInbox() }
        reload()
        refreshControl?.endRefreshing()
    }

    @objc private func friendsTapped() {
        navigationController?.pushViewController(FriendsViewController(), animated: true)
    }

    // MARK: - Add

    @objc private func addTapped() {
        let alert = UIAlertController(
            title: "Save a Link", message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "https://…"
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.text = UIPasteboard.general.url?.absoluteString
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak alert] _ in
            guard var text = alert?.textFields?.first?.text?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
            else { return }
            if !text.hasPrefix("http") { text = "https://" + text }
            Task { await ReadingListIngestor.shared.handleSavePress(urlString: text) }
        })
        present(alert, animated: true)
    }

    @objc private func settingsTapped() {
        navigationController?.pushViewController(SettingsViewController(), animated: true)
    }

    @objc private func deleteAllReadTapped() {
        let alert = UIAlertController(
            title: "Delete \(readItems.count) read article\(readItems.count == 1 ? "" : "s")?",
            message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Delete All Read", style: .destructive) { [weak self] _ in
            self?.store.deleteAllRead()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    // MARK: - Table

    private func item(at indexPath: IndexPath) -> ReadingListItem {
        indexPath.section == 0 ? unreadItems[indexPath.row] : readItems[indexPath.row]
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? unreadItems.count : readItems.count
    }

    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        if section == 0 {
            guard !unreadItems.isEmpty else { return nil }
            let header = UIView()
            let label = UILabel()
            label.text = "Unread"
            label.font = .preferredFont(forTextStyle: .headline)
            label.textColor = .secondaryLabel
            label.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 20),
                label.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            ])
            return header
        }
        guard !readItems.isEmpty else { return nil }

        let header = UIView()
        let label = UILabel()
        label.text = "Read"
        label.font = .preferredFont(forTextStyle: .headline)
        label.textColor = .secondaryLabel

        let deleteButton = UIButton(type: .system)
        deleteButton.setTitle("Delete All", for: .normal)
        deleteButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        deleteButton.tintColor = .systemRed
        deleteButton.addTarget(self, action: #selector(deleteAllReadTapped), for: .touchUpInside)

        label.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(label)
        header.addSubview(deleteButton)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 20),
            label.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            deleteButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -20),
            deleteButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])
        return header
    }

    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        if section == 0 { return unreadItems.isEmpty ? 0 : 36 }
        return readItems.isEmpty ? 0 : 44
    }

    override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let item = item(at: indexPath)

        var config = cell.defaultContentConfiguration()
        config.text = item.title ?? item.urlString
        let host = item.url?.host ?? ""
        let stateSuffix: String
        switch item.state {
        case .pending: stateSuffix = " · downloading…"
        case .failed: stateSuffix = " · failed (pull to retry)"
        case .ready: stateSuffix = ""
        }
        let leadingLabel = item.channelName
            ?? (item.isDocument ? (item.documentType?.uppercased() ?? "Document") : host)
        var infoParts = [leadingLabel, dateFormatter.string(from: item.dateAdded)]
        if !item.isYouTubeVideo {
            if ReaderSettings.showReadingTime, let words = item.wordCount, words > 0 {
                infoParts.append("\(max(1, Int((Double(words) / 220.0).rounded(.up)))) min")
            }
            if ReaderSettings.showReadingProgress, item.readState != .read,
               let progress = item.readingProgress, progress > 0.01 {
                infoParts.append("\(Int(progress * 100))%")
            }
        }
        if let sharedBy = item.sharedByUsername {
            infoParts.append("from \(sharedBy)")
        }
        switch item.sendState {
        case .sent: infoParts.append("sent to Kindle")
        case .failed: infoParts.append("send failed")
        case .queued: infoParts.append("sending…")
        case nil: break
        }
        config.secondaryText = infoParts.joined(separator: " · ") + stateSuffix

        if item.isYouTubeVideo {
            config.image = videoThumbnail(for: item)
            config.imageProperties.maximumSize = CGSize(width: 96, height: 54)
            config.imageProperties.cornerRadius = 6
        }
        // Unopened articles pop; anything touched fades back (but stays legible).
        config.textProperties.color = item.readState == .unopened ? .label : .secondaryLabel
        config.secondaryTextProperties.color = item.readState == .unopened
            ? .secondaryLabel : .tertiaryLabel
        config.textProperties.numberOfLines = 2
        cell.contentConfiguration = config
        cell.accessoryType = item.state == .ready ? .disclosureIndicator : .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let item = item(at: indexPath)
        if item.isYouTubeVideo {
            openVideo(item)
            return
        }
        guard item.state == .ready, let content = store.content(for: item) else { return }
        let reader = ReaderViewController(item: item, content: content)
        navigationController?.pushViewController(reader, animated: true)
    }

    // MARK: - Video playback

    /// Prefers the YouTube app (marks read on successful handoff); otherwise
    /// the in-app player (marks read when playback finishes).
    private func openVideo(_ item: ReadingListItem) {
        guard let videoID = item.youtubeVideoID else { return }
        if let appURL = YouTubeURL.appURL(videoID: videoID),
           UIApplication.shared.canOpenURL(appURL) {
            UIApplication.shared.open(appURL) { [weak self] success in
                if success {
                    self?.store.markReadState(.read, for: item.id)
                }
            }
            return
        }
        present(YouTubePlayerViewController(videoID: videoID, itemID: item.id), animated: true)
    }

    /// Thumbnail with a play glyph composited on (cached file from ingest;
    /// falls back to a plain play tile).
    private func videoThumbnail(for item: ReadingListItem) -> UIImage {
        let size = CGSize(width: 96, height: 54)
        let baseImage: UIImage? = item.thumbnailFileName.flatMap {
            UIImage(contentsOfFile:
                store.articlesDirectory.appendingPathComponent($0).path)
        }
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            if let baseImage {
                // hqdefault is 4:3 with letterboxing; aspect-fill crops it to 16:9.
                let scale = max(size.width / baseImage.size.width,
                                size.height / baseImage.size.height)
                let drawSize = CGSize(width: baseImage.size.width * scale,
                                      height: baseImage.size.height * scale)
                baseImage.draw(in: CGRect(
                    x: (size.width - drawSize.width) / 2,
                    y: (size.height - drawSize.height) / 2,
                    width: drawSize.width, height: drawSize.height))
            }
            let glyphSize: CGFloat = 24
            let glyphRect = CGRect(
                x: (size.width - glyphSize) / 2, y: (size.height - glyphSize) / 2,
                width: glyphSize, height: glyphSize)
            UIImage(systemName: "play.circle.fill")?
                .withTintColor(.white.withAlphaComponent(0.92), renderingMode: .alwaysOriginal)
                .draw(in: glyphRect)
        }
    }

    override func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        let item = item(at: indexPath)
        let delete = UIContextualAction(style: .destructive, title: "Delete") {
            [weak self] _, _, done in
            self?.store.delete(item)
            done(true)
        }
        guard !item.isYouTubeVideo else {
            return UISwipeActionsConfiguration(actions: [delete])
        }
        let speedRead = UIContextualAction(style: .normal, title: "RSVP") {
            [weak self] _, _, done in
            guard let self, item.state == .ready,
                  let content = self.store.content(for: item) else { done(false); return }
            let reader = ReaderViewController(item: item, content: content, forceMode: .rsvp)
            self.navigationController?.pushViewController(reader, animated: true)
            done(true)
        }
        speedRead.backgroundColor = .systemIndigo
        return UISwipeActionsConfiguration(actions: [delete, speedRead])
    }

    // MARK: - Long-press send

    override func tableView(
        _ tableView: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        let item = item(at: indexPath)
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            let sendToFriend = UIAction(
                title: "Send to Friend…",
                image: UIImage(systemName: "person.2")
            ) { _ in
                guard let self else { return }
                let sourceView = self.tableView.cellForRow(at: indexPath) ?? self.view ?? UIView()
                SendToFriendSheet.present(
                    from: self, sourceView: sourceView,
                    urlString: item.urlString, title: item.title)
            }
            let sendToKindle = UIAction(
                title: "Send to Kindle",
                image: UIImage(systemName: "paperplane")
            ) { _ in
                self?.sendToKindle(item)
            }
            // Videos: friends only (no article to email). Documents: Kindle
            // only (no URL to share). Articles: both.
            var children: [UIAction] = []
            if item.canShareToFriends { children.append(sendToFriend) }
            if !item.isYouTubeVideo { children.append(sendToKindle) }
            return UIMenu(children: children)
        })
    }

    private func sendToKindle(_ item: ReadingListItem) {
        guard ArticleSendCoordinator.shared.isConfigured else {
            let alert = UIAlertController(
                title: "Set Up Send to Kindle",
                message: "Add your Kindle address and email account in Settings first.",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }
        Task { await ArticleSendCoordinator.shared.send(item) }
    }
}

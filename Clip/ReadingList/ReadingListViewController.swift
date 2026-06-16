//
//  ReadingListViewController.swift
//  Clip
//

import UIKit

/// The home screen. Items are grouped into sections in FIFO (oldest-saved
/// first) order:
/// - **From Pasteboard**: a one-tap suggestion for a readable URL on the
///   clipboard, shown above the list and only until tapped (not yet saved).
/// - **Reading**: unread items saved within the last week (always expanded).
/// - **Read**: finished items (collapsed by default).
/// - **Archive**: unread items older than a week by save date (collapsed by
///   default).
/// - **Couldn't Load**: items whose content failed to download/extract, in red,
///   at the very bottom (collapsed by default; pull to retry).
/// Collapsible headers expand/collapse on tap. Tap a row to read; press the drag
/// handle to reorder within Reading; long-press for the action menu.
final class ReadingListViewController: UITableViewController {

    init() {
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Items older than this (by save date) move to the Archive section.
    private static let archiveAge: TimeInterval = 7 * 24 * 60 * 60

    /// The list groups. Raw values are STABLE (persisted in `collapsedSections`),
    /// so new cases append at the end; display order is `displayOrder`, not the
    /// declaration order.
    private enum Section: Int, CaseIterable {
        case reading = 0
        case read = 1
        case archive = 2
        case error = 3
        case pasteboard = 4

        var title: String {
            switch self {
            case .reading: return "Reading"
            case .read: return "Read"
            case .archive: return "Archive"
            case .error: return "Couldn't Load"
            case .pasteboard: return "From Pasteboard"
            }
        }

        /// Reading and the pasteboard suggestion are always open; the rest collapse.
        var isCollapsible: Bool {
            switch self {
            case .reading, .pasteboard: return false
            case .read, .archive, .error: return true
            }
        }
    }

    /// Top-to-bottom display order: a pasteboard suggestion sits above the list,
    /// failed items in a collapsible section at the very bottom.
    private static let displayOrder: [Section] = [.pasteboard, .reading, .read, .archive, .error]

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
    private static let collapsedDefaultsKey = "readingListCollapsedSections"

    private var filter: ListFilter {
        get {
            ListFilter(rawValue: UserDefaults.standard.integer(forKey: Self.filterDefaultsKey))
                ?? .all
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.filterDefaultsKey) }
    }

    /// Persisted collapsed sections. Absent (first run) means Read and Archive
    /// start collapsed.
    private var collapsedSections: Set<Section> {
        get {
            guard let raw = UserDefaults.standard.array(forKey: Self.collapsedDefaultsKey) as? [Int]
            else { return [.read, .archive, .error] }
            return Set(raw.compactMap(Section.init(rawValue:)))
        }
        set {
            UserDefaults.standard.set(newValue.map(\.rawValue), forKey: Self.collapsedDefaultsKey)
        }
    }

    private let store = ReadingListStore.shared

    /// A readable URL found on the system pasteboard, shown as a one-tap "From
    /// Pasteboard" row until saved. nil when there's nothing to suggest.
    private var pasteboardCandidate: PasteboardCandidate?
    /// The pasteboard `changeCount` last evaluated, so we only read its contents
    /// (which shows the system paste banner) when it has actually changed.
    private var lastCheckedPasteboardChangeCount = -1

    /// The Articles/Videos filter — only shown when the list actually has both
    /// (a video and an article), otherwise it's pointless.
    private let filterControl = UISegmentedControl()
    private var filterHeaderView: UIView?

    /// Non-empty groups in display order; rebuilt on every `reload`.
    private var groups: [(section: Section, items: [ReadingListItem])] = []

    /// Set while persisting a manual reorder so the resulting
    /// `.readingListChanged` notification doesn't reload the table mid-drop
    /// (which mangles the layout).
    private var isApplyingReorder = false

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

        filterControl.removeAllSegments()
        for (index, option) in ListFilter.allCases.enumerated() {
            filterControl.insertSegment(withTitle: option.displayName, at: index, animated: false)
        }
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
        filterHeaderView = header

        // Permanent reorder mode: Reading rows show a drag handle you can press
        // and drag, while taps still open the article (selection-during-editing)
        // and there's no delete badge (editingStyle .none). Delete/RSVP live in
        // the long-press menu.
        tableView.allowsSelectionDuringEditing = true
        tableView.setEditing(true, animated: false)

        NotificationCenter.default.addObserver(
            self, selector: #selector(reload), name: .readingListChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(checkPasteboard),
            name: UIApplication.didBecomeActiveNotification, object: nil)
        reload()
        checkPasteboard()
    }

    // MARK: - Pasteboard suggestion

    /// If the pasteboard holds a new URL with extractable content, surface it as
    /// the top "From Pasteboard" row. Gated on `changeCount` so the system paste
    /// banner shows at most once per newly copied URL.
    @objc private func checkPasteboard() {
        let pasteboard = UIPasteboard.general
        guard pasteboard.changeCount != lastCheckedPasteboardChangeCount else { return }
        lastCheckedPasteboardChangeCount = pasteboard.changeCount

        guard pasteboard.hasURLs, let url = pasteboard.url else {
            // Pasteboard changed to something with no URL — drop any stale row.
            if pasteboardCandidate != nil { pasteboardCandidate = nil; reload() }
            return
        }
        Task { [weak self] in
            let candidate = await PasteboardSuggester.shared.evaluate(urlString: url.absoluteString)
            await MainActor.run {
                guard let self else { return }
                self.pasteboardCandidate = candidate
                self.reload()
            }
        }
    }

    /// Saves the pasteboard candidate and opens it. On return, the row is gone
    /// and the item sits in its normal section.
    private func openPasteboardCandidate() {
        guard let candidate = pasteboardCandidate else { return }
        pasteboardCandidate = nil
        reload() // drop the row immediately

        if candidate.isVideo {
            Task { [weak self] in
                await ReadingListIngestor.shared.handleSavePress(urlString: candidate.urlString)
                await MainActor.run {
                    guard let self, let item = self.store.item(forURLString: candidate.urlString)
                    else { return }
                    self.openVideo(item)
                }
            }
        } else if let content = candidate.content {
            Task { [weak self] in
                let item = await ReadingListIngestor.shared.saveNewWithContent(
                    urlString: candidate.urlString, content: content)
                await MainActor.run {
                    guard let self, let saved = self.store.content(for: item) else { return }
                    let reader = ReaderViewController(
                        item: item, content: saved,
                        shareProvider: AppReaderShareProvider.shared,
                        gazeTrackerFactory: AppGazeTracker.factory)
                    self.navigationController?.pushViewController(reader, animated: true)
                }
            }
        }
    }

    @objc private func reload() {
        // A reorder we just persisted fires this notification; ignore it so the
        // drop animation isn't interrupted by a full reloadData.
        if isApplyingReorder { return }

        updateFilterVisibility()
        let all = store.items().filter { filter.includes($0) }
        let now = Date()
        var reading: [ReadingListItem] = []
        var read: [ReadingListItem] = []
        var archive: [ReadingListItem] = []
        var failed: [ReadingListItem] = []
        for item in all {
            if item.state == .failed {
                failed.append(item)
            } else if item.readState == .read {
                read.append(item)
            } else if now.timeIntervalSince(item.dateAdded) > Self.archiveAge {
                archive.append(item)
            } else {
                reading.append(item)
            }
        }
        var bySection: [Section: [ReadingListItem]] =
            [.reading: reading, .read: read, .archive: archive, .error: failed]

        // The pasteboard suggestion, unless it's since been saved by some path.
        if let candidate = pasteboardCandidate {
            if store.item(forURLString: candidate.urlString) != nil {
                pasteboardCandidate = nil
            } else {
                bySection[.pasteboard] = [displayItem(for: candidate)]
            }
        }

        groups = Self.displayOrder.compactMap { section in
            let items = bySection[section] ?? []
            return items.isEmpty ? nil : (section, items)
        }
        tableView.reloadData()
    }

    /// A transient (unsaved) item used to render the pasteboard suggestion row.
    private func displayItem(for candidate: PasteboardCandidate) -> ReadingListItem {
        var item = ReadingListItem(urlString: candidate.urlString)
        item.title = candidate.title
        item.state = .ready
        item.youtubeVideoID = candidate.videoID
        item.channelName = candidate.channelName
        return item
    }

    @objc private func filterChanged(_ control: UISegmentedControl) {
        filter = ListFilter(rawValue: control.selectedSegmentIndex) ?? .all
        reload()
    }

    /// Shows the Articles/Videos filter only when the list has BOTH a video and
    /// an article; otherwise it's meaningless. Resets to "All" when hidden so a
    /// stale "Videos"/"Articles" selection can't leave the list empty.
    private func updateFilterVisibility() {
        let items = store.items()
        let hasVideo = items.contains { $0.isYouTubeVideo }
        let hasArticle = items.contains { !$0.isYouTubeVideo }
        let shouldShow = hasVideo && hasArticle
        if shouldShow {
            if tableView.tableHeaderView !== filterHeaderView {
                tableView.tableHeaderView = filterHeaderView
            }
        } else {
            if filter != .all {
                filter = .all
                filterControl.selectedSegmentIndex = ListFilter.all.rawValue
            }
            if tableView.tableHeaderView != nil { tableView.tableHeaderView = nil }
        }
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
        let readCount = groups.first { $0.section == .read }?.items.count ?? 0
        let alert = UIAlertController(
            title: "Delete \(readCount) read article\(readCount == 1 ? "" : "s")?",
            message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Delete All Read", style: .destructive) { [weak self] _ in
            self?.store.deleteAllRead()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    // MARK: - Section / collapse helpers

    private func section(at index: Int) -> Section { groups[index].section }

    private func isCollapsed(_ section: Section) -> Bool {
        section.isCollapsible && collapsedSections.contains(section)
    }

    @objc private func headerTapped(_ gesture: UITapGestureRecognizer) {
        guard let raw = gesture.view?.tag, let section = Section(rawValue: raw),
              section.isCollapsible,
              let index = groups.firstIndex(where: { $0.section == section })
        else { return }
        var collapsed = collapsedSections
        if collapsed.contains(section) { collapsed.remove(section) } else { collapsed.insert(section) }
        collapsedSections = collapsed
        tableView.reloadSections(IndexSet(integer: index), with: .automatic)
    }

    // MARK: - Table

    private func item(at indexPath: IndexPath) -> ReadingListItem {
        groups[indexPath.section].items[indexPath.row]
    }

    override func numberOfSections(in tableView: UITableView) -> Int { groups.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        let group = groups[section]
        return isCollapsed(group.section) ? 0 : group.items.count
    }

    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let group = groups[section]
        let kind = group.section

        let header = UIView()
        header.tag = kind.rawValue

        // The error section is tinted red to flag it; the rest are muted.
        let headerColor: UIColor = kind == .error ? .systemRed : .secondaryLabel

        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .headline)
        label.textColor = headerColor
        label.translatesAutoresizingMaskIntoConstraints = false

        if kind.isCollapsible {
            let collapsed = isCollapsed(kind)
            let chevron = collapsed ? "chevron.right" : "chevron.down"
            let glyph = NSTextAttachment()
            glyph.image = UIImage(systemName: chevron)?
                .withConfiguration(UIImage.SymbolConfiguration(textStyle: .caption1))
                .withTintColor(headerColor, renderingMode: .alwaysOriginal)
            let title = NSMutableAttributedString(attachment: glyph)
            title.append(NSAttributedString(string: "  \(kind.title) (\(group.items.count))"))
            label.attributedText = title

            let tap = UITapGestureRecognizer(target: self, action: #selector(headerTapped(_:)))
            header.addGestureRecognizer(tap)
        } else {
            label.text = kind.title
        }

        header.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 20),
            label.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])

        if kind == .read {
            let deleteButton = UIButton(type: .system)
            deleteButton.setTitle("Delete All", for: .normal)
            deleteButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
            deleteButton.tintColor = .systemRed
            deleteButton.addTarget(self, action: #selector(deleteAllReadTapped), for: .touchUpInside)
            deleteButton.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(deleteButton)
            NSLayoutConstraint.activate([
                deleteButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -20),
                deleteButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            ])
        }
        return header
    }

    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        44
    }

    override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let item = item(at: indexPath)

        var config = cell.defaultContentConfiguration()
        config.text = item.title ?? item.urlString
        config.secondaryAttributedText = secondaryText(for: item)
        config.textProperties.numberOfLines = 2

        if item.isYouTubeVideo {
            config.image = videoThumbnail(for: item)
            config.imageProperties.maximumSize = CGSize(width: 96, height: 54)
            config.imageProperties.cornerRadius = 6
        }
        if item.state == .failed {
            // Items in the "Couldn't Load" section read in red.
            config.textProperties.color = .systemRed
        } else {
            // Unopened articles pop; anything touched fades back (but stays legible).
            config.textProperties.color = item.readState == .unopened ? .label : .secondaryLabel
        }
        cell.contentConfiguration = config
        cell.accessoryType = item.state == .ready ? .disclosureIndicator : .none
        cell.showsReorderControl = true
        return cell
    }

    /// Builds the grey metadata line, with the "from <friend>" attribution in
    /// the accent color so social shares stand out.
    private func secondaryText(for item: ReadingListItem) -> NSAttributedString {
        let baseColor: UIColor = item.readState == .unopened ? .secondaryLabel : .tertiaryLabel
        let host = item.url?.host ?? ""
        let leadingLabel = item.channelName
            ?? (item.isDocument ? (item.documentType?.uppercased() ?? "Document") : host)
        var parts = [leadingLabel, dateFormatter.string(from: item.dateAdded)]
        if !item.isYouTubeVideo {
            if ReaderSettings.showReadingTime, let words = item.wordCount, words > 0 {
                parts.append("\(max(1, Int((Double(words) / 220.0).rounded(.up)))) min")
            }
            if ReaderSettings.showReadingProgress, item.readState != .read,
               let progress = item.readingProgress, progress > 0.01 {
                parts.append("\(Int(progress * 100))%")
            }
        }
        switch item.sendState {
        case .sent: parts.append("sent to Kindle")
        case .failed: parts.append("send failed")
        case .queued: parts.append("sending…")
        case nil: break
        }
        switch item.state {
        case .pending: parts.append("downloading…")
        case .failed: parts.append("pull to retry")
        case .ready: break
        }

        let result = NSMutableAttributedString(
            string: parts.joined(separator: " · "),
            attributes: [.foregroundColor: baseColor])
        if let sharedBy = item.sharedByUsername {
            if !result.string.isEmpty {
                result.append(NSAttributedString(
                    string: " · ", attributes: [.foregroundColor: baseColor]))
            }
            result.append(NSAttributedString(
                string: "from \(sharedBy)",
                attributes: [.foregroundColor: view.tintColor ?? .systemBlue]))
        }
        return result
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if section(at: indexPath.section) == .pasteboard {
            openPasteboardCandidate()
            return
        }
        let item = item(at: indexPath)
        if item.isYouTubeVideo {
            openVideo(item)
            return
        }
        guard item.state == .ready, let content = store.content(for: item) else { return }
        let reader = ReaderViewController(
            item: item, content: content,
            shareProvider: AppReaderShareProvider.shared,
            gazeTrackerFactory: AppGazeTracker.factory)
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

    // MARK: - Reordering (Reading section only)

    override func tableView(
        _ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath
    ) -> UITableViewCell.EditingStyle {
        .none // reorder handle only, no delete badge
    }

    override func tableView(
        _ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath
    ) -> Bool {
        false
    }

    override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        section(at: indexPath.section) == .reading
    }

    /// Keep drags within the Reading section.
    override func tableView(
        _ tableView: UITableView,
        targetIndexPathForMoveFromRowAt sourceIndexPath: IndexPath,
        toProposedIndexPath proposedDestinationIndexPath: IndexPath
    ) -> IndexPath {
        proposedDestinationIndexPath.section == sourceIndexPath.section
            ? proposedDestinationIndexPath
            : sourceIndexPath
    }

    override func tableView(
        _ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath
    ) {
        guard let groupIndex = groups.firstIndex(where: { $0.section == .reading }) else { return }
        var reading = groups[groupIndex].items
        let moved = reading.remove(at: sourceIndexPath.row)
        reading.insert(moved, at: destinationIndexPath.row)
        groups[groupIndex].items = reading

        // Persist the full order across all sections, preserving each section's
        // (now-updated) order. Suppress the reload this triggers so the drop
        // animation finishes cleanly.
        let fullOrder = groups.flatMap(\.items).map(\.id)
        isApplyingReorder = true
        store.setOrder(fullOrder)
        DispatchQueue.main.async { [weak self] in self?.isApplyingReorder = false }
    }

    // MARK: - Long-press menu

    override func tableView(
        _ tableView: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        // The pasteboard suggestion isn't saved yet — no row actions apply.
        guard section(at: indexPath.section) != .pasteboard else { return nil }
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
            let speedRead = UIAction(
                title: "Speed Read",
                image: UIImage(systemName: "bolt.fill")
            ) { _ in
                guard let self, item.state == .ready,
                      let content = self.store.content(for: item) else { return }
                self.navigationController?.pushViewController(
                    ReaderViewController(
                        item: item, content: content, forceMode: .rsvp,
                        shareProvider: AppReaderShareProvider.shared,
                        gazeTrackerFactory: AppGazeTracker.factory),
                    animated: true)
            }
            let delete = UIAction(
                title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive
            ) { _ in
                self?.store.delete(item)
            }
            // Videos: share to friends + delete. Documents: Kindle + read + delete.
            // Articles: everything. "Send to Kindle" only when Kindle is set up.
            var children: [UIAction] = []
            if item.canShareToFriends { children.append(sendToFriend) }
            if !item.isYouTubeVideo {
                if ArticleSendCoordinator.shared.isConfigured { children.append(sendToKindle) }
                children.append(speedRead)
            }
            children.append(delete)
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

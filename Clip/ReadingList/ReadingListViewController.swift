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

    /// What the list shows: everything, only articles (anything that opens in the
    /// text reader — articles, documents, emails), or only media & links (everything
    /// else — YouTube, platform posts, music/podcasts).
    private enum ListFilter: Int, CaseIterable {
        case all
        case articles
        case mediaAndLinks

        var displayName: String {
            switch self {
            case .all: return "All"
            case .articles: return "Articles"
            case .mediaAndLinks: return "Media & Links"
            }
        }

        func includes(_ item: ReadingListItem) -> Bool {
            switch self {
            case .all: return true
            case .articles: return ReadingListViewController.rendersAsReader(item)
            case .mediaAndLinks: return !ReadingListViewController.rendersAsReader(item)
            }
        }
    }

    /// Whether the item opens in the text reader (articles, documents, emails), as
    /// opposed to media & links (YouTube, platform posts, music/podcasts) which open
    /// in a player, embed, or browser. Mirrors the tap routing in `didSelectRowAt`.
    static func rendersAsReader(_ item: ReadingListItem) -> Bool {
        item.contentPlatform == nil && !item.isYouTubeVideo
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
    /// While set, the pasteboard URL whose preview is still being fetched — the
    /// row shows a spinner until the candidate (or nil) resolves.
    private var evaluatingPasteboardURL: String?
    /// The pasteboard `changeCount` last evaluated, so we only read its contents
    /// (which shows the system paste banner) when it has actually changed.
    private var lastCheckedPasteboardChangeCount = -1

    /// The Articles / Media & Links filter — only shown when the list actually has
    /// both a reader item and a media/link item, otherwise it's pointless.
    private let filterControl = UISegmentedControl()
    private var filterHeaderView: UIView?

    /// Non-blocking bottom pill for media-download progress/result (created lazily).
    private weak var mediaDownloadStatus: MediaDownloadStatusView?

    /// The "catch up" nav button; pulses + glows when there are many unread items.
    private let catchUpButton = UIButton(type: .system)
    private static let catchUpPulseThreshold = 12

    /// Non-empty groups in display order; rebuilt on every `reload`.
    private var groups: [(section: Section, items: [ReadingListItem])] = []

    /// Set while persisting a manual reorder so the resulting
    /// `.readingListChanged` notification doesn't reload the table mid-drop
    /// (which mangles the layout).
    private var isApplyingReorder = false
    /// True while an animated single-row delete runs, so the `.readingListChanged`
    /// notification doesn't full-reload mid-animation (which kills the fade).
    private var isAnimatingRowChange = false

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

        tableView.register(
            ReadingListItemCell.self, forCellReuseIdentifier: ReadingListItemCell.reuseID)

        catchUpButton.setImage(UIImage(systemName: "rectangle.stack"), for: .normal)
        catchUpButton.tintColor = GlassStyle.readingAccent
        catchUpButton.accessibilityLabel = "Catch up"
        catchUpButton.addTarget(self, action: #selector(catchUpTapped), for: .touchUpInside)
        catchUpButton.frame = CGRect(x: 0, y: 0, width: 34, height: 34)
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(
                barButtonSystemItem: .add, target: self, action: #selector(addTapped)),
            UIBarButtonItem(
                image: UIImage(systemName: "person.2"), style: .plain,
                target: self, action: #selector(friendsTapped)),
            UIBarButtonItem(customView: catchUpButton),
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
            if pasteboardCandidate != nil || evaluatingPasteboardURL != nil {
                pasteboardCandidate = nil
                evaluatingPasteboardURL = nil
                reload()
            }
            return
        }
        // Show a spinner row immediately, then fill it in once the preview
        // (content + thumbnail) resolves.
        let urlString = url.absoluteString
        guard store.item(forURLString: urlString) == nil else { return }
        pasteboardCandidate = nil
        evaluatingPasteboardURL = urlString
        reload()
        Task { [weak self] in
            let candidate = await PasteboardSuggester.shared.evaluate(urlString: urlString)
            await MainActor.run {
                guard let self, self.evaluatingPasteboardURL == urlString else { return }
                self.evaluatingPasteboardURL = nil
                self.pasteboardCandidate = candidate
                self.reload()
            }
        }
    }

    /// The trailing Save button: persists the candidate (it then moves into the
    /// Reading section) without opening it.
    private func savePasteboardCandidate() {
        guard let candidate = pasteboardCandidate else { return }
        pasteboardCandidate = nil
        evaluatingPasteboardURL = nil
        reload() // drop the pasteboard row; the saved item arrives via the notification
        if let content = candidate.content {
            Task {
                await ReadingListIngestor.shared.saveNewWithContent(
                    urlString: candidate.urlString, content: content, source: .paste)
            }
        } else {
            Task {
                await ReadingListIngestor.shared.handleSavePress(
                    urlString: candidate.urlString, source: .paste)
            }
        }
    }

    /// Tapping the row PREVIEWS the candidate without saving it (a transient item;
    /// the row stays until the user taps Save).
    private func previewPasteboardCandidate() {
        guard let candidate = pasteboardCandidate else { return }
        var transient = ReadingListItem(urlString: candidate.urlString)
        transient.title = candidate.title
        transient.youtubeVideoID = candidate.videoID
        transient.channelName = candidate.channelName
        transient.platform = candidate.platform
        transient.state = .ready

        if candidate.isVideo {
            openVideo(transient, from: self)
        } else if let platform = candidate.platform {
            openPlatformItem(transient, platform: platform, from: self)
        } else if let content = candidate.content {
            let reader = ReaderViewController(
                item: transient, content: content,
                shareProvider: AppReaderShareProvider.shared,
                gazeTrackerFactory: AppGazeTracker.factory)
            navigationController?.pushViewController(reader, animated: true)
        }
    }

    @objc private func reload() {
        // A reorder we just persisted fires this notification; ignore it so the
        // drop animation isn't interrupted by a full reloadData.
        if isApplyingReorder || isAnimatingRowChange { return }

        updateFilterVisibility()
        updateCatchUpButton()
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

        // The pasteboard suggestion: a spinner row while evaluating, then the
        // resolved candidate (unless it's since been saved by some path).
        if let candidate = pasteboardCandidate {
            if store.item(forURLString: candidate.urlString) != nil {
                pasteboardCandidate = nil
            } else {
                bySection[.pasteboard] = [displayItem(for: candidate)]
            }
        } else if let evaluatingURL = evaluatingPasteboardURL {
            var loading = ReadingListItem(urlString: evaluatingURL)
            loading.state = .pending
            bySection[.pasteboard] = [loading]
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
        item.platform = candidate.platform
        return item
    }

    @objc private func filterChanged(_ control: UISegmentedControl) {
        filter = ListFilter(rawValue: control.selectedSegmentIndex) ?? .all
        reload()
    }

    /// Shows the Articles / Media & Links filter only when the list has BOTH a
    /// reader item and a media/link item; otherwise it's meaningless. Resets to
    /// "All" when hidden so a stale selection can't leave the list empty.
    private func updateFilterVisibility() {
        let items = store.items()
        let hasReaderItem = items.contains { Self.rendersAsReader($0) }
        let hasMediaOrLink = items.contains { !Self.rendersAsReader($0) }
        let shouldShow = hasReaderItem && hasMediaOrLink
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

    // MARK: - Catch up

    /// Items worth catching up on: unread (incl. partially read), and renderable
    /// (ready articles, or any platform/media item).
    private func catchUpQueue() -> [ReadingListItem] {
        store.items().filter { item in
            guard item.readState != .read else { return false }
            return Self.rendersAsReader(item) ? item.state == .ready : true
        }
    }

    /// Starts/stops the pulse-and-glow when the unread count crosses the threshold.
    private func updateCatchUpButton() {
        let unread = store.items().filter { $0.readState != .read }.count
        if unread > Self.catchUpPulseThreshold {
            startCatchUpPulse()
        } else {
            catchUpButton.layer.removeAnimation(forKey: "catchUpPulse")
            catchUpButton.layer.removeAnimation(forKey: "catchUpGlow")
            catchUpButton.layer.shadowOpacity = 0
        }
    }

    private func startCatchUpPulse() {
        guard catchUpButton.layer.animation(forKey: "catchUpPulse") == nil else { return }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.0
        scale.toValue = 1.14
        scale.duration = 0.8
        scale.autoreverses = true
        scale.repeatCount = .infinity
        scale.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        catchUpButton.layer.add(scale, forKey: "catchUpPulse")

        catchUpButton.layer.shadowColor = GlassStyle.readingAccent.cgColor
        catchUpButton.layer.shadowRadius = 8
        catchUpButton.layer.shadowOffset = .zero
        let glow = CABasicAnimation(keyPath: "shadowOpacity")
        glow.fromValue = 0.1
        glow.toValue = 0.9
        glow.duration = 0.8
        glow.autoreverses = true
        glow.repeatCount = .infinity
        glow.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        catchUpButton.layer.add(glow, forKey: "catchUpGlow")
    }

    @objc private func catchUpTapped() {
        let catchUp = CatchUpViewController(unread: catchUpQueue(), router: self)
        present(catchUp, animated: true)
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

    // MARK: - Delete

    /// Removes one item with an animated row (or section) deletion instead of a
    /// full `reloadData`, so the row fades out smoothly. The triggering row is
    /// always in an expanded section (collapsed sections show no cells to
    /// long-press), so an in-place `deleteRows` is safe.
    private func deleteItemAnimated(_ item: ReadingListItem) {
        guard let sectionIndex = groups.firstIndex(where: {
            $0.items.contains(where: { $0.id == item.id })
        }), let rowIndex = groups[sectionIndex].items.firstIndex(where: { $0.id == item.id }),
            !isCollapsed(groups[sectionIndex].section) else {
            store.delete(item) // fall back to the notification-driven reload
            return
        }

        isAnimatingRowChange = true
        store.delete(item)
        groups[sectionIndex].items.remove(at: rowIndex)
        tableView.performBatchUpdates {
            if groups[sectionIndex].items.isEmpty {
                groups.remove(at: sectionIndex)
                tableView.deleteSections(IndexSet(integer: sectionIndex), with: .automatic)
            } else {
                tableView.deleteRows(
                    at: [IndexPath(row: rowIndex, section: sectionIndex)], with: .automatic)
            }
        } completion: { [weak self] _ in
            self?.isAnimatingRowChange = false
            // A delete can change whether the Articles / Media & Links filter applies.
            self?.updateFilterVisibility()
        }
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
        let cell = tableView.dequeueReusableCell(
            withIdentifier: ReadingListItemCell.reuseID, for: indexPath) as? ReadingListItemCell
            ?? ReadingListItemCell(style: .default, reuseIdentifier: ReadingListItemCell.reuseID)
        let item = item(at: indexPath)
        let isPasteboard = section(at: indexPath.section) == .pasteboard

        let titleColor: UIColor = item.state == .failed
            ? .systemRed
            : (item.readState == .unopened ? .label : .secondaryLabel)

        if isPasteboard {
            // Spinner while evaluating; the candidate's preview thumbnail once
            // ready. A trailing Save button saves explicitly (tap just previews).
            let thumbnail: ReadingListItemCell.Thumbnail
            if let candidate = pasteboardCandidate {
                if let image = candidate.thumbnail { thumbnail = .image(image) }
                else if let platform = candidate.platform,
                        let module = PlatformRegistry.shared.module(for: platform) {
                    thumbnail = .logo(assetName: platform.logoAssetName, glyph: module.glyphSymbolName)
                } else { thumbnail = .none }
            } else {
                thumbnail = .loading
            }
            cell.configure(
                title: item.title ?? item.urlString, titleColor: titleColor,
                subtitle: secondaryText(for: item), thumbnail: thumbnail,
                showsDisclosure: false,
                reuseKey: "pasteboard|\(item.urlString)|\(pasteboardCandidate == nil)",
                trailingButtonSymbol: pasteboardCandidate == nil ? nil : "plus.circle.fill",
                onTrailingButton: pasteboardCandidate == nil ? nil : { [weak self] in
                    self?.savePasteboardCandidate()
                })
            cell.showsReorderControl = false
            return cell
        }

        cell.configure(
            title: item.title ?? item.urlString,
            titleColor: titleColor,
            subtitle: secondaryText(for: item),
            thumbnail: thumbnail(for: item, isPasteboard: isPasteboard),
            showsDisclosure: item.state == .ready,
            reuseKey: "\(item.id.uuidString)|\(item.thumbnailFileName ?? "")|\(item.state.rawValue)")
        cell.showsReorderControl = true
        if AppEnvironment.isSimulator {
            cell.setSimulatorMenu(rowMenu(for: item, at: indexPath))
        }
        return cell
    }

    /// Builds the grey metadata line, with the "from <friend>" attribution in
    /// the accent color so social shares stand out.
    private func secondaryText(for item: ReadingListItem) -> NSAttributedString {
        let baseColor: UIColor = item.readState == .unopened ? .secondaryLabel : .tertiaryLabel
        let host = item.url?.host ?? ""
        // Platform items show a logical container (subreddit / author / channel /
        // artist), never the bare host. Falls back to the platform name.
        let leadingLabel: String
        if let platform = item.contentPlatform,
           let module = PlatformRegistry.shared.module(for: platform) {
            leadingLabel = module.subtitle(for: item) ?? platform.displayName
        } else if item.isDocument {
            leadingLabel = item.documentType?.uppercased() ?? "Document"
        } else {
            leadingLabel = item.channelName ?? host
        }
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
        // Per-destination send status (e.g. "sent to Kindle", "Boox send failed").
        let destinationNames = [
            ArticleDestinationID.kindle: "Kindle",
            ArticleDestinationID.boox: "Boox",
        ]
        for (destinationID, state) in item.sendStates.sorted(by: { $0.key < $1.key }) {
            let name = destinationNames[destinationID] ?? destinationID
            switch state {
            case .sent: parts.append("sent to \(name)")
            case .failed: parts.append("\(name) send failed")
            case .queued: parts.append("sending to \(name)…")
            }
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
            previewPasteboardCandidate()
            return
        }
        let item = item(at: indexPath)
        if openItem(item, presentingFrom: self) { return }
        guard item.state == .ready, let content = store.content(for: item) else { return }
        let reader = ReaderViewController(
            item: item, content: content,
            shareProvider: AppReaderShareProvider.shared,
            gazeTrackerFactory: AppGazeTracker.factory)
        navigationController?.pushViewController(reader, animated: true)
    }

    /// Opens a non-article item (video / platform post / music / podcast) the way
    /// tapping its row does, presenting any in-app viewer from `presenter` (the
    /// reading list, or the catch-up screen). Returns false for reader articles, so
    /// the caller can render those itself.
    @discardableResult
    func openItem(_ item: ReadingListItem, presentingFrom presenter: UIViewController) -> Bool {
        if item.isYouTubeVideo {
            openVideo(item, from: presenter)
            return true
        }
        if let platform = item.contentPlatform {
            switch platform {
            case .music, .podcast: openMediaItem(item, platform: platform, from: presenter)
            default: openPlatformItem(item, platform: platform, from: presenter)
            }
            return true
        }
        return false
    }

    // MARK: - Platform item playback / open

    /// The launch ladder for a non-YouTube platform item: native app → in-app
    /// embed → in-app Safari.
    private func openPlatformItem(
        _ item: ReadingListItem, platform: ContentPlatform, from presenter: UIViewController
    ) {
        guard let module = PlatformRegistry.shared.module(for: platform) else { return }

        if let appURL = module.appDeepLink(for: item), UIApplication.shared.canOpenURL(appURL) {
            UIApplication.shared.open(appURL) { [weak self] success in
                if success { self?.store.markReadState(.read, for: item.id) }
            }
            return
        }
        if let embed = module.embed(for: item) {
            presenter.present(PlatformEmbedViewController(embed: embed, itemID: item.id), animated: true)
            return
        }
        InAppBrowser.present(urlString: item.urlString, from: presenter)
    }

    /// Opens a music/podcast item in the user's preferred provider (exact link
    /// when same-provider, else a search), prompting to pick a provider if unset.
    private func openMediaItem(
        _ item: ReadingListItem, platform: ContentPlatform, from presenter: UIViewController
    ) {
        guard let provider = MediaProviderSettings.preferredProvider(for: platform) else {
            promptChooseMediaProvider(from: presenter)
            return
        }
        let query = [item.mediaCreatorName, item.mediaItemTitle ?? item.title]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        let markRead: (Bool) -> Void = { [weak self] success in
            if success { self?.store.markReadState(.read, for: item.id) }
        }

        if item.mediaSourceService == provider,
           let appURL = MediaLink.appSchemeURL(forWebURL: item.urlString),
           UIApplication.shared.canOpenURL(appURL) {
            UIApplication.shared.open(appURL, completionHandler: markRead)
            return
        }
        if !query.isEmpty, let appSearch = provider.appSearchURL(query: query, platform: platform),
           UIApplication.shared.canOpenURL(appSearch) {
            UIApplication.shared.open(appSearch, completionHandler: markRead)
            return
        }
        // Web fallback: the original http URL, else a web search in the provider.
        if let url = URL(string: item.urlString), let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            InAppBrowser.present(urlString: item.urlString, from: presenter)
        } else if !query.isEmpty, let webSearch = provider.webSearchURL(query: query, platform: platform) {
            InAppBrowser.present(urlString: webSearch.absoluteString, from: presenter)
        }
    }

    private func promptChooseMediaProvider(from presenter: UIViewController) {
        let alert = UIAlertController(
            title: "Choose a Music App",
            message: "Pick which app opens songs and podcasts.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Open Settings", style: .default) { [weak self] _ in
            self?.navigationController?.pushViewController(MediaProviderSettingsScreen(), animated: true)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        presenter.present(alert, animated: true)
    }

    /// Sends a URL-less music/podcast item to a friend (via the CloudKit media case).
    private func sendMediaToFriend(_ item: ReadingListItem, from sourceView: UIView) {
        let friends = FriendsStore.shared.items()
        guard !friends.isEmpty else {
            presentInfoAlert(
                title: "No Friends Yet",
                message: "Add friends from the Friends screen to share directly.")
            return
        }
        let sheet = UIAlertController(
            title: item.title ?? "Share", message: nil, preferredStyle: .actionSheet)
        let kind = item.contentPlatform ?? .music
        let creator = item.mediaCreatorName ?? ""
        let title = item.mediaItemTitle ?? item.title ?? ""
        for friend in friends {
            sheet.addAction(UIAlertAction(title: "Send to \(friend.card.username)", style: .default) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    guard await ICloudGate.requireICloud(presenting: self) else { return }
                    do {
                        try await SocialMessageCenter.shared.sendMediaItem(
                            kind: kind, creator: creator, title: title, to: friend)
                        Toast.show("Sent to \(friend.card.username)", from: self)
                    } catch {
                        self.presentInfoAlert(title: "Couldn't Send", message: "\(error)")
                    }
                }
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = sourceView
        present(sheet, animated: true)
    }

    // MARK: - Video playback

    /// Prefers the YouTube app (marks read on successful handoff); otherwise
    /// the in-app player (marks read when playback finishes).
    private func openVideo(_ item: ReadingListItem, from presenter: UIViewController) {
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
        presenter.present(YouTubePlayerViewController(videoID: videoID, itemID: item.id), animated: true)
    }

    /// The thumbnail state for a row: cached art (aspect-fit) when present, a
    /// spinner while the item is still being fetched, or the platform-logo
    /// fallback once the fetch finished with no image. The pasteboard suggestion
    /// is transient (never ingesting) so it never spins.
    private func thumbnail(
        for item: ReadingListItem, isPasteboard: Bool
    ) -> ReadingListItemCell.Thumbnail {
        if let fileName = item.thumbnailFileName {
            return .art(path: store.articlesDirectory.appendingPathComponent(fileName).path)
        }
        let fetchFinished = isPasteboard || item.state == .ready || item.state == .failed

        if item.isYouTubeVideo {
            return fetchFinished
                ? .logo(assetName: ContentPlatform.youtube.logoAssetName, glyph: "play.rectangle.fill")
                : .loading
        }
        if let platform = item.contentPlatform,
           let module = PlatformRegistry.shared.module(for: platform) {
            return fetchFinished
                ? .logo(assetName: platform.logoAssetName, glyph: module.glyphSymbolName)
                : .loading
        }
        // Plain article/document: a cover image may still be downloading. Spin
        // while pending; show nothing once finished without one.
        return fetchFinished ? .none : .loading
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
            self?.rowMenu(for: item, at: indexPath)
        })
    }

    /// Builds the long-press row menu. Also driven by a simulator-only tap button on
    /// the cell (see `cellForRowAt`) so the menu is testable without a synthesized
    /// long-press.
    private func rowMenu(for item: ReadingListItem, at indexPath: IndexPath) -> UIMenu {
        let sendToFriend = UIAction(
            title: "Send to Friend…",
            image: UIImage(systemName: "person.2")
        ) { [weak self] _ in
            guard let self else { return }
            let sourceView = self.tableView.cellForRow(at: indexPath) ?? self.view ?? UIView()
            SendToFriendSheet.present(
                from: self, sourceView: sourceView,
                urlString: item.urlString, title: item.title)
        }
        let sendToKindle = UIAction(
            title: "Send to Kindle",
            image: UIImage(systemName: "paperplane")
        ) { [weak self] _ in
            self?.sendToEreader(item, destinationID: ArticleDestinationID.kindle)
        }
        let sendToBoox = UIAction(
            title: "Send to Boox",
            image: UIImage(systemName: "books.vertical")
        ) { [weak self] _ in
            self?.sendToEreader(item, destinationID: ArticleDestinationID.boox)
        }
        let shareEbook = UIAction(
            title: "Share eBook…",
            image: UIImage(systemName: "square.and.arrow.up")
        ) { [weak self] _ in
            guard let self else { return }
            let sourceView = self.tableView.cellForRow(at: indexPath) ?? self.view ?? UIView()
            self.shareEbook(item, from: sourceView)
        }
        let shareLink = UIAction(
            title: "Share Link…",
            image: UIImage(systemName: "link")
        ) { [weak self] _ in
            guard let self else { return }
            let sourceView = self.tableView.cellForRow(at: indexPath) ?? self.view ?? UIView()
            SendToFriendSheet.shareLink(
                urlString: item.urlString, from: self, sourceView: sourceView)
        }
        let delete = UIAction(
            title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive
        ) { [weak self] _ in
            self?.deleteItemAnimated(item)
        }
        // Videos: share to friends + delete. Documents: ereaders + read +
        // delete. Articles: everything. Each ereader row shows only when
        // that destination is set up.
        let sendMediaToFriend = UIAction(
            title: "Send to Friend…",
            image: UIImage(systemName: "person.2")
        ) { [weak self] _ in
            guard let self else { return }
            let sourceView = self.tableView.cellForRow(at: indexPath) ?? self.view ?? UIView()
            self.sendMediaToFriend(item, from: sourceView)
        }

        var children: [UIAction] = []
        if item.canShareToFriends {
            children.append(sendToFriend)
        } else if item.isURLlessMedia {
            children.append(sendMediaToFriend)
        }
        // Any item that kept a real web URL (articles AND platform items like
        // Reddit/Spotify/X) can share that link.
        if item.isShareable {
            children.append(shareLink)
        }
        // X / Instagram / TikTok posts: download the post's media to Photos.
        if MediaDownloadablePlatform.supports(item.urlString) {
            let downloadMedia = UIAction(
                title: "Download Media to Photos",
                image: UIImage(systemName: "photo.badge.arrow.down")
            ) { [weak self] _ in
                self?.downloadMediaToPhotos(item)
            }
            children.append(downloadMedia)
        }
        // Article-only actions — ereader sends, and the eBook for text-only
        // no-url articles (email/document) that can't share a link.
        if !item.isPlatformItem {
            if ArticleSendCoordinator.shared.isConfigured(destinationID: ArticleDestinationID.kindle) {
                children.append(sendToKindle)
            }
            if ArticleSendCoordinator.shared.isConfigured(destinationID: ArticleDestinationID.boox) {
                children.append(sendToBoox)
            }
            if !item.isShareable, item.state == .ready {
                children.append(shareEbook)
            }
        }
        children.append(delete)
        return UIMenu(children: children)
    }

    /// Downloads the first media item of an X/Instagram/TikTok post to the photo
    /// library. Progress + result show in a non-blocking bottom status pill (the
    /// list stays interactive and the pill never appears over the reader), and the
    /// work continues if the app is backgrounded (a background task assertion).
    private func downloadMediaToPhotos(_ item: ReadingListItem) {
        guard let url = URL(string: item.urlString) else { return }
        let status = mediaDownloadStatusView()
        status.startProgress()

        var backgroundTask = UIBackgroundTaskIdentifier.invalid
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "media-download") {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
        let endBackground = {
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
        }

        Task { [weak self] in
            do {
                _ = try await MediaDownloadService().downloadFirstMediaToPhotos(from: url) { progress in
                    Task { @MainActor in self?.mediaDownloadStatus?.update(progress: progress) }
                }
                await MainActor.run {
                    self?.mediaDownloadStatus?.showResult(message: "Saved to Photos", success: true)
                    endBackground()
                }
            } catch {
                let message = (error as? MediaDownloadError)?.message ?? "Couldn't save the media."
                await MainActor.run {
                    self?.mediaDownloadStatus?.showResult(message: message, success: false)
                    endBackground()
                }
            }
        }
    }

    /// Lazily creates the bottom status pill, pinned above the safe area.
    private func mediaDownloadStatusView() -> MediaDownloadStatusView {
        if let existing = mediaDownloadStatus { return existing }
        let status = MediaDownloadStatusView()
        view.addSubview(status)
        NSLayoutConstraint.activate([
            status.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            status.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            status.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            status.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])
        mediaDownloadStatus = status
        return status
    }

    /// Explicit send of one article to one ereader destination (the long-press
    /// menu only offers a destination when it's configured).
    private func sendToEreader(_ item: ReadingListItem, destinationID: String) {
        Task { await ArticleSendCoordinator.shared.send(item, toDestinationID: destinationID) }
    }

    /// Builds the article's EPUB off-main and presents the system share sheet so
    /// the user can send it to Apple Books, Kobo, reMarkable, Boox, Files, etc.
    private func shareEbook(_ item: ReadingListItem, from sourceView: UIView) {
        ArticleExportService().presentShareSheet(for: item, from: self, sourceView: sourceView)
    }
}

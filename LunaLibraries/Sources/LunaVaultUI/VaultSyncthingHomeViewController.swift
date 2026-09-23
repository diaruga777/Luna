import UIKit
import UniformTypeIdentifiers

public extension VaultAccessibilityID {
    static let connectionStatus = "vault.connection.status"
    static let browse = "vault.browse"
    static let refresh = "vault.refresh"
    static let pairingDeviceID = "vault.pairing.local-device-id"
}

/// Native, search-first file library. Connection state determines the next useful action.
public final class VaultSyncthingHomeViewController: UITableViewController, UISearchResultsUpdating {
    private let runtime: any VaultPresentationProviding
    private let importHandler: (() -> Void)?
    private let importFolderHandler: (() -> Void)?
    private let openHandler: ((String) -> Void)?
    private let settingsController: (() -> UIViewController)?
    private let search = UISearchController(searchResultsController: nil)
    private var status: VaultConnectionStatus = .notPaired
    private var pendingUploads = 0
    private var recents: [VaultPresentedFile] = []
    private var results: [VaultPresentedFile] = []
    private var loaded = false
    private var searching = false
    private var loadError = false
    private var searchError = false
    private var searchTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var loadGeneration = 0
    public private(set) var emptyStateConfiguration: UIContentUnavailableConfiguration?

    public init(runtime: any VaultPresentationProviding, importHandler: (() -> Void)? = nil,
                importFolderHandler: (() -> Void)? = nil, openHandler: ((String) -> Void)? = nil,
                settingsController: (() -> UIViewController)? = nil) {
        self.runtime = runtime
        self.importHandler = importHandler
        self.importFolderHandler = importFolderHandler
        self.openHandler = openHandler
        self.settingsController = settingsController
        super.init(style: .insetGrouped)
    }
    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { searchTask?.cancel(); loadTask?.cancel(); refreshTask?.cancel() }

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = "Vault"
        navigationItem.largeTitleDisplayMode = .always
        navigationItem.backButtonDisplayMode = .minimal
        tableView.accessibilityIdentifier = VaultAccessibilityID.content
        tableView.keyboardDismissMode = .onDrag
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "file")
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 76
        definesPresentationContext = true
        search.obscuresBackgroundDuringPresentation = false
        search.searchResultsUpdater = self
        search.searchBar.placeholder = "Search files and contents"
        search.searchBar.searchTextField.accessibilityIdentifier = VaultAccessibilityID.search
        search.searchBar.searchTextField.accessibilityLabel = "Search your Vault"
        navigationItem.hidesSearchBarWhenScrolling = false
        let settings = UIBarButtonItem(image: UIImage(systemName: "gearshape"), style: .plain,
                                       target: self, action: #selector(settingsTapped))
        settings.accessibilityIdentifier = VaultAccessibilityID.settings
        settings.accessibilityLabel = "Vault settings"
        navigationItem.rightBarButtonItem = settings
        refreshControl = UIRefreshControl()
        refreshControl?.accessibilityIdentifier = VaultAccessibilityID.refresh
        refreshControl?.addTarget(self, action: #selector(refreshPulled), for: .valueChanged)
        updatePresentation()
    }
    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.navigationBar.prefersLargeTitles = true
        refresh()
    }
    public func refresh() {
        guard isViewLoaded else { return }
        loadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        loadTask = Task { [weak self, runtime] in
            async let connection = runtime.connectionStatus()
            async let pending = vaultAsyncResult { try await runtime.pendingUploadCount() }
            let files = await vaultAsyncResult { try await runtime.recentFiles(limit: 30) }
            let state = await connection
            let uploadCount = await pending
            guard let self, !Task.isCancelled, generation == loadGeneration else { return }
            let previous = recents
            let previousStatus = status
            let previousPending = pendingUploads
            let wasLoaded = loaded
            let hadError = loadError
            status = state
            if case .success(let count) = uploadCount { pendingUploads = count }
            loaded = true
            switch files {
            case .success(let items): recents = items; loadError = false
            case .failure: loadError = true
            }
            if previous != recents || previousStatus != status || previousPending != pendingUploads || !wasLoaded || hadError != loadError {
                updatePresentation()
            }
            // Preserve search results and keyboard during background connection updates.
        }
    }
    private var query: String { (search.searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasQuery: Bool { !query.isEmpty }
    private var needsSetup: Bool { loaded && status == .notPaired && recents.isEmpty && !loadError }
    private var visibleFiles: [VaultPresentedFile] { hasQuery ? results : recents }

    @objc private func settingsTapped() {
        guard let controller = settingsController?() else { return }
        navigationController?.pushViewController(controller, animated: true)
    }
    @objc private func importTapped() { importHandler?() }
    @objc private func refreshPulled() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self, runtime] in
            await runtime.refresh()
            guard let self, !Task.isCancelled else { return }
            refreshControl?.endRefreshing()
            refreshTask = nil
            refresh()
            if hasQuery { scheduleSearch(delay: 0) }
        }
    }
    public func updateSearchResults(for searchController: UISearchController) { scheduleSearch(delay: 200_000_000) }
    private func scheduleSearch(delay: UInt64) {
        searchTask?.cancel()
        let requestedQuery = query
        results = []
        searchError = false
        searching = !requestedQuery.isEmpty
        updatePresentation()
        guard !requestedQuery.isEmpty else { return }
        searchTask = Task { [weak self, runtime] in
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            guard !Task.isCancelled else { return }
            let result = await vaultAsyncResult { try await runtime.search(requestedQuery, limit: 100) }
            guard let self, !Task.isCancelled, query == requestedQuery else { return }
            searching = false
            switch result {
            case .success(let items): results = items
            case .failure: searchError = true
            }
            updatePresentation()
        }
    }
    private func updatePresentation() {
        navigationItem.searchController = needsSetup || !loaded ? nil : search
        if loaded && status != .notPaired {
            let actions = [UIAction(title: "Import File", image: UIImage(systemName: "doc")) { [weak self] _ in self?.importHandler?() },
                           UIAction(title: "Import Folder", image: UIImage(systemName: "folder")) { [weak self] _ in self?.importFolderHandler?() }]
            let add = UIBarButtonItem(image: UIImage(systemName: "plus"), menu: UIMenu(children: actions))
            add.accessibilityLabel = "Import file or folder"
            add.accessibilityIdentifier = VaultAccessibilityID.importButton
            navigationItem.leftBarButtonItem = add
        } else { navigationItem.leftBarButtonItem = nil }
        updateEmptyState()
        tableView.reloadData()
    }
    private func updateEmptyState() {
        var empty = UIContentUnavailableConfiguration.empty()
        if !loaded {
            emptyStateConfiguration = UIContentUnavailableConfiguration.loading()
            return
        } else if needsSetup {
            empty.image = UIImage(systemName: "externaldrive.badge.icloud")
            empty.text = "Your files. With you."
            empty.secondaryText = "Connect your Mac to browse and search your files here. Download what you need, when you need it."
            empty.button = .filled()
            empty.button.title = "Connect Mac"
            empty.button.cornerStyle = .capsule
            empty.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.settingsTapped() }
        } else if hasQuery && searching {
            var loading = UIContentUnavailableConfiguration.loading()
            loading.text = "Searching…"
            emptyStateConfiguration = loading
            return
        } else if hasQuery && results.isEmpty {
            empty.image = UIImage(systemName: searchError ? "exclamationmark.magnifyingglass" : "magnifyingglass")
            empty.text = searchError ? "Couldn’t Search" : "No Results"
            empty.secondaryText = searchError ? "Try again or pull down to refresh." : "No files match “\(query)”. Try another name or a word from a downloaded file."
            if searchError {
                empty.button.title = "Try Again"
                empty.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.scheduleSearch(delay: 0) }
            }
        } else if !hasQuery && recents.isEmpty {
            empty.image = UIImage(systemName: loadError ? "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90" : "folder")
            empty.text = loadError ? "Couldn’t Load Files" : "No Files Yet"
            empty.secondaryText = loadError ? "Pull down to refresh your library." : "Add a file from this iPhone or put files in your Mac’s Vault folder."
            empty.button.title = loadError ? "Try Again" : "Import File"
            empty.buttonProperties.primaryAction = UIAction { [weak self] _ in
                guard let self else { return }
                if loadError { refresh() } else { importTapped() }
            }
        } else {
            emptyStateConfiguration = nil
            return
        }
        emptyStateConfiguration = empty
    }
    public override func numberOfSections(in tableView: UITableView) -> Int { !loaded || needsSetup || hasQuery ? 1 : 2 }
    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if !loaded || needsSetup { return 1 }
        return !hasQuery && section == 0 ? 2 : max(1, visibleFiles.count)
    }
    public override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        hasQuery ? (visibleFiles.isEmpty ? nil : "\(visibleFiles.count) Results") : (section == 1 && !recents.isEmpty ? "Recent Files" : nil)
    }
    public override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if let emptyStateConfiguration, !loaded || needsSetup || hasQuery || indexPath.section == 1 {
            return vaultEmptyCell(configuration: emptyStateConfiguration, minimumHeight: max(280,
                tableView.bounds.height - tableView.adjustedContentInset.top - tableView.adjustedContentInset.bottom - (needsSetup || hasQuery ? 0 : 190)))
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: "file", for: indexPath)
        if !hasQuery && indexPath.section == 0 {
            var content = cell.defaultContentConfiguration()
            content.text = indexPath.row == 0 ? "My Mac" : "Browse Folders"
            content.secondaryText = indexPath.row == 0 ? connectionDescription : nil
            content.image = UIImage(systemName: indexPath.row == 0 ? "desktopcomputer" : "folder")
            content.imageProperties.tintColor = .tintColor
            cell.contentConfiguration = content
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityIdentifier = indexPath.row == 0 ? VaultAccessibilityID.connectionStatus : VaultAccessibilityID.browse
            cell.accessibilityLabel = nil
            cell.accessibilityHint = indexPath.row == 0 ? "Connection and storage settings" : "Browse Vault folders"
        } else { configureVaultFileCell(cell, item: visibleFiles[indexPath.row], prefix: hasQuery ? "vault.result" : "vault.recent") }
        return cell
    }
    private var connectionDescription: String {
        if pendingUploads > 0 {
            let count = "\(pendingUploads) item\(pendingUploads == 1 ? "" : "s")"
            return status == .connected ? "\(count) uploading · Keep Vault open" : "\(count) waiting for Mac · Reconnect to resume"
        }
        switch status {
        case .connected: return "Connected"
        case .syncing: return "Syncing files…"
        case .offline: return "Offline · Downloaded files available"
        case .notPaired: return "Connect your Mac"
        }
    }
    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard loaded, !needsSetup else { return }
        if !hasQuery && indexPath.section == 0 {
            if indexPath.row == 0 { settingsTapped() }
            else { openFolder("") }
        } else {
            guard visibleFiles.indices.contains(indexPath.row) else { return }
            let file = visibleFiles[indexPath.row]
            if file.isDirectory { openFolder(file.path) } else { openHandler?(file.id) }
        }
    }
    private func openFolder(_ path: String) {
        navigationController?.pushViewController(VaultBrowseViewController(runtime: runtime, path: path, openHandler: openHandler), animated: true)
    }
}

/// Reusable native rows keep large folders bounded by the number of visible cells.
public final class VaultBrowseViewController: UITableViewController {
    private let runtime: any VaultPresentationProviding
    public let path: String
    private let openHandler: ((String) -> Void)?
    private var items: [VaultPresentedFile] = []
    private var loadTask: Task<Void, Never>?
    private var sortByDate = false
    public private(set) var emptyStateConfiguration: UIContentUnavailableConfiguration?
    public init(runtime: any VaultPresentationProviding, path: String, openHandler: ((String) -> Void)? = nil) {
        self.runtime = runtime; self.path = path; self.openHandler = openHandler
        super.init(style: .insetGrouped)
    }
    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { loadTask?.cancel() }
    public override func viewDidLoad() {
        super.viewDidLoad()
        title = path.isEmpty ? "Browse" : (path as NSString).lastPathComponent
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.backButtonDisplayMode = .minimal
        tableView.accessibilityIdentifier = "vault.browse.list"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "file")
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 76
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(refreshPulled), for: .valueChanged)
        configureSort()
    }
    public override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); loadChildren() }
    private func configureSort() {
        let actions = [("Name", false), ("Date Modified", true)].map { title, byDate in
            UIAction(title: title, state: sortByDate == byDate ? .on : .off) { [weak self] _ in
                self?.sortByDate = byDate; self?.sortItems(); self?.tableView.reloadData(); self?.configureSort()
            }
        }
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "arrow.up.arrow.down"), menu: UIMenu(title: "Sort By", children: actions))
        navigationItem.rightBarButtonItem?.accessibilityLabel = "Sort files"
    }
    private func sortItems() {
        items.sort {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            if sortByDate && $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    @objc private func refreshPulled() { loadChildren(refresh: true) }
    private func loadChildren(refresh: Bool = false) {
        loadTask?.cancel()
        loadTask = Task { [weak self, runtime, path] in
            if refresh { await runtime.refresh() }
            let result = await vaultAsyncResult { try await runtime.children(of: path) }
            guard let self, !Task.isCancelled else { return }
            refreshControl?.endRefreshing()
            switch result {
            case .success(let loaded):
                items = loaded; sortItems()
                if loaded.isEmpty { showEmpty(title: "This Folder Is Empty", message: "Files added on your Mac will appear here after syncing.", error: false) }
                else { emptyStateConfiguration = nil }
            case .failure:
                items = []
                showEmpty(title: "Couldn’t Open Folder", message: "Check your connection and try again.", error: true)
            }
            tableView.reloadData()
        }
    }
    private func showEmpty(title: String, message: String, error: Bool) {
        var empty = UIContentUnavailableConfiguration.empty()
        empty.image = UIImage(systemName: error ? "wifi.exclamationmark" : "folder")
        empty.text = title; empty.secondaryText = message
        if error {
            empty.button.title = "Try Again"
            empty.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.loadChildren(refresh: true) }
        }
        emptyStateConfiguration = empty
    }
    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { emptyStateConfiguration == nil ? items.count : 1 }
    public override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if let emptyStateConfiguration {
            return vaultEmptyCell(configuration: emptyStateConfiguration, minimumHeight: max(280,
                tableView.bounds.height - tableView.adjustedContentInset.top - tableView.adjustedContentInset.bottom))
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: "file", for: indexPath)
        configureVaultFileCell(cell, item: items[indexPath.row], prefix: "vault.browse.item")
        return cell
    }
    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard items.indices.contains(indexPath.row) else { return }
        let item = items[indexPath.row]
        if item.isDirectory {
            navigationController?.pushViewController(VaultBrowseViewController(runtime: runtime, path: item.path, openHandler: openHandler), animated: true)
        } else { openHandler?(item.id) }
    }
}

/// Empty configurations in table rows stay in the accessibility tree and can
/// scroll at large text sizes; UIViewController's overlay is swallowed by an
/// empty UITableView's “Empty list” accessibility element on iOS 26.
private func vaultEmptyCell(configuration: UIContentUnavailableConfiguration, minimumHeight: CGFloat) -> UITableViewCell {
    let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
    cell.contentConfiguration = configuration
    cell.backgroundConfiguration = .clear()
    cell.selectionStyle = .none
    cell.separatorInset = UIEdgeInsets(top: 0, left: 10_000, bottom: 0, right: 0)
    cell.contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: minimumHeight).isActive = true
    return cell
}

private func configureVaultFileCell(_ cell: UITableViewCell, item: VaultPresentedFile, prefix: String) {
    var content = cell.defaultContentConfiguration()
    content.text = item.name
    content.textProperties.numberOfLines = 2
    content.secondaryText = [VaultDateChipFormatter.string(from: item.modifiedAt),
                             item.isDirectory ? nil : ByteCountFormatter.string(fromByteCount: item.byteCount, countStyle: .file)]
        .compactMap { $0 }.joined(separator: " · ")
    if !item.snippet.isEmpty { content.secondaryText = item.snippet + "\n" + (content.secondaryText ?? "") }
    content.secondaryTextProperties.numberOfLines = 3
    content.image = item.thumbnailData.flatMap(UIImage.init(data:)) ?? UIImage(systemName: vaultFileSymbol(item))
    content.imageProperties.maximumSize = CGSize(width: 40, height: 48)
    content.imageProperties.reservedLayoutSize = CGSize(width: 44, height: 48)
    content.imageProperties.tintColor = .tintColor
    cell.contentConfiguration = content
    cell.accessoryType = item.isDirectory ? .disclosureIndicator : .none
    cell.accessibilityIdentifier = "\(prefix).\(safeID(item.id))"
    cell.accessibilityLabel = nil
    cell.accessibilityHint = item.isDirectory ? "Open folder" : "Open file"
}
private func vaultFileSymbol(_ item: VaultPresentedFile) -> String {
    if item.isDirectory { return "folder.fill" }
    guard let type = UTType(filenameExtension: (item.name as NSString).pathExtension) else { return "doc.fill" }
    if type.conforms(to: .image) { return "photo" }
    if type.conforms(to: .pdf) { return "doc.richtext" }
    if type.conforms(to: .movie) { return "film" }
    if type.conforms(to: .audio) { return "waveform" }
    if type.conforms(to: .archive) { return "doc.zipper" }
    return "doc.text"
}
private func vaultAsyncResult<T>(_ operation: () async throws -> T) async -> Result<T, Error> {
    do { return .success(try await operation()) } catch { return .failure(error) }
}
enum VaultDateChipFormatter {
    private static let formatter: DateFormatter = {
        let value = DateFormatter(); value.dateStyle = .medium; value.doesRelativeDateFormatting = true; return value
    }()
    static func string(from date: Date) -> String { formatter.string(from: date) }
}
private func safeID(_ value: String) -> String {
    Data(value.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "=", with: "")
}

import UIKit
import LunaVaultBEP

/// Live Mac directory listings. No mutation actions are offered on this surface.
public final class VaultMacBrowseViewController: UITableViewController {
    private let runtime: any VaultPresentationProviding
    public let path: String?
    private let openHandler: ((String) -> Void)?
    private var entries: [VaultMacBrowseEntry] = []
    private var nextOffset: Int64?
    private var showHidden = false
    private var sortByDate = false
    private var loading = false
    private var loadError: String?
    private var task: Task<Void, Never>?
    public private(set) var emptyStateConfiguration: UIContentUnavailableConfiguration?

    public init(runtime: any VaultPresentationProviding, path: String? = nil,
                showHidden: Bool = false, openHandler: ((String) -> Void)? = nil) {
        self.runtime = runtime; self.path = path; self.openHandler = openHandler; self.showHidden = showHidden
        super.init(style: .insetGrouped)
    }
    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { task?.cancel() }

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = path.map { $0 == "/" ? "Macintosh HD" : ($0 as NSString).lastPathComponent } ?? "Mac Files"
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.backButtonDisplayMode = .minimal
        tableView.accessibilityIdentifier = "vault.mac.files"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "file")
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 76
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(reload), for: .valueChanged)
        configureMenu()
        load()
    }
    private func configureMenu() {
        let go = UIAction(title: "Go to Folder…", image: UIImage(systemName: "folder")) { [weak self] _ in self?.goToFolder() }
        let hidden = UIAction(title: "Show Hidden Files", image: UIImage(systemName: "eye"), state: showHidden ? .on : .off) { [weak self] _ in
            guard let self else { return }; showHidden.toggle(); configureMenu(); load()
        }
        let sorts = [("Name", false), ("Date Modified", true)].map { name, date in
            UIAction(title: name, state: sortByDate == date ? .on : .off) { [weak self] _ in
                self?.sortByDate = date; self?.sort(); self?.tableView.reloadData(); self?.configureMenu()
            }
        }
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"),
            menu: UIMenu(children: [go, hidden, UIMenu(title: "Sort By", children: sorts)]))
        navigationItem.rightBarButtonItem?.accessibilityLabel = "Mac browser options"
    }
    private func goToFolder() {
        let alert = UIAlertController(title: "Go to Folder", message: "Enter a full Mac path, such as /Users or /Volumes.", preferredStyle: .alert)
        alert.addTextField { [path] field in
            field.placeholder = "/Users"; field.text = path
            field.autocorrectionType = .no; field.autocapitalizationType = .none
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Go", style: .default) { [weak self, weak alert] _ in
            guard let self, let value = alert?.textFields?.first?.text, !value.isEmpty else { return }
            openFolder(value)
        })
        present(alert, animated: true)
    }
    @objc private func reload() { load() }
    private func sort() {
        guard path != nil else { return }
        entries.sort {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            if sortByDate && $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    private func load(more: Bool = false) {
        task?.cancel()
        let offset = more ? (nextOffset ?? 0) : 0
        if !more { entries = []; nextOffset = nil }
        loading = true; loadError = nil; updateEmpty(); tableView.reloadData()
        task = Task { [weak self, runtime, path, showHidden] in
            do {
                let page = try await runtime.macDirectory(path: path, offset: offset, showHidden: showHidden)
                guard let self, !Task.isCancelled else { return }
                let existing = Set(entries.map(\.path))
                entries += page.entries.filter { !existing.contains($0.path) }
                nextOffset = page.nextOffset.flatMap { $0 > offset ? $0 : nil }
                sort()
            } catch {
                guard let self, !Task.isCancelled else { return }
                loadError = error.localizedDescription
            }
            guard let self, !Task.isCancelled else { return }
            loading = false; refreshControl?.endRefreshing(); updateEmpty(); tableView.reloadData()
        }
    }
    private func updateEmpty() {
        guard entries.isEmpty else { emptyStateConfiguration = nil; return }
        if loading { emptyStateConfiguration = .loading(); return }
        var empty = UIContentUnavailableConfiguration.empty()
        empty.image = UIImage(systemName: loadError == nil ? "folder" : "exclamationmark.folder")
        empty.text = loadError == nil ? "This Folder Is Empty" : "Couldn’t Open Folder"
        empty.secondaryText = loadError ?? "Pull down to refresh files from your Mac."
        if loadError != nil {
            empty.button.title = "Try Again"
            empty.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.load() }
        }
        emptyStateConfiguration = empty
    }
    public override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { path ?? "Locations on your Mac" }
    public override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "Read only · Open a file to download and preview it. Use Share to save a copy. Search and uploads are available in the Vault folder."
    }
    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        emptyStateConfiguration != nil ? 1 : entries.count + (nextOffset == nil ? 0 : 1)
    }
    public override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if let emptyStateConfiguration { return vaultEmptyCell(configuration: emptyStateConfiguration, minimumHeight: 300) }
        let cell = tableView.dequeueReusableCell(withIdentifier: "file", for: indexPath)
        if indexPath.row == entries.count {
            var content = cell.defaultContentConfiguration()
            content.text = loading ? "Loading…" : loadError == nil ? "Load More" : "Try Again"
            content.secondaryText = loadError
            content.secondaryTextProperties.numberOfLines = 0
            cell.contentConfiguration = content; cell.accessoryType = .none
            cell.accessibilityIdentifier = "vault.mac.loadMore"
            return cell
        }
        let entry = entries[indexPath.row]
        configureVaultFileCell(cell, item: VaultPresentedFile(id: entry.path, name: entry.name, path: entry.path,
            modifiedAt: entry.modifiedAt, byteCount: entry.size, isDirectory: entry.isDirectory), prefix: "vault.mac.item")
        if path == nil {
            var content = cell.defaultContentConfiguration()
            content.text = entry.name; content.secondaryText = entry.path
            content.image = UIImage(systemName: entry.path == "/" || entry.path == "/Volumes" ? "internaldrive" : "folder.fill")
            content.imageProperties.tintColor = .tintColor
            cell.contentConfiguration = content
        }
        return cell
    }
    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard emptyStateConfiguration == nil else { return }
        if indexPath.row == entries.count { if !loading { load(more: true) }; return }
        let entry = entries[indexPath.row]
        if entry.isDirectory { openFolder(entry.path) } else { openHandler?(entry.path) }
    }
    private func openFolder(_ path: String) {
        navigationController?.pushViewController(VaultMacBrowseViewController(runtime: runtime, path: path,
            showHidden: showHidden, openHandler: openHandler), animated: true)
    }
}

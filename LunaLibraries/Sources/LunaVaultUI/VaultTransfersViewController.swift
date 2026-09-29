import UIKit

/// Upload activity has its own screen so progress never displaces file rows.
public final class VaultTransfersViewController: UITableViewController {
    private let runtime: any VaultPresentationProviding
    private var items: [VaultPendingUpload] = []
    private var queued = 0
    private var connected = false
    private var loaded = false
    private var errorMessage: String?
    private var task: Task<Void, Never>?
    public init(runtime: any VaultPresentationProviding) { self.runtime = runtime; super.init(style: .insetGrouped) }
    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { task?.cancel() }
    public override func viewDidLoad() {
        super.viewDidLoad()
        title = "Transfers"
        tableView.accessibilityIdentifier = "vault.transfers.list"
        tableView.register(VaultPendingUploadCell.self, forCellReuseIdentifier: "upload")
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 110
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(retry), for: .valueChanged)
    }
    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }
    public override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); task?.cancel() }
    @objc private func retry() {
        Task { [weak self, runtime] in await runtime.refresh(); await self?.refresh(); self?.refreshControl?.endRefreshing() }
    }
    private func refresh() async {
        do {
            let pending = try await runtime.pendingUploads()
            let queue = try await runtime.queuedImportCount()
            let online = await runtime.connectionStatus() == .connected
            guard !Task.isCancelled else { return }
            let sameRows = loaded && errorMessage == nil && queued == queue && connected == online &&
                pending.map(\.name) == items.map(\.name) &&
                zip(pending, items).allSatisfy { $0.isDeleting == $1.isDeleting && $0.isDirectory == $1.isDirectory }
            items = pending; queued = queue; connected = online; loaded = true; errorMessage = nil
            if sameRows {
                for path in tableView.indexPathsForVisibleRows ?? [] where items.indices.contains(path.row) {
                    if let cell = tableView.cellForRow(at: path) as? VaultPendingUploadCell { configure(cell, item: items[path.row]) }
                }
            } else { tableView.reloadData() }
        } catch {
            guard !Task.isCancelled else { return }
            loaded = true; errorMessage = error.localizedDescription; tableView.reloadData()
        }
    }
    public override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { items.isEmpty ? nil : "To Vault on your Mac" }
    public override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        items.isEmpty && queued == 0 ? nil : connected ? "Uploads finish when your Mac confirms they are saved." : "Waiting for your Mac. Queued files will resume when it reconnects."
    }
    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        errorMessage != nil ? 1 : max(1, items.count + (queued > 0 ? 1 : 0))
    }
    public override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if errorMessage != nil || (items.isEmpty && queued == 0) {
            var empty = loaded ? UIContentUnavailableConfiguration.empty() : .loading()
            if loaded {
                empty.image = UIImage(systemName: errorMessage == nil ? "checkmark.circle" : "exclamationmark.arrow.triangle.2.circlepath")
                empty.text = errorMessage == nil ? "No Transfers" : "Couldn’t Load Transfers"
                empty.secondaryText = errorMessage ?? "Files you add will appear here while they upload to your Mac’s Vault folder."
            }
            return vaultEmptyCell(configuration: empty, minimumHeight: 340)
        }
        if indexPath.row == items.count {
            let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
            var content = cell.defaultContentConfiguration()
            content.text = "\(queued) file\(queued == 1 ? "" : "s") queued"
            content.secondaryText = "Preparing to send to your Mac"
            content.image = UIImage(systemName: "tray.full")
            cell.contentConfiguration = content; cell.selectionStyle = .none
            return cell
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: "upload", for: indexPath) as! VaultPendingUploadCell
        configure(cell, item: items[indexPath.row]); return cell
    }
    private func configure(_ cell: VaultPendingUploadCell, item: VaultPendingUpload) {
        cell.configure(item, connected: connected) { [weak self] in self?.cancel(item) }
    }
    private func cancel(_ item: VaultPendingUpload) {
        guard !item.isDeleting else { return }
        let alert = UIAlertController(title: "Cancel \((item.name as NSString).lastPathComponent)?",
            message: "Vault will stop this transfer and delete its local copy. If the Mac already saved it, Vault will remove that copy too.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Keep", style: .cancel))
        alert.addAction(UIAlertAction(title: "Cancel and Delete", style: .destructive) { [weak self, runtime] _ in
            Task {
                do { try await runtime.cancelPendingUpload(named: item.name); await self?.refresh() }
                catch {
                    let failed = UIAlertController(title: "Couldn’t Cancel Transfer", message: error.localizedDescription, preferredStyle: .alert)
                    failed.addAction(UIAlertAction(title: "OK", style: .default)); self?.present(failed, animated: true)
                }
            }
        })
        present(alert, animated: true)
    }
}

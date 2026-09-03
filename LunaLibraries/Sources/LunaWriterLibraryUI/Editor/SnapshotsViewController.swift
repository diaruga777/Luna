import UIKit
import LunaDesignSystem
import LunaModels
import LunaWriterModels
import LunaWriterStorage

/// Lists a sheet's kept snapshots, newest first, with a preview and Restore.
/// Restoring first snapshots the CURRENT text — so restoring never loses the
/// version you restored from — then writes the old text back.
public final class SnapshotsViewController: UITableViewController {

    private let snapshotStore: DocumentSnapshotStoring
    private let textStore: DocumentTextStoring
    private var document: WriterDocument
    private var snapshots: [DocumentSnapshot] = []

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    public init(snapshotStore: DocumentSnapshotStoring, textStore: DocumentTextStoring, document: WriterDocument) {
        self.snapshotStore = snapshotStore
        self.textStore = textStore
        self.document = document
        super.init(style: .plain)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.string("WriterLibrary_snapshots_title")
        tableView.backgroundColor = LunaColors.background
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: L10n.string("Common_done"), style: .done, target: self, action: #selector(doneTapped))
        reload()
    }

    @objc private func doneTapped() { dismiss(animated: true) }

    public func reload() {
        snapshots = ((try? snapshotStore.snapshots(for: document.id)) ?? []).sorted { $0.createdAt > $1.createdAt }
        tableView.reloadData()
    }

    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        snapshots.isEmpty ? 1 : snapshots.count
    }

    public override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        guard !snapshots.isEmpty else {
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.textLabel?.text = L10n.string("WriterLibrary_snapshots_emptyRow")
            cell.textLabel?.textColor = LunaColors.secondaryText
            cell.selectionStyle = .none
            return cell
        }
        let snapshot = snapshots[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = Self.formatter.string(from: snapshot.createdAt)
        cell.detailTextLabel?.text = String(snapshot.text.prefix(120))
        cell.detailTextLabel?.textColor = LunaColors.secondaryText
        cell.detailTextLabel?.numberOfLines = 2
        cell.backgroundColor = LunaColors.secondaryBackground
        return cell
    }

    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.row < snapshots.count else { return }
        presentRestoreConfirmation(for: snapshots[indexPath.row])
    }

    private func presentRestoreConfirmation(for snapshot: DocumentSnapshot) {
        let alert = UIAlertController(
            title: L10n.string("WriterLibrary_snapshots_restoreConfirmTitle"),
            message: Self.formatter.string(from: snapshot.createdAt), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.string("Common_cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.string("WriterLibrary_snapshots_restoreAction"), style: .default) {
            [weak self] _ in self?.restore(snapshot)
        })
        present(alert, animated: true)
    }

    /// Snapshots the current text, then writes the chosen snapshot's text
    /// back through `DocumentTextStoring`.
    @discardableResult
    public func restore(_ snapshot: DocumentSnapshot) -> Bool {
        guard let currentText = try? textStore.loadText(document) else { return false }
        guard (try? snapshotStore.recordSnapshot(currentText, for: document.id)) != nil else { return false }
        guard (try? textStore.saveText(snapshot.text, for: &document)) != nil else { return false }
        reload()
        return true
    }
}

import LunaModels
import LunaPluginKit
import UIKit

/// Multi-selection exports only source text, never plugin settings or credentials.
final class PluginBundleExportViewController: UITableViewController {
    private let catalog: PluginCatalogProviding
    private let listings: [PluginListing]
    private var selected: Set<String>

    init(catalog: PluginCatalogProviding) {
        self.catalog = catalog
        listings = catalog.managementListings()
        selected = Set(listings.map { $0.summary.id })
        super.init(style: .insetGrouped)
        title = L10n.string("PluginBundles_exportTitle")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .action, primaryAction: UIAction { [weak self] _ in self?.exportBundle() })
        navigationItem.rightBarButtonItem?.isEnabled = !selected.isEmpty
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { listings.count }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        L10n.string("PluginBundles_exportDescription")
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let summary = listings[indexPath.row].summary
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = summary.name
        cell.detailTextLabel?.text = summary.version
        cell.accessoryType = selected.contains(summary.id) ? .checkmark : .none
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let id = listings[indexPath.row].summary.id
        if !selected.insert(id).inserted { selected.remove(id) }
        tableView.reloadRows(at: [indexPath], with: .none)
        navigationItem.rightBarButtonItem?.isEnabled = !selected.isEmpty
    }
    private func exportBundle() {
        var directory: URL?
        do {
            let sources = try listings.filter { selected.contains($0.summary.id) }.map { listing -> String in
                guard let source = catalog.sourceText(pluginID: listing.summary.id) else {
                    throw PluginBundleArchive.ArchiveError.invalid("source for \(listing.summary.name) is unavailable.")
                }
                return source
            }
            let data = try PluginBundleArchive.data(sources: sources)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            directory = folder
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("Luna-Plugins.lunabundle")
            try data.write(to: url, options: .atomic)
            let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            sheet.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: folder) }
            sheet.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
            present(sheet, animated: true)
        } catch {
            if let directory { try? FileManager.default.removeItem(at: directory) }
            let alert = UIAlertController(title: L10n.string("PluginBundles_exportFailed"), message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: L10n.string("Common_ok"), style: .default))
            present(alert, animated: true)
        }
    }
}

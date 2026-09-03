//
//  PluginsSettingsScreen.swift
//  LunaPluginUI
//
//  Settings → Plugins (§11.2): every installed plugin, bundled or imported,
//  with its status; an Add button that offers Files or paste import.
//

import LunaDesignSystem
import LunaModels
import LunaPluginIngest
import LunaPluginKit
import UIKit

public final class PluginsSettingsScreen: NavHeaderTableController {

    private enum Section: Int, CaseIterable { case installed }

    private let catalog: PluginCatalogProviding
    private let settingsStore: PluginSettingsStoring
    private let invoker: PluginHookInvoking?
    private lazy var importCoordinator: PluginImportCoordinator? = importer.map {
        let coordinator = PluginImportCoordinator(importer: $0)
        coordinator.observer = self
        return coordinator
    }
    private let importer: PluginImporting?

    private var listings: [PluginListing] = []

    public init(
        catalog: PluginCatalogProviding,
        importer: PluginImporting?,
        settingsStore: PluginSettingsStoring,
        invoker: PluginHookInvoking?
    ) {
        self.catalog = catalog
        self.importer = importer
        self.settingsStore = settingsStore
        self.invoker = invoker
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    public override func viewDidLoad() {
        headerTitle = L10n.string("Common_plugins")
        super.viewDidLoad()
        _ = importCoordinator
        reload()
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    public override func makeTrailingControls() -> [UIView] {
        guard importer != nil else { return [] }
        return [
            NavHeaderBar.imageButton(
                systemName: "wand.and.stars", target: self, action: #selector(createTapped),
                accessibilityLabel: L10n.string("Plugins_recoveryCreateForWebsite")),
            NavHeaderBar.imageButton(
                systemName: "plus", target: self, action: #selector(addTapped),
                accessibilityLabel: L10n.string("Plugins_importTitle")),
        ]
    }

    private func reload() {
        listings = catalog.listings()
        tableView.reloadData()
    }

    @objc private func addTapped() {
        importCoordinator?.begin(from: self, sourceView: header)
    }

    @objc private func createTapped() {
        let alert = UIAlertController(
            title: L10n.string("Plugins_recoveryURLTitle"),
            message: L10n.string("Plugins_recoveryURLMessage"), preferredStyle: .alert)
        alert.addTextField {
            $0.placeholder = "https://example.com/article"
            $0.keyboardType = .URL
            $0.autocapitalizationType = .none
            $0.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: L10n.string("Common_cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.string("Common_continue"), style: .default) {
            [weak self, weak alert] _ in
            self?.probe(alert?.textFields?.first?.text ?? "")
        })
        present(alert, animated: true)
    }

    private func probe(_ value: String) {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host != nil else {
            reportRecoveryError(L10n.string("Plugins_recoveryInvalidURL"))
            return
        }
        let progress = UIAlertController(
            title: L10n.string("Plugins_recoveryProbing"), message: url.host,
            preferredStyle: .alert)
        present(progress, animated: true)
        Task { @MainActor [weak self, weak progress] in
            let result = await PluginRecoveryProbe.run(url: url)
            progress?.dismiss(animated: true) {
                guard let self, let importer = self.importer else { return }
                self.navigationController?.pushViewController(
                    PluginRecoveryWorkshopViewController(
                        recoveryCase: result.recoveryCase, importer: importer),
                    animated: true)
            }
        }
    }

    private func reportRecoveryError(_ message: String) {
        let alert = UIAlertController(
            title: L10n.string("Plugins_recoveryURLTitle"), message: message,
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.string("Common_ok"), style: .default))
        present(alert, animated: true)
    }

    // MARK: - Table

    public override func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        max(listings.count, 1)
    }

    public override func tableView(
        _ tableView: UITableView, titleForHeaderInSection section: Int
    ) -> String? {
        L10n.string("Plugins_installedSectionHeader")
    }

    public override func tableView(
        _ tableView: UITableView, titleForFooterInSection section: Int
    ) -> String? {
        L10n.string("Plugins_screenFooter")
    }

    public override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        guard !listings.isEmpty else { return emptyCell() }
        return row(for: listings[indexPath.row])
    }

    private func emptyCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        cell.textLabel?.text = L10n.string("Plugins_emptyRow")
        cell.textLabel?.textColor = LunaColors.secondaryText
        cell.textLabel?.numberOfLines = 0
        return cell
    }

    private func row(for listing: PluginListing) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.accessoryType = .disclosureIndicator
        cell.textLabel?.text = listing.summary.name
        cell.detailTextLabel?.numberOfLines = 0
        cell.detailTextLabel?.textColor = LunaColors.secondaryText
        cell.detailTextLabel?.text = detailLine(for: listing)
        return cell
    }

    /// The one-line summary: what it produces or exports to, its version, and
    /// its status if that status is not the quiet default.
    private func detailLine(for listing: PluginListing) -> String {
        let produces = listing.summary.export?.title
            ?? listing.summary.produces.map(PluginCapabilityCopy.sentence(for:)).joined(separator: ", ")
        var line = L10n.string("Plugins_rowVersionAndSummary", listing.summary.version, produces)
        if listing.status != .enabled {
            line += "\n" + PluginCapabilityCopy.sentence(for: listing.status)
        }
        return line
    }

    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.row < listings.count else { return }
        let screen = PluginDetailScreen(
            listing: listings[indexPath.row], catalog: catalog, settingsStore: settingsStore,
            invoker: invoker)
        navigationController?.pushViewController(screen, animated: true)
    }
}

extension PluginsSettingsScreen: PluginImportObserving {
    public func pluginImportDidFinish(_ coordinator: PluginImportCoordinator) {
        reload()
    }
}

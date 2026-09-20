//
//  PluginsSettingsScreen.swift
//  LunaPluginUI
//
//  Settings → Plugins (§11.2): every installed plugin, bundled or imported,
//  with its status; an Add button that offers Files or paste import.
//

import LunaDesignSystem
import LunaModels
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
    /// How this process opens a chat model. Nil hides the Create button: a
    /// surface that cannot open a provider has nothing to offer there.
    private let launcher: (any LLMLaunching)?

    private var listings: [PluginListing] = []

    public init(
        catalog: PluginCatalogProviding,
        importer: PluginImporting?,
        settingsStore: PluginSettingsStoring,
        invoker: PluginHookInvoking?,
        launcher: (any LLMLaunching)? = nil
    ) {
        self.catalog = catalog
        self.importer = importer
        self.settingsStore = settingsStore
        self.invoker = invoker
        self.launcher = launcher
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
        var controls: [UIView] = []
        if launcher != nil {
            controls.append(NavHeaderBar.imageButton(
                systemName: "wand.and.stars", target: self, action: #selector(createTapped),
                accessibilityLabel: L10n.string("Plugins_create1Title")))
        }
        controls.append(NavHeaderBar.imageButton(
            systemName: "plus", target: self, action: #selector(addTapped),
            accessibilityLabel: L10n.string("Plugins_importTitle")))
        return controls
    }

    private func reload() {
        listings = catalog.listings()
        tableView.reloadData()
    }

    @objc private func addTapped() {
        importCoordinator?.begin(from: self, sourceView: header)
    }

    @objc private func createTapped() {
        guard let launcher else { return }
        navigationController?.pushViewController(
            PluginCreateViewController(launcher: launcher), animated: true)
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

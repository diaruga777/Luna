//
//  WeeklyProposalsScreen.swift
//  Luna
//

import LunaDesignSystem
import LunaModels
import LunaWeekly
import UIKit

/// The curator's inbox: everything anyone has proposed as a Save of the Week.
///
/// Reachable only from Settings, and only on a device holding the signing key
/// (`SettingsViewController` appends the category conditionally). Promoting and
/// deleting both remove the proposal record — the queue only ever shrinks.
final class WeeklyProposalsScreen: NavHeaderTableController {
    private let refresher: WeeklySaveRefresher
    private var proposals: [WeeklyProposal] = []
    private var isLoading = true
    private var loadError: String?

    private let relativeDate: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    /// Defaulted to `nil` and resolved here: a default argument is evaluated in
    /// the caller's context, which is not the main actor even though this
    /// initializer is, and `WeeklySaveRefresher` is main-actor isolated.
    init(refresher: WeeklySaveRefresher? = nil) {
        self.refresher = refresher ?? .shared
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        headerTitle = L10n.string("Settings_weeklyProposals_title")
        super.viewDidLoad()
        tableView.accessibilityIdentifier = "settings.weeklyProposals"
        reload()
    }

    private func reload() {
        Task { @MainActor in
            do {
                proposals = try await refresher.fetchProposals()
                loadError = nil
            } catch {
                proposals = []
                loadError = error.localizedDescription
            }
            isLoading = false
            tableView.reloadData()
        }
    }

    // MARK: - Table

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        proposals.count
    }

    override func tableView(
        _ tableView: UITableView, titleForFooterInSection section: Int
    ) -> String? {
        if isLoading { return L10n.string("Settings_weeklyProposals_checkingFooter") }
        if let loadError { return loadError }
        return proposals.isEmpty ? L10n.string("Settings_weeklyProposals_emptyFooter") : nil
    }

    override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let proposal = proposals[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = Self.displayTitle(for: proposal)
        content.secondaryText = proposal.kind.rawValue.capitalized + " • "
            + relativeDate.localizedString(for: proposal.date, relativeTo: Date())
        content.textProperties.color = LunaColors.primaryText
        content.secondaryTextProperties.color = LunaColors.secondaryText
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard proposals.indices.contains(indexPath.row) else { return }
        let proposal = proposals[indexPath.row]
        let sheet = UIAlertController(
            title: Self.displayTitle(for: proposal),
            message: proposal.urlString,
            preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(
            title: L10n.string("Common_promote"), style: .default
        ) { [weak self] _ in self?.promote(proposal) })
        sheet.addAction(UIAlertAction(
            title: L10n.string("Common_delete"), style: .destructive
        ) { [weak self] _ in self?.delete(proposal) })
        sheet.addAction(UIAlertAction(title: L10n.string("Common_cancel"), style: .cancel))
        sheet.popoverPresentationController?.sourceView =
            tableView.cellForRow(at: indexPath) ?? tableView
        present(sheet, animated: true)
    }

    override func tableView(
        _ tableView: UITableView,
        commit editingStyle: UITableViewCell.EditingStyle,
        forRowAt indexPath: IndexPath
    ) {
        guard editingStyle == .delete, proposals.indices.contains(indexPath.row) else { return }
        delete(proposals[indexPath.row])
    }

    override func tableView(
        _ tableView: UITableView, canEditRowAt indexPath: IndexPath
    ) -> Bool { true }

    // MARK: - Actions

    private func promote(_ proposal: WeeklyProposal) {
        Task { @MainActor in
            do {
                try await refresher.promote(
                    kind: proposal.kind, urlString: proposal.urlString)
                // A promoted proposal has served its purpose.
                try? await refresher.deleteProposal(recordName: proposal.recordName)
                reload()
            } catch {
                presentInfoAlert(
                    title: L10n.string("Common_couldntPromote"),
                    message: error.localizedDescription)
            }
        }
    }

    private func delete(_ proposal: WeeklyProposal) {
        Task { @MainActor in
            do {
                try await refresher.deleteProposal(recordName: proposal.recordName)
                reload()
            } catch {
                presentInfoAlert(
                    title: L10n.string("Settings_weeklyProposals_deleteFailedTitle"),
                    message: error.localizedDescription)
            }
        }
    }

    /// Host plus path — enough to recognize a link without the scheme noise.
    static func displayTitle(for proposal: WeeklyProposal) -> String {
        guard let url = URL(string: proposal.urlString), let host = url.host
        else { return proposal.urlString }
        let path = url.path
        return path.isEmpty || path == "/" ? host : host + path
    }
}

//
//  PendingRequestsViewController.swift
//  LunaSocialUI
//

import LunaSocial
import LunaSaves
import LunaStorage
import LunaDesignSystem
import UIKit
import LunaModels

/// The moderation queue for Luna shares from people who aren't friends yet.
/// Accepting imports the article (and optionally adds the sender as a friend so
/// future shares auto-import). The originating mail was already marked read when
/// it was parsed, so accepting is purely a local decision.
public final class PendingRequestsViewController: NavHeaderTableController {

    private var requests: [PendingRequest] = PendingRequestsStore.shared.items()

    public init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func viewDidLoad() {
        headerTitle = L10n.string("Sharing_pendingRequests_screenTitle")
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        NotificationCenter.default.addObserver(
            self, selector: #selector(reload), name: .pendingRequestsChanged, object: nil)
    }

    @objc private func reload() {
        requests = PendingRequestsStore.shared.items()
        tableView.reloadData()
    }

    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        requests.count
    }

    public override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let request = requests[indexPath.row]
        var config = cell.defaultContentConfiguration()
        config.text = request.title ?? request.urlString
        config.secondaryText = "from \(request.displaySender)"
        config.image = UIImage(systemName: "envelope.badge")
        cell.contentConfiguration = config
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let request = requests[indexPath.row]
        let sheet = UIAlertController(
            title: request.title ?? request.urlString,
            message: L10n.string("Sharing_pendingRequests_sharedByMessage", request.displaySender),
            preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: L10n.string("Sharing_pendingRequests_action1AddAndImport"), style: .default) { [weak self] _ in
            FriendsStore.shared.add(email: request.senderEmail, name: request.senderName)
            self?.importAndRemove(request)
        })
        sheet.addAction(UIAlertAction(title: L10n.string("Sharing_pendingRequests_action2ImportOnce"), style: .default) { [weak self] _ in
            self?.importAndRemove(request)
        })
        sheet.addAction(UIAlertAction(title: L10n.string("Common_delete"), style: .destructive) { [weak self] _ in
            PendingRequestsStore.shared.remove(id: request.id)
            self?.reload()
        })
        sheet.addAction(UIAlertAction(title: L10n.string("Common_cancel"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = tableView.cellForRow(at: indexPath)
        present(sheet, animated: true)
    }

    private func importAndRemove(_ request: PendingRequest) {
        if let item = SavesStore.shared.addIfAbsent(urlString: request.urlString, source: .email) {
            SavesStore.shared.setIncomingSender(
                email: request.senderEmail, displayName: request.displaySender, for: item.id)
            Task { await SavesIngestor.shared.ingest(item) }
        }
        PendingRequestsStore.shared.remove(id: request.id)
        reload()
        if navigationController?.topViewController === self, requests.isEmpty {
            navigationController?.popViewController(animated: true)
        }
    }
}

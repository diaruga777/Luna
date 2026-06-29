//
//  BooxSettingsScreen.swift
//  Clip
//

import ClipReadingListUI
import ClipSend
import ClipDesignSystem
import UIKit

/// Send-to-Boox settings: region, an OTP login that stores the long-lived
/// token, the auto-send mode, and a test send. Mirrors the Kindle settings.
final class BooxSettingsScreen: NavHeaderTableController {

    private enum Section: Int, CaseIterable { case account, send }

    private let credentials = KeychainSendCredentialsStore.shared

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("not used") }

    private var isLoggedIn: Bool { !(credentials.booxToken() ?? "").isEmpty }

    override func viewDidLoad() {
        headerTitle = "Send to Boox"
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
    }

    override func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .account: return 2 // region, log in/out
        case .send: return 2    // mode, test send
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .account: return "Onyx Account"
        case .send: return "Send to Boox"
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .account:
            return "Boox sending uses Onyx's unofficial Send2Boox service. Log in with the email on your BOOX account; you'll get a code by email."
        case .send:
            return "Saves are uploaded to your Onyx account and your Boox device downloads them over WiFi."
        }
    }

    override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var content = cell.defaultContentConfiguration()
        cell.accessoryView = nil
        cell.accessoryType = .none
        cell.selectionStyle = .none

        switch Section(rawValue: indexPath.section)! {
        case .account:
            switch indexPath.row {
            case 0:
                content.text = "Region"
                let control = UISegmentedControl(
                    items: BooxSendSettings.Region.allCases.map(\.displayName))
                control.selectedSegmentIndex = BooxSendSettings.Region.allCases
                    .firstIndex(of: BooxSendSettings.region) ?? 0
                control.addTarget(self, action: #selector(regionChanged(_:)), for: .valueChanged)
                cell.accessoryView = control
            default:
                if isLoggedIn {
                    content.text = "Log Out"
                    content.secondaryText = BooxSendSettings.accountIdentity
                    content.textProperties.color = .systemRed
                } else {
                    content.text = "Log In to Boox"
                    content.textProperties.color = view.tintColor ?? .systemBlue
                    content.image = UIImage(systemName: "person.crop.circle")
                }
                cell.selectionStyle = .default
            }

        case .send:
            switch indexPath.row {
            case 0:
                content.text = "Boox Forwarding Settings"
                cell.accessoryType = .disclosureIndicator
                cell.selectionStyle = .default
            default:
                content.text = "Send Test to Boox"
                content.textProperties.color = view.tintColor ?? .systemBlue
                content.image = UIImage(systemName: "paperplane")
                cell.selectionStyle = .default
            }
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch (Section(rawValue: indexPath.section)!, indexPath.row) {
        case (.account, 1):
            isLoggedIn ? logOut() : startLogin()
        case (.send, 0):
            navigationController?.pushViewController(
                AutoSendBySourceScreen(
                    destinationID: ArticleDestinationID.boox, destinationName: "Boox"),
                animated: true)
        case (.send, 1):
            sendTest()
        default:
            break
        }
    }

    @objc private func regionChanged(_ control: UISegmentedControl) {
        let regions = BooxSendSettings.Region.allCases
        BooxSendSettings.region = regions[max(0, min(control.selectedSegmentIndex, regions.count - 1))]
    }

    // MARK: - Login (OTP)

    private func startLogin() {
        let alert = UIAlertController(
            title: "Log In to Boox",
            message: "Enter the email on your BOOX account. We'll send a verification code.",
            preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "you@example.com"
            field.keyboardType = .emailAddress
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.text = BooxSendSettings.accountIdentity
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Send Code", style: .default) { [weak self, weak alert] _ in
            let identity = (alert?.textFields?.first?.text ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !identity.isEmpty else { return }
            self?.requestCode(identity: identity)
        })
        present(alert, animated: true)
    }

    private func requestCode(identity: String) {
        Task { [weak self] in
            do {
                try await BooxAuthClient(host: BooxSendSettings.host).requestLoginCode(identity: identity)
                self?.promptForCode(identity: identity)
            } catch {
                self?.presentInfoAlert(title: "Couldn't Send Code", message: "\(error)")
            }
        }
    }

    private func promptForCode(identity: String) {
        let alert = UIAlertController(
            title: "Enter Code",
            message: "Enter the verification code emailed to \(identity).",
            preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "Code"
            field.keyboardType = .numberPad
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Log In", style: .default) { [weak self, weak alert] _ in
            let code = (alert?.textFields?.first?.text ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !code.isEmpty else { return }
            self?.completeLogin(identity: identity, code: code)
        })
        present(alert, animated: true)
    }

    private func completeLogin(identity: String, code: String) {
        Task { [weak self] in
            do {
                let token = try await BooxAuthClient(host: BooxSendSettings.host)
                    .login(identity: identity, code: code)
                self?.credentials.setBooxToken(token)
                BooxSendSettings.accountIdentity = identity
                self?.tableView.reloadData()
            } catch {
                self?.presentInfoAlert(title: "Login Failed", message: "\(error)")
            }
        }
    }

    private func logOut() {
        credentials.setBooxToken(nil)
        BooxSendSettings.accountIdentity = ""
        tableView.reloadData()
    }

    private func sendTest() {
        guard ArticleSendCoordinator.shared.isConfigured(destinationID: ArticleDestinationID.boox) else {
            presentInfoAlert(title: "Not Logged In", message: "Log in to Boox first.")
            return
        }
        Task { [weak self] in
            do {
                try await ArticleSendCoordinator.shared.sendTestDocument(
                    toDestinationID: ArticleDestinationID.boox)
                self?.presentInfoAlert(
                    title: "Test Sent",
                    message: "Check your Boox device after it syncs over WiFi.")
            } catch {
                self?.presentInfoAlert(title: "Test Failed", message: "\(error)")
            }
        }
    }
}

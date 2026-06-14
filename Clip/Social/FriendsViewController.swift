//
//  FriendsViewController.swift
//  Clip
//

import CoreImage
import UIKit

/// Friends home: your shareable QR code + editable cosmetic profile, the
/// friends list, and entry points for scanning and link-sharing.
final class FriendsViewController: UITableViewController, UITextFieldDelegate {

    private enum Section: Int, CaseIterable {
        case myCode
        case friends
        case scan
    }

    private enum MyCodeRow: Int, CaseIterable {
        case qr
        case username
        case email
        case phone
        case shareLink
    }

    private let identityStore: IdentityStoring = KeychainIdentityStore.shared
    private var friends: [Friend] = []
    private var qrImage: UIImage?
    /// Reused across cell rebuilds so profile edits can refresh the QR in
    /// place without reloading the section (which would steal field focus).
    private let qrImageView = UIImageView()
    private var unavailableReason: String?
    private var hasShownICloudAlert = false

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    init() {
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Friends"
        navigationItem.largeTitleDisplayMode = .never

        NotificationCenter.default.addObserver(
            self, selector: #selector(reload), name: .friendsListChanged, object: nil)
        regenerateQR()
        reload()
        refreshAvailability()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Confirm the iCloud requirement once per visit when unavailable.
        guard !hasShownICloudAlert else { return }
        hasShownICloudAlert = true
        Task { _ = await ICloudGate.requireICloud(presenting: self) }
    }

    @objc private func reload() {
        friends = FriendsStore.shared.items()
        tableView.reloadData()
    }

    private func refreshAvailability() {
        Task { [weak self] in
            let availability = await SocialMessageCenter.shared.availability()
            await MainActor.run {
                if case .unavailable(let reason) = availability {
                    self?.unavailableReason = reason
                } else {
                    self?.unavailableReason = nil
                }
                self?.tableView.reloadData()
            }
        }
    }

    private func regenerateQR() {
        guard let identity = identityStore.loadIdentity(),
              let url = FriendLink.url(for: identity.card)
        else {
            qrImage = nil
            return
        }
        qrImage = Self.qrCode(for: url.absoluteString)
    }

    /// Renders a crisp (nearest-neighbor upscaled) QR code for a string.
    static func qrCode(for text: String, sideLength: CGFloat = 220) -> UIImage? {
        let filter = CIFilter(name: "CIQRCodeGenerator")
        filter?.setValue(Data(text.utf8), forKey: "inputMessage")
        filter?.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter?.outputImage else { return nil }
        let scale = sideLength / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    // MARK: - Table structure

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .myCode: return MyCodeRow.allCases.count
        case .friends: return max(friends.count, 1)
        case .scan: return 1
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .myCode: return "My Code"
        case .friends: return "Friends"
        case .scan: return nil
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .myCode:
            var footer = "Friends scan this code (or open your link) to add you. Username, email, and phone are cosmetic and shared with friends."
            if let unavailableReason {
                footer = "⚠️ Sharing with friends requires iCloud. \(unavailableReason)\n\n" + footer
            }
            return footer
        case .friends:
            return "Adding is two-way: when someone adds you, you're added back automatically. Friends can send articles to your reading list."
        case .scan:
            return "You can also scan a Clip code with the system Camera app."
        }
    }

    // MARK: - Cells

    override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        let identity = identityStore.loadIdentity()

        switch Section(rawValue: indexPath.section)! {
        case .myCode:
            switch MyCodeRow(rawValue: indexPath.row)! {
            case .qr:
                qrImageView.image = qrImage
                qrImageView.contentMode = .center
                qrImageView.removeFromSuperview()
                qrImageView.translatesAutoresizingMaskIntoConstraints = false
                cell.contentView.addSubview(qrImageView)
                NSLayoutConstraint.activate([
                    qrImageView.centerXAnchor.constraint(equalTo: cell.contentView.centerXAnchor),
                    qrImageView.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 16),
                    qrImageView.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -16),
                    qrImageView.heightAnchor.constraint(equalToConstant: 220),
                    qrImageView.widthAnchor.constraint(equalToConstant: 220),
                ])
                cell.selectionStyle = .none
                return cell
            case .username:
                return makeProfileFieldCell(
                    label: "Username", text: identity?.username ?? "", field: .username)
            case .email:
                return makeProfileFieldCell(
                    label: "Email", text: identity?.email ?? "", field: .email)
            case .phone:
                return makeProfileFieldCell(
                    label: "Phone", text: identity?.phone ?? "", field: .phone)
            case .shareLink:
                content.text = "Share My Link"
                content.textProperties.color = view.tintColor ?? .systemBlue
                content.image = UIImage(systemName: "square.and.arrow.up")
            }

        case .friends:
            if friends.isEmpty {
                content.text = "No friends yet"
                content.textProperties.color = .secondaryLabel
                cell.selectionStyle = .none
            } else {
                let friend = friends[indexPath.row]
                content.text = friend.card.username
                var details = [dateFormatter.string(from: friend.dateAdded)]
                if let email = friend.card.email { details.append(email) }
                if let phone = friend.card.phone { details.append(phone) }
                let autoShared = ShareSuggestionStore.shared
                    .alwaysSharedBaseURLs(friendUUID: friend.card.uuid)
                if !autoShared.isEmpty {
                    details.append("auto-shares: \(autoShared.joined(separator: ", "))")
                }
                content.secondaryText = details.joined(separator: " · ")
                content.secondaryTextProperties.color = .secondaryLabel
                content.secondaryTextProperties.numberOfLines = 2
                content.image = UIImage(systemName: "person.circle")
                cell.accessoryType = .disclosureIndicator
            }

        case .scan:
            content.text = "Scan Friend Code"
            content.textProperties.color = view.tintColor ?? .systemBlue
            content.image = UIImage(systemName: "qrcode.viewfinder")
        }

        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Section(rawValue: indexPath.section)! {
        case .myCode:
            guard MyCodeRow(rawValue: indexPath.row) == .shareLink,
                  let identity = identityStore.loadIdentity(),
                  let url = FriendLink.url(for: identity.card)
            else { return }
            let activity = UIActivityViewController(
                activityItems: [url.absoluteString], applicationActivities: nil)
            activity.popoverPresentationController?.sourceView =
                tableView.cellForRow(at: indexPath) ?? view
            present(activity, animated: true)
        case .scan:
            let scanner = QRScannerViewController { [weak self] card in
                guard let self else { return }
                FriendAddFlow.confirmAndAdd(card: card, from: self)
            }
            present(scanner, animated: true)
        case .friends:
            guard !friends.isEmpty else { return }
            let detail = FriendDetailViewController(friend: friends[indexPath.row]) { [weak self] in
                self?.reload()
            }
            navigationController?.pushViewController(detail, animated: true)
        }
    }

    override func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard Section(rawValue: indexPath.section) == .friends, !friends.isEmpty else { return nil }
        let friend = friends[indexPath.row]
        let delete = UIContextualAction(style: .destructive, title: "Delete") { _, _, done in
            FriendsStore.shared.delete(uuid: friend.card.uuid)
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }

    // MARK: - Profile field editing

    private enum ProfileField: Int {
        case username = 1
        case email
        case phone
    }

    private func makeProfileFieldCell(
        label: String, text: String, field: ProfileField
    ) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)

        let nameLabel = UILabel()
        nameLabel.text = label
        nameLabel.font = .preferredFont(forTextStyle: .body)

        let textField = UITextField()
        textField.text = text
        textField.placeholder = field == .username ? "Required" : "Optional"
        textField.tag = field.rawValue
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.textAlignment = .right
        textField.textColor = .secondaryLabel
        textField.delegate = self
        textField.addTarget(self, action: #selector(profileFieldChanged(_:)), for: .editingChanged)
        textField.addTarget(self, action: #selector(profileFieldEnded(_:)), for: .editingDidEnd)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        textField.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(nameLabel)
        cell.contentView.addSubview(textField)
        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            nameLabel.centerYAnchor.constraint(equalTo: cell.contentView.centerYAnchor),
            textField.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 12),
            textField.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            textField.centerYAnchor.constraint(equalTo: cell.contentView.centerYAnchor),
            cell.contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        nameLabel.setContentHuggingPriority(.required, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        cell.selectionStyle = .none
        return cell
    }

    /// Hard-caps the username field while typing.
    func textField(
        _ textField: UITextField, shouldChangeCharactersIn range: NSRange,
        replacementString string: String
    ) -> Bool {
        guard ProfileField(rawValue: textField.tag) == .username else { return true }
        let current = (textField.text ?? "") as NSString
        let proposed = current.replacingCharacters(in: range, with: string)
        return proposed.count <= ProfileValidation.usernameMaxLength
    }

    @objc private func profileFieldChanged(_ textField: UITextField) {
        persistProfile(editedField: textField)
    }

    @objc private func profileFieldEnded(_ textField: UITextField) {
        persistProfile(editedField: textField)
        regenerateQR()
        qrImageView.image = qrImage
    }

    private func persistProfile(editedField: UITextField) {
        guard let identity = identityStore.loadIdentity() else { return }
        var username = identity.username
        var email = identity.email
        var phone = identity.phone
        let value = editedField.text ?? ""
        switch ProfileField(rawValue: editedField.tag) {
        case .username: username = value
        case .email: email = value
        case .phone: phone = value
        case nil: return
        }
        // Invalid usernames (empty/too long) simply aren't persisted.
        identityStore.updateProfile(username: username, email: email, phone: phone)
    }
}

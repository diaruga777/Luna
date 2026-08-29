import Foundation
import LunaVaultBackend
import LunaVaultModels
import LunaVaultSetup
import UIKit

public enum VaultICloudLocalState: Equatable, Sendable {
    case keptLocal
    case evictionRequested
    case evicting
    case evicted
    case unavailable
    case failed
}

/// The Vault settings root is intentionally a short, capability-oriented list.
/// It does not expose URL-app settings or a Share-extension key path.
public final class VaultSettingsViewController: UITableViewController {
    private enum Row: CaseIterable { case storage, cache, index, security, mac
        var title: String { switch self { case .storage: return "Storage"; case .cache: return "Cache"; case .index: return "Search index"; case .security: return "Security"; case .mac: return "Mac" } }
        var symbol: String { switch self { case .storage: return "internaldrive"; case .cache: return "archivebox"; case .index: return "magnifyingglass"; case .security: return "lock"; case .mac: return "desktopcomputer" } }
    }
    private let setupCoordinator: VaultSetupCoordinator?
    private let macCredentialStore: VaultMacKeychainCredentialStore?
    public init(setupCoordinator: VaultSetupCoordinator? = nil, macCredentialStore: VaultMacKeychainCredentialStore? = nil) {
        self.setupCoordinator = setupCoordinator
        self.macCredentialStore = macCredentialStore
        super.init(style: .insetGrouped)
        title = "Vault Settings"
    }
    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    public override func viewDidLoad() { super.viewDidLoad(); tableView.accessibilityIdentifier = "vault.settings.list"; tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell") }
    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { Row.allCases.count }
    public override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell { let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath); let row = Row.allCases[indexPath.row]; var content = cell.defaultContentConfiguration(); content.text = row.title; content.image = UIImage(systemName: row.symbol); cell.contentConfiguration = content; cell.accessoryType = .disclosureIndicator; cell.accessibilityIdentifier = "vault.settings.\(row.title.lowercased().replacingOccurrences(of: " ", with: "-"))"; return cell }
    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) { tableView.deselectRow(at: indexPath, animated: true); switch Row.allCases[indexPath.row] { case .storage: navigationController?.pushViewController(VaultStorageSettingsViewController(setupCoordinator: setupCoordinator), animated: true); case .cache: navigationController?.pushViewController(VaultCacheSettingsViewController(), animated: true); case .index: navigationController?.pushViewController(VaultIndexSettingsViewController(), animated: true); case .security: navigationController?.pushViewController(VaultSecuritySettingsViewController(), animated: true); case .mac: navigationController?.pushViewController(VaultMacPairingViewController(credentialStore: macCredentialStore), animated: true) } }
}

public final class VaultStorageSettingsViewController: UIViewController {
    public var onPolicyChanged: ((VaultStoragePolicy) -> Void)?
    /// The storage backend owns eviction. This UI callback only records the
    /// user's intent and renders the explicit in-progress state.
    public var onICloudEvictionRequested: (() -> Void)?
    public var icloudState: VaultICloudLocalState = .keptLocal { didSet { if isViewLoaded { renderState() } } }
    private let setupCoordinator: VaultSetupCoordinator?
    private let locationControl = UISegmentedControl(items: ["iPhone", "iCloud", "Mac"])
    private let keepLocal = UISwitch()
    private let evictionButton = UIButton(type: .system)
    private let status = UILabel()
    private var policy = VaultStoragePolicy(location: .device)
    public init(setupCoordinator: VaultSetupCoordinator? = nil) { self.setupCoordinator = setupCoordinator; super.init(nibName: nil, bundle: nil); title = "Storage" }
    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    public override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemBackground
        if let saved = setupCoordinator?.state.policy { policy = saved }
        locationControl.selectedSegmentIndex = [.device, .iCloud, .mac].firstIndex(of: policy.location) ?? 0; locationControl.addTarget(self, action: #selector(locationChanged), for: .valueChanged); locationControl.accessibilityIdentifier = "vault.storage.location"
        keepLocal.isOn = policy.keepLocalCopy; keepLocal.addTarget(self, action: #selector(keepLocalChanged), for: .valueChanged); keepLocal.accessibilityIdentifier = "vault.storage.keep-local"
        evictionButton.setTitle("Request local eviction", for: .normal); evictionButton.addTarget(self, action: #selector(requestEviction), for: .touchUpInside); evictionButton.accessibilityIdentifier = "vault.storage.evict"
        status.numberOfLines = 0; status.textColor = .secondaryLabel; status.accessibilityIdentifier = "vault.storage.status"
        let stack = UIStackView(arrangedSubviews: [heading("Where should Vault store encrypted files?"), locationControl, labeled("Keep a local iCloud copy", keepLocal), evictionButton, status]); stack.axis = .vertical; stack.spacing = 18; stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack); NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 22), stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -22), stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24)]); renderState()
    }
    @objc private func locationChanged() { let locations: [VaultStorageLocation] = [.device, .iCloud, .mac]; policy = VaultStoragePolicy(location: locations[max(0, min(2, locationControl.selectedSegmentIndex))], keepLocalCopy: keepLocal.isOn); persist() }
    @objc private func keepLocalChanged() { policy = VaultStoragePolicy(location: policy.location, keepLocalCopy: keepLocal.isOn); persist() }
    @objc private func requestEviction() { guard policy.location == .iCloud else { return }; icloudState = .evictionRequested; onICloudEvictionRequested?(); renderState() }
    private func persist() { _ = setupCoordinator?.updateStoragePolicy(policy); onPolicyChanged?(policy); renderState() }
    private func renderState() { let iCloud = policy.location == .iCloud; keepLocal.isEnabled = iCloud; evictionButton.isHidden = !iCloud; status.text = iCloud ? icloudMessage() : policy.location == .mac ? "Mac storage requires a paired, user-owned Mac." : "Files remain on this iPhone." }
    private func icloudMessage() -> String { switch icloudState { case .keptLocal: return keepLocal.isOn ? "iCloud is configured; this device keeps a working copy." : "iCloud is configured; local eviction may be requested per file."; case .evictionRequested: return "Eviction requested. Waiting for iCloud to confirm it."; case .evicting: return "iCloud is evicting the local working copy…"; case .evicted: return "The local working copy is evicted; iCloud remains canonical."; case .unavailable: return "iCloud is unavailable. No local fallback is being used."; case .failed: return "iCloud could not evict this copy. The local state is unchanged." } }
    private func heading(_ text: String) -> UILabel { let label = UILabel(); label.text = text; label.font = .preferredFont(forTextStyle: .headline); label.numberOfLines = 0; return label }
    private func labeled(_ text: String, _ control: UIView) -> UIView { let row = UIStackView(arrangedSubviews: [heading(text), UIView(), control]); row.axis = .horizontal; row.alignment = .center; return row }
}

public final class VaultCacheSettingsViewController: UIViewController {
    public var onClearCache: (() -> Void)?
    public override func viewDidLoad() { super.viewDidLoad(); title = "Cache"; view.backgroundColor = .systemBackground; let text = UILabel(); text.text = "Vault cache is local working data protected by iOS Data Protection. Pinned files are kept until you change their policy."; text.numberOfLines = 0; let button = UIButton(type: .system); button.setTitle("Clear unpinned cache", for: .normal); button.accessibilityIdentifier = "vault.cache.clear"; button.addAction(UIAction { [weak self] _ in self?.onClearCache?() }, for: .touchUpInside); let stack = UIStackView(arrangedSubviews: [text, button]); stack.axis = .vertical; stack.spacing = 18; stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack); NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 22), stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -22), stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24)]) }
}

public final class VaultIndexSettingsViewController: UIViewController {
    public override func viewDidLoad() { super.viewDidLoad(); title = "Search index"; view.backgroundColor = .systemBackground; let text = UILabel(); text.text = "Search is on-device. Filename, extracted text, OCR and transcripts stay in the local encrypted Vault index. Rebuilding is bounded and can be resumed."; text.numberOfLines = 0; let button = UIButton(type: .system); button.setTitle("Rebuild index", for: .normal); button.accessibilityIdentifier = "vault.index.rebuild"; let stack = UIStackView(arrangedSubviews: [text, button]); stack.axis = .vertical; stack.spacing = 18; stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack); NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 22), stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -22), stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24)]) }
}

public final class VaultSecuritySettingsViewController: UIViewController {
    public override func viewDidLoad() { super.viewDidLoad(); title = "Security"; view.backgroundColor = .systemBackground; let text = UILabel(); text.text = "The Vault root key is created once during first-run setup and loaded from Keychain thereafter. The Share extension never receives the root key."; text.numberOfLines = 0; let stack = UIStackView(arrangedSubviews: [text]); stack.axis = .vertical; stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack); NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 22), stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -22), stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24)]) }
}

/// Mac pairing UI. A capsule is imported/pasted locally, then the server
/// fingerprint is confirmed out of band before enrollment is prepared. The
/// protocol has no unauthenticated network enrollment endpoint: the prepared
/// enrollment is handed to the caller for a file/QR/capsule exchange.
public final class VaultMacPairingViewController: UIViewController {
    public var credentialStore: VaultMacKeychainCredentialStore?
    public var onEnrollmentPrepared: ((VaultMacPairingEnrollment) -> Void)?
    public var onCredentialSaved: ((VaultMacPairingCredential) -> Void)?
    public var onRevokeCredential: ((VaultMacPairingCredential) -> Void)?
    public var onUnpaired: (() -> Void)?
    private weak var presenter: UIViewController?
    private let capsuleField = UITextView()
    private let endpointField = UITextField()
    private let serverBindingField = UITextField()
    private let nonceField = UITextField()
    private let expiryField = UITextField()
    private let codeField = UITextField()
    private let status = UILabel()
    private let prepareButton = UIButton(type: .system)
    private let unpairButton = UIButton(type: .system)
    private var credential: VaultMacPairingCredential?

    public init(credentialStore: VaultMacKeychainCredentialStore? = nil) { self.credentialStore = credentialStore; super.init(nibName: nil, bundle: nil); title = "Mac" }
    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    public override func viewDidLoad() {
        super.viewDidLoad(); presenter = self; view.backgroundColor = .systemBackground
        capsuleField.font = .preferredFont(forTextStyle: .footnote); capsuleField.layer.borderColor = UIColor.separator.cgColor; capsuleField.layer.borderWidth = 1; capsuleField.layer.cornerRadius = 8; capsuleField.heightAnchor.constraint(equalToConstant: 110).isActive = true; capsuleField.accessibilityIdentifier = "vault.mac.capsule"
        configure(endpointField, placeholder: "tailscale:mac-name.ts.net:49200", id: "vault.mac.endpoint"); configure(serverBindingField, placeholder: "Server binding (base64)", id: "vault.mac.server-binding"); configure(nonceField, placeholder: "Offer nonce (base64)", id: "vault.mac.nonce"); configure(expiryField, placeholder: "Expiry (ISO-8601, optional)", id: "vault.mac.expiry"); configure(codeField, placeholder: "One-time code (base64)", id: "vault.mac.code")
        prepareButton.setTitle("Confirm fingerprint and prepare enrollment", for: .normal); prepareButton.addTarget(self, action: #selector(preparePairingTapped), for: .touchUpInside); prepareButton.accessibilityIdentifier = "vault.mac.prepare"
        unpairButton.setTitle("Revoke and unpair this Mac", for: .normal); unpairButton.setTitleColor(.systemRed, for: .normal); unpairButton.addTarget(self, action: #selector(unpair), for: .touchUpInside); unpairButton.accessibilityIdentifier = "vault.mac.unpair"
        status.numberOfLines = 0; status.textColor = .secondaryLabel; status.accessibilityIdentifier = "vault.mac.status"
        let heading = UILabel(); heading.text = "Pair a user-owned Mac"; heading.font = .preferredFont(forTextStyle: .headline); let instructions = UILabel(); instructions.text = "Import/paste the Mac's pairing capsule, or enter its validated offer fields. Compare the server fingerprint on the Mac before continuing. Prepared enrollment is exchanged out of band (file, QR or paste); Vault does not send setup material to an unauthenticated listener."; instructions.numberOfLines = 0; instructions.textColor = .secondaryLabel
        let stack = UIStackView(arrangedSubviews: [heading, instructions, capsuleField, endpointField, serverBindingField, nonceField, expiryField, codeField, prepareButton, unpairButton, status]); stack.axis = .vertical; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false; let scroll = UIScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false; scroll.addSubview(stack); NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 22), stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -22), stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 22), stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -22), stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -44), scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor), scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor)]); view.addSubview(scroll)
        credential = try? credentialStore?.load() ?? nil; if let credential { status.text = "Paired Mac fingerprint: \(credential.fingerprint)" }
    }
    private func configure(_ field: UITextField, placeholder: String, id: String) { field.placeholder = placeholder; field.borderStyle = .roundedRect; field.accessibilityIdentifier = id; field.autocorrectionType = .no; field.autocapitalizationType = .none }
    @objc private func preparePairingTapped() {
        do {
            let capsule = try decodeCapsule() ?? manualCapsule()
            let confirmer = VaultMacUIIdentityConfirmer(presenter: presenter)
            Task { [weak self] in
                guard let self else { return }
                do {
                    let result = try await VaultMacPairingClient.prepareEnrollment(capsule: capsule, identityConfirmer: confirmer)
                    try self.credentialStore?.save(result.credential); self.credential = result.credential; self.onEnrollmentPrepared?(result.enrollment); self.onCredentialSaved?(result.credential)
                    await MainActor.run { self.status.text = "Enrollment prepared. Exchange it with the Mac out of band, then keep this fingerprint: \(result.credential.fingerprint)." }
                } catch { await MainActor.run { self.status.text = "Pairing was not completed: \(error)." } }
            }
        } catch { status.text = "Invalid pairing capsule or offer: \(error)." }
    }
    @objc private func unpair() { guard let credential else { return }; if let revoked = try? credential.revoked(now: Date()) { onRevokeCredential?(revoked) }; try? credentialStore?.remove(); self.credential = nil; status.text = "Mac credential revoked locally and removed from this iPhone."; onUnpaired?() }
    private func decodeCapsule() throws -> VaultMacPairingCapsule? { let value = capsuleField.text.trimmingCharacters(in: .whitespacesAndNewlines); guard !value.isEmpty else { return nil }; let data = Data(base64Encoded: value) ?? Data(value.utf8); return try JSONDecoder().decode(VaultMacPairingCapsule.self, from: data) }
    private func manualCapsule() throws -> VaultMacPairingCapsule { let binding = endpointField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""; _ = try VaultMacEndpoint(binding: binding); guard let server = Data(base64Encoded: serverBindingField.text ?? ""), server.count == 32, let nonce = Data(base64Encoded: nonceField.text ?? ""), nonce.count == 32 else { throw VaultMacProtocolError.invalidChallenge }; let expiry = ISO8601DateFormatter().date(from: expiryField.text ?? "") ?? Date(timeIntervalSinceNow: 10 * 60); let offer = try VaultMacPairingOffer(pairingID: UUID(), serverBinding: server, endpointBinding: binding, nonce: nonce, expiresAt: expiry); let code = try VaultMacPairingSecret(base64Encoded: codeField.text ?? ""); return VaultMacPairingCapsule(offer: offer, oneTimeCode: code) }
}

private final class VaultMacUIIdentityConfirmer: VaultMacServerIdentityConfirming, @unchecked Sendable {
    weak var presenter: UIViewController?
    init(presenter: UIViewController?) { self.presenter = presenter }
    func confirm(fingerprint: String, endpointBinding: String) async throws -> VaultMacServerIdentityConfirmation? { await withCheckedContinuation { continuation in DispatchQueue.main.async { [weak self] in guard let self, let presenter = self.presenter else { continuation.resume(returning: nil); return }; let alert = UIAlertController(title: "Confirm your Mac", message: "Compare this fingerprint on both devices:\n\n\(fingerprint)\n\nEndpoint: \(endpointBinding)\n\nThis is an out-of-band confirmation.", preferredStyle: .alert); alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in continuation.resume(returning: nil) }); alert.addAction(UIAlertAction(title: "Fingerprints Match", style: .default) { _ in continuation.resume(returning: VaultMacServerIdentityConfirmation(fingerprint: fingerprint, endpointBinding: endpointBinding)) }); presenter.present(alert, animated: true) } } }
}

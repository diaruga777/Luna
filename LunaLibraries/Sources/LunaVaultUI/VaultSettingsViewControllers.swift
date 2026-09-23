import Foundation
import LunaVaultBackend
import LunaVaultModels
import LunaVaultSetup
import SafariServices
import UIKit

public enum VaultICloudLocalState: Equatable, Sendable {
    case keptLocal, evictionRequested, evicting, evicted, unavailable, failed

    /// Aggregates one eviction outcome per local object into the state
    /// reported for the whole local working copy. An empty list means no
    /// object was evictable at all. Any failure makes the whole request
    /// `.failed`; any still-`.pending` object keeps the aggregate
    /// `.evictionRequested` until every evictable object confirms eviction.
    public static func aggregating(_ outcomes: [Result<VaultEvictionOutcome, Error>]) -> VaultICloudLocalState {
        guard !outcomes.isEmpty else { return .unavailable }
        var sawEvicted = false
        var sawPending = false
        for outcome in outcomes {
            switch outcome {
            case .failure: return .failed
            case .success(.evicted): sawEvicted = true
            case .success(.pending): sawPending = true
            case .success(.notEvictable): break
            }
        }
        if sawPending { return .evictionRequested }
        return sawEvicted ? .evicted : .unavailable
    }
}

public enum VaultMacRemoteRevocationOutcome: Equatable, Sendable {
    case revokedRemotely
    case localOnly(reason: String)
}

/// Host-owned operations used by Settings. An absent backend operation is
/// shown as unavailable instead of being treated as success.
public struct VaultSettingsActions {
    public var storagePolicyChanged: ((VaultStoragePolicy) -> Void)?
    public var clearCache: (() async throws -> Void)?
    public var rebuildIndex: (() async throws -> Void)?
    public var requestICloudEviction: (() async -> VaultICloudLocalState)?
    public var wifiOnlyUploads: (() -> Bool)?
    public var setWifiOnlyUploads: ((Bool) -> Void)?
    /// Called after a child settings flow changes a provider/keychain input.
    /// The host uses this to replace its runtime and wake the new sync queue.
    public var reconfigureRuntime: (() -> Void)?
    public var enrollmentPrepared: ((VaultMacPairingEnrollment) -> Void)?
    public var credentialSaved: ((VaultMacPairingCredential) -> Void)?
    public var revokeMacCredential: ((VaultMacPairingCredential) async -> VaultMacRemoteRevocationOutcome)?
    public var credentialUnpaired: ((VaultMacRemoteRevocationOutcome) -> Void)?
    /// Present when the host embeds a Tailscale node. The Mac screen shows
    /// tailnet status and drives the interactive web-auth login through it.
    public var tailnet: (any VaultTailnetControlling)?

    public init(storagePolicyChanged: ((VaultStoragePolicy) -> Void)? = nil,
                clearCache: (() async throws -> Void)? = nil,
                rebuildIndex: (() async throws -> Void)? = nil,
                requestICloudEviction: (() async -> VaultICloudLocalState)? = nil,
                wifiOnlyUploads: (() -> Bool)? = nil,
                setWifiOnlyUploads: ((Bool) -> Void)? = nil,
                reconfigureRuntime: (() -> Void)? = nil,
                enrollmentPrepared: ((VaultMacPairingEnrollment) -> Void)? = nil,
                credentialSaved: ((VaultMacPairingCredential) -> Void)? = nil,
                revokeMacCredential: ((VaultMacPairingCredential) async -> VaultMacRemoteRevocationOutcome)? = nil,
                credentialUnpaired: ((VaultMacRemoteRevocationOutcome) -> Void)? = nil,
                tailnet: (any VaultTailnetControlling)? = nil) {
        self.storagePolicyChanged = storagePolicyChanged
        self.clearCache = clearCache
        self.rebuildIndex = rebuildIndex
        self.requestICloudEviction = requestICloudEviction
        self.wifiOnlyUploads = wifiOnlyUploads
        self.setWifiOnlyUploads = setWifiOnlyUploads
        self.reconfigureRuntime = reconfigureRuntime
        self.enrollmentPrepared = enrollmentPrepared
        self.credentialSaved = credentialSaved
        self.revokeMacCredential = revokeMacCredential
        self.credentialUnpaired = credentialUnpaired
        self.tailnet = tailnet
    }
}

public final class VaultSettingsViewController: UITableViewController {
    private enum Row: CaseIterable {
        case storage, cache, index, uploads, security, mac
        var title: String {
            switch self {
            case .storage: return "Storage"
            case .cache: return "Cache"
            case .index: return "Search index"
            case .uploads: return "Uploads"
            case .security: return "Security"
            case .mac: return "Mac"
            }
        }
        var symbol: String {
            switch self {
            case .storage: return "internaldrive"
            case .cache: return "archivebox"
            case .index: return "magnifyingglass"
            case .uploads: return "arrow.up.circle"
            case .security: return "lock"
            case .mac: return "desktopcomputer"
            }
        }
    }

    private let setupCoordinator: VaultSetupCoordinator?
    private let macCredentialStore: VaultMacKeychainCredentialStore?
    private let actions: VaultSettingsActions

    public init(setupCoordinator: VaultSetupCoordinator? = nil,
                macCredentialStore: VaultMacKeychainCredentialStore? = nil,
                actions: VaultSettingsActions = VaultSettingsActions()) {
        self.setupCoordinator = setupCoordinator
        self.macCredentialStore = macCredentialStore
        self.actions = actions
        super.init(style: .insetGrouped)
        title = "Vault Settings"
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        tableView.accessibilityIdentifier = "vault.settings.list"
        tableView.accessibilityLabel = "Vault settings"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
    }

    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        Row.allCases.count
    }

    public override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let row = Row.allCases[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = row.title
        content.image = UIImage(systemName: row.symbol)
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityIdentifier = "vault.settings.\(row.title.lowercased().replacingOccurrences(of: " ", with: "-"))"
        cell.accessibilityLabel = row.title
        return cell
    }

    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let controller: UIViewController
        switch Row.allCases[indexPath.row] {
        case .storage:
            let value = VaultStorageSettingsViewController(setupCoordinator: setupCoordinator)
            value.onPolicyChanged = { [actions] policy in
                actions.storagePolicyChanged?(policy)
                actions.reconfigureRuntime?()
            }
            value.onICloudEvictionRequested = actions.requestICloudEviction
            controller = value
        case .cache:
            controller = VaultCacheSettingsViewController(onClearCache: actions.clearCache)
        case .index:
            controller = VaultIndexSettingsViewController(onRebuildIndex: actions.rebuildIndex)
        case .uploads:
            controller = VaultUploadSettingsViewController(
                wifiOnly: actions.wifiOnlyUploads?() ?? true,
                onChange: actions.setWifiOnlyUploads)
        case .security:
            controller = VaultSecuritySettingsViewController()
        case .mac:
            let value = VaultMacPairingViewController(credentialStore: macCredentialStore)
            value.tailnet = actions.tailnet
            value.onTailnetChanged = actions.reconfigureRuntime
            value.onEnrollmentPrepared = actions.enrollmentPrepared
            value.onCredentialSaved = { [actions] credential in
                actions.credentialSaved?(credential)
                actions.reconfigureRuntime?()
            }
            value.onRevokeCredential = actions.revokeMacCredential
            value.onUnpaired = { [actions] outcome in
                actions.credentialUnpaired?(outcome)
                actions.reconfigureRuntime?()
            }
            controller = value
        }
        navigationController?.pushViewController(controller, animated: true)
    }
}

public final class VaultStorageSettingsViewController: UIViewController {
    public var onPolicyChanged: ((VaultStoragePolicy) -> Void)?
    public var onICloudEvictionRequested: (() async -> VaultICloudLocalState)?
    public var icloudState: VaultICloudLocalState = .keptLocal {
        didSet { if isViewLoaded { renderState() } }
    }
    private let setupCoordinator: VaultSetupCoordinator?
    private let locationControl = UISegmentedControl(items: ["iPhone", "Mac"])
    private let status = UILabel()
    private var policy = VaultStoragePolicy(location: .device)

    public init(setupCoordinator: VaultSetupCoordinator? = nil) {
        self.setupCoordinator = setupCoordinator
        super.init(nibName: nil, bundle: nil)
        title = "Storage"
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        if let saved = setupCoordinator?.state.policy {
            policy = saved.location == .iCloud
                ? VaultStoragePolicy(location: .device)
                : saved
            if saved.location == .iCloud { _ = setupCoordinator?.updateStoragePolicy(policy) }
        }
        locationControl.selectedSegmentIndex = policy.location == .mac ? 1 : 0
        locationControl.addTarget(self, action: #selector(locationChanged), for: .valueChanged)
        locationControl.accessibilityIdentifier = "vault.storage.location"
        locationControl.accessibilityLabel = "Storage location"
        status.numberOfLines = 0
        status.textColor = .secondaryLabel
        status.accessibilityIdentifier = "vault.storage.status"
        let stack = settingsStack([
            heading("Where should Vault store encrypted files?"), locationControl, status,
        ])
        view.addSubview(stack)
        pin(stack)
        renderState()
    }

    @objc private func locationChanged() {
        let locations: [VaultStorageLocation] = [.device, .mac]
        policy = VaultStoragePolicy(location: locations[max(0, min(1, locationControl.selectedSegmentIndex))])
        persist()
    }

    private func persist() {
        _ = setupCoordinator?.updateStoragePolicy(policy)
        onPolicyChanged?(policy)
        renderState()
    }

    private func renderState() {
        status.text = policy.location == .mac ? "Mac storage requires a paired, user-owned Mac."
            : "Files remain on this iPhone."
        status.accessibilityLabel = status.text
    }

    private func heading(_ text: String) -> UILabel {
        let label = UILabel(); label.text = text
        label.font = .preferredFont(forTextStyle: .headline); label.numberOfLines = 0
        return label
    }

}

public final class VaultCacheSettingsViewController: UIViewController {
    public var onClearCache: (() async throws -> Void)?
    private let status = UILabel()
    private let button = UIButton(type: .system)

    public init(onClearCache: (() async throws -> Void)? = nil) {
        self.onClearCache = onClearCache
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func viewDidLoad() {
        super.viewDidLoad(); title = "Cache"; view.backgroundColor = .systemBackground
        let text = UILabel()
        text.text = "Vault cache is local working data protected by iOS Data Protection. Pinned files are kept until you change their policy."
        text.numberOfLines = 0
        button.setTitle("Clear unpinned cache", for: .normal)
        button.accessibilityIdentifier = "vault.cache.clear"
        button.accessibilityLabel = "Clear unpinned Vault cache"
        button.addTarget(self, action: #selector(clearCache), for: .touchUpInside)
        status.numberOfLines = 0; status.textColor = .secondaryLabel
        status.accessibilityIdentifier = "vault.cache.status"
        let stack = settingsStack([text, button, status]); view.addSubview(stack); pin(stack)
    }

    @objc private func clearCache() {
        guard let onClearCache else { status.text = "Cache clearing is unavailable."; return }
        button.isEnabled = false; status.text = "Clearing unpinned cache…"
        Task { [weak self] in
            do {
                try await onClearCache()
                await MainActor.run { self?.status.text = "Unpinned cache cleared." }
            } catch {
                await MainActor.run { self?.status.text = "Cache could not be cleared: \(error)." }
            }
            await MainActor.run { self?.button.isEnabled = true }
        }
    }
}

public final class VaultIndexSettingsViewController: UIViewController {
    public var onRebuildIndex: (() async throws -> Void)?
    private let status = UILabel()
    private let button = UIButton(type: .system)

    public init(onRebuildIndex: (() async throws -> Void)? = nil) {
        self.onRebuildIndex = onRebuildIndex
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func viewDidLoad() {
        super.viewDidLoad(); title = "Search index"; view.backgroundColor = .systemBackground
        let text = UILabel()
        text.text = "Search is on-device. Filename, extracted text, OCR and transcripts stay in the local protected Vault index."
        text.numberOfLines = 0
        button.setTitle("Rebuild index", for: .normal)
        button.accessibilityIdentifier = "vault.index.rebuild"
        button.accessibilityLabel = "Rebuild Vault search index"
        button.addTarget(self, action: #selector(rebuildIndex), for: .touchUpInside)
        status.numberOfLines = 0; status.textColor = .secondaryLabel
        status.accessibilityIdentifier = "vault.index.status"
        let stack = settingsStack([text, button, status]); view.addSubview(stack); pin(stack)
    }

    @objc private func rebuildIndex() {
        guard let onRebuildIndex else { status.text = "Index rebuilding is unavailable."; return }
        button.isEnabled = false; status.text = "Rebuilding the local index…"
        Task { [weak self] in
            do {
                try await onRebuildIndex()
                await MainActor.run { self?.status.text = "Index rebuilt." }
            } catch {
                await MainActor.run { self?.status.text = "Index rebuild failed: \(error)." }
            }
            await MainActor.run { self?.button.isEnabled = true }
        }
    }
}

public final class VaultUploadSettingsViewController: UIViewController {
    private let wifiOnlySwitch = UISwitch()
    private let onChange: ((Bool) -> Void)?

    public init(wifiOnly: Bool, onChange: ((Bool) -> Void)? = nil) {
        self.onChange = onChange
        super.init(nibName: nil, bundle: nil)
        title = "Uploads"
        wifiOnlySwitch.isOn = wifiOnly
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let heading = UILabel()
        heading.text = "Upload queued files only on Wi-Fi"
        heading.font = .preferredFont(forTextStyle: .headline)
        heading.numberOfLines = 0

        let explanation = UILabel()
        explanation.text = "Queued uploads wait for Wi-Fi when this is on. Downloads and other sync work can still use cellular."
        explanation.font = .preferredFont(forTextStyle: .body)
        explanation.textColor = .secondaryLabel
        explanation.numberOfLines = 0

        wifiOnlySwitch.accessibilityIdentifier = "vault.uploads.wifi-only"
        wifiOnlySwitch.accessibilityLabel = "Upload queued files only on Wi-Fi"
        wifiOnlySwitch.addTarget(self, action: #selector(valueChanged), for: .valueChanged)

        let row = UIStackView(arrangedSubviews: [heading, wifiOnlySwitch])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 16
        let stack = settingsStack([row, explanation])
        view.addSubview(stack)
        pin(stack)
    }

    @objc private func valueChanged() {
        onChange?(wifiOnlySwitch.isOn)
    }
}

public final class VaultSecuritySettingsViewController: UIViewController {
    public override func viewDidLoad() {
        super.viewDidLoad(); title = "Security"; view.backgroundColor = .systemBackground
        let text = UILabel()
        text.text = "The Vault root key is created once during first-run setup and loaded from Keychain thereafter. The Share extension never receives the root key."
        text.numberOfLines = 0
        let stack = settingsStack([text]); view.addSubview(stack); pin(stack)
    }
}

public struct VaultMacManualPairingInput: Equatable, Sendable {
    public let pairingID: String
    public let endpointBinding: String
    public let serverBindingBase64: String
    public let nonceBase64: String
    public let expiresAtISO8601: String
    public let oneTimeCodeBase64: String

    public init(pairingID: String, endpointBinding: String,
                serverBindingBase64: String, nonceBase64: String,
                expiresAtISO8601: String, oneTimeCodeBase64: String) {
        self.pairingID = pairingID; self.endpointBinding = endpointBinding
        self.serverBindingBase64 = serverBindingBase64; self.nonceBase64 = nonceBase64
        self.expiresAtISO8601 = expiresAtISO8601; self.oneTimeCodeBase64 = oneTimeCodeBase64
    }

    public func capsule(now: Date = Date()) throws -> VaultMacPairingCapsule {
        let rawID = pairingID.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = endpointBinding.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawExpiry = expiresAtISO8601.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = UUID(uuidString: rawID), !rawID.isEmpty,
              !rawExpiry.isEmpty, let expiry = Self.parseExpiry(rawExpiry),
              now < expiry, expiry.timeIntervalSince(now) <= 15 * 60,
              let server = Data(base64Encoded: serverBindingBase64.trimmingCharacters(in: .whitespacesAndNewlines)), server.count == 32,
              let nonce = Data(base64Encoded: nonceBase64.trimmingCharacters(in: .whitespacesAndNewlines)), nonce.count == 32 else {
            if let expiry = Self.parseExpiry(rawExpiry), expiry <= now {
                throw VaultMacProtocolError.expired
            }
            throw VaultMacProtocolError.invalidChallenge
        }
        _ = try VaultMacEndpoint(binding: endpoint)
        let offer = try VaultMacPairingOffer(pairingID: id, serverBinding: server,
            endpointBinding: endpoint, nonce: nonce, expiresAt: expiry)
        let code = try VaultMacPairingSecret(base64Encoded:
            oneTimeCodeBase64.trimmingCharacters(in: .whitespacesAndNewlines))
        return VaultMacPairingCapsule(offer: offer, oneTimeCode: code)
    }

    private static func parseExpiry(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }
}

/// Pairing remains a capsule/file exchange. The prepared enrollment is shown
/// for copy, share, or file export after explicit fingerprint confirmation.
public final class VaultMacPairingViewController: UIViewController, SFSafariViewControllerDelegate,
    UIDocumentPickerDelegate {
    public var credentialStore: VaultMacKeychainCredentialStore?
    public var onEnrollmentPrepared: ((VaultMacPairingEnrollment) -> Void)?
    public var onCredentialSaved: ((VaultMacPairingCredential) -> Void)?
    public var onRevokeCredential: ((VaultMacPairingCredential) async -> VaultMacRemoteRevocationOutcome)?
    public var onUnpaired: ((VaultMacRemoteRevocationOutcome) -> Void)?
    public var tailnet: (any VaultTailnetControlling)?
    public var onTailnetChanged: (() -> Void)?
    private let tailnetHeading = UILabel()
    private let tailnetInstructions = UILabel()
    private let tailnetStatus = UILabel()
    private let connectTailnetButton = UIButton(type: .system)
    private let disconnectTailnetButton = UIButton(type: .system)
    private var tailnetLoginTask: Task<Void, Never>?
    private weak var tailnetLoginBrowser: SFSafariViewController?
    private let capsuleField = UITextView()
    private let pairingIDField = UITextField()
    private let endpointField = UITextField()
    private let serverBindingField = UITextField()
    private let nonceField = UITextField()
    private let expiryField = UITextField()
    private let codeField = UITextField()
    private let enrollmentOutput = UITextView()
    private let outputButtons = UIStackView()
    private let status = UILabel()
    private let prepareButton = UIButton(type: .system)
    private let unpairButton = UIButton(type: .system)
    private var credential: VaultMacPairingCredential?
    private var enrollmentData: Data?
    /// The one-use enrollment secret's temporary export file. It is deleted
    /// as soon as the picker reports either outcome; it must never be left
    /// behind in the app's shared temporary directory.
    private var pendingExportURL: URL?

    public init(credentialStore: VaultMacKeychainCredentialStore? = nil) {
        self.credentialStore = credentialStore
        super.init(nibName: nil, bundle: nil); title = "Mac"
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemBackground
        capsuleField.font = .preferredFont(forTextStyle: .footnote)
        capsuleField.layer.borderColor = UIColor.separator.cgColor
        // `CGColor` is resolved once and does not follow later trait
        // changes on its own; re-resolve on every user-interface-style
        // change so the border does not go stale after an appearance
        // switch (Vault does not yet adopt the app-wide LunaSky appearance
        // system, so this re-resolves against the plain system trait).
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
            (self: VaultMacPairingViewController, _: UITraitCollection) in
            self.capsuleField.layer.borderColor = UIColor.separator.cgColor
        }
        capsuleField.layer.borderWidth = 1; capsuleField.layer.cornerRadius = 8
        capsuleField.heightAnchor.constraint(equalToConstant: 110).isActive = true
        capsuleField.accessibilityIdentifier = "vault.mac.capsule"
        capsuleField.accessibilityLabel = "Pairing capsule JSON or base64"
        configure(pairingIDField, label: "Pairing ID", id: "vault.mac.pairing-id")
        configure(endpointField, label: "Endpoint", id: "vault.mac.endpoint")
        configure(serverBindingField, label: "Server binding, base64", id: "vault.mac.server-binding")
        configure(nonceField, label: "Offer nonce, base64", id: "vault.mac.nonce")
        configure(expiryField, label: "Expiry, ISO 8601", id: "vault.mac.expiry")
        configure(codeField, label: "One-time code, base64", id: "vault.mac.code")
        prepareButton.setTitle("Confirm fingerprint and prepare enrollment", for: .normal)
        prepareButton.addTarget(self, action: #selector(preparePairingTapped), for: .touchUpInside)
        prepareButton.accessibilityIdentifier = "vault.mac.prepare"
        prepareButton.accessibilityLabel = "Confirm Mac fingerprint and prepare enrollment"
        unpairButton.setTitle("Revoke and unpair this Mac", for: .normal)
        unpairButton.setTitleColor(.systemRed, for: .normal)
        unpairButton.addTarget(self, action: #selector(unpair), for: .touchUpInside)
        unpairButton.accessibilityIdentifier = "vault.mac.unpair"
        unpairButton.accessibilityLabel = "Revoke and unpair this Mac"
        configureEnrollmentOutput()
        status.numberOfLines = 0; status.textColor = .secondaryLabel
        status.accessibilityIdentifier = "vault.mac.status"
        let heading = UILabel(); heading.text = "Pair a user-owned Mac"
        heading.font = .preferredFont(forTextStyle: .headline)
        let instructions = UILabel()
        instructions.text = "Paste the Mac's capsule, or enter every offer field exactly. Compare the fingerprint on both devices. Enrollment is exchanged out of band by file, copy, or share; Vault never sends it to an unauthenticated listener."
        instructions.numberOfLines = 0; instructions.textColor = .secondaryLabel
        configureTailnetSection()
        let stack = UIStackView(arrangedSubviews: [
            tailnetHeading, tailnetInstructions, tailnetStatus,
            connectTailnetButton, disconnectTailnetButton,
            heading, instructions, fieldLabel("Pairing capsule (JSON or base64)"), capsuleField,
            labeledField("Pairing ID", pairingIDField), labeledField("Endpoint", endpointField),
            labeledField("Server binding (base64)", serverBindingField),
            labeledField("Offer nonce (base64)", nonceField),
            labeledField("Expiry (ISO 8601)", expiryField),
            labeledField("One-time code (base64)", codeField),
            prepareButton, enrollmentOutput, outputButtons, unpairButton, status,
        ])
        stack.axis = .vertical; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.accessibilityIdentifier = "vault.mac.form"; scroll.addSubview(stack); view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -22),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -44),
        ])
        do {
            credential = try credentialStore?.load()
            if let credential { status.text = "Paired Mac fingerprint: \(credential.fingerprint)" }
        } catch { status.text = "The saved Mac credential could not be loaded: \(error)." }
    }

    private func configureTailnetSection() {
        tailnetHeading.text = "Tailscale routing"
        tailnetHeading.font = .preferredFont(forTextStyle: .headline)
        tailnetInstructions.text = "Vault reaches the Mac companion over its own embedded Tailscale connection. Connect once with your Tailscale account; pairing below stays separate and still authenticates the Mac."
        tailnetInstructions.numberOfLines = 0
        tailnetInstructions.textColor = .secondaryLabel
        tailnetStatus.numberOfLines = 0
        tailnetStatus.textColor = .secondaryLabel
        tailnetStatus.accessibilityIdentifier = "vault.mac.tailnet.status"
        connectTailnetButton.setTitle("Connect Tailscale…", for: .normal)
        connectTailnetButton.addTarget(self, action: #selector(connectTailnet), for: .touchUpInside)
        connectTailnetButton.accessibilityIdentifier = "vault.mac.tailnet.connect"
        connectTailnetButton.accessibilityLabel = "Connect Tailscale"
        disconnectTailnetButton.setTitle("Log out of Tailscale", for: .normal)
        disconnectTailnetButton.setTitleColor(.systemRed, for: .normal)
        disconnectTailnetButton.addTarget(self, action: #selector(disconnectTailnet), for: .touchUpInside)
        disconnectTailnetButton.accessibilityIdentifier = "vault.mac.tailnet.disconnect"
        disconnectTailnetButton.accessibilityLabel = "Log out of Tailscale"
        let hidden = tailnet == nil
        for view in [tailnetHeading, tailnetInstructions, tailnetStatus,
                     connectTailnetButton, disconnectTailnetButton] {
            view.isHidden = hidden
        }
        guard !hidden else { return }
        renderTailnet(nil)
        refreshTailnetStatus()
    }

    private func refreshTailnetStatus() {
        guard let tailnet else { return }
        Task { [weak self] in
            let summary = await tailnet.statusSummary()
            await MainActor.run { self?.renderTailnet(summary) }
        }
    }

    private func renderTailnet(_ summary: VaultTailnetStatusSummary?) {
        switch summary?.backend {
        case .running:
            let name = summary?.dnsName ?? summary?.ipv4 ?? "an unknown address"
            let tailnetName = summary?.tailnetName.map { " on \($0)" } ?? ""
            tailnetStatus.text = "Connected as \(name)\(tailnetName)."
            connectTailnetButton.isHidden = true
            disconnectTailnetButton.isHidden = false
        case .starting, .stopped:
            tailnetStatus.text = "Tailscale is signed in and will connect when the Mac is used."
            connectTailnetButton.isHidden = true
            disconnectTailnetButton.isHidden = false
        default:
            tailnetStatus.text = "Not connected. Tailscale endpoints stay unreachable until you connect."
            connectTailnetButton.isHidden = false
            connectTailnetButton.isEnabled = true
            disconnectTailnetButton.isHidden = true
        }
    }

    @objc private func connectTailnet() {
        guard let tailnet else { return }
        connectTailnetButton.isEnabled = false
        tailnetStatus.text = "Contacting the Tailscale control plane…"
        tailnetLoginTask?.cancel()
        tailnetLoginTask = Task { [weak self] in
            do {
                for try await event in await tailnet.interactiveLoginEvents() {
                    await MainActor.run { self?.handleTailnetEvent(event) }
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.tailnetLoginBrowser?.dismiss(animated: true)
                    self.tailnetStatus.text = "Tailscale login was not completed: \(error)."
                    self.connectTailnetButton.isEnabled = true
                }
            }
        }
    }

    private func handleTailnetEvent(_ event: VaultTailnetAuthEvent) {
        switch event {
        case .browseToURL(let url):
            tailnetStatus.text = "Finish the Tailscale login in the browser sheet."
            let browser = SFSafariViewController(url: url)
            browser.delegate = self
            tailnetLoginBrowser = browser
            present(browser, animated: true)
        case .loginFinished:
            tailnetLoginBrowser?.dismiss(animated: true)
            tailnetStatus.text = "Login accepted. Waiting for the tailnet…"
        case .running(let summary):
            tailnetLoginBrowser?.dismiss(animated: true)
            renderTailnet(summary)
            onTailnetChanged?()
        }
    }

    /// The user closed the login sheet without the tailnet ever reporting
    /// `.running` — dismissed manually, or the login didn't propagate. Stop
    /// waiting on the in-flight login and let a fresh status query decide
    /// the real outcome, instead of leaving Connect disabled and the status
    /// text stuck on "Finish the Tailscale login…" until the screen is
    /// left and reopened.
    public func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        tailnetLoginTask?.cancel()
        tailnetLoginBrowser = nil
        connectTailnetButton.isEnabled = true
        refreshTailnetStatus()
    }

    @objc private func disconnectTailnet() {
        guard let tailnet else { return }
        disconnectTailnetButton.isEnabled = false
        Task { [weak self] in
            do {
                try await tailnet.logout()
                let summary = await tailnet.statusSummary()
                await MainActor.run {
                    guard let self else { return }
                    self.disconnectTailnetButton.isEnabled = true
                    self.renderTailnet(summary)
                    self.onTailnetChanged?()
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.disconnectTailnetButton.isEnabled = true
                    self.tailnetStatus.text = "Tailscale logout failed: \(error)."
                }
            }
        }
    }

    private func configureEnrollmentOutput() {
        enrollmentOutput.isEditable = false
        enrollmentOutput.font = .preferredFont(forTextStyle: .caption1)
        enrollmentOutput.backgroundColor = .secondarySystemBackground
        enrollmentOutput.layer.cornerRadius = 8
        enrollmentOutput.heightAnchor.constraint(equalToConstant: 120).isActive = true
        enrollmentOutput.accessibilityIdentifier = "vault.mac.enrollment-output"
        enrollmentOutput.accessibilityLabel = "Prepared enrollment JSON"
        enrollmentOutput.isHidden = true
        outputButtons.axis = .horizontal; outputButtons.distribution = .fillEqually
        outputButtons.spacing = 8; outputButtons.isHidden = true
        outputButtons.addArrangedSubview(actionButton("Copy", id: "vault.mac.enrollment.copy", action: #selector(copyEnrollment)))
        outputButtons.addArrangedSubview(actionButton("Share", id: "vault.mac.enrollment.share", action: #selector(shareEnrollment)))
        outputButtons.addArrangedSubview(actionButton("Export", id: "vault.mac.enrollment.export", action: #selector(exportEnrollment)))
    }

    @objc private func preparePairingTapped() {
        do {
            let capsule = try decodeCapsule() ?? manualInput().capsule()
            let confirmer = VaultMacUIIdentityConfirmer(presenter: self)
            prepareButton.isEnabled = false
            Task { [weak self] in
                guard let self else { return }
                do {
                    let result = try await VaultMacPairingClient.prepareEnrollment(
                        capsule: capsule, identityConfirmer: confirmer)
                    guard let credentialStore = self.credentialStore else { throw VaultMacProtocolError.unavailable }
                    try credentialStore.save(result.credential)
                    await MainActor.run {
                        self.credential = result.credential
                        self.onEnrollmentPrepared?(result.enrollment)
                        self.onCredentialSaved?(result.credential)
                        self.showEnrollment(result.enrollment)
                        self.status.text = "Enrollment prepared and the credential was saved. Exchange it with the Mac out of band, then keep fingerprint \(result.credential.fingerprint)."
                    }
                } catch { await MainActor.run { self.status.text = "Pairing was not completed: \(error)." } }
                await MainActor.run { self.prepareButton.isEnabled = true }
            }
        } catch {
            status.text = "Invalid pairing capsule or offer. Check the pairing ID, endpoint, 32-byte base64 values, and ISO 8601 expiry."
        }
    }

    @objc private func copyEnrollment() {
        guard let enrollmentData, let text = String(data: enrollmentData, encoding: .utf8) else { return }
        UIPasteboard.general.string = text
        status.text = "Prepared enrollment copied. Treat it as one-use setup material."
    }

    @objc private func shareEnrollment() {
        guard let enrollmentData else { return }
        let controller = UIActivityViewController(activityItems: [enrollmentData], applicationActivities: nil)
        if let popover = controller.popoverPresentationController { popover.sourceView = outputButtons }
        present(controller, animated: true)
    }

    @objc private func exportEnrollment() {
        guard let enrollmentData else { return }
        do {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("luna-vault-enrollment-\(UUID().uuidString).json")
            try enrollmentData.write(to: url, options: [.atomic, .completeFileProtection])
            pendingExportURL = url
            let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
            picker.delegate = self
            present(picker, animated: true)
        } catch { status.text = "Prepared enrollment could not be exported: \(error)." }
    }

    /// Both picker outcomes (exported or cancelled) must remove the
    /// temporary export file; the picker already copied it wherever the
    /// user chose, or the user chose nowhere.
    public func documentPicker(_ controller: UIDocumentPickerViewController,
                               didPickDocumentsAt urls: [URL]) {
        removePendingExportFile()
    }

    public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        removePendingExportFile()
    }

    private func removePendingExportFile() {
        guard let url = pendingExportURL else { return }
        pendingExportURL = nil
        try? FileManager.default.removeItem(at: url)
    }

    @objc private func unpair() {
        guard let credential else { status.text = "No paired Mac credential is stored."; return }
        unpairButton.isEnabled = false
        status.text = "Attempting remote revocation before removing the local credential…"
        Task { [weak self] in
            guard let self else { return }
            let revoked = (try? credential.revoked(now: Date())) ?? credential
            let outcome = await self.onRevokeCredential?(revoked)
                ?? .localOnly(reason: "Remote revocation is not configured.")
            do {
                try self.credentialStore?.remove()
                await MainActor.run {
                    self.credential = nil; self.unpairButton.isEnabled = true
                    switch outcome {
                    case .revokedRemotely:
                        self.status.text = "The Mac acknowledged revocation and the local credential was removed."
                    case .localOnly(let reason):
                        self.status.text = "The local credential was removed, but the Mac could not be revoked remotely. \(reason) Revoke it on the Mac before pairing again."
                    }
                    self.onUnpaired?(outcome)
                }
            } catch {
                await MainActor.run {
                    self.unpairButton.isEnabled = true
                    self.status.text = "The local credential could not be removed: \(error)."
                }
            }
        }
    }

    private func decodeCapsule() throws -> VaultMacPairingCapsule? {
        let value = capsuleField.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        guard let data = Data(base64Encoded: value) ?? value.data(using: .utf8) else {
            throw VaultMacProtocolError.invalidChallenge
        }
        let capsule = try JSONDecoder().decode(VaultMacPairingCapsule.self, from: data)
        // Codable synthesis does not invoke the throwing protocol/endpoint
        // initializers. Rebuild every validated value before use so a pasted
        // capsule cannot bypass the endpoint, size, identity, or expiry
        // contract.
        let offer = try VaultMacPairingOffer(pairingID: capsule.offer.pairingID,
            serverBinding: capsule.offer.serverBinding,
            endpointBinding: capsule.offer.endpointBinding,
            nonce: capsule.offer.nonce,
            expiresAt: capsule.offer.expiresAt)
        guard Date() < offer.expiresAt,
              offer.expiresAt.timeIntervalSinceNow <= 15 * 60 else {
            throw VaultMacProtocolError.expired
        }
        let secret = try VaultMacPairingSecret(rawValue: capsule.oneTimeCode.rawValue)
        return VaultMacPairingCapsule(offer: offer, oneTimeCode: secret)
    }

    private func manualInput() -> VaultMacManualPairingInput {
        VaultMacManualPairingInput(pairingID: pairingIDField.text ?? "",
            endpointBinding: endpointField.text ?? "",
            serverBindingBase64: serverBindingField.text ?? "",
            nonceBase64: nonceField.text ?? "",
            expiresAtISO8601: expiryField.text ?? "",
            oneTimeCodeBase64: codeField.text ?? "")
    }

    private func showEnrollment(_ enrollment: VaultMacPairingEnrollment) {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(enrollment) else {
            status.text = "Enrollment was prepared but could not be displayed."; return
        }
        enrollmentData = data; enrollmentOutput.text = String(data: data, encoding: .utf8)
        enrollmentOutput.isHidden = false; outputButtons.isHidden = false
    }

    private func configure(_ field: UITextField, label: String, id: String) {
        field.placeholder = label; field.borderStyle = .roundedRect
        field.accessibilityIdentifier = id; field.accessibilityLabel = label
        field.autocorrectionType = .no; field.autocapitalizationType = .none
    }

    private func labeledField(_ text: String, _ field: UITextField) -> UIView {
        let stack = UIStackView(arrangedSubviews: [fieldLabel(text), field])
        stack.axis = .vertical; stack.spacing = 5; return stack
    }

    private func fieldLabel(_ text: String) -> UILabel {
        let label = UILabel(); label.text = text
        label.font = .preferredFont(forTextStyle: .caption1); label.textColor = .secondaryLabel
        return label
    }

    private func actionButton(_ title: String, id: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system); button.setTitle(title, for: .normal)
        button.accessibilityIdentifier = id; button.accessibilityLabel = "\(title) prepared enrollment"
        button.addTarget(self, action: action, for: .touchUpInside); return button
    }
}

private final class VaultMacUIIdentityConfirmer: VaultMacServerIdentityConfirming, @unchecked Sendable {
    weak var presenter: UIViewController?
    init(presenter: UIViewController?) { self.presenter = presenter }
    func confirm(fingerprint: String, endpointBinding: String) async throws
        -> VaultMacServerIdentityConfirmation? {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { [weak self] in
                guard let presenter = self?.presenter else { continuation.resume(returning: nil); return }
                // A VC already presenting something cannot also present this
                // alert; treat that as presentation being impossible rather
                // than leaving the continuation to hang.
                var topmost = presenter
                while let presented = topmost.presentedViewController { topmost = presented }
                guard topmost.presentedViewController == nil else { continuation.resume(returning: nil); return }
                let resume = VaultSettingsOneShotResume(continuation)
                let alert = VaultSettingsConfirmAlertController(title: "Confirm your Mac",
                    message: "Compare this fingerprint on both devices:\n\n\(fingerprint)\n\nEndpoint: \(endpointBinding)\n\nThis is an out-of-band confirmation.",
                    preferredStyle: .alert)
                // A dismissal with neither button tapped — the presenting
                // screen disappearing out from under the alert — must still
                // resolve the continuation instead of hanging the caller.
                alert.onDisappear = { resume.resume(returning: nil) }
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in resume.resume(returning: nil) })
                alert.addAction(UIAlertAction(title: "Fingerprints Match", style: .default) { _ in
                    resume.resume(returning: VaultMacServerIdentityConfirmation(
                        fingerprint: fingerprint, endpointBinding: endpointBinding))
                })
                topmost.present(alert, animated: true)
            }
        }
    }
}

/// Resumes a checked continuation exactly once. Both a button action and a
/// disappearance callback race to resolve the same confirmation; only the
/// first resume must take effect.
private final class VaultSettingsOneShotResume<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) { self.continuation = continuation }

    func resume(returning value: T) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

/// An alert that reports its own disappearance, so a confirmation flow can
/// resolve even when the alert is dismissed without either action firing.
private final class VaultSettingsConfirmAlertController: UIAlertController {
    var onDisappear: (() -> Void)?

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        onDisappear?()
    }
}

private func settingsStack(_ views: [UIView]) -> UIStackView {
    let stack = UIStackView(arrangedSubviews: views)
    stack.axis = .vertical; stack.spacing = 18; stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
}

private func pin(_ stack: UIStackView) {
    guard let view = stack.superview else { return }
    NSLayoutConstraint.activate([
        stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 22),
        stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -22),
        stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
    ])
}

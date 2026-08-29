import Foundation
import LunaVaultBackend
import LunaVaultCrypto
import LunaVaultModels
import LunaVaultSearch
import LunaVaultSetup
import LunaVaultStorage
import LunaVaultUI
import VaultTestKit
import UIKit
import XCTest

final class VaultStage5SetupTests: XCTestCase {
    func testLaunchLoadNeverCreatesMissingRootKey() throws {
        let store = InMemoryVaultSetupStore(), keys = Stage5MemoryKeyStore()
        let manager = VaultRootKeyManager(configuration: VaultCryptoConfiguration(keychainAccessGroup: "test.group"), store: keys, lifecycleLockURL: nil)
        let coordinator = VaultSetupCoordinator(store: store, rootKeyManager: manager)
        XCTAssertEqual(coordinator.load(), .firstRun)
        XCTAssertNil(try keys.data(for: manager.descriptor))
    }

    func testFirstRunCreationThenRecoveryUsesLoadRequired() {
        let store = InMemoryVaultSetupStore(), keys = Stage5MemoryKeyStore()
        let manager = VaultRootKeyManager(configuration: VaultCryptoConfiguration(keychainAccessGroup: "test.group"), store: keys, lifecycleLockURL: nil)
        let policy = VaultStoragePolicy(location: .iCloud, keepLocalCopy: false)
        let coordinator = VaultSetupCoordinator(store: store, rootKeyManager: manager)
        XCTAssertEqual(coordinator.completeFirstRun(policy: policy), .ready(policy: policy))
        let recovered = VaultSetupCoordinator(store: store, rootKeyManager: manager)
        XCTAssertEqual(recovered.load(), .ready(policy: policy))
    }

    @MainActor
    func testSearchFirstRootExposesStableAccessibilityContractBeforeSetup() {
        let coordinator = VaultSetupCoordinator(store: InMemoryVaultSetupStore(), rootKeyManager: nil)
        let root = VaultRootViewController(setupCoordinator: coordinator)
        root.loadViewIfNeeded()
        XCTAssertNotNil(root.view.viewWithAccessibilityIdentifier(VaultAccessibilityID.search))
        XCTAssertNotNil(root.view.viewWithAccessibilityIdentifier(VaultAccessibilityID.setup))
        XCTAssertNotNil(root.view.viewWithAccessibilityIdentifier(VaultAccessibilityID.setupContinue))
    }

    @MainActor
    func testFirstRunPolicyControlAndContinueButtonAreInteractive() throws {
        let store = InMemoryVaultSetupStore()
        let keys = Stage5MemoryKeyStore()
        let manager = VaultRootKeyManager(
            configuration: VaultCryptoConfiguration(keychainAccessGroup: "test.group"),
            store: keys, lifecycleLockURL: nil)
        let coordinator = VaultSetupCoordinator(store: store, rootKeyManager: manager)
        let root = VaultRootViewController(setupCoordinator: coordinator)
        root.loadViewIfNeeded()

        let policy = try XCTUnwrap(root.view.viewWithAccessibilityIdentifier(VaultAccessibilityID.setupPolicy) as? UISegmentedControl)
        XCTAssertEqual(policy.selectedSegmentIndex, 0)
        policy.selectedSegmentIndex = 1
        policy.sendActions(for: .valueChanged)

        let continueButton = try XCTUnwrap(root.view.viewWithAccessibilityIdentifier(VaultAccessibilityID.setupContinue) as? UIButton)
        continueButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(coordinator.state, .ready(policy: VaultStoragePolicy(location: .iCloud)))
        XCTAssertTrue(root.view.viewWithAccessibilityIdentifier(VaultAccessibilityID.setup)?.isHidden == true)
        XCTAssertTrue(root.view.viewWithAccessibilityIdentifier(VaultAccessibilityID.content)?.isHidden == false)
    }

    @MainActor
    func testSearchResultOpensCanonicalObjectThroughHostCallback() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("luna-vault-ui-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = try VaultSearchIndex(databaseURL: directory.appendingPathComponent("index.sqlite"))
        let objectID = VaultObjectID(rawValue: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!)
        let date = Date(timeIntervalSinceReferenceDate: 10)
        try index.upsert(VaultIndexedDocument(id: objectID, revision: UUID(), logicalTime: 1,
            deviceID: "test", filename: "canonical.txt", bodyText: "needle text",
            createdAt: date, updatedAt: date, accessedAt: date))

        var opened: VaultObjectID?
        let root = VaultRootViewController(searchIndex: index, openHandler: { opened = $0 })
        root.loadViewIfNeeded()
        let search = try XCTUnwrap(root.view.viewWithAccessibilityIdentifier(VaultAccessibilityID.search) as? UITextField)
        search.text = "needle"
        search.sendActions(for: .editingChanged)
        try await Task.sleep(nanoseconds: 500_000_000)

        let open = try XCTUnwrap(root.view.viewWithAccessibilityIdentifier(
            "vault.result.open.\(objectID.rawValue.uuidString)") as? UIButton)
        open.sendActions(for: .touchUpInside)
        XCTAssertEqual(opened, objectID)
    }

    func testManualPairingInputRejectsMalformedIDAndExpiredOffer() throws {
        let now = Date(timeIntervalSince1970: 100)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let base = VaultMacManualPairingInput(
            pairingID: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            endpointBinding: "tailscale:vault.example.ts.net:49200",
            serverBindingBase64: Data(repeating: 9, count: 32).base64EncodedString(),
            nonceBase64: Data(repeating: 4, count: 32).base64EncodedString(),
            expiresAtISO8601: formatter.string(from: now.addingTimeInterval(300)),
            oneTimeCodeBase64: Data(repeating: 7, count: 32).base64EncodedString())
        let capsule = try base.capsule(now: now)
        XCTAssertEqual(capsule.offer.pairingID.uuidString, base.pairingID)

        let expired = VaultMacManualPairingInput(
            pairingID: base.pairingID, endpointBinding: base.endpointBinding,
            serverBindingBase64: base.serverBindingBase64, nonceBase64: base.nonceBase64,
            expiresAtISO8601: formatter.string(from: now.addingTimeInterval(-1)),
            oneTimeCodeBase64: base.oneTimeCodeBase64)
        XCTAssertThrowsError(try expired.capsule(now: now)) {
            XCTAssertEqual($0 as? VaultMacProtocolError, .expired)
        }

        let malformedID = VaultMacManualPairingInput(
            pairingID: "not-a-pairing-id", endpointBinding: base.endpointBinding,
            serverBindingBase64: base.serverBindingBase64, nonceBase64: base.nonceBase64,
            expiresAtISO8601: base.expiresAtISO8601, oneTimeCodeBase64: base.oneTimeCodeBase64)
        XCTAssertThrowsError(try malformedID.capsule(now: now))
    }

    @MainActor
    func testSettingsStorageRowInvokesHostAction() throws {
        var selected: VaultStoragePolicy?
        var reconfigured = false
        let actions = VaultSettingsActions(
            storagePolicyChanged: { selected = $0 },
            reconfigureRuntime: { reconfigured = true })
        let settings = VaultSettingsViewController(actions: actions)
        let navigation = UINavigationController(rootViewController: settings)
        settings.loadViewIfNeeded()
        settings.tableView(settings.tableView, didSelectRowAt: IndexPath(row: 0, section: 0))
        let storage = try XCTUnwrap(navigation.topViewController as? VaultStorageSettingsViewController)
        storage.loadViewIfNeeded()
        let control = try XCTUnwrap(storage.view.viewWithAccessibilityIdentifier("vault.storage.location") as? UISegmentedControl)
        control.selectedSegmentIndex = 1
        control.sendActions(for: .valueChanged)
        XCTAssertEqual(selected, VaultStoragePolicy(location: .iCloud))
        XCTAssertTrue(reconfigured)
    }

    @MainActor
    func testPairingSamePolicyRebuildsBackendAndRootImmediately() throws {
        let policy = VaultStoragePolicy(location: .mac)
        let first = try makeStage5Runtime(policy: policy, backend: nil,
            credentialGeneration: nil, credentialFingerprint: nil, runtimeGeneration: 1)
        let pairedBackend = InMemoryVaultBackend(identity: VaultBackendIdentity(
            location: .mac, containerIdentifier: "paired-mac", vaultID: "default"))
        let second = try makeStage5Runtime(policy: policy, backend: pairedBackend,
            credentialGeneration: 7, credentialFingerprint: "paired-fingerprint",
            runtimeGeneration: 2)
        defer {
            try? FileManager.default.removeItem(at: first.directory)
            try? FileManager.default.removeItem(at: second.directory)
        }

        let coordinator = makeReadyCoordinator(policy: policy)
        let indexDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("luna-vault-ui-runtime-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: indexDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: indexDirectory) }
        let index = try VaultSearchIndex(databaseURL: indexDirectory.appendingPathComponent("index.sqlite"))
        var current: VaultRuntimeServices? = first.services
        let root = VaultRootViewController(services: first.services,
            setupCoordinator: coordinator, searchIndex: index,
            servicesProvider: { current })
        root.loadViewIfNeeded()
        root.viewWillAppear(false)
        let status = try XCTUnwrap(root.view.viewWithAccessibilityIdentifier(
            VaultAccessibilityID.contentStatus))
        XCTAssertFalse(status.superview?.isHidden ?? true)

        current = second.services
        root.viewWillAppear(false)
        XCTAssertTrue(status.superview?.isHidden ?? false)
        XCTAssertNotEqual(first.services.runtimeIdentity, second.services.runtimeIdentity)
        XCTAssertEqual(second.services.remoteBackend?.identity, pairedBackend.identity)
    }

    @MainActor
    func testUnpairSamePolicyRemovesBackendAndUpdatesRootWithoutRelaunch() throws {
        let policy = VaultStoragePolicy(location: .mac)
        let pairedBackend = InMemoryVaultBackend(identity: VaultBackendIdentity(
            location: .mac, containerIdentifier: "paired-mac", vaultID: "default"))
        let paired = try makeStage5Runtime(policy: policy, backend: pairedBackend,
            credentialGeneration: 7, credentialFingerprint: "paired-fingerprint",
            runtimeGeneration: 1)
        let unpaired = try makeStage5Runtime(policy: policy, backend: nil,
            credentialGeneration: nil, credentialFingerprint: nil, runtimeGeneration: 2)
        defer {
            try? FileManager.default.removeItem(at: paired.directory)
            try? FileManager.default.removeItem(at: unpaired.directory)
        }

        let coordinator = makeReadyCoordinator(policy: policy)
        let indexDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("luna-vault-ui-runtime-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: indexDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: indexDirectory) }
        let index = try VaultSearchIndex(databaseURL: indexDirectory.appendingPathComponent("index.sqlite"))
        var current: VaultRuntimeServices? = paired.services
        let root = VaultRootViewController(services: paired.services,
            setupCoordinator: coordinator, searchIndex: index,
            servicesProvider: { current })
        root.loadViewIfNeeded()
        root.viewWillAppear(false)
        let status = try XCTUnwrap(root.view.viewWithAccessibilityIdentifier(
            VaultAccessibilityID.contentStatus))
        XCTAssertTrue(status.superview?.isHidden ?? false)

        current = unpaired.services
        root.viewWillAppear(false)
        XCTAssertFalse(status.superview?.isHidden ?? true)
        let label = try XCTUnwrap(status as? UILabel)
        XCTAssertTrue(label.text?.contains("Mac storage is unavailable") == true)
        XCTAssertNil(unpaired.services.remoteBackend)
    }
}

private struct Stage5RuntimeFixture {
    let services: VaultRuntimeServices
    let directory: URL
}

private func makeStage5Runtime(policy: VaultStoragePolicy,
                               backend: VaultBackendTransport?,
                               credentialGeneration: UInt64?,
                               credentialFingerprint: String?,
                               runtimeGeneration: UInt64) throws -> Stage5RuntimeFixture {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("luna-vault-ui-runtime-\(UUID().uuidString)", isDirectory: true)
    let repository = try VaultRepository(
        configuration: VaultStorageConfiguration(databaseName: "vault.sqlite", policy: policy),
        testContainerURL: directory)
    let identity = VaultRuntimeIdentity(policy: policy,
        backendIdentity: backend?.identity,
        credentialGeneration: credentialGeneration,
        credentialFingerprint: credentialFingerprint,
        runtimeGeneration: runtimeGeneration)
    let services = VaultRuntimeServices(policy: policy, repository: repository,
        deviceBackend: VaultDeviceBackend(store: repository), remoteBackend: backend,
        syncCoordinator: nil, runtimeIdentity: identity)
    return Stage5RuntimeFixture(services: services, directory: directory)
}

private func makeReadyCoordinator(policy: VaultStoragePolicy) -> VaultSetupCoordinator {
    let keys = Stage5MemoryKeyStore()
    let manager = VaultRootKeyManager(
        configuration: VaultCryptoConfiguration(keychainAccessGroup: "test.group"),
        store: keys, lifecycleLockURL: nil)
    let coordinator = VaultSetupCoordinator(store: InMemoryVaultSetupStore(),
        rootKeyManager: manager)
    _ = coordinator.completeFirstRun(policy: policy)
    return coordinator
}

private extension UIView {
    func viewWithAccessibilityIdentifier(_ identifier: String) -> UIView? {
        if accessibilityIdentifier == identifier { return self }
        return subviews.lazy.compactMap { $0.viewWithAccessibilityIdentifier(identifier) }.first
    }
}

private final class Stage5MemoryKeyStore: VaultAtomicKeyStoring, @unchecked Sendable {
    private let lock = NSLock(); private var values: [VaultKeyDescriptor: Data] = [:]
    func data(for descriptor: VaultKeyDescriptor) throws -> Data? { lock.withLock { values[descriptor] } }
    func setData(_ data: Data, for descriptor: VaultKeyDescriptor) throws { lock.withLock { values[descriptor] = data } }
    func removeData(for descriptor: VaultKeyDescriptor) throws { lock.withLock { values.removeValue(forKey: descriptor) } }
    func createDataIfAbsent(_ data: Data, for descriptor: VaultKeyDescriptor) throws -> Bool { lock.withLock { guard values[descriptor] == nil else { return false }; values[descriptor] = data; return true } }
}

private extension NSLock { func withLock<T>(_ body: () throws -> T) rethrows -> T { lock(); defer { unlock() }; return try body() } }

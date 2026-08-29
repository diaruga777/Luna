import Foundation
import LunaVaultBackend
import LunaVaultCrypto
import LunaVaultModels
import LunaVaultSearch
import LunaVaultSetup
import LunaVaultUI
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

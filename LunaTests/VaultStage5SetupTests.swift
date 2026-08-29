import Foundation
import LunaVaultCrypto
import LunaVaultModels
import LunaVaultSetup
import LunaVaultUI
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

import Foundation
import LunaAppConfig
import LunaVaultCrypto
import LunaVaultModels
import LunaVaultStorage

public enum LunaVaultSetupModule {
    public static let identifier = "LunaVaultSetup"
}

public struct VaultSetupConfiguration: Equatable, Sendable {
    public let storagePolicy: VaultStoragePolicy?
    /// The Vault host's private Keychain group. This is deliberately supplied
    /// by the host (and never by the Share extension).
    public let keychainAccessGroup: String?
    public let vaultID: String

    public init(storagePolicy: VaultStoragePolicy? = nil,
                keychainAccessGroup: String? = AppConfig.vaultKeychainAccessGroup,
                vaultID: String = "default") {
        self.storagePolicy = storagePolicy
        self.keychainAccessGroup = keychainAccessGroup
        self.vaultID = vaultID
    }
}

/// A setup failure is intentionally a small, stable vocabulary. Localized
/// Keychain/SQLite/provider errors must not become persisted user-facing data.
public enum VaultSetupUnavailableReason: String, Codable, Equatable, Sendable {
    case keychainUnavailable
    case storageUnavailable
    case iCloudUnavailable
    case macNotPaired
}

public enum VaultSetupFailure: Error, Equatable, Sendable {
    case invalidStoredState
    case cannotPersistState
    case rootKeyUnavailable
    case backendUnavailable
    case unexpected
}

/// The launch state is typed so a caller cannot accidentally treat an
/// unavailable provider as an empty local Vault. `ready` is the only state in
/// which search/storage work should be constructed.
public enum VaultSetupState: Equatable, Sendable {
    case firstRun
    case ready(policy: VaultStoragePolicy)
    case unavailable(VaultSetupUnavailableReason)
    case error(VaultSetupFailure)

    public var policy: VaultStoragePolicy? {
        guard case let .ready(policy) = self else { return nil }
        return policy
    }
    public var isReady: Bool { policy != nil }
}

public struct VaultSetupRecord: Codable, Equatable, Sendable {
    public let policy: VaultStoragePolicy
    public let completedAt: Date
    public init(policy: VaultStoragePolicy, completedAt: Date = Date()) {
        self.policy = policy; self.completedAt = completedAt
    }
}

/// The persistence seam keeps staged UI tests away from the real App Group.
public protocol VaultSetupStateStoring: Sendable {
    func load() throws -> VaultSetupRecord?
    func save(_ record: VaultSetupRecord) throws
    func remove() throws
}

public final class UserDefaultsVaultSetupStore: VaultSetupStateStoring, @unchecked Sendable {
    public static let key = "LunaVault.setup.v1"
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = UserDefaultsVaultSetupStore.key) {
        self.defaults = defaults; self.key = key
    }

    public func load() throws -> VaultSetupRecord? {
        guard let data = defaults.data(forKey: key) else { return nil }
        guard data.count <= 16 * 1024 else { throw VaultSetupFailure.invalidStoredState }
        do { return try JSONDecoder().decode(VaultSetupRecord.self, from: data) }
        catch { throw VaultSetupFailure.invalidStoredState }
    }
    public func save(_ record: VaultSetupRecord) throws {
        do {
            let data = try JSONEncoder().encode(record)
            guard data.count <= 16 * 1024 else { throw VaultSetupFailure.cannotPersistState }
            defaults.set(data, forKey: key)
            guard defaults.data(forKey: key) == data else { throw VaultSetupFailure.cannotPersistState }
        } catch let failure as VaultSetupFailure { throw failure }
        catch { throw VaultSetupFailure.cannotPersistState }
    }
    public func remove() throws { defaults.removeObject(forKey: key) }
}

/// A tiny deterministic store useful for staged screens and package tests.
public final class InMemoryVaultSetupStore: VaultSetupStateStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var record: VaultSetupRecord?
    public init(record: VaultSetupRecord? = nil) { self.record = record }
    public func load() throws -> VaultSetupRecord? { lock.withLock { record } }
    public func save(_ record: VaultSetupRecord) throws { lock.withLock { self.record = record } }
    public func remove() throws { lock.withLock { record = nil } }
}

/// Coordinates the one setup-only root-key creation and all later launch
/// reads. In particular, `load()` never calls `createFirstRun()`.
public final class VaultSetupCoordinator: @unchecked Sendable {
    public let configuration: VaultSetupConfiguration
    public let store: any VaultSetupStateStoring
    public let rootKeyManager: VaultRootKeyManager?
    private let lock = NSLock()
    private var current: VaultSetupState

    public init(configuration: VaultSetupConfiguration = VaultSetupConfiguration(),
                store: any VaultSetupStateStoring = UserDefaultsVaultSetupStore(),
                rootKeyManager: VaultRootKeyManager? = nil) {
        self.configuration = configuration; self.store = store
        self.rootKeyManager = rootKeyManager ?? Self.makeRootKeyManager(configuration)
        current = .firstRun
    }

    /// Current in-memory state. `load()` should be called once at app launch.
    public var state: VaultSetupState { lock.withLock { current } }
    /// Read-only spelling for callers that want to make the launch-state
    /// dependency explicit at call sites.
    public var currentState: VaultSetupState { state }

    /// Recovery/launch path. Existing state requires an existing root key.
    @discardableResult
    public func load() -> VaultSetupState {
        lock.withLock {
            do {
                guard let record = try store.load() else {
                    current = .firstRun; return current
                }
                guard let manager = rootKeyManager else {
                    current = .unavailable(.keychainUnavailable); return current
                }
                _ = try manager.loadRequired()
                // iCloud-backed Vault storage was removed from the product
                // surface. Treat records written by older builds as the
                // on-device policy and persist the migration so the retired
                // provider cannot reappear on the next launch.
                let policy = record.policy.location == .iCloud
                    ? VaultStoragePolicy(location: .device)
                    : record.policy
                if policy != record.policy {
                    try store.save(VaultSetupRecord(policy: policy, completedAt: record.completedAt))
                }
                current = .ready(policy: policy)
            } catch let failure as VaultSetupFailure {
                current = .error(failure)
            } catch is VaultCryptoError {
                current = .unavailable(.keychainUnavailable)
            } catch {
                current = .error(.unexpected)
            }
            return current
        }
    }

    /// Alias used by scene coordinators that model setup as a refresh event.
    @discardableResult
    public func refresh() -> VaultSetupState { load() }

    /// Setup-only path. This is the sole coordinator call that can create the
    /// initial root key.
    @discardableResult
    public func completeFirstRun(policy: VaultStoragePolicy? = nil) -> VaultSetupState {
        lock.withLock {
            guard case .firstRun = current else { return current }
            let chosen = policy ?? configuration.storagePolicy ?? VaultStoragePolicy(location: .device)
            do {
                guard let manager = rootKeyManager else {
                    current = .unavailable(.keychainUnavailable); return current
                }
                _ = try manager.createFirstRun()
                try store.save(VaultSetupRecord(policy: chosen))
                current = .ready(policy: chosen)
            } catch let failure as VaultSetupFailure {
                current = .error(failure)
            } catch is VaultCryptoError {
                current = .unavailable(.keychainUnavailable)
            } catch {
                current = .error(.cannotPersistState)
            }
            return current
        }
    }

    /// Changes policy only after the key has been loaded and the new policy is
    /// durable. Backend availability is evaluated by the runtime layer.
    @discardableResult
    public func updateStoragePolicy(_ policy: VaultStoragePolicy) -> VaultSetupState {
        lock.withLock {
            guard case .ready = current else { return current }
            do {
                try store.save(VaultSetupRecord(policy: policy))
                current = .ready(policy: policy)
            } catch { current = .error(.cannotPersistState) }
            return current
        }
    }

    /// Explicit reset is setup-only/destructive and intentionally separate
    /// from launch recovery.
    @discardableResult
    public func resetConfirmed() -> VaultSetupState {
        lock.withLock {
            do { try store.remove(); try rootKeyManager?.resetConfirmed(); current = .firstRun }
            catch { current = .error(.cannotPersistState) }
            return current
        }
    }

    private static func makeRootKeyManager(_ configuration: VaultSetupConfiguration) -> VaultRootKeyManager? {
        guard let accessGroup = configuration.keychainAccessGroup, !accessGroup.isEmpty else { return nil }
        return VaultRootKeyManager(configuration: VaultCryptoConfiguration(
            keychainAccessGroup: accessGroup, vaultID: configuration.vaultID))
    }
}

public typealias VaultSetupStore = UserDefaultsVaultSetupStore

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }; return try body()
    }
}

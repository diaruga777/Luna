import Foundation
import LunaVaultCrypto
import LunaVaultModels

public enum LunaVaultBackendModule {
    public static let identifier = "LunaVaultBackend"
}

/// Availability is deliberately more precise than a Boolean. An iCloud file
/// can exist in the ubiquitous container while its bytes are not present on
/// this device, and a request to evict is only a request until the system
/// reports that state.
public enum VaultBackendAvailability: String, Codable, Equatable, Sendable {
    case unavailable
    case available
    case needsDownload
    case downloading
    case evicting
    case failed
}

public struct VaultBackendCapabilities: Codable, Equatable, Sendable {
    public let location: VaultStorageLocation
    public let availability: VaultBackendAvailability
    public let supportsAtomicWrites: Bool
    public let supportsRangeReads: Bool
    public let supportsEviction: Bool
    /// `true` means the transport must only receive client-side encrypted
    /// bytes. Device storage is protected by Data Protection instead.
    public let requiresClientSideEncryption: Bool

    public init(location: VaultStorageLocation,
                availability: VaultBackendAvailability,
                supportsAtomicWrites: Bool,
                supportsRangeReads: Bool,
                supportsEviction: Bool,
                requiresClientSideEncryption: Bool) {
        self.location = location
        self.availability = availability
        self.supportsAtomicWrites = supportsAtomicWrites
        self.supportsRangeReads = supportsRangeReads
        self.supportsEviction = supportsEviction
        self.requiresClientSideEncryption = requiresClientSideEncryption
    }
}

public enum VaultBackendError: Error, Equatable, Sendable {
    case unavailable
    case notFound
    case invalidPath
    case invalidRange
    case unsupported
    case conflict
    case io(String)
}

public struct VaultBackendRetryPolicy: Equatable, Sendable {
    public let maximumAttempts: Int
    public let initialDelayNanoseconds: UInt64
    public let maximumDelayNanoseconds: UInt64

    public init(maximumAttempts: Int = 3,
                initialDelayNanoseconds: UInt64 = 50_000_000,
                maximumDelayNanoseconds: UInt64 = 1_000_000_000) {
        self.maximumAttempts = max(1, maximumAttempts)
        self.initialDelayNanoseconds = initialDelayNanoseconds
        self.maximumDelayNanoseconds = max(initialDelayNanoseconds, maximumDelayNanoseconds)
    }
}

/// Every future network-backed transport (the Mac path in v1) receives its
/// session from the composition root. This makes no-egress tests enforceable;
/// adapters must not construct or reach for URLSession.shared internally.
public protocol VaultBackendNetworkSessionProviding: Sendable {
    var session: URLSession { get }
}

/// Tailscale is an optional transport path for the user's paired Mac. The
/// app still authenticates the Mac and encrypts every protocol message; a
/// Tailscale IP or MagicDNS name is never treated as identity or storage.
public struct VaultMacConnectionConfiguration: Equatable, Sendable {
    public let endpoint: String
    public let port: UInt16
    public let usesTailscale: Bool

    public init(endpoint: String, port: UInt16, usesTailscale: Bool = true) {
        self.endpoint = endpoint
        self.port = port
        self.usesTailscale = usesTailscale
    }
}

/// Opaque, already-encrypted payload transport. Device, iCloud, and Mac
/// adapters arrive in a later stage and must never receive plaintext names,
/// metadata or file bytes. Cloud-provider-specific adapters are intentionally
/// out of the v1 contract.
public protocol VaultBackendTransport: Sendable {
    var capabilities: VaultBackendCapabilities { get }
    func putCiphertext(_ ciphertext: Data, for id: VaultObjectID) async throws
    func ciphertext(for id: VaultObjectID) async throws -> Data?
    func removeCiphertext(for id: VaultObjectID) async throws
}

public extension VaultBackendTransport {
    /// The common transport intentionally permits a full-read fallback. A
    /// backend advertises whether it has a native range implementation, while
    /// callers can still use this method safely for small previews.
    func ciphertext(for id: VaultObjectID, range: Range<Int>) async throws -> Data? {
        guard range.lowerBound >= 0, range.upperBound >= range.lowerBound else {
            throw VaultBackendError.invalidRange
        }
        guard let value = try await ciphertext(for: id) else { return nil }
        guard range.upperBound <= value.count else { throw VaultBackendError.invalidRange }
        return Data(value[range])
    }

    /// Backend writes are idempotent by opaque object ID. This helper gives
    /// adapters one shared retry policy without hiding retries from tests.
    func retrying<T: Sendable>(_ policy: VaultBackendRetryPolicy = VaultBackendRetryPolicy(),
                               operation: @escaping @Sendable () async throws -> T) async throws -> T {
        var attempt = 0
        var delay = policy.initialDelayNanoseconds
        while true {
            do { return try await operation() }
            catch let error as VaultBackendError {
                guard (error == .unavailable || error == .conflict),
                      attempt + 1 < policy.maximumAttempts else { throw error }
                attempt += 1
                if delay > 0 { try await Task.sleep(nanoseconds: delay) }
                delay = min(policy.maximumDelayNanoseconds, max(delay, 1) * 2)
            }
        }
    }
}

public struct VaultBackendConfiguration: Equatable, Sendable {
    public let location: VaultStorageLocation
    public let macConnection: VaultMacConnectionConfiguration?

    public init(location: VaultStorageLocation, macConnection: VaultMacConnectionConfiguration? = nil) {
        self.location = location
        self.macConnection = location == .mac ? macConnection : nil
    }
}

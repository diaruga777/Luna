import Foundation
import LunaVaultCrypto
import LunaVaultModels
#if canImport(Darwin)
import Darwin
#endif

public enum LunaVaultBackendModule {
    public static let identifier = "LunaVaultBackend"
}

/// Removes only stale, regular-file download artifacts that Vault itself
/// named in the process temporary directory.  A crash can bypass the normal
/// `defer` cleanup in the iCloud and Mac adapters, but startup cleanup must
/// never recursively delete an attacker-controlled directory or a live
/// download.  The prefix, UUID suffix, regular-file/symlink check, age gate,
/// and entry cap together keep ownership and work bounded.
public enum VaultProtectedDownloadTemporarySweep {
    public static let defaultMaximumAge: TimeInterval = 24 * 60 * 60
    public static let defaultMaximumEntries = 256

    @discardableResult
    public static func sweep(
        fileManager: FileManager = .default,
        temporaryDirectory: URL? = nil,
        now: Date = Date(),
        maximumAge: TimeInterval = defaultMaximumAge,
        maximumEntries: Int = defaultMaximumEntries) -> Int {
        guard now.timeIntervalSinceReferenceDate.isFinite,
              maximumAge.isFinite, maximumAge >= 0,
              maximumEntries > 0 else { return 0 }
        let root = temporaryDirectory ?? fileManager.temporaryDirectory
        guard root.isFileURL else { return 0 }
        // Download artifacts are always direct children of the system temp
        // directory.  Do not use a recursive enumerator here: stale content
        // must never turn startup into a subtree walk.
        let candidates = (try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey,
                                                   .contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        var scanned = 0
        var removed = 0
        for candidate in candidates.prefix(maximumEntries) {
            scanned += 1
            guard isOwnedDownloadName(candidate.lastPathComponent),
                  isRegularFileOrSymlink(candidate),
                  let attributes = try? fileManager.attributesOfItem(atPath: candidate.path),
                  let modified = attributes[FileAttributeKey.modificationDate] as? Date,
                  now.timeIntervalSince(modified) >= maximumAge else { continue }
            do {
                // `removeItem` unlinks a matching symlink itself; directories
                // are excluded above, so no descendant can be traversed.
                try fileManager.removeItem(at: candidate)
                removed += 1
            } catch { continue }
        }
        return removed
    }

    private static func isOwnedDownloadName(_ name: String) -> Bool {
        for prefix in ["luna-vault-icloud-", "luna-vault-mac-"] {
            guard name.hasPrefix(prefix), name.hasSuffix(".lvf") else { continue }
            let rawID = name.dropFirst(prefix.count).dropLast(".lvf".count)
            return UUID(uuidString: String(rawID)) != nil
        }
        return false
    }

    private static func isRegularFileOrSymlink(_ url: URL) -> Bool {
        #if canImport(Darwin)
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        let kind = info.st_mode & S_IFMT
        return kind == S_IFREG || kind == S_IFLNK
        #else
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isDirectory != true
        #endif
    }
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

public enum VaultBackendError: String, Error, Codable, Equatable, Sendable {
    case unavailable
    case notFound = "not_found"
    case invalidPath = "invalid_path"
    case invalidRange = "invalid_range"
    case unsupported
    case conflict
    case staleVersion = "stale_version"
    case corruptPayload = "corrupt_payload"
    case permissionDenied = "permission_denied"
    case uploadFailed = "upload_failed"
    case retryExhausted = "retry_exhausted"
    case io

    public var isTransient: Bool {
        switch self {
        case .unavailable, .conflict, .staleVersion, .uploadFailed, .io: return true
        case .notFound, .invalidPath, .invalidRange, .unsupported,
             .corruptPayload, .permissionDenied, .retryExhausted: return false
        }
    }
}

public struct VaultBackendIdentity: Codable, Hashable, Sendable {
    public let location: VaultStorageLocation
    public let containerIdentifier: String
    public let vaultID: String

    public init(location: VaultStorageLocation, containerIdentifier: String,
                vaultID: String) {
        self.location = location
        self.containerIdentifier = containerIdentifier
        self.vaultID = vaultID
    }

    public var stableKey: String {
        "\(location.rawValue):\(containerIdentifier):\(vaultID)"
    }
}

public enum VaultRemoteObjectState: String, Codable, Equatable, Sendable {
    case missing
    case pendingUpload
    case current
    case needsDownload
    case downloading
    case failed
    case conflicted
}

public enum VaultBackendWriteOutcome: String, Codable, Equatable, Sendable {
    case pending
    case current
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
    var identity: VaultBackendIdentity { get }
    var capabilities: VaultBackendCapabilities { get }
    var currentAvailability: VaultBackendAvailability { get }
    func put(_ payload: VaultVerifiedCiphertext,
             expectedRevision: UUID?) async throws -> VaultBackendWriteOutcome
    func payload(for identity: VaultRemoteObjectIdentity) async throws -> VaultAuthenticatedCiphertext?
    func remove(_ identity: VaultRemoteObjectIdentity,
                expectedRevision: UUID?) async throws
    func state(for identity: VaultRemoteObjectIdentity) async throws -> VaultRemoteObjectState
}

/// File-backed transport capability.  Implementations that conform to this
/// protocol must copy encrypted frames in bounded chunks; the legacy
/// `VaultBackendTransport` methods remain for small artifact compatibility.
public protocol VaultStreamingBackendTransport: VaultBackendTransport {
    func put(_ payload: VaultVerifiedCiphertextFile,
             expectedRevision: UUID?) async throws -> VaultBackendWriteOutcome
    func payloadFile(for identity: VaultRemoteObjectIdentity) async throws
        -> VaultAuthenticatedCiphertextFile?
}

public extension VaultBackendTransport {
    var currentAvailability: VaultBackendAvailability { capabilities.availability }
}

public extension VaultBackendTransport {
    /// The common transport intentionally permits a full-read fallback. A
    /// backend advertises whether it has a native range implementation, while
    /// callers can still use this method safely for small previews.
    func encryptedRange(for identity: VaultRemoteObjectIdentity,
                        range: Range<Int>) async throws -> Data? {
        guard range.lowerBound >= 0, range.upperBound >= range.lowerBound else {
            throw VaultBackendError.invalidRange
        }
        guard let value = try await payload(for: identity)?.encoded() else { return nil }
        guard range.upperBound <= value.count else { throw VaultBackendError.invalidRange }
        return Data(value[range])
    }

    /// Backend writes are idempotent by opaque object ID. This helper gives
    /// adapters one shared retry policy without hiding retries from tests.
    ///
    /// A CAS conflict or a stale-version mismatch is a deterministic read of
    /// state already compared once; the operation's own inputs (an expected
    /// revision, a compared byte range) do not change between attempts, so
    /// an immediate retry only reproduces the same failure. Excluding them
    /// here is local to this in-place retry loop: `VaultBackendError
    /// .isTransient` is unchanged, so a caller one layer up (a sync job
    /// scheduler that re-derives the expected revision before trying again)
    /// still sees these as retryable at its own cadence.
    func retrying<T: Sendable>(_ policy: VaultBackendRetryPolicy = VaultBackendRetryPolicy(),
                               operation: @escaping @Sendable () async throws -> T) async throws -> T {
        var attempt = 0
        var delay = policy.initialDelayNanoseconds
        while true {
            do { return try await operation() }
            catch let error as VaultBackendError {
                guard error.isTransient, error != .conflict, error != .staleVersion,
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

import Foundation
import LunaVaultModels

/// The state reported by the file provider for one ubiquitous object.
public struct VaultUbiquitousFileState: Equatable, Sendable {
    public let exists: Bool
    public let isUbiquitous: Bool
    public let isDownloaded: Bool
    public let isDownloading: Bool
    public let isUploaded: Bool

    public init(exists: Bool, isUbiquitous: Bool, isDownloaded: Bool,
                isDownloading: Bool, isUploaded: Bool) {
        self.exists = exists
        self.isUbiquitous = isUbiquitous
        self.isDownloaded = isDownloaded
        self.isDownloading = isDownloading
        self.isUploaded = isUploaded
    }
}

public enum VaultEvictionOutcome: String, Codable, Equatable, Sendable {
    /// The system has confirmed that the local bytes are not downloaded.
    case evicted
    /// The system accepted the request, but has not yet reported eviction.
    case pending
    /// The file is not eligible for iCloud eviction.
    case notEvictable
}

/// This is the only filesystem surface used by `VaultICloudBackend`. Tests
/// inject a deterministic implementation; production uses NSFileCoordinator
/// and FileManager's ubiquity APIs. The protocol contains no provider SDK or
/// network primitive, so indexing cannot accidentally depend on it.
public protocol VaultUbiquitousFileCoordinating: Sendable {
    var rootURL: URL? { get }
    var availability: VaultBackendAvailability { get }
    func state(for relativePath: String) throws -> VaultUbiquitousFileState
    func write(_ data: Data, at relativePath: String) throws
    func read(at relativePath: String) throws -> Data?
    func remove(at relativePath: String) throws
    func startDownloading(at relativePath: String) throws
    func requestEviction(at relativePath: String) throws -> VaultEvictionOutcome
}

public struct VaultICloudBackendConfiguration: Equatable, Sendable {
    public let containerIdentifier: String
    public let vaultID: String
    public let keepLocalCopy: Bool
    public let retryPolicy: VaultBackendRetryPolicy

    public init(containerIdentifier: String,
                vaultID: String = "default",
                keepLocalCopy: Bool = true,
                retryPolicy: VaultBackendRetryPolicy = VaultBackendRetryPolicy()) {
        self.containerIdentifier = containerIdentifier
        self.vaultID = vaultID
        self.keepLocalCopy = keepLocalCopy
        self.retryPolicy = retryPolicy
    }
}

/// Opt-in iCloud Documents-style backend. Every object is addressed by an
/// opaque UUID path and the input is required to be client-side ciphertext.
/// iCloud's file provider owns upload/download timing; this adapter reports
/// that state instead of pretending a write or eviction is immediately remote.
public final class VaultICloudBackend: VaultBackendTransport, @unchecked Sendable {
    private let coordinator: VaultUbiquitousFileCoordinating
    private let configuration: VaultICloudBackendConfiguration
    private let rootAvailable: Bool

    public let capabilities: VaultBackendCapabilities

    public init(configuration: VaultICloudBackendConfiguration,
                coordinator: VaultUbiquitousFileCoordinating? = nil) {
        self.configuration = configuration
        let resolvedCoordinator = coordinator ?? SystemVaultUbiquitousFileCoordinator(
            containerIdentifier: configuration.containerIdentifier)
        self.coordinator = resolvedCoordinator
        rootAvailable = resolvedCoordinator.rootURL != nil
        capabilities = VaultBackendCapabilities(
            location: .iCloud,
            availability: resolvedCoordinator.availability,
            supportsAtomicWrites: true,
            // iCloud ubiquity files do not expose a provider-independent
            // remote range API. The transport safely falls back to a full
            // coordinated read, then slices locally.
            supportsRangeReads: false,
            supportsEviction: true,
            requiresClientSideEncryption: true)
    }

    public func putCiphertext(_ ciphertext: Data, for id: VaultObjectID) async throws {
        try ensureAvailable()
        let path = objectPath(id)
        try await retrying(configuration.retryPolicy) { [coordinator] in
            do { try coordinator.write(ciphertext, at: path) }
            catch { throw Self.map(error) }
        }
        if !configuration.keepLocalCopy {
            // A pending outcome is deliberately ignored here: the write is
            // complete, but callers can query `evictionOutcome` to observe
            // whether the OS has actually removed local bytes.
            _ = try? await evictionOutcome(for: id)
        }
    }

    public func ciphertext(for id: VaultObjectID) async throws -> Data? {
        try ensureAvailable()
        let path = objectPath(id)
        let state = try coordinator.state(for: path)
        guard state.exists else { return nil }
        if state.isUbiquitous && !state.isDownloaded {
            try coordinator.startDownloading(at: path)
            throw VaultBackendError.unavailable
        }
        return try await retrying(configuration.retryPolicy) { [coordinator] in
            do { return try coordinator.read(at: path) }
            catch { throw Self.map(error) }
        }
    }

    public func ciphertext(for id: VaultObjectID, range: Range<Int>) async throws -> Data? {
        guard range.lowerBound >= 0, range.upperBound >= range.lowerBound else {
            throw VaultBackendError.invalidRange
        }
        guard let value = try await ciphertext(for: id) else { return nil }
        guard range.upperBound <= value.count else { throw VaultBackendError.invalidRange }
        return Data(value[range])
    }

    public func removeCiphertext(for id: VaultObjectID) async throws {
        try ensureAvailable()
        let path = objectPath(id)
        try await retrying(configuration.retryPolicy) { [coordinator] in
            do { try coordinator.remove(at: path) }
            catch { throw Self.map(error) }
        }
    }

    /// Requests local eviction and returns only a state confirmed by the
    /// ubiquity coordinator. `.pending` is not success and must remain visible
    /// in UI/sync state until a later query returns `.evicted`.
    public func evictionOutcome(for id: VaultObjectID) async throws -> VaultEvictionOutcome {
        try ensureAvailable()
        let path = objectPath(id)
        let state = try coordinator.state(for: path)
        guard state.exists, state.isUbiquitous else { return .notEvictable }
        if !state.isDownloaded { return .evicted }
        do { return try coordinator.requestEviction(at: path) }
        catch { throw Self.map(error) }
    }

    public func state(for id: VaultObjectID) throws -> VaultUbiquitousFileState {
        try ensureAvailable()
        return try coordinator.state(for: objectPath(id))
    }

    private func ensureAvailable() throws {
        guard rootAvailable else { throw VaultBackendError.unavailable }
        guard capabilities.availability != .unavailable else { throw VaultBackendError.unavailable }
    }

    private func objectPath(_ id: VaultObjectID) -> String {
        // UUID is the only remotely observable path component. Vault ID is
        // bounded to a safe directory component during configuration.
        let safeVaultID = configuration.vaultID
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        return "VaultObjects/\(safeVaultID)/\(id.rawValue.uuidString).vault"
    }

    private static func map(_ error: Error) -> VaultBackendError {
        if let error = error as? VaultBackendError { return error }
        return .io(String(describing: error))
    }
}

/// NSFileCoordinator is required for iCloud document coordination. This
/// object resolves the ubiquity root at initialization, so an absent iCloud
/// entitlement/account is represented as `.unavailable` rather than falling
/// back to a local directory (which would silently violate the selected
/// storage policy).
public final class SystemVaultUbiquitousFileCoordinator: VaultUbiquitousFileCoordinating, @unchecked Sendable {
    public let rootURL: URL?
    public let availability: VaultBackendAvailability

    private let fileManager: FileManager
    private let coordinator: NSFileCoordinator

    public init(containerIdentifier: String? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.coordinator = NSFileCoordinator(filePresenter: nil)
        let resolved = containerIdentifier.flatMap {
            fileManager.url(forUbiquityContainerIdentifier: $0)
        }
        rootURL = resolved?.appendingPathComponent("Documents", isDirectory: true)
        availability = resolved == nil ? .unavailable : .available
    }

    public func state(for relativePath: String) throws -> VaultUbiquitousFileState {
        guard let url = url(for: relativePath) else { return missingState() }
        guard fileManager.fileExists(atPath: url.path) else { return missingState() }
        let values = try url.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .ubiquitousItemIsDownloadingKey,
            .ubiquitousItemIsUploadedKey,
            .ubiquitousItemDownloadingStatusKey,
        ])
        let downloadingStatus = values.ubiquitousItemDownloadingStatus
        let isDownloaded = downloadingStatus == .current || downloadingStatus == .downloaded || downloadingStatus == nil
        return VaultUbiquitousFileState(
            exists: true,
            isUbiquitous: values.isUbiquitousItem ?? false,
            isDownloaded: isDownloaded,
            isDownloading: values.ubiquitousItemIsDownloading ?? false,
            isUploaded: values.ubiquitousItemIsUploaded ?? false)
    }

    public func write(_ data: Data, at relativePath: String) throws {
        guard let url = url(for: relativePath) else { throw VaultBackendError.unavailable }
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try coordinateWriting(url) { target in
            try data.write(to: target, options: .atomic)
        }
    }

    public func read(at relativePath: String) throws -> Data? {
        guard let url = url(for: relativePath) else { throw VaultBackendError.unavailable }
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        var result: Data?
        try coordinateReading(url) { target in result = try Data(contentsOf: target) }
        return result
    }

    public func remove(at relativePath: String) throws {
        guard let url = url(for: relativePath) else { throw VaultBackendError.unavailable }
        guard fileManager.fileExists(atPath: url.path) else { return }
        try coordinateWriting(url) { target in try fileManager.removeItem(at: target) }
    }

    public func startDownloading(at relativePath: String) throws {
        guard let url = url(for: relativePath) else { throw VaultBackendError.unavailable }
        try fileManager.startDownloadingUbiquitousItem(at: url)
    }

    public func requestEviction(at relativePath: String) throws -> VaultEvictionOutcome {
        guard let url = url(for: relativePath) else { throw VaultBackendError.unavailable }
        let before = try state(for: relativePath)
        guard before.exists, before.isUbiquitous else { return .notEvictable }
        if !before.isDownloaded { return .evicted }
        try fileManager.evictUbiquitousItem(at: url)
        let after = try state(for: relativePath)
        return after.isDownloaded ? .pending : .evicted
    }

    private func url(for relativePath: String) -> URL? {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), !relativePath.contains("..") else { return nil }
        return rootURL?.appendingPathComponent(relativePath)
    }

    private func missingState() -> VaultUbiquitousFileState {
        VaultUbiquitousFileState(exists: false, isUbiquitous: false,
                                 isDownloaded: false, isDownloading: false,
                                 isUploaded: false)
    }

    private func coordinateWriting(_ url: URL, body: (URL) throws -> Void) throws {
        var coordinationError: NSError?
        var operationError: Error?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            do { try body(target) } catch { operationError = error }
        }
        if let operationError { throw operationError }
        if let coordinationError { throw VaultBackendError.io(coordinationError.localizedDescription) }
    }

    private func coordinateReading(_ url: URL, body: (URL) throws -> Void) throws {
        var coordinationError: NSError?
        var operationError: Error?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { target in
            do { try body(target) } catch { operationError = error }
        }
        if let operationError { throw operationError }
        if let coordinationError { throw VaultBackendError.io(coordinationError.localizedDescription) }
    }
}

import Foundation
import LunaVaultCrypto
import LunaVaultModels
import LunaVaultStorage

/// The state reported by the file provider for one ubiquitous object.
public struct VaultUbiquitousFileState: Equatable, Sendable {
    public let exists: Bool
    public let isDownloadStatusKnown: Bool
    public let isUbiquitous: Bool
    public let isDownloaded: Bool
    public let isCurrent: Bool
    public let isDownloading: Bool
    public let isUploaded: Bool
    public let isUploading: Bool
    public let uploadFailed: Bool
    public let hasUnresolvedConflicts: Bool

    public init(exists: Bool, isDownloadStatusKnown: Bool = true,
                isUbiquitous: Bool, isDownloaded: Bool,
                isCurrent: Bool, isDownloading: Bool, isUploaded: Bool,
                isUploading: Bool = false, uploadFailed: Bool = false,
                hasUnresolvedConflicts: Bool = false) {
        self.exists = exists
        self.isDownloadStatusKnown = isDownloadStatusKnown
        self.isUbiquitous = isUbiquitous
        self.isDownloaded = isDownloaded
        self.isCurrent = isCurrent
        self.isDownloading = isDownloading
        self.isUploaded = isUploaded
        self.isUploading = isUploading
        self.uploadFailed = uploadFailed
        self.hasUnresolvedConflicts = hasUnresolvedConflicts
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
    func compareAndWrite(_ data: Data, at relativePath: String,
                         identity: VaultRemoteObjectIdentity,
                         versionAt versionPath: String,
                         expectedRevision: UUID?) throws
    func compareAndWriteFile(from sourceURL: URL, byteCount: UInt64,
                             at relativePath: String,
                             identity: VaultRemoteObjectIdentity,
                             versionAt versionPath: String,
                             expectedRevision: UUID?) throws
    func compareAndWriteFile(from payload: VaultVerifiedCiphertextFile,
                             at relativePath: String,
                             identity: VaultRemoteObjectIdentity,
                             versionAt versionPath: String,
                             expectedRevision: UUID?) throws
    func currentIdentity(at versionPath: String) throws -> VaultRemoteObjectIdentity?
    func read(at relativePath: String) throws -> Data?
    func readToFile(at relativePath: String, destinationURL: URL) throws -> UInt64?
    func compareAndRemove(at relativePath: String,
                          identity: VaultRemoteObjectIdentity,
                          versionAt versionPath: String,
                          expectedRevision: UUID?) throws
    func startDownloading(at relativePath: String) throws
    func requestEviction(at relativePath: String) throws -> VaultEvictionOutcome
}

public extension VaultUbiquitousFileCoordinating {
    /// Compatibility fallback for deterministic fake coordinators. Production
    /// coordinators override this with a descriptor-backed copy.
    func compareAndWriteFile(from sourceURL: URL, byteCount: UInt64,
                             at relativePath: String,
                             identity: VaultRemoteObjectIdentity,
                             versionAt versionPath: String,
                             expectedRevision: UUID?) throws {
        // A legacy coordinator that cannot stream is not a safe fallback for
        // a potentially 100-GB content object. It must opt into the explicit
        // file API rather than silently materialising the source as Data.
        _ = sourceURL; _ = byteCount; _ = relativePath; _ = identity
        _ = versionPath; _ = expectedRevision
        throw VaultBackendError.unsupported
    }
    func compareAndWriteFile(from payload: VaultVerifiedCiphertextFile,
                             at relativePath: String,
                             identity: VaultRemoteObjectIdentity,
                             versionAt versionPath: String,
                             expectedRevision: UUID?) throws {
        _ = payload; _ = relativePath; _ = identity; _ = versionPath; _ = expectedRevision
        throw VaultBackendError.unsupported
    }
    func readToFile(at relativePath: String, destinationURL: URL) throws -> UInt64? {
        _ = relativePath; _ = destinationURL
        throw VaultBackendError.unsupported
    }
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
public final class VaultICloudBackend: VaultStreamingBackendTransport, @unchecked Sendable {
    private let coordinator: VaultUbiquitousFileCoordinating
    private let configuration: VaultICloudBackendConfiguration
    private let rootAvailable: Bool

    public let capabilities: VaultBackendCapabilities
    public let identity: VaultBackendIdentity
    public var currentAvailability: VaultBackendAvailability { coordinator.availability }

    public init(configuration: VaultICloudBackendConfiguration,
                coordinator: VaultUbiquitousFileCoordinating? = nil) {
        _ = VaultProtectedDownloadTemporarySweep.sweep()
        self.configuration = configuration
        let resolvedCoordinator = coordinator ?? SystemVaultUbiquitousFileCoordinator(
            containerIdentifier: configuration.containerIdentifier)
        self.coordinator = resolvedCoordinator
        rootAvailable = resolvedCoordinator.rootURL != nil
        identity = VaultBackendIdentity(location: .iCloud,
                                        containerIdentifier: configuration.containerIdentifier,
                                        vaultID: configuration.vaultID)
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

    public func put(_ payload: VaultVerifiedCiphertext,
                    expectedRevision: UUID?) async throws -> VaultBackendWriteOutcome {
        try ensureAvailable()
        guard payload.vaultID == configuration.vaultID else { throw VaultBackendError.corruptPayload }
        let path = objectPath(payload.identity)
        let encoded = try payload.encoded()
        try await retrying(configuration.retryPolicy) { [coordinator] in
            do {
                try coordinator.compareAndWrite(
                    encoded, at: path, identity: payload.identity,
                    versionAt: self.versionPath(payload.identity),
                    expectedRevision: expectedRevision)
            }
            catch { throw Self.map(error) }
        }
        let fileState = try coordinator.state(for: path)
        guard !fileState.hasUnresolvedConflicts else { throw VaultBackendError.conflict }
        guard !fileState.uploadFailed else { throw VaultBackendError.uploadFailed }
        guard fileState.isUploaded, !fileState.isUploading else { return .pending }
        if !configuration.keepLocalCopy {
            _ = try await evictionOutcome(for: payload.identity)
        }
        return .current
    }

    public func put(_ payload: VaultVerifiedCiphertextFile,
                    expectedRevision: UUID?) async throws -> VaultBackendWriteOutcome {
        try ensureAvailable()
        guard payload.vaultID == configuration.vaultID,
              payload.identity.kind.envelopeRole != .dek else {
            throw VaultBackendError.corruptPayload
        }
        try await retrying(configuration.retryPolicy) { [coordinator] in
            do {
                try coordinator.compareAndWriteFile(from: payload,
                    at: self.objectPath(payload.identity), identity: payload.identity,
                    versionAt: self.versionPath(payload.identity),
                    expectedRevision: expectedRevision)
            } catch { throw Self.map(error) }
        }
        let fileState = try coordinator.state(for: objectPath(payload.identity))
        guard !fileState.hasUnresolvedConflicts else { throw VaultBackendError.conflict }
        guard !fileState.uploadFailed else { throw VaultBackendError.uploadFailed }
        guard fileState.isUploaded, !fileState.isUploading else { return .pending }
        if !configuration.keepLocalCopy { _ = try await evictionOutcome(for: payload.identity) }
        return .current
    }

    public func payload(for identity: VaultRemoteObjectIdentity) async throws -> VaultAuthenticatedCiphertext? {
        try ensureAvailable()
        guard try coordinator.currentIdentity(at: versionPath(identity)) == identity else {
            throw VaultBackendError.staleVersion
        }
        let path = objectPath(identity)
        let fileState = try coordinator.state(for: path)
        guard fileState.exists else { return nil }
        guard !fileState.hasUnresolvedConflicts else { throw VaultBackendError.conflict }
        guard !fileState.uploadFailed else { throw VaultBackendError.uploadFailed }
        // A provider that cannot report download status has not established
        // that the bytes are a usable current copy. Never read/install based
        // on an optimistic or stale resource-value snapshot.
        guard fileState.isDownloadStatusKnown else { throw VaultBackendError.unavailable }
        if fileState.isUbiquitous && !fileState.isCurrent {
            try coordinator.startDownloading(at: path)
            throw VaultBackendError.unavailable
        }
        let data = try await retrying(configuration.retryPolicy) { [coordinator] in
            do { return try coordinator.read(at: path) }
            catch { throw Self.map(error) }
        }
        guard let data else { return nil }
        do { return try VaultAuthenticatedCiphertext.decodeAndValidate(
            data, expected: identity, vaultID: configuration.vaultID) }
        catch { throw VaultBackendError.corruptPayload }
    }

    public func payloadFile(for identity: VaultRemoteObjectIdentity) async throws
        -> VaultAuthenticatedCiphertextFile? {
        try ensureAvailable()
        guard try coordinator.currentIdentity(at: versionPath(identity)) == identity else {
            throw VaultBackendError.staleVersion
        }
        let path = objectPath(identity)
        let state = try coordinator.state(for: path)
        guard state.exists else { return nil }
        guard !state.hasUnresolvedConflicts else { throw VaultBackendError.conflict }
        guard !state.uploadFailed else { throw VaultBackendError.uploadFailed }
        guard state.isDownloadStatusKnown else { throw VaultBackendError.unavailable }
        if state.isUbiquitous && !state.isCurrent {
            try coordinator.startDownloading(at: path)
            throw VaultBackendError.unavailable
        }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("luna-vault-icloud-\(UUID().uuidString).lvf")
        var keepTemporary = false
        defer {
            if !keepTemporary { try? VaultSecureFileAccess.removeRegularFile(at: temporary) }
        }
        // The coordinator writes into this inode. Create and protect it
        // before asking iCloud for the first byte; a coordinator must not be
        // able to create an unprotected download and add protection later.
        let created = try VaultSecureFileAccess.createEmptyFile(at: temporary)
        try created.close()
        #if os(iOS)
        let protection = SystemVaultFileProtectionApplier()
        try protection.apply(to: temporary)
        guard (try? protection.hasRequiredProtection(at: temporary)) == true else {
            throw VaultBackendError.permissionDenied
        }
        #endif
        guard try await retrying(configuration.retryPolicy, operation: {
            try self.coordinator.readToFile(at: path, destinationURL: temporary)
        }) != nil else { return nil }
        do {
            let result = try VaultAuthenticatedCiphertextFile(fileURL: temporary,
                expectedIdentity: identity, vaultID: configuration.vaultID, ownsFile: true)
            keepTemporary = true
            return result
        } catch {
            throw VaultBackendError.corruptPayload
        }
    }

    public func remove(_ identity: VaultRemoteObjectIdentity,
                       expectedRevision: UUID?) async throws {
        try ensureAvailable()
        let path = objectPath(identity)
        try await retrying(configuration.retryPolicy) { [coordinator] in
            do {
                try coordinator.compareAndRemove(
                    at: path, identity: identity,
                    versionAt: self.versionPath(identity),
                    expectedRevision: expectedRevision)
            }
            catch { throw Self.map(error) }
        }
    }

    /// Requests local eviction and returns only a state confirmed by the
    /// ubiquity coordinator. `.pending` is not success and must remain visible
    /// in UI/sync state until a later query returns `.evicted`.
    public func evictionOutcome(for identity: VaultRemoteObjectIdentity) async throws -> VaultEvictionOutcome {
        try ensureAvailable()
        let path = objectPath(identity)
        let fileState = try coordinator.state(for: path)
        guard fileState.exists, fileState.isUbiquitous else { return .notEvictable }
        guard !fileState.hasUnresolvedConflicts else { throw VaultBackendError.conflict }
        guard !fileState.uploadFailed else { throw VaultBackendError.uploadFailed }
        if fileState.isDownloadStatusKnown && !fileState.isDownloaded { return .evicted }
        do { return try coordinator.requestEviction(at: path) }
        catch { throw Self.map(error) }
    }

    public func state(for identity: VaultRemoteObjectIdentity) async throws -> VaultRemoteObjectState {
        try ensureAvailable()
        guard let current = try coordinator.currentIdentity(at: versionPath(identity)) else {
            return .missing
        }
        guard current == identity else { return .conflicted }
        let fileState = try coordinator.state(for: objectPath(identity))
        guard fileState.exists else { return .missing }
        if fileState.hasUnresolvedConflicts { return .conflicted }
        if fileState.uploadFailed { return .failed }
        if fileState.isUploading || !fileState.isUploaded { return .pendingUpload }
        if fileState.isDownloading { return .downloading }
        if !fileState.isCurrent { return .needsDownload }
        return .current
    }

    private func ensureAvailable() throws {
        guard rootAvailable else { throw VaultBackendError.unavailable }
        guard coordinator.availability != .unavailable else { throw VaultBackendError.unavailable }
    }

    private func objectPath(_ identity: VaultRemoteObjectIdentity) -> String {
        // UUID is the only remotely observable path component. Vault ID is
        // bounded to a safe directory component during configuration.
        let safeVaultID = configuration.vaultID
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        return "VaultObjects/\(safeVaultID)/\(identity.kind.rawValue)/\(identity.objectID.rawValue.uuidString)/\(identity.revision.uuidString)/\(identity.generation).vault"
    }

    private func versionPath(_ identity: VaultRemoteObjectIdentity) -> String {
        let safeVaultID = configuration.vaultID
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        return "VaultObjects/\(safeVaultID)/\(identity.kind.rawValue)/\(identity.objectID.rawValue.uuidString)/current.json"
    }

    private static func map(_ error: Error) -> VaultBackendError {
        if let error = error as? VaultBackendError { return error }
        return .io
    }
}

/// NSFileCoordinator is required for iCloud document coordination. This
/// object resolves the ubiquity root at initialization, so an absent iCloud
/// entitlement/account is represented as `.unavailable` rather than falling
/// back to a local directory (which would silently violate the selected
/// storage policy).
public final class SystemVaultUbiquitousFileCoordinator: VaultUbiquitousFileCoordinating, @unchecked Sendable {
    public let rootURL: URL?
    public var availability: VaultBackendAvailability {
        rootURL == nil || fileManager.ubiquityIdentityToken == nil ? .unavailable : .available
    }

    private let fileManager: FileManager
    private let coordinator: NSFileCoordinator
    private let protection: VaultFileProtectionApplying

    public init(containerIdentifier: String? = nil, fileManager: FileManager = .default,
                protectionApplier: VaultFileProtectionApplying = SystemVaultFileProtectionApplier()) {
        self.fileManager = fileManager
        self.coordinator = NSFileCoordinator(filePresenter: nil)
        self.protection = protectionApplier
        let resolved = containerIdentifier.flatMap {
            fileManager.url(forUbiquityContainerIdentifier: $0)
        }
        rootURL = resolved?.appendingPathComponent("Documents", isDirectory: true)
    }

    public func state(for relativePath: String) throws -> VaultUbiquitousFileState {
        guard let url = url(for: relativePath) else { return missingState() }
        guard fileManager.fileExists(atPath: url.path) else { return missingState() }
        let values = try url.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .ubiquitousItemIsDownloadingKey,
            .ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey,
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemHasUnresolvedConflictsKey,
            .ubiquitousItemUploadingErrorKey,
        ])
        let downloadingStatus = values.ubiquitousItemDownloadingStatus
        let isCurrent = downloadingStatus == .current
        let isDownloaded = isCurrent || downloadingStatus == .downloaded
        return VaultUbiquitousFileState(
            exists: true,
            isDownloadStatusKnown: downloadingStatus != nil,
            isUbiquitous: values.isUbiquitousItem ?? false,
            isDownloaded: isDownloaded,
            isCurrent: isCurrent,
            isDownloading: values.ubiquitousItemIsDownloading ?? false,
            isUploaded: values.ubiquitousItemIsUploaded ?? false,
            isUploading: values.ubiquitousItemIsUploading ?? false,
            uploadFailed: values.ubiquitousItemUploadingError != nil,
            hasUnresolvedConflicts: values.ubiquitousItemHasUnresolvedConflicts ?? false)
    }

    public func compareAndWrite(_ data: Data, at relativePath: String,
                                identity: VaultRemoteObjectIdentity,
                                versionAt versionPath: String,
                                expectedRevision: UUID?) throws {
        guard let payloadURL = url(for: relativePath), let versionURL = url(for: versionPath) else {
            throw VaultBackendError.unavailable
        }
        try coordinateWriting(payloadURL, versionURL) { payloadTarget, versionTarget in
            let current = try self.decodeIdentity(at: versionTarget)
            if current == identity {
                guard self.fileManager.fileExists(atPath: payloadTarget.path),
                      try Data(contentsOf: payloadTarget) == data else {
                    throw VaultBackendError.conflict
                }
                return
            }
            guard current?.revision == expectedRevision else { throw VaultBackendError.staleVersion }
            try self.fileManager.createDirectory(
                at: payloadTarget.deletingLastPathComponent(), withIntermediateDirectories: true)
            if self.fileManager.fileExists(atPath: payloadTarget.path) {
                guard try Data(contentsOf: payloadTarget) == data else {
                    throw VaultBackendError.conflict
                }
            } else {
                try data.write(to: payloadTarget, options: .atomic)
            }
            try JSONEncoder().encode(identity).write(to: versionTarget, options: .atomic)
        }
    }

    public func compareAndWriteFile(from sourceURL: URL, byteCount: UInt64,
                                    at relativePath: String,
                                    identity: VaultRemoteObjectIdentity,
                                    versionAt versionPath: String,
                                    expectedRevision: UUID?) throws {
        guard let sourceAttributes = try? fileManager.attributesOfItem(atPath: sourceURL.path),
              (sourceAttributes[.type] as? FileAttributeType) == .typeRegular,
              (sourceAttributes[.size] as? NSNumber)?.uint64Value == byteCount else {
            throw VaultBackendError.invalidRange
        }
        guard let payloadURL = url(for: relativePath), let versionURL = url(for: versionPath) else {
            throw VaultBackendError.unavailable
        }
        try coordinateWriting(payloadURL, versionURL) { payloadTarget, versionTarget in
            let current = try self.decodeIdentity(at: versionTarget)
            if current == identity {
                guard try self.filesEqual(sourceURL, payloadTarget, expectedBytes: byteCount) else {
                    throw VaultBackendError.conflict
                }
                return
            }
            guard current?.revision == expectedRevision else { throw VaultBackendError.staleVersion }
            try self.fileManager.createDirectory(at: payloadTarget.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
            let staging = payloadTarget.deletingLastPathComponent()
                .appendingPathComponent(".staging-\(UUID().uuidString)")
            try self.copyFile(sourceURL, staging, expectedBytes: byteCount)
            if self.fileManager.fileExists(atPath: payloadTarget.path) {
                try self.fileManager.removeItem(at: payloadTarget)
            }
            try self.fileManager.moveItem(at: staging, to: payloadTarget)
            try JSONEncoder().encode(identity).write(to: versionTarget, options: .atomic)
        }
    }

    /// Copies from the already-authenticated descriptor held by the verified
    /// payload.  No pathname is reopened between verification and upload.
    public func compareAndWriteFile(from payload: VaultVerifiedCiphertextFile,
                                    at relativePath: String,
                                    identity: VaultRemoteObjectIdentity,
                                    versionAt versionPath: String,
                                    expectedRevision: UUID?) throws {
        guard payload.identity == identity,
              payload.ciphertextByteCount > 0 else { throw VaultBackendError.corruptPayload }
        guard let payloadURL = url(for: relativePath), let versionURL = url(for: versionPath) else {
            throw VaultBackendError.unavailable
        }
        try coordinateWriting(payloadURL, versionURL) { payloadTarget, versionTarget in
            let current = try self.decodeIdentity(at: versionTarget)
            if current == identity {
                guard try self.filesEqual(payload, payloadTarget,
                                          expectedBytes: payload.ciphertextByteCount) else {
                    throw VaultBackendError.conflict
                }
                return
            }
            guard current?.revision == expectedRevision else { throw VaultBackendError.staleVersion }
            try self.fileManager.createDirectory(at: payloadTarget.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
            let staging = payloadTarget.deletingLastPathComponent()
                .appendingPathComponent(".staging-\(UUID().uuidString)")
            do {
                let before = try payload.digest()
                _ = try payload.writeCopy(to: staging)
                let after = try payload.digest()
                guard before == after else { throw VaultBackendError.conflict }
                if self.fileManager.fileExists(atPath: payloadTarget.path) {
                    try self.fileManager.removeItem(at: payloadTarget)
                }
                try self.fileManager.moveItem(at: staging, to: payloadTarget)
                try JSONEncoder().encode(identity).write(to: versionTarget, options: .atomic)
            } catch {
                try? self.fileManager.removeItem(at: staging)
                throw error
            }
        }
    }

    public func currentIdentity(at versionPath: String) throws -> VaultRemoteObjectIdentity? {
        guard let versionURL = url(for: versionPath) else { throw VaultBackendError.unavailable }
        guard fileManager.fileExists(atPath: versionURL.path) else { return nil }
        var result: VaultRemoteObjectIdentity?
        try coordinateReading(versionURL) { result = try self.decodeIdentity(at: $0) }
        return result
    }

    public func read(at relativePath: String) throws -> Data? {
        guard let url = url(for: relativePath) else { throw VaultBackendError.unavailable }
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        var result: Data?
        try coordinateReading(url) { target in result = try Data(contentsOf: target) }
        return result
    }

    public func readToFile(at relativePath: String, destinationURL: URL) throws -> UInt64? {
        guard let sourceURL = url(for: relativePath) else { throw VaultBackendError.unavailable }
        guard fileManager.fileExists(atPath: sourceURL.path) else { return nil }
        var byteCount: UInt64?
        try coordinateReading(sourceURL) { target in
            let attrs = try self.fileManager.attributesOfItem(atPath: target.path)
            guard let size = (attrs[.size] as? NSNumber)?.uint64Value else {
                throw VaultBackendError.io
            }
            try self.copyFile(target, destinationURL, expectedBytes: size)
            byteCount = size
        }
        return byteCount
    }

    public func compareAndRemove(at relativePath: String,
                                 identity: VaultRemoteObjectIdentity,
                                 versionAt versionPath: String,
                                 expectedRevision: UUID?) throws {
        guard let payloadURL = url(for: relativePath), let versionURL = url(for: versionPath) else {
            throw VaultBackendError.unavailable
        }
        try coordinateWriting(payloadURL, versionURL) { payloadTarget, versionTarget in
            guard let current = try self.decodeIdentity(at: versionTarget) else { return }
            guard current == identity, current.revision == expectedRevision else {
                throw VaultBackendError.staleVersion
            }
            if self.fileManager.fileExists(atPath: payloadTarget.path) {
                try self.fileManager.removeItem(at: payloadTarget)
            }
            if self.fileManager.fileExists(atPath: versionTarget.path) {
                try self.fileManager.removeItem(at: versionTarget)
            }
        }
    }

    public func startDownloading(at relativePath: String) throws {
        guard let url = url(for: relativePath) else { throw VaultBackendError.unavailable }
        try fileManager.startDownloadingUbiquitousItem(at: url)
    }

    public func requestEviction(at relativePath: String) throws -> VaultEvictionOutcome {
        guard let url = url(for: relativePath) else { throw VaultBackendError.unavailable }
        let before = try state(for: relativePath)
        guard before.exists, before.isUbiquitous else { return .notEvictable }
        if before.isDownloadStatusKnown && !before.isDownloaded { return .evicted }
        try fileManager.evictUbiquitousItem(at: url)
        let after = try state(for: relativePath)
        return after.isDownloadStatusKnown && !after.isDownloaded ? .evicted : .pending
    }

    private func url(for relativePath: String) -> URL? {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), !relativePath.contains("..") else { return nil }
        return rootURL?.appendingPathComponent(relativePath)
    }

    private func missingState() -> VaultUbiquitousFileState {
        VaultUbiquitousFileState(exists: false, isDownloadStatusKnown: false, isUbiquitous: false,
                                 isDownloaded: false, isCurrent: false,
                                 isDownloading: false, isUploaded: false)
    }

    private func coordinateWriting(_ url: URL, body: (URL) throws -> Void) throws {
        var coordinationError: NSError?
        var operationError: Error?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            do { try body(target) } catch { operationError = error }
        }
        if let operationError { throw operationError }
        if coordinationError != nil { throw VaultBackendError.io }
    }

    private func coordinateWriting(_ firstURL: URL, _ secondURL: URL,
                                   body: (URL, URL) throws -> Void) throws {
        var coordinationError: NSError?
        var operationError: Error?
        coordinator.coordinate(
            writingItemAt: firstURL, options: .forReplacing,
            writingItemAt: secondURL, options: .forReplacing,
            error: &coordinationError
        ) { firstTarget, secondTarget in
            do { try body(firstTarget, secondTarget) } catch { operationError = error }
        }
        if let operationError { throw operationError }
        if coordinationError != nil { throw VaultBackendError.io }
    }

    private func decodeIdentity(at url: URL) throws -> VaultRemoteObjectIdentity? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do { return try JSONDecoder().decode(VaultRemoteObjectIdentity.self, from: Data(contentsOf: url)) }
        catch { throw VaultBackendError.conflict }
    }

    private func copyFile(_ source: URL, _ destination: URL, expectedBytes: UInt64) throws {
        let input = try VaultSecureFileAccess.openRegularReadOnly(at: source)
        defer { try? input.close() }
        if fileManager.fileExists(atPath: destination.path) {
            try VaultSecureFileAccess.removeRegularFile(at: destination)
        }
        var destinationCreated = false
        defer {
            if destinationCreated { try? VaultSecureFileAccess.removeRegularFile(at: destination) }
        }
        let created = try VaultSecureFileAccess.createEmptyFile(at: destination)
        destinationCreated = true
        try created.close()
        try protection.apply(to: destination)
        guard (try? protection.hasRequiredProtection(at: destination)) == true else {
            throw VaultBackendError.permissionDenied
        }
        do {
            let output = try VaultSecureFileAccess.openForWriting(at: destination)
            defer { try? output.close() }
            var copied: UInt64 = 0
            while copied < expectedBytes {
                guard let chunk = try input.read(upToCount: Int(min(UInt64(1_048_576), expectedBytes - copied))),
                      !chunk.isEmpty else { throw VaultBackendError.io }
                try output.write(contentsOf: chunk); copied += UInt64(chunk.count)
            }
            guard try input.read(upToCount: 1)?.isEmpty != false else { throw VaultBackendError.io }
            try output.synchronize()
            destinationCreated = false
        } catch {
            try? VaultSecureFileAccess.removeRegularFile(at: destination)
            throw error
        }
    }

    private func filesEqual(_ lhs: URL, _ rhs: URL, expectedBytes: UInt64) throws -> Bool {
        guard fileManager.fileExists(atPath: rhs.path) else { return false }
        let attrs = try fileManager.attributesOfItem(atPath: rhs.path)
        guard (attrs[.size] as? NSNumber)?.uint64Value == expectedBytes else { return false }
        let left = try VaultSecureFileAccess.openRegularReadOnly(at: lhs)
        let right = try VaultSecureFileAccess.openRegularReadOnly(at: rhs)
        defer { try? left.close(); try? right.close() }
        var remaining = expectedBytes
        while remaining > 0 {
            let count = Int(min(UInt64(1_048_576), remaining))
            guard let a = try left.read(upToCount: count), let b = try right.read(upToCount: count), a == b else { return false }
            remaining -= UInt64(count)
        }
        let leftEnd = try left.read(upToCount: 1)?.isEmpty != false
        let rightEnd = try right.read(upToCount: 1)?.isEmpty != false
        return leftEnd && rightEnd
    }

    private func filesEqual(_ lhs: VaultVerifiedCiphertextFile, _ rhs: URL,
                            expectedBytes: UInt64) throws -> Bool {
        guard fileManager.fileExists(atPath: rhs.path) else { return false }
        let attrs = try fileManager.attributesOfItem(atPath: rhs.path)
        guard (attrs[.size] as? NSNumber)?.uint64Value == expectedBytes else { return false }
        let right = try VaultSecureFileAccess.openRegularReadOnly(at: rhs)
        defer { try? right.close() }
        var offset: UInt64 = 0
        while offset < expectedBytes {
            let count = Int(min(UInt64(1_048_576), expectedBytes - offset))
            let leftBytes = try lhs.read(offset: offset, count: count)
            guard let rightBytes = try right.read(upToCount: count), leftBytes == rightBytes else {
                return false
            }
            offset += UInt64(count)
        }
        return try right.read(upToCount: 1)?.isEmpty != false
    }

    private func coordinateReading(_ url: URL, body: (URL) throws -> Void) throws {
        var coordinationError: NSError?
        var operationError: Error?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { target in
            do { try body(target) } catch { operationError = error }
        }
        if let operationError { throw operationError }
        if coordinationError != nil { throw VaultBackendError.io }
    }
}

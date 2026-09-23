import Foundation

/// The four user-visible connection states. Transport-specific retry,
/// discovery, and BEP details deliberately stop below this boundary.
public enum VaultConnectionStatus: String, Equatable, Sendable {
    case connected = "Connected"
    case syncing = "Syncing"
    case offline = "Offline"
    case notPaired = "Not paired"
}

/// A file row ready for UIKit. `id` is opaque to the UI and is normally the
/// Syncthing folder-relative name.
public struct VaultPresentedFile: Equatable, Sendable {
    public let id: String
    public let name: String
    public let path: String
    public let snippet: String
    public let modifiedAt: Date
    public let byteCount: Int64
    public let isDirectory: Bool
    public let thumbnailData: Data?

    public init(id: String, name: String, path: String, snippet: String = "",
                modifiedAt: Date, byteCount: Int64 = 0,
                isDirectory: Bool = false, thumbnailData: Data? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.snippet = snippet
        self.modifiedAt = modifiedAt
        self.byteCount = byteCount
        self.isDirectory = isDirectory
        self.thumbnailData = thumbnailData
    }
}

/// Bytes accepted by the transport for an iPhone-originated file. Completion
/// still waits for the Mac's index acknowledgement after its final disk write.
public struct VaultPendingUpload: Equatable, Sendable {
    public let name: String
    public let totalBytes: Int64
    public let sentBytes: Int64
    public let isDeleting: Bool
    public let isDirectory: Bool

    public init(name: String, totalBytes: Int64, sentBytes: Int64,
                isDeleting: Bool, isDirectory: Bool) {
        self.name = name
        self.totalBytes = totalBytes
        self.sentBytes = sentBytes
        self.isDeleting = isDeleting
        self.isDirectory = isDirectory
    }
}

public enum VaultNetworkSelection: String, CaseIterable, Equatable, Sendable {
    case syncthingPublic
    case tailscale

    public var title: String {
        switch self {
        case .syncthingPublic: return "Syncthing public"
        case .tailscale: return "Tailscale"
        }
    }
}

public struct VaultPairingSnapshot: Equatable, Sendable {
    public let localDeviceID: String
    public let remoteDeviceID: String?
    public let remoteName: String?
    public let folderID: String?
    public let folderLabel: String?
    public let network: VaultNetworkSelection
    public let manualAddresses: [String]

    public init(localDeviceID: String, remoteDeviceID: String? = nil,
                remoteName: String? = nil, folderID: String? = nil,
                folderLabel: String? = nil,
                network: VaultNetworkSelection = .syncthingPublic,
                manualAddresses: [String] = []) {
        self.localDeviceID = localDeviceID
        self.remoteDeviceID = remoteDeviceID
        self.remoteName = remoteName
        self.folderID = folderID
        self.folderLabel = folderLabel
        self.network = network
        self.manualAddresses = manualAddresses
    }

    public var isPaired: Bool { remoteDeviceID?.isEmpty == false }
}

public struct VaultPairingDraft: Equatable, Sendable {
    public var remoteDeviceID: String
    public var remoteName: String
    public var folderID: String
    public var folderLabel: String
    public var network: VaultNetworkSelection
    public var manualAddresses: [String]

    public init(remoteDeviceID: String, remoteName: String,
                folderID: String, folderLabel: String,
                network: VaultNetworkSelection,
                manualAddresses: [String]) {
        self.remoteDeviceID = remoteDeviceID
        self.remoteName = remoteName
        self.folderID = folderID
        self.folderLabel = folderLabel
        self.network = network
        self.manualAddresses = manualAddresses
    }
}

public struct VaultCachePresentation: Equatable, Sendable {
    public let usedBytes: Int64
    public let quotaBytes: Int64
    public let fileCount: Int
    public let pinnedBytes: Int64

    public init(usedBytes: Int64, quotaBytes: Int64, fileCount: Int,
                pinnedBytes: Int64 = 0) {
        self.usedBytes = usedBytes
        self.quotaBytes = quotaBytes
        self.fileCount = fileCount
        self.pinnedBytes = pinnedBytes
    }
}

public struct VaultIndexPresentation: Equatable, Sendable {
    public let filesRemaining: Int
    public let scratchQuotaBytes: Int64
    public let isRebuilding: Bool

    public init(filesRemaining: Int, scratchQuotaBytes: Int64,
                isRebuilding: Bool = false) {
        self.filesRemaining = filesRemaining
        self.scratchQuotaBytes = scratchQuotaBytes
        self.isRebuilding = isRebuilding
    }
}

/// UI-level capabilities supplied by composition. Implementations may use the
/// folder store, sync controller, and search index, but no transport type is
/// exposed to UIKit.
public protocol VaultPresentationProviding: Sendable {
    func connectionStatus() async -> VaultConnectionStatus
    func pendingUploadCount() async throws -> Int
    func pendingUploads() async throws -> [VaultPendingUpload]
    func queuedImportCount() async throws -> Int
    func cancelPendingUpload(named name: String) async throws
    func deleteItem(named name: String) async throws
    func recentFiles(limit: Int) async throws -> [VaultPresentedFile]
    func search(_ query: String, limit: Int) async throws -> [VaultPresentedFile]
    func children(of path: String) async throws -> [VaultPresentedFile]
    func refresh() async

    func pairingSnapshot() async throws -> VaultPairingSnapshot
    func savePairing(_ draft: VaultPairingDraft) async throws
    func removePairing() async throws

    func cachePresentation() async throws -> VaultCachePresentation
    func setCacheQuota(bytes: Int64) async throws
    func clearCache() async throws

    func indexPresentation() async throws -> VaultIndexPresentation
    func setScratchQuota(bytes: Int64) async throws
    func rebuildIndex() async throws
}

public extension VaultPresentationProviding {
    func pendingUploadCount() async throws -> Int { 0 }
    func pendingUploads() async throws -> [VaultPendingUpload] { [] }
    func queuedImportCount() async throws -> Int { 0 }
    func cancelPendingUpload(named name: String) async throws {}
    func deleteItem(named name: String) async throws {}
}

/// Closure-backed composition object used by the app and deterministic tests.
/// Defaults describe an empty, unpaired Vault, so unavailable optional work
/// fails quietly without inventing transport state.
public struct VaultPresentationServices: VaultPresentationProviding, @unchecked Sendable {
    public var connectionStatusHandler: @Sendable () async -> VaultConnectionStatus
    public var pendingUploadsHandler: @Sendable () async throws -> [VaultPendingUpload]
    public var recentFilesHandler: @Sendable (Int) async throws -> [VaultPresentedFile]
    public var searchHandler: @Sendable (String, Int) async throws -> [VaultPresentedFile]
    public var childrenHandler: @Sendable (String) async throws -> [VaultPresentedFile]
    public var refreshHandler: @Sendable () async -> Void
    public var pairingSnapshotHandler: @Sendable () async throws -> VaultPairingSnapshot
    public var savePairingHandler: @Sendable (VaultPairingDraft) async throws -> Void
    public var removePairingHandler: @Sendable () async throws -> Void
    public var cachePresentationHandler: @Sendable () async throws -> VaultCachePresentation
    public var setCacheQuotaHandler: @Sendable (Int64) async throws -> Void
    public var clearCacheHandler: @Sendable () async throws -> Void
    public var indexPresentationHandler: @Sendable () async throws -> VaultIndexPresentation
    public var setScratchQuotaHandler: @Sendable (Int64) async throws -> Void
    public var rebuildIndexHandler: @Sendable () async throws -> Void

    public init(
        connectionStatus: @escaping @Sendable () async -> VaultConnectionStatus = { .notPaired },
        pendingUploads: @escaping @Sendable () async throws -> [VaultPendingUpload] = { [] },
        recentFiles: @escaping @Sendable (Int) async throws -> [VaultPresentedFile] = { _ in [] },
        search: @escaping @Sendable (String, Int) async throws -> [VaultPresentedFile] = { _, _ in [] },
        children: @escaping @Sendable (String) async throws -> [VaultPresentedFile] = { _ in [] },
        refresh: @escaping @Sendable () async -> Void = {},
        pairingSnapshot: @escaping @Sendable () async throws -> VaultPairingSnapshot = {
            VaultPairingSnapshot(localDeviceID: "Preparing device ID…")
        },
        savePairing: @escaping @Sendable (VaultPairingDraft) async throws -> Void = { _ in },
        removePairing: @escaping @Sendable () async throws -> Void = {},
        cachePresentation: @escaping @Sendable () async throws -> VaultCachePresentation = {
            VaultCachePresentation(usedBytes: 0, quotaBytes: 500 * 1_024 * 1_024, fileCount: 0)
        },
        setCacheQuota: @escaping @Sendable (Int64) async throws -> Void = { _ in },
        clearCache: @escaping @Sendable () async throws -> Void = {},
        indexPresentation: @escaping @Sendable () async throws -> VaultIndexPresentation = {
            VaultIndexPresentation(filesRemaining: 0, scratchQuotaBytes: 2 * 1_024 * 1_024 * 1_024)
        },
        setScratchQuota: @escaping @Sendable (Int64) async throws -> Void = { _ in },
        rebuildIndex: @escaping @Sendable () async throws -> Void = {}
    ) {
        connectionStatusHandler = connectionStatus
        pendingUploadsHandler = pendingUploads
        recentFilesHandler = recentFiles
        searchHandler = search
        childrenHandler = children
        refreshHandler = refresh
        pairingSnapshotHandler = pairingSnapshot
        savePairingHandler = savePairing
        removePairingHandler = removePairing
        cachePresentationHandler = cachePresentation
        setCacheQuotaHandler = setCacheQuota
        clearCacheHandler = clearCache
        indexPresentationHandler = indexPresentation
        setScratchQuotaHandler = setScratchQuota
        rebuildIndexHandler = rebuildIndex
    }

    public func connectionStatus() async -> VaultConnectionStatus { await connectionStatusHandler() }
    public func pendingUploads() async throws -> [VaultPendingUpload] { try await pendingUploadsHandler() }
    public func recentFiles(limit: Int) async throws -> [VaultPresentedFile] { try await recentFilesHandler(limit) }
    public func search(_ query: String, limit: Int) async throws -> [VaultPresentedFile] { try await searchHandler(query, limit) }
    public func children(of path: String) async throws -> [VaultPresentedFile] { try await childrenHandler(path) }
    public func refresh() async { await refreshHandler() }
    public func pairingSnapshot() async throws -> VaultPairingSnapshot { try await pairingSnapshotHandler() }
    public func savePairing(_ draft: VaultPairingDraft) async throws { try await savePairingHandler(draft) }
    public func removePairing() async throws { try await removePairingHandler() }
    public func cachePresentation() async throws -> VaultCachePresentation { try await cachePresentationHandler() }
    public func setCacheQuota(bytes: Int64) async throws { try await setCacheQuotaHandler(bytes) }
    public func clearCache() async throws { try await clearCacheHandler() }
    public func indexPresentation() async throws -> VaultIndexPresentation { try await indexPresentationHandler() }
    public func setScratchQuota(bytes: Int64) async throws { try await setScratchQuotaHandler(bytes) }
    public func rebuildIndex() async throws { try await rebuildIndexHandler() }
}

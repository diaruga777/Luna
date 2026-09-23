import Foundation
import LunaVaultBEP
import LunaVaultStore

public enum VaultSyncSessionState: Equatable, Sendable {
    case idle
    case resolving
    case connecting(VaultPeerAddress)
    case awaitingFolder
    case syncing
    case connected
    case offline(String)
}

public enum VaultSyncSessionError: Error, Equatable, Sendable, LocalizedError {
    case notPaired
    case folderNotAccepted
    case folderNotOffered(String)
    case noConnection
    case allAddressesFailed([String])
    case initialIndexTimedOut
    case uploadPending
    case uploadInterrupted(String)

    public var errorDescription: String? {
        switch self {
        case .notPaired: return "Pair your Mac first."
        case .folderNotAccepted, .folderNotOffered: return "The Mac has not shared this folder with your iPhone. Accept the request in Luna Vault on the Mac."
        case .noConnection: return "The Mac closed the connection. Keep Luna Vault open on the Mac and accept the pairing request."
        case .allAddressesFailed: return "Your iPhone could not reach the Mac. Connect both devices to the same Wi-Fi, allow Local Network access for Luna Vault in iPhone Settings, and copy a fresh code. For a Tailscale address, connect Tailscale on both devices."
        case .initialIndexTimedOut: return "The Mac did not send its file list. Accept the pairing request on the Mac, then try again."
        case .uploadPending: return "This import is saved on your iPhone but has not reached your Mac. Keep both apps open and reconnect; Vault will retry the pending upload."
        case .uploadInterrupted(let reason): return "This import is saved on your iPhone but has not reached your Mac. Transfer stopped: \(reason). Reconnect to retry."
        }
    }
}

public struct VaultRemoteFolder: Equatable, Sendable {
    public var id: String
    public var label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

public struct VaultSyncSessionCallbacks: Sendable {
    public var stateChanged: @Sendable (VaultSyncSessionState) async -> Void
    public var foldersChanged: @Sendable ([VaultRemoteFolder]) async -> Void
    public var indexApplied: @Sendable (VaultIndexApplyResult) async -> Void

    public init(stateChanged: @escaping @Sendable (VaultSyncSessionState) async -> Void = { _ in },
                foldersChanged: @escaping @Sendable ([VaultRemoteFolder]) async -> Void = { _ in },
                indexApplied: @escaping @Sendable (VaultIndexApplyResult) async -> Void = { _ in }) {
        self.stateChanged = stateChanged
        self.foldersChanged = foldersChanged
        self.indexApplied = indexApplied
    }
}

/// One authenticated BEP connection to the paired Mac. It owns index exchange,
/// request serving, file pulls, and durable local-change announcements.
public actor VaultSyncSession: BEPConnectionDelegate {
    private let store: any VaultSyncStoring
    private let dialer: any VaultPeerDialing
    private let resolver: VaultAddressResolver
    private let localDevice: DeviceID
    private let localName: String
    private let hello: BEPHello
    private let cache: VaultCacheManager
    private let fetcher: VaultBlockFetcher
    private let writer: VaultLocalChangeWriter
    private let callbacks: VaultSyncSessionCallbacks
    private let clock: @Sendable () -> Date

    private var connection: BEPConnection?
    private var state: VaultSyncSessionState = .idle
    private var receivedInitialIndex = false
    private var offeredFolders: [VaultRemoteFolder] = []
    private var invalidatedCacheNames = Set<String>()

    public init(store: any VaultSyncStoring, dialer: any VaultPeerDialing,
                lookup: (any VaultPeerLookup)?, localDevice: DeviceID,
                localName: String = "Luna Vault", clientVersion: String = "1.0",
                cache: VaultCacheManager? = nil,
                projections: VaultDeletionProjectionHandler = VaultDeletionProjectionHandler(),
                callbacks: VaultSyncSessionCallbacks = VaultSyncSessionCallbacks(),
                clock: @escaping @Sendable () -> Date = { Date() }) {
        let cache = cache ?? VaultCacheManager(store: store)
        self.store = store
        self.dialer = dialer
        resolver = VaultAddressResolver(lookup: lookup, clock: clock)
        self.localDevice = localDevice
        self.localName = localName
        hello = BEPHello(deviceName: localName, clientName: "Luna Vault", clientVersion: clientVersion)
        self.cache = cache
        fetcher = VaultBlockFetcher(store: store, cache: cache)
        writer = VaultLocalChangeWriter(store: store, cache: cache, localDevice: localDevice,
                                        projections: projections)
        self.callbacks = callbacks
        self.clock = clock
    }

    public var currentState: VaultSyncSessionState { state }
    public var isConnected: Bool {
        switch state {
        case .connected, .syncing, .awaitingFolder: return connection != nil
        default: return false
        }
    }
    public var availableFolders: [VaultRemoteFolder] { offeredFolders }

    public func start(forceLookup: Bool = false) async throws {
        if isConnected, !forceLookup { return }
        await closeConnection(reason: "Reconnect")
        guard let peer = try store.peer() else {
            await setState(.offline("Not paired"))
            throw VaultSyncSessionError.notPaired
        }
        receivedInitialIndex = false
        _ = try store.purgeStaleGenerations()
        await setState(.resolving)
        let addresses: [VaultPeerAddress]
        do { addresses = try await resolver.addresses(for: peer, forceRefresh: forceLookup) }
        catch {
            await setState(.offline(String(describing: error)))
            throw error
        }
        var failures: [String] = []
        for address in addresses {
            if Task.isCancelled { throw CancellationError() }
            await setState(.connecting(address))
            do {
                let stream = try await dialer.dial(address, expecting: peer.deviceID)
                let candidate = BEPConnection(stream: stream, peerDevice: peer.deviceID,
                                              localHello: hello, delegate: self)
                connection = candidate
                await setState(peer.isFolderAccepted ? .syncing : .awaitingFolder)
                _ = try await candidate.start()
                let entries = try store.announcedIndexEntries()
                try await candidate.send(clusterConfig: clusterConfig(peer: peer, entries: entries))
                if peer.isFolderAccepted {
                    try await candidate.send(index: BEPIndex(
                        folder: peer.folderID, files: entries,
                        lastSequence: entries.map(\.sequence).max() ?? 0, isUpdate: false))
                }
                // A successful write is not an acknowledgement from the Mac.
                // The first accepted index below establishes connection readiness.
                return
            } catch {
                if let transportError = error as? VaultTransportError, transportError == .localNetworkDenied {
                    await setState(.offline(transportError.localizedDescription))
                    throw transportError
                }
                failures.append("\(address): \(String(describing: error))")
                if let candidate = connection { await candidate.close(reason: "Dial failed") }
                connection = nil
            }
        }
        let error = VaultSyncSessionError.allAddressesFailed(failures)
        await setState(.offline("Connection failed"))
        throw error
    }

    public func stop(reason: String = "Background") async {
        await closeConnection(reason: reason)
        await setState(.idle)
    }

    public func acceptFolder(id: String, label: String? = nil) async throws {
        guard var peer = try store.peer() else { throw VaultSyncSessionError.notPaired }
        guard let offered = offeredFolders.first(where: { $0.id == id }) else {
            throw VaultSyncSessionError.folderNotOffered(id)
        }
        peer.folderID = id
        peer.folderLabel = label ?? offered.label
        try store.savePeer(peer)
        try await start(forceLookup: true)
    }

    @discardableResult
    public func waitForInitialIndex(timeout: TimeInterval = 20) async throws -> Bool {
        let deadline = clock().addingTimeInterval(max(0, timeout))
        while !receivedInitialIndex {
            guard isConnected else { throw VaultSyncSessionError.noConnection }
            guard clock() < deadline else { throw VaultSyncSessionError.initialIndexTimedOut }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        return true
    }

    public func announcePendingChanges() async throws {
        guard let connection, let peer = try store.peer() else { throw VaultSyncSessionError.noConnection }
        guard peer.isFolderAccepted else { throw VaultSyncSessionError.folderNotAccepted }
        let entries = try store.announcedIndexEntries()
        try await connection.send(index: BEPIndex(
            folder: peer.folderID, files: entries,
            lastSequence: entries.map(\.sequence).max() ?? 0,
            prevSequence: 0, isUpdate: true))
    }

    @discardableResult
    public func addFile(at sourceURL: URL, named name: String, now: Date = Date()) async throws -> VaultFileRecord {
        let record = try writer.addFile(at: sourceURL, named: name, now: now)
        if isConnected { try? await announcePendingChanges() }
        return record
    }

    /// Stage every entry before announcing the folder. Paths stay relative to
    /// the selected folder's parent so the same hierarchy appears on the Mac.
    public func addFolder(at sourceURL: URL, now: Date = Date()) async throws -> [String] {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                                         .contentModificationDateKey]
        let root = sourceURL.standardizedFileURL
        var entries: [(URL, String, Bool, Date)] = []
        func collect(_ url: URL, name: String) throws {
            try BEPFileInfo.validateName(name)
            let values = try url.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else { throw VaultLocalWriteError.unsupportedEntry(name) }
            let directory = values.isDirectory == true
            guard directory || values.isRegularFile == true else { throw VaultLocalWriteError.unsupportedEntry(name) }
            entries.append((url, name, directory, values.contentModificationDate ?? now))
            if directory {
                for child in try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys)).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    // The Mac scanner also excludes hidden entries. Do not
                    // leave an invisible upload pending forever for .DS_Store.
                    if child.lastPathComponent.hasPrefix(".") { continue }
                    try collect(child, name: name + "/" + child.lastPathComponent.precomposedStringWithCanonicalMapping)
                }
            }
        }
        try collect(root, name: root.lastPathComponent.precomposedStringWithCanonicalMapping)
        for (_, name, directory, _) in entries {
            if let existing = try store.file(named: name), !existing.deleted,
               !(directory && existing.type == .directory) {
                throw VaultLocalWriteError.fileAlreadyExists(name)
            }
        }
        var names: [String] = []
        for (url, name, directory, modified) in entries {
            try Task.checkCancellation()
            if directory {
                if let existing = try store.file(named: name), !existing.deleted { continue }
                _ = try writer.addDirectory(named: name, modified: modified, now: now)
            }
            else { _ = try writer.addFile(at: url, named: name, now: now) }
            names.append(name)
        }
        if isConnected { try? await announcePendingChanges() }
        return names
    }

    @discardableResult
    public func deleteFile(named name: String, now: Date = Date()) async throws -> VaultFileRecord? {
        let record = try await writer.deleteFile(named: name, now: now)
        if record != nil, isConnected { try await announcePendingChanges() }
        return record
    }

    @discardableResult
    public func fetchFile(named name: String, to destination: VaultBlockDestination = .cache(pinned: false),
                          now: Date = Date()) async throws -> URL {
        guard let connection, let peer = try store.peer(), peer.isFolderAccepted else {
            throw VaultSyncSessionError.noConnection
        }
        guard let file = try store.file(named: name) else { throw VaultBlockFetchError.unavailable }
        return try await fetcher.fetch(file, folderID: peer.folderID, from: connection,
                                       to: destination, now: now)
    }

    @discardableResult
    public func refreshInvalidatedCache(now: Date = Date()) async -> [String] {
        let names = invalidatedCacheNames.sorted()
        var refreshed: [String] = []
        for name in names {
            if Task.isCancelled { break }
            do {
                _ = try await fetchFile(named: name, now: now)
                invalidatedCacheNames.remove(name)
                refreshed.append(name)
            } catch {
                continue
            }
        }
        return refreshed
    }

    @discardableResult
    public func evictExpiredCache(now: Date = Date()) throws -> [String] {
        try cache.evictExpired(now: now)
    }

    // MARK: BEPConnectionDelegate

    public func connection(_ connection: BEPConnection, didReceive clusterConfig: BEPClusterConfig) async {
        guard self.connection === connection, let peer = try? store.peer() else { return }
        let folders = clusterConfig.folders
            .filter { folder in folder.devices.contains(where: { $0.id == localDevice }) }
            .map { VaultRemoteFolder(id: $0.id, label: $0.label) }
        offeredFolders = folders
        await callbacks.foldersChanged(folders)
        guard peer.isFolderAccepted else { return }
        guard folders.contains(where: { $0.id == peer.folderID }) else {
            await connection.close(reason: "The Mac has not shared this folder with this iPhone")
            return
        }
        guard let folder = clusterConfig.folders.first(where: { $0.id == peer.folderID }),
              let peerState = folder.devices.first(where: { $0.id == peer.deviceID }) else { return }
        if peerState.indexID != 0, peerState.indexID != peer.theirIndexID {
            try? store.forgetTheirIndex()
            try? store.updateTheirIndexState(indexID: peerState.indexID, maxSequence: 0)
        }
    }

    public func connection(_ connection: BEPConnection, didReceive index: BEPIndex) async {
        guard self.connection === connection, let peer = try? store.peer(),
              peer.isFolderAccepted, index.folder == peer.folderID else { return }
        do {
            let result = try store.applyIndex(index, ourShortID: localDevice.shortID, now: clock())
            for name in result.cacheInvalidated {
                try? cache.removeMaterial(name)
                invalidatedCacheNames.insert(name)
            }
            for name in result.confirmed { try? cache.setPinned(false, name: name) }
            if !index.isUpdate {
                receivedInitialIndex = true
                try store.recordConnected(at: clock())
                await setState(.connected)
            }
            await callbacks.indexApplied(result)
        } catch {
            await connection.close(reason: "Invalid index")
        }
    }

    public func connection(_ connection: BEPConnection, serve request: BEPRequest) async -> Result<Data, BEPErrorCode> {
        guard self.connection === connection, let peer = try? store.peer(),
              request.folder == peer.folderID,
              let record = try? store.file(named: request.name),
              record.isCachedCurrent,
              record.blocks.contains(where: {
                  $0.offset == request.offset && $0.size == request.size && $0.hash == request.hash
              }),
              let url = try? cache.cachedURL(for: request.name) else {
            return .failure(.noSuchFile)
        }
        do {
            let input = try FileHandle(forReadingFrom: url)
            defer { try? input.close() }
            try input.seek(toOffset: UInt64(request.offset))
            let data = try input.read(upToCount: Int(request.size)) ?? Data()
            guard data.count == Int(request.size), SHA256Digest.hash(data) == request.hash else {
                return .failure(.invalidFile)
            }
            return .success(data)
        } catch {
            return .failure(.generic)
        }
    }

    public func connection(_ connection: BEPConnection, didCloseWith error: Error?) async {
        guard self.connection === connection else { return }
        self.connection = nil
        if state != .idle { await setState(.offline(error.map { String(describing: $0) } ?? "Disconnected")) }
    }

    private func clusterConfig(peer: VaultPeerRecord, entries: [BEPFileInfo]) -> BEPClusterConfig {
        guard peer.isFolderAccepted else { return BEPClusterConfig(folders: []) }
        let local = BEPDevice(id: localDevice, name: localName, compression: .never,
                              maxSequence: entries.map(\.sequence).max() ?? 0, indexID: peer.ourIndexID)
        let remote = BEPDevice(id: peer.deviceID, name: peer.name, compression: .metadata,
                               maxSequence: peer.theirMaxSequence, indexID: peer.theirIndexID)
        return BEPClusterConfig(folders: [
            BEPFolder(id: peer.folderID, label: peer.folderLabel, devices: [local, remote])
        ])
    }

    private func closeConnection(reason: String) async {
        let old = connection
        connection = nil
        if let old { await old.close(reason: reason) }
    }

    private func setState(_ newState: VaultSyncSessionState) async {
        guard state != newState else { return }
        state = newState
        await callbacks.stateChanged(newState)
    }
}

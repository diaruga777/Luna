import Foundation
import LunaVaultBEP
import LunaVaultStore
import LunaVaultSync
import LunaVaultSearch

/// The home screen and Settings share this single durable peer and session.
public actor VaultConnectedRuntime: VaultPresentationProviding {
    public nonisolated let store: VaultFolderStore
    private let dialer: any VaultPeerDialing
    private let lookup: (any VaultPeerLookup)?
    private let localID: DeviceID
    private let session: VaultSyncSession
    private let cache: VaultCacheManager
    private let searchIndex: VaultSearchIndex
    private var busy = false

    public init(store: VaultFolderStore, dialer: any VaultPeerDialing,
                lookup: (any VaultPeerLookup)?, localID: DeviceID) throws {
        self.store = store; self.dialer = dialer; self.lookup = lookup; self.localID = localID
        cache = VaultCacheManager(store: store)
        searchIndex = try VaultSearchIndex(databaseURL: store.searchIndexURL)
        session = VaultSyncSession(store: store, dialer: dialer, lookup: lookup, localDevice: localID)
    }

    public func pair(code: String) async throws {
        let value: VaultPairingCode
        do { value = try VaultPairingCode(string: code) }
        catch {
            throw VaultTransportError.internalError("This pairing code isn’t valid. Copy a fresh code from Luna Vault on your Mac and paste the whole code here.")
        }
        try await savePairing(VaultPairingDraft(remoteDeviceID: value.deviceID.description,
            remoteName: "Luna Mac", folderID: "vault", folderLabel: "Vault",
            network: .syncthingPublic, manualAddresses: value.addresses.map(\.description)))
    }

    public func savePairing(_ draft: VaultPairingDraft) async throws {
        guard !busy else { throw VaultTransportError.internalError("A connection is already in progress. Try again when it finishes.") }
        busy = true
        defer { busy = false }
        let id = try DeviceID(string: draft.remoteDeviceID)
        if let existing = try store.peer(), existing.deviceID != id, try !store.pendingLocalChanges().isEmpty {
            throw VaultTransportError.internalError("Some files haven’t reached your current Mac yet. Let uploads finish before connecting a different Mac.")
        }
        guard id != localID else { throw VaultTransportError.internalError("Enter the Mac's code, not this iPhone's code.") }
        let addresses = try draft.manualAddresses.map { value -> VaultPeerAddress in
            guard let address = VaultPeerAddress(syncthingURL: value) else {
                throw VaultTransportError.internalError("Invalid Mac address: \(value)")
            }
            return address
        }
        let peer = VaultPeerRecord(deviceID: id, name: draft.remoteName,
            networkMode: draft.network == .tailscale ? .tailscale : .syncthingPublic,
            manualAddresses: addresses, folderID: draft.folderID, folderLabel: draft.folderLabel)
        // Verify in an isolated mirror. Failed pairing must not replace the
        // previously working Mac or wipe its files and pending local changes.
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("VaultPairing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let probeStore = try VaultFolderStore(rootURL: temporary)
        try probeStore.savePeer(peer)
        let probe = VaultSyncSession(store: probeStore, dialer: dialer,
            lookup: addresses.isEmpty ? lookup : nil, localDevice: localID)
        do {
            try await probe.start()
            try await probe.waitForInitialIndex(timeout: 60)
        } catch {
            await probe.stop(reason: "Pairing failed")
            throw error
        }
        await probe.stop(reason: "Pairing verified")
        await session.stop(reason: "Pairing changed")
        var verified = peer
        verified.lastConnectedAt = Date()
        try store.savePeer(verified)
        // Reconnect the durable mirror before reporting success to the UI.
        try await session.start()
        try await session.waitForInitialIndex()
    }

    public func removePairing() async throws {
        guard !busy else { throw VaultTransportError.internalError("Wait for pairing to finish before removing the Mac.") }
        guard try store.pendingLocalChanges().isEmpty else {
            throw VaultTransportError.internalError("Some files haven’t reached your Mac yet. Connect and let uploads finish before disconnecting.")
        }
        await session.stop(reason: "Unpaired")
        try store.removePeer()
        try searchIndex.rebuild()
    }

    public func connectionStatus() async -> VaultConnectionStatus {
        guard let peer = try? store.peer() else { return .notPaired }
        switch await session.currentState {
        case .connected: return .connected
        case .syncing, .connecting, .resolving, .awaitingFolder: return .syncing
        default: return peer.lastConnectedAt == nil ? .notPaired : .offline
        }
    }

    public func pairingSnapshot() async throws -> VaultPairingSnapshot {
        let peer = try store.peer()
        // Pre-repair code could create a row without ever contacting the Mac.
        let verified = peer?.lastConnectedAt != nil
        return VaultPairingSnapshot(localDeviceID: localID.description,
            remoteDeviceID: verified ? peer?.deviceID.description : nil,
            remoteName: verified ? peer?.name : nil,
            folderID: peer?.folderID, folderLabel: peer?.folderLabel,
            network: peer?.networkMode == .tailscale ? .tailscale : .syncthingPublic,
            manualAddresses: peer?.manualAddresses.map(\.description) ?? [])
    }

    public func refresh() async { await reconnect(force: true) }

    public func reconnect(force: Bool = false) async {
        guard !busy, (try? store.peer()?.lastConnectedAt) != nil else { return }
        busy = true
        defer { busy = false }
        do {
            try await session.start(forceLookup: force)
            try await session.waitForInitialIndex()
            _ = await session.refreshInvalidatedCache()
        } catch { /* The session's offline state retains the verified pairing. */ }
    }

    public func stop() async { await session.stop() }

    public func recentFiles(limit: Int) async throws -> [VaultPresentedFile] {
        try store.liveFiles().filter { $0.type == .file }.sorted { $0.modified > $1.modified }
            .prefix(limit).map(Self.present)
    }

    public func children(of path: String) async throws -> [VaultPresentedFile] {
        try store.children(of: path).map(Self.present)
    }

    public func search(_ query: String, limit: Int) async throws -> [VaultPresentedFile] {
        let names = Set(try searchIndex.search(query, limit: limit).map(\.filename))
        return try store.liveFiles().filter {
            $0.name.localizedCaseInsensitiveContains(query) || names.contains($0.name)
        }.prefix(limit).map(Self.present)
    }

    public func fileURL(named name: String) async throws -> URL {
        if let url = try cache.cachedURL(for: name) { return url }
        if !(await session.isConnected) { try await session.start() }
        return try await session.fetchFile(named: name)
    }

    public func importFile(at url: URL) async throws {
        try await importFile(at: url, named: url.lastPathComponent.precomposedStringWithCanonicalMapping)
    }

    public func importFile(at url: URL, named name: String) async throws {
        guard try store.peer()?.lastConnectedAt != nil else { throw VaultSyncSessionError.notPaired }
        try await ensureParentDirectories(of: name)
        _ = try await session.addFile(at: url, named: name)
    }

    public func importDirectory(named name: String) async throws {
        guard try store.peer()?.lastConnectedAt != nil else { throw VaultSyncSessionError.notPaired }
        try await ensureParentDirectories(of: name)
        if let existing = try store.file(named: name), !existing.deleted {
            guard existing.type == .directory else { throw VaultLocalWriteError.fileAlreadyExists(name) }
            return
        }
        _ = try await session.addDirectory(named: name)
    }

    public func importFolder(at url: URL) async throws -> [String] {
        guard try store.peer()?.lastConnectedAt != nil else { throw VaultSyncSessionError.notPaired }
        return try await session.addFolder(at: url)
    }

    private func ensureParentDirectories(of name: String) async throws {
        let components = name.split(separator: "/").dropLast()
        var path = ""
        for component in components {
            path = path.isEmpty ? String(component) : path + "/" + component
            if let existing = try store.file(named: path), !existing.deleted {
                guard existing.type == .directory else { throw VaultLocalWriteError.fileAlreadyExists(path) }
            } else { _ = try await session.addDirectory(named: path) }
        }
    }

    public func pendingUploadCount() async throws -> Int { try store.pendingLocalChanges().count }

    public func queuedImportCount() async throws -> Int {
        let inbox = store.rootURL.appendingPathComponent("Incoming", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? []
        return files.filter {
            !$0.lastPathComponent.hasPrefix(".") &&
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("item.json").path)
        }.count
    }

    public func pendingUploads() async throws -> [VaultPendingUpload] {
        let sent = await session.sentBytesByFile
        return try store.pendingLocalChanges().compactMap { change in
            guard let record = try store.file(named: change.name) else { return nil }
            return VaultPendingUpload(name: change.name,
                totalBytes: change.kind == .add ? record.size : 0,
                sentBytes: change.kind == .add ? min(record.size, sent[change.name] ?? 0) : 0,
                isDeleting: change.kind == .delete, isDirectory: record.type == .directory)
        }
    }

    public func cancelPendingUpload(named name: String) async throws {
        try await session.cancelPendingUpload(named: name)
    }

    public func deleteItem(named name: String) async throws {
        guard try store.peer()?.lastConnectedAt != nil else { throw VaultSyncSessionError.notPaired }
        try await session.deleteItem(named: name)
    }

    /// Mac confirmation arrives only after it has written and indexed the bytes.
    public func waitForUpload(names: [String], timeout: TimeInterval? = nil) async throws {
        let wanted = Set(names)
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while true {
            try Task.checkCancellation()
            let pending = try store.pendingLocalChanges()
            if pending.contains(where: { wanted.contains($0.name) && $0.kind == .delete }) {
                throw CancellationError()
            }
            if Set(pending.map(\.name)).isDisjoint(with: wanted) { return }
            guard await session.isConnected else {
                if case .offline(let reason) = await session.currentState {
                    throw VaultSyncSessionError.uploadInterrupted(reason)
                }
                throw VaultSyncSessionError.uploadPending
            }
            if let deadline, Date() >= deadline { throw VaultSyncSessionError.uploadPending }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    public func cachePresentation() async throws -> VaultCachePresentation {
        let totals = try store.cacheTotals()
        return VaultCachePresentation(usedBytes: totals.bytes, quotaBytes: try store.settings().cacheQuotaBytes,
            fileCount: totals.count, pinnedBytes: totals.pinnedBytes)
    }
    public func setCacheQuota(bytes: Int64) async throws {
        var settings = try store.settings(); settings.cacheQuotaBytes = max(0, bytes); try store.saveSettings(settings)
    }
    public func clearCache() async throws { _ = try cache.clearUnpinned() }
    public func indexPresentation() async throws -> VaultIndexPresentation {
        VaultIndexPresentation(filesRemaining: try store.indexBacklogCount(), scratchQuotaBytes: try store.settings().scratchQuotaBytes)
    }
    public func setScratchQuota(bytes: Int64) async throws {
        var settings = try store.settings(); settings.scratchQuotaBytes = max(0, bytes); try store.saveSettings(settings)
    }
    public func rebuildIndex() async throws {
        try searchIndex.rebuild(); try store.markAllNeedingIndex()
        _ = await VaultNightlyIndexer(store: store, search: searchIndex).run()
    }
    private static func present(_ file: VaultFileRecord) -> VaultPresentedFile {
        VaultPresentedFile(id: file.name, name: file.displayName, path: file.name,
            modifiedAt: file.modified, byteCount: file.size, isDirectory: file.type == .directory)
    }
}

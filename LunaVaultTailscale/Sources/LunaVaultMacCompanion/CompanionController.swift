import AppKit
import Foundation
import LunaCodeMac
import LunaVaultBEP
import LunaVaultMacPeer
import LunaVaultTailscale

final class CompanionController: @unchecked Sendable {
    private let lock = NSLock()
    private let scanQueue = DispatchQueue(label: "LunaMac.folderScan", qos: .utility)
    private let stateURL: URL
    private let transport: LunaVaultGoTransport
    private var folderURL: URL
    private var status = "Starting…"
    private var code: String?
    private var pairingUntil = Date.distantPast
    private var listener: LunaVaultGoListener?
    private var active = CompanionSessions()
    private var codeService: CodeService?
    private let account: CompanionAccountGate
    private var configuredClients: Set<LunaMacClient>
    private var selectedGeneration = 0

    var isPaired: Bool { account.trustedDevice != nil }
    var clients: [LunaMacClient] { lock.withLock { LunaMacClient.allCases.filter { configuredClients.contains($0) } } }
    var sharedFolderPath: String { lock.withLock { folderURL.path } }
    var pairingCode: String? { lock.withLock { code } }
    var statusText: String { CompanionFileAccess.shared.statusMessage ?? lock.withLock { status } }
    init() {
        stateURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Luna Vault", isDirectory: true)
        folderURL = UserDefaults.standard.url(forKey: "LunaVaultCompanion.folder")
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Luna Vault")
        let trusted = UserDefaults.standard.string(forKey: "LunaVaultCompanion.trustedDevice").flatMap { try? DeviceID(string: $0) }
        account = CompanionAccountGate(trustedDevice: trusted)
        configuredClients = trusted == nil ? [] : Set((UserDefaults.standard.stringArray(forKey: "LunaMac.configuredClients") ?? []).compactMap(LunaMacClient.init(rawValue:)))
        transport = LunaVaultGoTransport(configuration: .init(stateDirectory: stateURL.appendingPathComponent("Identity")))
    }
    func openPairingWindow() { lock.withLock { pairingUntil = Date().addingTimeInterval(300) } }
    func forgetConnection() {
        let old = lock.withLock { () -> [(BEPConnection, CompanionBEPDelegate)] in
            account.reset(); configuredClients.removeAll(); selectedGeneration += 1
            pairingUntil = Date().addingTimeInterval(300)
            UserDefaults.standard.removeObject(forKey: "LunaVaultCompanion.trustedDevice")
            UserDefaults.standard.removeObject(forKey: "LunaMac.configuredClients")
            let old = Array(active.values); active.removeAll(); status = "Ready to Connect"
            return old
        }
        for connection in old { connection.1.revoke(); connection.0.stream.close() }
        Task { for connection in old { await connection.0.close(reason: "Connection forgotten on Mac") } }
    }
    private func clientStarted(_ client: LunaMacClient, device: DeviceID, generation: Int) {
        lock.withLock {
            guard account.trustedDevice == device, selectedGeneration == generation else { return }
            configuredClients.insert(client)
            UserDefaults.standard.set(configuredClients.map(\.rawValue).sorted(), forKey: "LunaMac.configuredClients")
        }
    }
    private func handleCode(_ data: Data) async -> Data {
        let service = lock.withLock { () -> CodeService? in
            if codeService == nil { codeService = try? CodeService(root: stateURL.appendingPathComponent("Code", isDirectory: true), checkAccess: { path in
                try await CompanionFileAccess.shared.checkDirectory(URL(fileURLWithPath: path, isDirectory: true))
            }) }
            return codeService
        }
        guard let service else { return Data() }
        return await service.handle(data)
    }
    func selectFolder(_ url: URL) {
        lock.withLock { folderURL = url; selectedGeneration += 1; status = "Folder selected: \(url.lastPathComponent). Reconnect the iPhone to refresh." }
        UserDefaults.standard.set(url, forKey: "LunaVaultCompanion.folder")
        Task {
            let old = lock.withLock { let old = Array(active.values); active.removeAll(); return old }
            for connection in old { await connection.0.close(reason: "Shared folder changed") }
        }
    }
    func start() {
        Task {
            do {
                try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: true)
                let localID = try transport.identity()
                let listener: LunaVaultGoListener
                do {
                    // Syncthing commonly already owns 22000 on the user's Mac.
                    listener = try await transport.listen(bindAddress: "0.0.0.0:49200")
                } catch {
                    // The pairing code carries the actual bound port, so an
                    // available system-assigned port remains fully usable.
                    listener = try await transport.listen(bindAddress: "0.0.0.0:0")
                }
                let addresses = await listener.announcedAddresses.compactMap(VaultPeerAddress.init(syncthingURL:))
                lock.withLock {
                    self.listener = listener
                    code = VaultPairingCode(deviceID: localID, addresses: addresses).text
                    status = account.trustedDevice == nil ? "Ready to Connect" : "Waiting for Apps"
                    pairingUntil = Date().addingTimeInterval(300)
                }
                while !Task.isCancelled {
                    let accepted = try await listener.accept()
                    // Approval and BEP work must not block the next TLS accept.
                    Task { await self.handle(accepted, localID: localID) }
                }
            } catch { lock.withLock { status = "Could not start Luna Mac: \(error)" } }
        }
    }

    private func handle(_ accepted: VaultAcceptedPeer, localID: DeviceID) async {
        let allowed = lock.withLock { account.allows(accepted.device, pairingOpen: Date() < pairingUntil) }
        guard allowed else { accepted.stream.close(); return }
        var openedConnection: BEPConnection?
        do {
            let (folder, generation) = lock.withLock { (folderURL, selectedGeneration) }
            // Reuse the durable snapshot for the handshake; refresh it after services are ready.
            let index = try CompanionIndex(databaseURL: stateURL.appendingPathComponent("companion.sqlite"))
            let delegate = CompanionBEPDelegate(rootURL: folder, index: index, localDevice: localID, folderID: "vault", codeHandler: { [weak self] data in
                guard let self else { return Data() }; return await self.handleCode(data)
            }, clientStarted: { [weak self] client in
                self?.clientStarted(client, device: accepted.device, generation: generation)
            })
            let connection = BEPConnection(stream: accepted.stream, peerDevice: accepted.device,
                localHello: BEPHello(deviceName: Host.current().localizedName ?? "Luna Mac", clientName: "Luna Mac", clientVersion: "1.0"),
                delegate: delegate)
            openedConnection = connection
            let hello = try await connection.start()
            let accountGeneration = account.generation
            if account.trustedDevice != accepted.device {
                let approved = await MainActor.run {
                    NSApp.activate(ignoringOtherApps: true)
                    let alert = NSAlert()
                    alert.messageText = "Connect your Luna apps to this Mac?"
                    alert.informativeText = "\(hello.deviceName) can read files throughout this Mac, subject to macOS permissions. Vault syncs \(folder.path). Luna Code can save text files and run Xcode builds and TestFlight deployments using this Mac’s configured account.\n\nDevices with the same iCloud Passwords & Keychain will share this authorization. A different account cannot connect until you forget this connection here.\n\nIdentity: \(accepted.device.description)"
                    alert.addButton(withTitle: "Accept"); alert.addButton(withTitle: "Reject")
                    return alert.runModal() == .alertFirstButtonReturn
                }
                guard approved else { await connection.close(reason: "Pairing rejected on Mac"); return }
                let saved = lock.withLock { () -> Bool in
                    guard generation == selectedGeneration, account.approve(accepted.device, generation: accountGeneration) else { return false }
                    pairingUntil = .distantPast
                    UserDefaults.standard.set(accepted.device.description, forKey: "LunaVaultCompanion.trustedDevice")
                    return true
                }
                guard saved else { await connection.close(reason: "Another Luna account is already connected"); return }
            }
            guard lock.withLock({ generation == selectedGeneration && account.trustedDevice == accepted.device }) else {
                await connection.close(reason: "Shared folder changed"); return
            }
            let connectionID = UUID()
            let registration = lock.withLock { () -> (Bool, (BEPConnection, CompanionBEPDelegate)?) in
                guard generation == selectedGeneration, account.trustedDevice == accepted.device else { return (false, nil) }
                return (true, active.insert((connection, delegate), for: connectionID))
            }
            guard registration.0 else { await connection.close(reason: "Connection changed"); return }
            if let retired = registration.1 {
                // A trusted reconnect must make progress even if half-open
                // sessions from the previous network have filled the limit.
                retired.1.revoke()
                retired.0.stream.close()
                await retired.0.close(reason: "Replaced by a newer connection")
            }
            defer {
                delegate.revoke()
                connection.stream.close()
                lock.withLock {
                    active.removeValue(forKey: connectionID)
                    status = active.isEmpty ? "Apps Offline" : "Connected"
                }
            }
            try index.prepareSnapshot(root: folder)
            try await CompanionInitialExchange.send(connection: connection, delegate: delegate, index: index,
                config: BEPClusterConfig(folders: [BEPFolder(id: "vault", label: folder.lastPathComponent,
                    devices: [BEPDevice(id: localID, name: "Luna Mac"), BEPDevice(id: accepted.device, name: hello.deviceName)])]))
            lock.withLock { status = "Connected" }
            let scanner = CompanionFolderScanner(rootURL: folder, deviceShortID: localID.shortID)
            var lastScan: [CompanionFileRecord]?
            while !(await connection.isClosed) {
                guard lock.withLock({ active[connectionID]?.0 === connection && generation == selectedGeneration }) else { return }
                do {
                    try await CompanionFileAccess.shared.checkDirectory(folder.deletingLastPathComponent())
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try await CompanionFileAccess.shared.checkDirectory(folder)
                    try FileManager.default.createDirectory(at: folder.appendingPathComponent("Music"), withIntermediateDirectories: true)
                    try await CompanionFileAccess.shared.checkTree(folder)
                    let indexed = try index.all()
                    // Filesystem enumeration/hashing may stall on a mounted or
                    // protected folder. Never occupy the Swift executor needed
                    // by connection timers and Code/Music requests.
                    let scan: [CompanionFileRecord] = try await withCheckedThrowingContinuation { continuation in
                        scanQueue.async { [self] in
                            guard lock.withLock({ active[connectionID]?.0 === connection && generation == selectedGeneration }) else {
                                continuation.resume(throwing: BEPStreamError.closed); return
                            }
                            continuation.resume(with: Result {
                                try scanner.scan(previous: Dictionary(uniqueKeysWithValues: indexed.map { ($0.name, $0) }))
                            })
                        }
                    }
                    guard lock.withLock({ active[connectionID]?.0 === connection && generation == selectedGeneration }),
                          !(await connection.isClosed) else { return }
                    if scan != lastScan {
                        try index.reconcileScan(scan, deviceShortID: localID.shortID)
                        let updated = try index.all()
                        try await connection.send(index: BEPIndex(folder: "vault", files: updated,
                            lastSequence: updated.map(\.sequence).max() ?? 0, isUpdate: false))
                        lastScan = scan
                    }
                } catch {
                    if await connection.isClosed { return }
                    // A Vault folder problem must not take down the shared
                    // authenticated channel used by Code and Music.
                    lock.withLock { status = "Connected. Folder sync: \(error.localizedDescription)" }
                }
                try await Task.sleep(for: .seconds(5))
            }
        } catch {
            if let openedConnection { await openedConnection.close(reason: error.localizedDescription) }
            else { accepted.stream.close() }
            lock.withLock { status = "Connection failed: \(error)" }
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}

import AppKit
import Foundation
import LunaCodeMac
import LunaVaultBEP
import LunaVaultMacPeer
import LunaVaultTailscale

final class CompanionController: @unchecked Sendable {
    private let lock = NSLock()
    private let stateURL: URL
    private let transport: LunaVaultGoTransport
    private var folderURL: URL
    private var status = "Starting…"
    private var code: String?
    private var pairingUntil = Date.distantPast
    private var listener: LunaVaultGoListener?
    private var active: [UUID: (BEPConnection, CompanionBEPDelegate)] = [:]
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
            // A fresh scan each connection guarantees reconnect sees changed files.
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
            let registered = lock.withLock { () -> Bool in
                guard generation == selectedGeneration, account.trustedDevice == accepted.device, active.count < 8 else { return false }
                active[connectionID] = (connection, delegate)
                return true
            }
            guard registered else { await connection.close(reason: "Connection changed or too many sessions"); return }
            defer { _ = lock.withLock { active.removeValue(forKey: connectionID) } }
            try await CompanionFileAccess.shared.checkDirectory(folder.deletingLastPathComponent())
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try await CompanionFileAccess.shared.checkDirectory(folder)
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("Music"), withIntermediateDirectories: true)
            try await CompanionFileAccess.shared.checkTree(folder)
            let scanner = CompanionFolderScanner(rootURL: folder, deviceShortID: localID.shortID)
            let existing = Dictionary(uniqueKeysWithValues: try index.all().map { ($0.name, $0) })
            try index.reconcileScan(scanner.scan(previous: existing), deviceShortID: localID.shortID)
            try await connection.send(clusterConfig: BEPClusterConfig(folders: [BEPFolder(id: "vault", label: folder.lastPathComponent,
                devices: [BEPDevice(id: localID, name: "Luna Mac"), BEPDevice(id: accepted.device, name: hello.deviceName)])]))
            let files = try index.all()
            // The iPhone can request a block as soon as it reads this index.
            // Authorize serving before the index is put on the wire.
            delegate.startServing(connection)
            try await connection.send(index: BEPIndex(folder: "vault", files: files,
                lastSequence: files.map(\.sequence).max() ?? 0, isUpdate: false))
            lock.withLock { status = "Connected" }
            var lastScan = try scanner.scan(previous: Dictionary(uniqueKeysWithValues: files.map { ($0.name, $0) }))
            while !(await connection.isClosed) {
                try await Task.sleep(for: .seconds(5))
                guard lock.withLock({ active[connectionID]?.0 === connection && generation == selectedGeneration }) else { return }
                try await CompanionFileAccess.shared.checkTree(folder)
                let indexed = try index.all()
                let scan = try scanner.scan(previous: Dictionary(uniqueKeysWithValues: indexed.map { ($0.name, $0) }))
                if scan != lastScan {
                    try index.reconcileScan(scan, deviceShortID: localID.shortID)
                    let updated = try index.all()
                    try await connection.send(index: BEPIndex(folder: "vault", files: updated,
                        lastSequence: updated.map(\.sequence).max() ?? 0, isUpdate: false))
                    lastScan = scan
                }
            }
            lock.withLock {
                if active[connectionID]?.0 === connection { active.removeValue(forKey: connectionID); status = active.isEmpty ? "Apps Offline" : "Connected" }
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

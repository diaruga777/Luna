import LunaCodeMac
import AppKit
import Foundation
import LunaVaultBEP
import LunaVaultMacPeer
import LunaVaultTailscale

@main @MainActor
final class LunaVaultCompanionApp: NSObject, NSApplicationDelegate {
    // This SwiftPM app has no nib to instantiate and retain its delegate.
    // NSApplicationMain alone leaves a running process with no UI or listener.
    static func main() {
        let app = NSApplication.shared
        let delegate = LunaVaultCompanionApp()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    private var window: NSWindow!
    private var statusItem: NSStatusItem!
    private var controller: CompanionController!
    private let codeField = NSTextField(wrappingLabelWithString: "Starting…")
    private let statusField = NSTextField(wrappingLabelWithString: "Starting…")
    private let featuresField = NSTextField(wrappingLabelWithString: "")
    private var chooseButton: NSButton!
    private var forgetButton: NSButton!
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        controller = CompanionController()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Luna Mac"; window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 540, height: 640)
        let heading = NSTextField(labelWithString: "Luna Mac")
        heading.font = .systemFont(ofSize: 24, weight: .semibold)
        let instructions = NSTextField(wrappingLabelWithString: "Open any Luna app on your iPhone or iPad, paste this Mac’s connection code, then approve here. Pair once. Your Luna apps and devices using the same iCloud Passwords & Keychain share one connection.")
        codeField.isSelectable = true; codeField.maximumNumberOfLines = 4
        codeField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        let copy = NSButton(title: "Copy connection code", target: self, action: #selector(copyCode))
        chooseButton = NSButton(title: "Choose shared folder…", target: self, action: #selector(chooseFolder))
        forgetButton = NSButton(title: "Forget Luna connection…", target: self, action: #selector(forgetConnection))
        chooseButton.isHidden = true; forgetButton.isHidden = true
        let permissions = NSButton(title: "Open Privacy & Security…", target: self, action: #selector(openPrivacySettings))
        let stack = NSStackView(views: [heading, instructions, codeField, copy, statusField, permissions, featuresField, chooseButton, forgetButton])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = CompanionDocumentView(); document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document; document.addSubview(stack)
        window.contentView!.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -28),
            instructions.widthAnchor.constraint(equalTo: stack.widthAnchor),
            codeField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            featuresField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusField.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Luna Mac"
        let menu = NSMenu()
        for (title, selector) in [("Open Luna Mac", #selector(showWindow)),
                                   ("Copy connection code", #selector(copyCode)),
                                   ("Quit Luna Mac", #selector(quit))] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        statusItem.menu = menu
        window.center(); showWindow()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.codeField.stringValue = self.controller.pairingCode ?? "Starting…"
                self.statusField.stringValue = self.controller.statusText
                self.statusField.textColor = CompanionFileAccess.shared.statusMessage == nil ? .labelColor : .systemOrange
                let clients = self.controller.clients
                self.featuresField.stringValue = clients.isEmpty ? "Your apps appear here after they connect." : clients.map {
                    switch $0 {
                    case .vault: return "Luna Vault · Browse Mac files and sync \(self.controller.sharedFolderPath)"
                    case .music: return "Luna Music · Add songs to Music/Artist/Album in \(self.controller.sharedFolderPath)"
                    case .code: return "Luna Code · Edit source files and run Xcode builds with this Mac’s developer setup."
                    }
                }.joined(separator: "\n\n")
                self.chooseButton.isHidden = !clients.contains(.vault) && !clients.contains(.music)
                self.forgetButton.isHidden = !self.controller.isPaired
            }
        }
        controller.start()
    }
    @objc private func showWindow() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc private func copyCode() {
        guard let code = controller.pairingCode else { return }
        controller.openPairingWindow()
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string)
        statusField.stringValue = "Code copied. Paste it in Luna on your iPhone or iPad."
    }
    @objc private func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.prompt = "Share folder"
        if panel.runModal() == .OK, let url = panel.url { controller.selectFolder(url) }
    }
    @objc private func forgetConnection() {
        let alert = NSAlert()
        alert.messageText = "Forget the Luna connection?"
        alert.informativeText = "All Luna apps and devices using this connection will lose access. Files stay on your Mac. Pair again to reconnect, or pair a different iCloud account."
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Forget Connection")
        if alert.runModal() == .alertSecondButtonReturn { controller.forgetConnection() }
    }
    @objc private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") { NSWorkspace.shared.open(url) }
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

private final class CompanionDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class CompanionController: @unchecked Sendable {
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
            let old = Array(active.values); active.removeAll(); status = "Ready to connect a Luna account"
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
                    status = account.trustedDevice == nil ? "Ready to connect" : "Luna account connected · Waiting for your apps"
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
            lock.withLock { status = "Connected · \(active.count) Luna sessions" }
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
                if active[connectionID]?.0 === connection { active.removeValue(forKey: connectionID); status = active.isEmpty ? "Luna account connected · Apps offline" : "Connected · \(active.count) Luna sessions" }
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

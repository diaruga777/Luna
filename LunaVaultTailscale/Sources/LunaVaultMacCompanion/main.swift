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
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        controller = CompanionController()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Luna Vault"; window.isReleasedWhenClosed = false
        let heading = NSTextField(labelWithString: "Luna Vault on Mac")
        heading.font = .systemFont(ofSize: 24, weight: .semibold)
        let instructions = NSTextField(wrappingLabelWithString: "Choose a folder, copy the pairing code, and paste it in Vault Settings on your iPhone. Accept the request here to browse this Mac from your iPhone. Only the Vault folder is indexed and writable; other folders are read only.")
        codeField.isSelectable = true; codeField.maximumNumberOfLines = 4
        codeField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        let copy = NSButton(title: "Copy pairing code", target: self, action: #selector(copyCode))
        let choose = NSButton(title: "Choose folder…", target: self, action: #selector(chooseFolder))
        let stack = NSStackView(views: [heading, instructions, choose, codeField, copy, statusField])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 28),
            instructions.widthAnchor.constraint(equalTo: stack.widthAnchor),
            codeField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusField.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Luna Vault"
        let menu = NSMenu()
        for (title, selector) in [("Open Luna Vault", #selector(showWindow)),
                                   ("Copy pairing code", #selector(copyCode)),
                                   ("Choose folder…", #selector(chooseFolder)),
                                   ("Quit Luna Vault", #selector(quit))] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        statusItem.menu = menu
        window.center(); showWindow()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.codeField.stringValue = self.controller.pairingCode ?? "Starting…"
                self.statusField.stringValue = self.controller.statusText
            }
        }
        controller.start()
    }
    @objc private func showWindow() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc private func copyCode() {
        guard let code = controller.pairingCode else { return }
        controller.openPairingWindow()
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string)
        statusField.stringValue = "Code copied. Paste it on the iPhone, then accept its request here."
    }
    @objc private func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.prompt = "Share folder"
        if panel.runModal() == .OK, let url = panel.url { controller.selectFolder(url) }
    }
    @objc private func quit() { NSApp.terminate(nil) }
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
    private var active: (BEPConnection, CompanionBEPDelegate)?
    private var trustedID: String?
    private var selectedGeneration = 0

    var pairingCode: String? { lock.withLock { code } }
    var statusText: String { lock.withLock { status } }
    init() {
        stateURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Luna Vault", isDirectory: true)
        folderURL = UserDefaults.standard.url(forKey: "LunaVaultCompanion.folder")
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Luna Vault")
        trustedID = UserDefaults.standard.string(forKey: "LunaVaultCompanion.trustedDevice")
        transport = LunaVaultGoTransport(configuration: .init(stateDirectory: stateURL.appendingPathComponent("Identity")))
    }
    func openPairingWindow() { lock.withLock { pairingUntil = Date().addingTimeInterval(300) } }
    func selectFolder(_ url: URL) {
        lock.withLock { folderURL = url; selectedGeneration += 1; status = "Folder selected: \(url.lastPathComponent). Reconnect the iPhone to refresh." }
        UserDefaults.standard.set(url, forKey: "LunaVaultCompanion.folder")
        Task {
            let old = lock.withLock { () -> (BEPConnection, CompanionBEPDelegate)? in defer { active = nil }; return active }
            if let old { await old.0.close(reason: "Shared folder changed") }
        }
    }
    func start() {
        Task {
            do {
                try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: true)
                let folder = lock.withLock { folderURL }
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
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
                    status = "Ready · \(folder.path)"
                    pairingUntil = Date().addingTimeInterval(300)
                }
                while !Task.isCancelled {
                    let accepted = try await listener.accept()
                    // Approval and BEP work must not block the next TLS accept.
                    Task { await self.handle(accepted, localID: localID) }
                }
            } catch { lock.withLock { status = "Could not start Vault: \(error)" } }
        }
    }

    private func handle(_ accepted: VaultAcceptedPeer, localID: DeviceID) async {
        let allowed = lock.withLock { trustedID == accepted.device.description || Date() < pairingUntil }
        guard allowed else { accepted.stream.close(); return }
        do {
            let (folder, generation) = lock.withLock { (folderURL, selectedGeneration) }
            // A fresh scan each connection guarantees reconnect sees changed files.
            let index = try CompanionIndex(databaseURL: stateURL.appendingPathComponent("companion.sqlite"))
            let delegate = CompanionBEPDelegate(rootURL: folder, index: index, localDevice: localID, folderID: "vault")
            let connection = BEPConnection(stream: accepted.stream, peerDevice: accepted.device,
                localHello: BEPHello(deviceName: Host.current().localizedName ?? "Luna Mac", clientName: "Luna Vault", clientVersion: "1.0"),
                delegate: delegate)
            let hello = try await connection.start()
            if !lock.withLock({ trustedID == accepted.device.description }) {
                let approved = await MainActor.run {
                    NSApp.activate(ignoringOtherApps: true)
                    let alert = NSAlert()
                    alert.messageText = "Allow this iPhone to browse your Mac?"
                    alert.informativeText = "\(hello.deviceName) can read files throughout this Mac, subject to macOS permissions. Only \(folder.path) is indexed and can receive uploads or deletions.\n\nDevice: \(accepted.device.description)"
                    alert.addButton(withTitle: "Accept"); alert.addButton(withTitle: "Reject")
                    return alert.runModal() == .alertFirstButtonReturn
                }
                guard approved else { await connection.close(reason: "Pairing rejected on Mac"); return }
                lock.withLock { trustedID = accepted.device.description; pairingUntil = .distantPast }
                UserDefaults.standard.set(accepted.device.description, forKey: "LunaVaultCompanion.trustedDevice")
            }
            guard lock.withLock({ generation == selectedGeneration }) else {
                await connection.close(reason: "Shared folder changed"); return
            }
            let old = lock.withLock { () -> (BEPConnection, CompanionBEPDelegate)? in
                let old = active; active = (connection, delegate); return old
            }
            if let old { await old.0.close(reason: "iPhone reconnected") }
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
            lock.withLock { status = "Connected · \(files.filter { $0.type == .file }.count) files · \(folder.path)" }
            var lastScan = try scanner.scan(previous: Dictionary(uniqueKeysWithValues: files.map { ($0.name, $0) }))
            while !(await connection.isClosed) {
                try await Task.sleep(for: .seconds(5))
                guard lock.withLock({ active?.0 === connection && generation == selectedGeneration }) else { return }
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
                if active?.0 === connection { active = nil; status = "iPhone offline · \(folder.path)" }
            }
        } catch {
            accepted.stream.close()
            lock.withLock { status = "Connection failed: \(error)" }
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}

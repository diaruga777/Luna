import AppKit
import CoreImage
import Foundation
import LunaVaultBEP
import LunaVaultMacPeer
import LunaVaultTailscale

/// Luna Vault's companion is intentionally a menu-bar accessory rather than a
/// document app. It owns one selected folder, one embedded tailnet identity,
/// and one BEP listener; all details stay behind the status item.
@main
@MainActor
final class LunaVaultCompanionApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var controller: CompanionController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = CompanionController()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Luna Vault"
        statusItem.menu = makeMenu()
        controller.start()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let status = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
        status.tag = 100
        menu.addItem(status)
        menu.addItem(.separator())
        menu.addItem(item: "Choose Folder…", action: #selector(chooseFolder))
        menu.addItem(item: "Pair iPhone…", action: #selector(pairPhone))
        menu.addItem(item: "Copy Device ID", action: #selector(copyDeviceID))
        menu.addItem(.separator())
        let network = NSMenuItem(title: "Announce on Syncthing discovery", action: #selector(toggleNetwork), keyEquivalent: "")
        network.tag = 101
        network.state = .on
        menu.addItem(network)
        menu.addItem(item: "Quit Luna Vault", action: #selector(quit), keyEquivalent: "q")
        menu.delegate = self
        return menu
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        controller.selectFolder(url)
    }

    @objc private func pairPhone() { controller.showPairing(on: statusItem.button?.window) }

    @objc private func copyDeviceID() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(controller.deviceIDText, forType: .string)
    }

    @objc private func toggleNetwork(_ item: NSMenuItem) {
        item.state = item.state == .on ? .off : .on
        controller.setDiscoveryEnabled(item.state == .on)
    }

    @objc private func quit() { NSApplication.shared.terminate(nil) }

    @MainActor
    func menuWillOpen(_ menu: NSMenu) {
        menu.item(withTag: 100)?.title = controller.statusText
        menu.item(withTag: 101)?.state = controller.discoveryEnabled ? .on : .off
    }
}

private extension NSMenu {
    func addItem(item title: String, action: Selector, keyEquivalent: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = NSApp.delegate
        addItem(item)
    }
}

private final class CompanionController: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private let rootStateURL: URL
    private var folderURL: URL
    private var discovery = true
    private var status = "Starting…"
    private var identity: DeviceID?
    private var transport: LunaVaultGoTransport!
    private var tailnet: VaultTailnetNodeRunner!
    private var index: CompanionIndex!
    private var listener: LunaVaultGoListener?
    private var listenerTask: Task<Void, Never>?

    var discoveryEnabled: Bool { lock.withLock { discovery } }
    var statusText: String { lock.withLock { status } }
    var deviceIDText: String { lock.withLock { identity?.description ?? "Unavailable until transport is built" } }

    override init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Luna Vault", isDirectory: true)
        rootStateURL = appSupport
        folderURL = UserDefaults.standard.url(forKey: "LunaVaultCompanion.folder")
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Luna Vault")
        super.init()
        try? FileManager.default.createDirectory(at: rootStateURL, withIntermediateDirectories: true)
        tailnet = VaultTailnetNodeRunner(configuration: VaultTailnetConfiguration(
            stateDirectory: rootStateURL.appendingPathComponent("Tailnet"), hostName: "luna-vault-mac"))
        let tailnet = self.tailnet!
        transport = LunaVaultGoTransport(configuration: .init(
            stateDirectory: rootStateURL.appendingPathComponent("Identity"),
            tailnetHandle: { try await tailnet.currentHandle() ?? 0 }))
        index = try? CompanionIndex(databaseURL: rootStateURL.appendingPathComponent("companion.sqlite"))
    }

    func start() { Task { await refresh() } }

    func selectFolder(_ url: URL) {
        lock.withLock { folderURL = url; status = "Scanning (url.lastPathComponent)…" }
        UserDefaults.standard.set(url, forKey: "LunaVaultCompanion.folder")
        Task { await refresh() }
    }

    func setDiscoveryEnabled(_ enabled: Bool) { lock.withLock { discovery = enabled } }

    func showPairing(on window: NSWindow?) {
        let id = deviceIDText
        let payload = "luna-vault://pair?device=\(id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? id)"
        let alert = NSAlert()
        alert.messageText = "Pair iPhone"
        alert.informativeText = "Scan this pairing code on the iPhone, then keep Luna Vault open to accept the request.\n\n\(payload)"
        if let image = Self.qrImage(for: payload) { alert.accessoryView = NSImageView(image: image) }
        alert.addButton(withTitle: "Done")
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    private func refresh() async {
        do {
            let localID = try transport.identity()
            lock.withLock { identity = localID }
            let scanner = CompanionFolderScanner(rootURL: folderURL, deviceShortID: localID.shortID)
            let records = try scanner.scan()
            try index.replace(with: records)
            lock.withLock { status = "Ready · \(records.filter { $0.info.type == .file }.count) files" }
            try await startListener(localID: localID)
        } catch {
            lock.withLock { status = "Transport unavailable · build libtailscale first" }
        }
    }

    private func startListener(localID: DeviceID) async throws {
        guard listener == nil else { return }
        let current = try await transport.listen(bindAddress: "0.0.0.0:22000")
        listener = current
        listenerTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let accepted = try await current.accept()
                    let delegate = CompanionBEPDelegate(rootURL: self.folderURL, index: self.index,
                        localDevice: localID, folderID: "vault")
                    let hello = BEPHello(deviceName: Host.current().localizedName ?? "Luna Mac",
                                         clientName: "Luna Vault", clientVersion: "1.0")
                    let connection = BEPConnection(stream: accepted.stream, peerDevice: accepted.device,
                        localHello: hello, delegate: delegate)
                    _ = try await connection.start()
                    let config = BEPClusterConfig(folders: [BEPFolder(id: "vault", label: "Vault",
                        devices: [BEPDevice(id: localID, name: "Luna Mac")])])
                    try await connection.send(clusterConfig: config)
                    let files = try self.index.all()
                    try await connection.send(index: BEPIndex(folder: "vault", files: files,
                        lastSequence: files.map(\.sequence).max() ?? 0, isUpdate: false))
                } catch {
                    if !Task.isCancelled { self.lock.withLock { self.status = "Waiting for iPhone" } }
                }
            }
        }
    }

    private static func qrImage(for string: String) -> NSImage? {
        guard let data = string.data(using: .utf8), let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("Q", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let rep = NSCIImageRep(ciImage: output.transformed(by: CGAffineTransform(scaleX: 5, y: 5)))
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}

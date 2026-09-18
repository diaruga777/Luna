import XCTest
import LunaVaultBEP
import LunaVaultStore
import LunaVaultSync
import LunaVaultMacPeer
import LunaVaultTailscale
import LunaVaultUI

final class VaultConnectedPairingTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PairingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func testDisconnectCannotForgetFilesWaitingToUpload() async throws {
        let store = try VaultFolderStore(rootURL: directory.appendingPathComponent("Phone"))
        let local = try DeviceID(bytes: Data(repeating: 1, count: 32))
        let peer = VaultPeerRecord(deviceID: try DeviceID(bytes: Data(repeating: 2, count: 32)),
            name: "My Mac", folderID: "vault", lastConnectedAt: Date())
        try store.savePeer(peer)
        let runtime = try VaultConnectedRuntime(store: store, dialer: RejectingDialer(), lookup: nil, localID: local)
        let source = directory.appendingPathComponent("Unsynced.txt")
        try Data("Must survive disconnect".utf8).write(to: source)
        try await runtime.importFile(at: source)
        do { try await runtime.removePairing(); XCTFail("Pending uploads must prevent disconnect") } catch { }
        XCTAssertEqual(try store.peer()?.deviceID, peer.deviceID)
        XCTAssertEqual(try store.pendingLocalChanges().count, 1)
    }

    func testChangingMacCannotForgetFilesWaitingToUpload() async throws {
        let store = try VaultFolderStore(rootURL: directory.appendingPathComponent("Phone"))
        let peer = VaultPeerRecord(deviceID: try DeviceID(bytes: Data(repeating: 2, count: 32)),
            name: "My Mac", folderID: "vault", lastConnectedAt: Date())
        try store.savePeer(peer)
        let runtime = try VaultConnectedRuntime(store: store, dialer: RejectingDialer(), lookup: nil,
            localID: DeviceID(bytes: Data(repeating: 1, count: 32)))
        let source = directory.appendingPathComponent("Unsynced.txt")
        try Data("Must survive changing Mac".utf8).write(to: source)
        try await runtime.importFile(at: source)
        let replacement = try DeviceID(bytes: Data(repeating: 3, count: 32))
        do {
            try await runtime.pair(code: VaultPairingCode(deviceID: replacement, addresses: []).text)
            XCTFail("Pending uploads must prevent changing Mac")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("uploads finish"))
        }
        XCTAssertEqual(try store.peer()?.deviceID, peer.deviceID)
        XCTAssertEqual(try store.pendingLocalChanges().count, 1)
    }

    func testInvalidPairingCodeExplainsHowToRecover() async throws {
        let store = try VaultFolderStore(rootURL: directory.appendingPathComponent("Phone"))
        let runtime = try VaultConnectedRuntime(store: store, dialer: RejectingDialer(), lookup: nil,
            localID: DeviceID(bytes: Data(repeating: 1, count: 32)))
        do { try await runtime.pair(code: "invalid-code"); XCTFail("Invalid code must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Copy a fresh code")) }
        XCTAssertNil(try store.peer())
    }

    func testCodeRoundTripCarriesDirectRouteAndRejectsBadPorts() throws {
        let id = try DeviceID(bytes: Data(repeating: 7, count: 32))
        let code = VaultPairingCode(deviceID: id, addresses: [.tcp(host: "192.168.1.8", port: 22000)])
        XCTAssertEqual(try VaultPairingCode(string: code.text), code)
        XCTAssertEqual(try VaultPairingCode(string: id.description).deviceID, id)
        XCTAssertNil(VaultPeerAddress(syncthingURL: "tcp://localhost:99999"))
        XCTAssertNil(VaultPeerAddress(syncthingURL: "tcp://localhost:0"))
    }

    func testOfflineMacCannotBecomePairedOrErasePreviousPairing() async throws {
        let store = try VaultFolderStore(rootURL: directory.appendingPathComponent("Phone"))
        let local = try DeviceID(bytes: Data(repeating: 1, count: 32))
        let previous = VaultPeerRecord(deviceID: try DeviceID(bytes: Data(repeating: 2, count: 32)),
            name: "Working Mac", folderID: "vault", lastConnectedAt: Date())
        try store.savePeer(previous)
        let runtime = try VaultConnectedRuntime(store: store, dialer: RejectingDialer(), lookup: nil, localID: local)
        let next = try DeviceID(bytes: Data(repeating: 3, count: 32))
        do {
            try await runtime.pair(code: VaultPairingCode(deviceID: next, addresses: [.tcp(host: "127.0.0.1", port: 1)]).text)
            XCTFail("An unreachable Mac must not pair")
        } catch { }
        XCTAssertEqual(try store.peer()?.deviceID, previous.deviceID)
        let snapshot = try await runtime.pairingSnapshot()
        XCTAssertEqual(snapshot.remoteName, "Working Mac")
    }

    func testOldLocallySavedCodeIsNotReportedAsVerifiedPairing() async throws {
        let store = try VaultFolderStore(rootURL: directory.appendingPathComponent("Phone"))
        try store.savePeer(VaultPeerRecord(deviceID: DeviceID(bytes: Data(repeating: 2, count: 32)), name: "Fake success", folderID: "vault"))
        let runtime = try VaultConnectedRuntime(store: store, dialer: RejectingDialer(), lookup: nil,
            localID: DeviceID(bytes: Data(repeating: 1, count: 32)))
        let snapshot = try await runtime.pairingSnapshot()
        let status = await runtime.connectionStatus()
        XCTAssertFalse(snapshot.isPaired)
        XCTAssertEqual(status, .notPaired)
    }

    func testRealTLSRoundTripPairDownloadUploadAndReopen() async throws {
        let folder = directory.appendingPathComponent("Shared")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let expected = Data("A real file served by the Mac protocol.\n".utf8)
        try expected.write(to: folder.appendingPathComponent("Read me.txt"))
        let server = try await LocalMacPeer(root: directory.appendingPathComponent("Mac"), folder: folder)
        defer { server.close() }
        let store = try VaultFolderStore(rootURL: directory.appendingPathComponent("Phone"))
        let transport = LunaVaultGoTransport(configuration: .init(stateDirectory: store.identityDirectory, requestLocalNetworkAccess: true))
        let local = try transport.identity()
        let runtime = try VaultConnectedRuntime(store: store, dialer: transport, lookup: nil, localID: local)
        try await runtime.pair(code: server.code.text)
        let status = await runtime.connectionStatus()
        XCTAssertEqual(status, .connected)
        XCTAssertNotNil(try store.peer()?.lastConnectedAt)
        let url = try await runtime.fileURL(named: "Read me.txt")
        XCTAssertEqual(try Data(contentsOf: url), expected)
        let upload = directory.appendingPathComponent("From iPhone.txt")
        let uploaded = Data("Uploaded and acknowledged, not merely indexed.\n".utf8)
        try uploaded.write(to: upload)
        try await runtime.importFile(at: upload)
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline, !(try store.pendingLocalChanges()).isEmpty {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(upload.lastPathComponent)), uploaded)
        XCTAssertTrue(try store.pendingLocalChanges().isEmpty)
        await runtime.stop()
        let reopened = try VaultFolderStore(rootURL: store.rootURL)
        let next = try VaultConnectedRuntime(store: reopened, dialer: transport, lookup: nil, localID: local)
        let snapshot = try await next.pairingSnapshot()
        XCTAssertTrue(snapshot.isPaired)
        let offline = await next.connectionStatus()
        XCTAssertEqual(offline, .offline)
        await next.reconnect()
        let reconnected = await next.connectionStatus()
        XCTAssertEqual(reconnected, .connected)
        let files = try await next.recentFiles(limit: 10)
        XCTAssertTrue(files.contains { $0.name == "Read me.txt" })
        await next.stop()
    }

    func testSessionDoesNotReportConnectedBeforeMacIndexArrives() async throws {
        let phone = try DeviceID(bytes: Data(repeating: 1, count: 32))
        let mac = try DeviceID(bytes: Data(repeating: 2, count: 32))
        let store = try VaultFolderStore(rootURL: directory.appendingPathComponent("Pending"))
        try store.savePeer(VaultPeerRecord(deviceID: mac, name: "Mac",
            manualAddresses: [.tcp(host: "localhost", port: 22000)], folderID: "vault"))
        let (clientStream, serverStream) = PipeByteStream.pair()
        let delegate = EmptyDelegate()
        let server = BEPConnection(stream: serverStream, peerDevice: phone,
            localHello: BEPHello(deviceName: "Mac", clientName: "Test", clientVersion: "1"), delegate: delegate)
        let session = VaultSyncSession(store: store, dialer: StreamDialer(stream: clientStream), lookup: nil, localDevice: phone)
        async let serverHello = server.start()
        try await session.start()
        _ = try await serverHello
        let pending = await session.currentState
        XCTAssertEqual(pending, .syncing)
        XCTAssertNil(try store.peer()?.lastConnectedAt)
        try await server.send(clusterConfig: BEPClusterConfig(folders: [BEPFolder(id: "vault", label: "Vault",
            devices: [BEPDevice(id: mac, name: "Mac"), BEPDevice(id: phone, name: "Phone")])]))
        try await server.send(index: BEPIndex(folder: "vault", files: [], lastSequence: 0, isUpdate: false))
        try await session.waitForInitialIndex(timeout: 1)
        let connected = await session.currentState
        XCTAssertEqual(connected, .connected)
        XCTAssertNotNil(try store.peer()?.lastConnectedAt)
        await session.stop()
        await server.close(reason: "Test ended")
    }

    func testRealTLSRejectsWrongMacIdentity() async throws {
        let folder = directory.appendingPathComponent("Shared")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let server = try await LocalMacPeer(root: directory.appendingPathComponent("Mac"), folder: folder)
        defer { server.close() }
        let transport = LunaVaultGoTransport(configuration: .init(stateDirectory: directory.appendingPathComponent("PhoneIdentity")))
        let wrong = try DeviceID(bytes: Data(repeating: 99, count: 32))
        do {
            let stream = try await transport.dial(XCTUnwrap(server.code.addresses.first), expecting: wrong)
            stream.close()
            XCTFail("A route must never override the certificate identity")
        } catch { }
    }

    func testHelloTimeoutActuallyClosesBlockedStream() async throws {
        let (client, server) = PipeByteStream.pair()
        defer { server.close() }
        let delegate = EmptyDelegate()
        var timing = BEPConnectionTiming(); timing.helloTimeout = 0.1
        let connection = BEPConnection(stream: client, peerDevice: try DeviceID(bytes: Data(repeating: 1, count: 32)),
            localHello: BEPHello(deviceName: "Phone", clientName: "Test", clientVersion: "1"), delegate: delegate, timing: timing)
        let start = Date()
        do { try await connection.start(); XCTFail("A silent peer must time out") } catch { }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
}

private struct RejectingDialer: VaultPeerDialing {
    func dial(_ address: VaultPeerAddress, expecting: DeviceID) async throws -> any BEPByteStream {
        throw VaultTransportError.unreachable("Test Mac is offline")
    }
}
private final class EmptyDelegate: BEPConnectionDelegate, @unchecked Sendable {
    func connection(_ connection: BEPConnection, didReceive clusterConfig: BEPClusterConfig) async {}
    func connection(_ connection: BEPConnection, didReceive index: BEPIndex) async {}
    func connection(_ connection: BEPConnection, serve request: BEPRequest) async -> Result<Data, BEPErrorCode> { .failure(.noSuchFile) }
    func connection(_ connection: BEPConnection, didCloseWith error: Error?) async {}
}

/// Real Go TLS sockets on loopback; uses the production companion file delegate.
/// No discovery, tailnet, cloud account, or user folder is touched.
private final class LocalMacPeer: @unchecked Sendable {
    let code: VaultPairingCode
    private let listener: LunaVaultGoListener
    private var task: Task<Void, Never>?
    private let lock = NSLock()
    private var sessions: [(BEPConnection, CompanionBEPDelegate)] = []

    init(root: URL, folder: URL) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let transport = LunaVaultGoTransport(configuration: .init(stateDirectory: root.appendingPathComponent("Identity")))
        let identity = try transport.identity()
        listener = try await transport.listen(bindAddress: "127.0.0.1:0")
        let addresses = await listener.announcedAddresses.compactMap(VaultPeerAddress.init(syncthingURL:))
        code = VaultPairingCode(deviceID: identity, addresses: addresses)
        let listener = self.listener
        task = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let peer = try await listener.accept()
                    guard let self else { peer.stream.close(); return }
                    let index = try CompanionIndex(databaseURL: root.appendingPathComponent("index.sqlite"))
                    try index.replace(with: CompanionFolderScanner(rootURL: folder, deviceShortID: identity.shortID).scan())
                    let delegate = CompanionBEPDelegate(rootURL: folder, index: index, localDevice: identity, folderID: "vault")
                    let connection = BEPConnection(stream: peer.stream, peerDevice: peer.device,
                        localHello: BEPHello(deviceName: "Mac", clientName: "Test", clientVersion: "1"), delegate: delegate)
                    self.retain(connection, delegate)
                    _ = try await connection.start()
                    try await connection.send(clusterConfig: BEPClusterConfig(folders: [BEPFolder(id: "vault", label: "Vault",
                        devices: [BEPDevice(id: identity, name: "Mac"), BEPDevice(id: peer.device, name: "Phone")])]))
                    let files = try index.all()
                    try await connection.send(index: BEPIndex(folder: "vault", files: files,
                        lastSequence: files.map(\.sequence).max() ?? 0, isUpdate: false))
                    delegate.startServing(connection)
                } catch { return }
            }
        }
    }
    private func retain(_ connection: BEPConnection, _ delegate: CompanionBEPDelegate) {
        lock.lock(); sessions.append((connection, delegate)); lock.unlock()
    }
    func close() {
        task?.cancel(); listener.close()
        lock.lock(); let current = sessions; sessions = []; lock.unlock()
        for (connection, _) in current { Task { await connection.close(reason: "Test ended") } }
    }
}

private struct StreamDialer: VaultPeerDialing {
    let stream: any BEPByteStream
    func dial(_ address: VaultPeerAddress, expecting: DeviceID) async throws -> any BEPByteStream { stream }
}

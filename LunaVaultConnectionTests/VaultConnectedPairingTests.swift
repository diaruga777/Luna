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

    func testPhotoAlbumPathsStageFoldersAndFileForMac() async throws {
        let store = try VaultFolderStore(rootURL: directory.appendingPathComponent("Phone"))
        let local = try DeviceID(bytes: Data(repeating: 3, count: 32))
        let peer = VaultPeerRecord(deviceID: try DeviceID(bytes: Data(repeating: 4, count: 32)),
            name: "My Mac", folderID: "vault", lastConnectedAt: Date())
        try store.savePeer(peer)
        let runtime = try VaultConnectedRuntime(store: store, dialer: RejectingDialer(), lookup: nil, localID: local)
        let source = directory.appendingPathComponent("sunrise.jpg")
        try Data("photo bytes".utf8).write(to: source)

        try await runtime.importFile(at: source, named: "Photos/Trips/sunrise.jpg")
        try await runtime.importDirectory(named: "Photos/Empty Album")

        XCTAssertEqual(try store.file(named: "Photos")?.type, .directory)
        XCTAssertEqual(try store.file(named: "Photos/Trips")?.type, .directory)
        XCTAssertEqual(try store.file(named: "Photos/Empty Album")?.type, .directory)
        XCTAssertEqual(try store.file(named: "Photos/Trips/sunrise.jpg")?.type, .file)
        XCTAssertEqual(Set(try store.pendingLocalChanges().map(\.name)),
            Set(["Photos", "Photos/Trips", "Photos/Trips/sunrise.jpg", "Photos/Empty Album"]))
    }

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
        do {
            try await runtime.waitForUpload(names: [source.lastPathComponent])
            XCTFail("A local import must not be reported as saved on the Mac")
        } catch let error as VaultSyncSessionError {
            XCTAssertEqual(error, .uploadPending)
        }
        let progress = try await runtime.pendingUploads()
        XCTAssertEqual(progress.first?.totalBytes, Int64(try Data(contentsOf: source).count))
        XCTAssertEqual(progress.first?.sentBytes, 0)
        try await runtime.cancelPendingUpload(named: source.lastPathComponent)
        XCTAssertEqual(try store.pendingLocalChanges().first?.kind, .delete)
        XCTAssertTrue(try XCTUnwrap(store.file(named: source.lastPathComponent)).deleted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.cacheFileURL(for: source.lastPathComponent).path))
        do {
            try await runtime.importFile(at: source)
            XCTFail("Retry must wait for the Mac's delete confirmation")
        } catch let error as VaultLocalWriteError {
            XCTAssertEqual(error, .deletionPending(source.lastPathComponent))
        }
    }

    func testFolderImportPreservesNestedFilesAndEmptyDirectories() async throws {
        let folder = directory.appendingPathComponent("Shared")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let server = try await LocalMacPeer(root: directory.appendingPathComponent("Mac"), folder: folder)
        defer { server.close() }
        let store = try VaultFolderStore(rootURL: directory.appendingPathComponent("Phone"))
        let transport = LunaVaultGoTransport(configuration: .init(stateDirectory: store.identityDirectory, requestLocalNetworkAccess: true))
        let runtime = try VaultConnectedRuntime(store: store, dialer: transport, lookup: nil,
            localID: transport.identity())
        try await runtime.pair(code: server.code.text)
        let selected = directory.appendingPathComponent("Project")
        let nested = selected.appendingPathComponent("Notes")
        let empty = selected.appendingPathComponent("Empty")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let content = Data("Nested upload".utf8)
        try content.write(to: nested.appendingPathComponent("readme.txt"))
        let names = try await runtime.importFolder(at: selected)
        XCTAssertEqual(Set(names), Set(["Project", "Project/Notes", "Project/Notes/readme.txt", "Project/Empty"]))
        try await runtime.waitForUpload(names: names, timeout: 15)
        XCTAssertTrue(try store.pendingLocalChanges().isEmpty)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("Project/Notes/readme.txt")), content)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Project/Empty").path,
                                                       isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        let second = directory.appendingPathComponent("Second/Project/Notes")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try Data("Added later".utf8).write(to: second.appendingPathComponent("extra.txt"))
        let additional = try await runtime.importFolder(at: second.deletingLastPathComponent())
        XCTAssertEqual(additional, ["Project/Notes/extra.txt"])
        try await runtime.waitForUpload(names: additional, timeout: 15)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("Project/Notes/extra.txt")),
                       Data("Added later".utf8))
        try await runtime.deleteItem(named: "Project")
        for _ in 0..<100 {
            if try store.pendingLocalChanges().isEmpty { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(try store.pendingLocalChanges().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Project").path))
        await runtime.stop()
    }

    func testFourGiBFileMetadataKeeps64BitSizeAndOffsets() throws {
        let size: Int64 = 4 * 1_024 * 1_024 * 1_024 + 123
        let blockSize = BlockLayout.blockSize(forFileSize: size)
        XCTAssertEqual(blockSize, 4 * 1_024 * 1_024)
        let hashes = Data(repeating: 7, count: Int((size + Int64(blockSize) - 1) / Int64(blockSize)) * 32)
        let blocks = BlockLayout.blocks(fromConcatenatedHashes: hashes, fileSize: size, blockSize: blockSize)
        XCTAssertEqual(blocks.last.map { $0.offset + Int64($0.size) }, size)
        let file = BEPFileInfo(name: "archive.zip", size: size, blockSize: Int32(blockSize), blocks: blocks,
                               blocksHash: BlockLayout.blocksHash(blocks))
        let decoded = try BEPFileInfo(protobuf: file.encoded())
        XCTAssertEqual(decoded.size, size)
        XCTAssertEqual(decoded.blocks.last?.offset, blocks.last?.offset)
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
        try await runtime.deleteItem(named: upload.lastPathComponent)
        let deletionDeadline = Date().addingTimeInterval(8)
        while Date() < deletionDeadline, !(try store.pendingLocalChanges()).isEmpty {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(upload.lastPathComponent).path))
        XCTAssertTrue(try store.pendingLocalChanges().isEmpty)
        try await runtime.importFile(at: upload)
        try await runtime.waitForUpload(names: [upload.lastPathComponent], timeout: 8)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(upload.lastPathComponent)), uploaded)
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

    func testPerFileSentBytesCountAfterABlockResponse() async throws {
        let phone = try DeviceID(bytes: Data(repeating: 1, count: 32))
        let mac = try DeviceID(bytes: Data(repeating: 2, count: 32))
        let store = try VaultFolderStore(rootURL: directory.appendingPathComponent("Progress"))
        try store.savePeer(VaultPeerRecord(deviceID: mac, name: "Mac",
            manualAddresses: [.tcp(host: "localhost", port: 22000)], folderID: "vault", lastConnectedAt: Date()))
        let (clientStream, serverStream) = PipeByteStream.pair()
        let delegate = EmptyDelegate()
        let server = BEPConnection(stream: serverStream, peerDevice: phone,
            localHello: BEPHello(deviceName: "Mac", clientName: "Test", clientVersion: "1"), delegate: delegate)
        let session = VaultSyncSession(store: store, dialer: StreamDialer(stream: clientStream), lookup: nil, localDevice: phone)
        async let hello = server.start()
        try await session.start()
        _ = try await hello
        try await server.send(clusterConfig: BEPClusterConfig(folders: [BEPFolder(id: "vault", label: "Vault",
            devices: [BEPDevice(id: mac, name: "Mac"), BEPDevice(id: phone, name: "Phone")])]))
        try await server.send(index: BEPIndex(folder: "vault", files: [], isUpdate: false))
        try await session.waitForInitialIndex(timeout: 1)
        let source = directory.appendingPathComponent("progress.bin")
        let contents = Data(repeating: 7, count: 64 * 1_024)
        try contents.write(to: source)
        let file = try await session.addFile(at: source, named: source.lastPathComponent)
        let received = try await server.request(folder: "vault", name: file.name,
                                                block: XCTUnwrap(file.blocks.first), blockNo: 0)
        XCTAssertEqual(received, contents)
        let deadline = Date().addingTimeInterval(1)
        var sent = await session.sentBytesByFile[file.name]
        while Date() < deadline, sent != Int64(contents.count) {
            try await Task.sleep(for: .milliseconds(10))
            sent = await session.sentBytesByFile[file.name]
        }
        XCTAssertEqual(sent, Int64(contents.count))
        await session.stop(); await server.close(reason: "Test ended")
    }

    func testNextUploadDoesNotReannouncePreviouslyConfirmedLargeFile() async throws {
        let folder = directory.appendingPathComponent("Shared")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let phone = try DeviceID(bytes: Data(repeating: 1, count: 32))
        let mac = try DeviceID(bytes: Data(repeating: 2, count: 32))
        let store = try VaultFolderStore(rootURL: directory.appendingPathComponent("Phone"))
        try store.savePeer(VaultPeerRecord(deviceID: mac, name: "Mac",
            manualAddresses: [.tcp(host: "localhost", port: 22000)], folderID: "vault", lastConnectedAt: Date()))
        let index = try CompanionIndex(databaseURL: directory.appendingPathComponent("Mac.sqlite"))
        let delegate = CompanionBEPDelegate(rootURL: folder, index: index, localDevice: mac, folderID: "vault")
        let (phoneStream, macStream) = PipeByteStream.pair()
        let server = BEPConnection(stream: macStream, peerDevice: phone,
            localHello: BEPHello(deviceName: "Mac", clientName: "Test", clientVersion: "1"), delegate: delegate)
        let session = VaultSyncSession(store: store, dialer: StreamDialer(stream: phoneStream), lookup: nil, localDevice: phone)
        async let hello = server.start()
        try await session.start()
        _ = try await hello
        try await server.send(clusterConfig: BEPClusterConfig(folders: [BEPFolder(id: "vault", label: "Vault",
            devices: [BEPDevice(id: mac, name: "Mac"), BEPDevice(id: phone, name: "Phone")])]))
        try await server.send(index: BEPIndex(folder: "vault", files: [], isUpdate: false))
        delegate.startServing(server)
        try await session.waitForInitialIndex(timeout: 1)
        do {
            let first = directory.appendingPathComponent("large.bin")
            let contents = Data(repeating: 7, count: 16 * 1024 * 1024)
            try contents.write(to: first)
            _ = try await session.addFile(at: first, named: "large.bin")
            try await waitForConfirmation(in: store)
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("large.bin")), contents)

            // A previously confirmed file must not be re-read or re-applied on
            // the next import. An independent Mac edit makes that visible.
            let edited = Data("Edited on Mac after confirmation".utf8)
            try edited.write(to: folder.appendingPathComponent("large.bin"))
            let second = directory.appendingPathComponent("next.bin")
            try Data("Next file".utf8).write(to: second)
            _ = try await session.addFile(at: second, named: "next.bin")
            try await waitForConfirmation(in: store)
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("next.bin")), Data("Next file".utf8))
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("large.bin")), edited)
            XCTAssertTrue(try store.pendingLocalChanges().isEmpty)
        } catch {
            await session.stop()
            await server.close(reason: "Test ended")
            throw error
        }
        await session.stop()
        await server.close(reason: "Test ended")
    }

    private func waitForConfirmation(in store: VaultFolderStore) async throws {
        let deadline = Date().addingTimeInterval(3)
        while try !store.pendingLocalChanges().isEmpty {
            guard Date() < deadline else { throw VaultSyncSessionError.uploadPending }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testInitialIndexTimeoutClosesSessionSoNextStartCanRedial() async throws {
        let phone = try DeviceID(bytes: Data(repeating: 1, count: 32))
        let mac = try DeviceID(bytes: Data(repeating: 2, count: 32))
        let store = try VaultFolderStore(rootURL: directory.appendingPathComponent("Timeout"))
        try store.savePeer(VaultPeerRecord(deviceID: mac, name: "Mac",
            manualAddresses: [.tcp(host: "localhost", port: 22000)], folderID: "vault", lastConnectedAt: Date()))
        let (clientStream, serverStream) = PipeByteStream.pair()
        let delegate = EmptyDelegate()
        let server = BEPConnection(stream: serverStream, peerDevice: phone,
            localHello: BEPHello(deviceName: "Mac", clientName: "Test", clientVersion: "1"), delegate: delegate)
        let session = VaultSyncSession(store: store, dialer: StreamDialer(stream: clientStream), lookup: nil, localDevice: phone)
        async let hello = server.start()
        try await session.start()
        _ = try await hello
        do {
            try await session.waitForInitialIndex(timeout: 0.05)
            XCTFail("Silent Mac must time out")
        } catch let error as VaultSyncSessionError { XCTAssertEqual(error, .initialIndexTimedOut) }
        let connected = await session.isConnected
        XCTAssertFalse(connected, "A timed-out session must not be reused by start()")
        let state = await session.currentState
        XCTAssertEqual(state, .offline("Initial index timed out"))
        await server.close(reason: "Test ended")
    }

    func testCloseUnblocksAStalledWrite() async throws {
        let (clientStream, serverStream) = PipeByteStream.pair()
        let stream = ControlledWriteStream(base: clientStream)
        let delegate = EmptyDelegate()
        let connection = BEPConnection(stream: stream, peerDevice: try DeviceID(bytes: Data(repeating: 1, count: 32)),
            localHello: BEPHello(deviceName: "Phone", clientName: "Test", clientVersion: "1"), delegate: delegate)
        try await serverStream.write(BEPFraming.encodeHello(BEPHello(deviceName: "Mac", clientName: "Test", clientVersion: "1")))
        try await connection.start()
        stream.mode = .stall
        let started = Date()
        await connection.close(reason: "Reconnect stalled transfer")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        let closed = await connection.isClosed
        XCTAssertTrue(closed)
        serverStream.close()
    }

    func testWriteFailureImmediatelyClosesConnection() async throws {
        let (clientStream, serverStream) = PipeByteStream.pair()
        let stream = ControlledWriteStream(base: clientStream)
        let delegate = EmptyDelegate()
        let connection = BEPConnection(stream: stream, peerDevice: try DeviceID(bytes: Data(repeating: 1, count: 32)),
            localHello: BEPHello(deviceName: "Phone", clientName: "Test", clientVersion: "1"), delegate: delegate)
        try await serverStream.write(BEPFraming.encodeHello(BEPHello(deviceName: "Mac", clientName: "Test", clientVersion: "1")))
        try await connection.start()
        stream.mode = .fail
        do { try await connection.send(clusterConfig: BEPClusterConfig(folders: [])); XCTFail("Write should fail") }
        catch { }
        let closed = await connection.isClosed
        XCTAssertTrue(closed, "A failed announcement must trigger reconnect rather than leave the session connected")
        serverStream.close()
    }

    func testRollingBlockWindowIsBoundedAndDoesNotWaitForSlowFirstBlock() async throws {
        let bytes = Data(repeating: 7, count: 24 * BlockLayout.minimumBlockSize)
        let blocks = BlockLayout.blocks(for: bytes).blocks
        let probe = TransferWindowProbe(bytes: bytes)
        var output = Data(count: bytes.count)
        try await BEPBlockTransfer.receive(blocks: blocks, request: { index, block in
            try await probe.read(index, block: block)
        }, write: { _, block, data in
            output.replaceSubrange(Int(block.offset)..<(Int(block.offset) + data.count), with: data)
        })
        XCTAssertEqual(output, bytes)
        let peak = await probe.peak
        let refilled = await probe.refilledBeforeFirstCompleted
        XCTAssertGreaterThan(peak, 1)
        XCTAssertLessThanOrEqual(peak, BEPBlockTransfer.maximumOutstandingRequests)
        XCTAssertTrue(refilled)
    }

    func testLargeBlocksLimitWindowToThirtyTwoMiB() async throws {
        let bytes = Data(repeating: 7, count: 3 * BlockLayout.maximumBlockSize)
        let blocks = BlockLayout.blocks(for: bytes, blockSize: BlockLayout.maximumBlockSize).blocks
        let probe = TransferWindowProbe(bytes: bytes)
        var received = 0
        try await BEPBlockTransfer.receive(blocks: blocks, request: { index, block in
            try await probe.read(index, block: block)
        }, write: { _, _, data in received += data.count })
        let peak = await probe.peak
        XCTAssertEqual(peak, 2)
        XCTAssertEqual(received, bytes.count)
    }

    func testBlockWindowLatencyBenchmark() async throws {
        let bytes = Data(repeating: 5, count: 32 * BlockLayout.minimumBlockSize)
        let blocks = BlockLayout.blocks(for: bytes).blocks
        let request: @Sendable (Int, BlockInfo) async throws -> Data = { _, block in
            try await Task.sleep(for: .milliseconds(20))
            return bytes.subdata(in: Int(block.offset)..<(Int(block.offset) + Int(block.size)))
        }
        let serialStart = Date()
        for (index, block) in blocks.enumerated() {
            let data = try await request(index, block)
            XCTAssertEqual(SHA256Digest.hash(data), block.hash)
        }
        let serialSeconds = Date().timeIntervalSince(serialStart)
        let windowStart = Date()
        var received = 0
        try await BEPBlockTransfer.receive(blocks: blocks, request: request,
                                           write: { _, _, data in received += data.count })
        let windowSeconds = Date().timeIntervalSince(windowStart)
        XCTAssertEqual(received, bytes.count)
        print("Vault 4 MiB / 20 ms simulated request latency: serial=\(serialSeconds)s window=\(windowSeconds)s speedup=\(serialSeconds / windowSeconds)x")
    }

    func testCorruptBlockIsNeverWritten() async throws {
        let bytes = Data([1, 2, 3])
        let blocks = BlockLayout.blocks(for: bytes).blocks
        var writes = 0
        do {
            try await BEPBlockTransfer.receive(blocks: blocks,
                request: { _, _ in Data([3, 2, 1]) }, write: { _, _, _ in writes += 1 })
            XCTFail("Corrupt bytes must be rejected")
        } catch let error as BEPRequestError { XCTAssertEqual(error, .hashMismatch) }
        XCTAssertEqual(writes, 0)
    }

    func testBlockRequestTimesOutEvenWhilePingsContinue() async throws {
        let phone = try DeviceID(bytes: Data(repeating: 1, count: 32))
        let mac = try DeviceID(bytes: Data(repeating: 2, count: 32))
        let (clientStream, serverStream) = PipeByteStream.pair()
        let clientDelegate = EmptyDelegate()
        let serverDelegate = SlowDelegate()
        var clientTiming = BEPConnectionTiming()
        clientTiming.requestTimeout = 0.1
        clientTiming.pingInterval = 0.02
        clientTiming.timerTick = 0.01
        var serverTiming = BEPConnectionTiming()
        serverTiming.pingInterval = 0.02
        serverTiming.timerTick = 0.01
        let client = BEPConnection(stream: clientStream, peerDevice: mac,
            localHello: BEPHello(deviceName: "Phone", clientName: "Test", clientVersion: "1"),
            delegate: clientDelegate, timing: clientTiming)
        let server = BEPConnection(stream: serverStream, peerDevice: phone,
            localHello: BEPHello(deviceName: "Mac", clientName: "Test", clientVersion: "1"),
            delegate: serverDelegate, timing: serverTiming)
        async let hello = server.start()
        try await client.start()
        _ = try await hello
        try await client.send(clusterConfig: BEPClusterConfig(folders: []))
        try await server.send(clusterConfig: BEPClusterConfig(folders: []))
        let block = BlockInfo(offset: 0, size: 1, hash: SHA256Digest.hash(Data([7])))
        do {
            _ = try await client.request(folder: "vault", name: "slow.bin", block: block, blockNo: 0)
            XCTFail("An unanswered block must not wait forever")
        } catch let error as BEPStreamError {
            XCTAssertEqual(error, .timedOut)
        }
        let closed = await client.isClosed
        XCTAssertTrue(closed)
        await server.close(reason: "Test ended")
    }

    func testMacRescanPreservesConfirmedVersionAndDeletion() throws {
        let folder = directory.appendingPathComponent("Rescan")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("archive.zip")
        try Data(repeating: 7, count: 128).write(to: url)
        let scanner = CompanionFolderScanner(rootURL: folder, deviceShortID: 22)
        let index = try CompanionIndex(databaseURL: directory.appendingPathComponent("RescanIndex.sqlite"))
        let initial = try XCTUnwrap(scanner.scan().first?.info)
        var received = initial
        received.version = VersionVector(counters: [VersionCounter(id: 11, value: 123)])
        received.sequence = 12
        try index.upsert(CompanionFileRecord(info: received))

        try index.reconcileScan(scanner.scan(), deviceShortID: 22)
        XCTAssertEqual(try index.file(named: received.name)?.version, received.version)

        try FileManager.default.removeItem(at: url)
        try index.reconcileScan(scanner.scan(), deviceShortID: 22)
        let deleted = try XCTUnwrap(index.file(named: received.name))
        XCTAssertTrue(deleted.deleted)
        XCTAssertNoThrow(try deleted.validateForWire())
        XCTAssertEqual(deleted.version.value(for: 11), 123)
        XCTAssertGreaterThan(deleted.version.value(for: 22), 0)

        try index.reconcileScan(scanner.scan(), deviceShortID: 22)
        XCTAssertEqual(try index.file(named: received.name)?.version, deleted.version)
        let reopened = try CompanionIndex(databaseURL: directory.appendingPathComponent("RescanIndex.sqlite"))
        XCTAssertEqual(try reopened.file(named: received.name)?.deleted, true)
    }

    func testMacResumesVerifiedBlocksAndReportsTheirProgress() async throws {
        let phone = try DeviceID(bytes: Data(repeating: 1, count: 32))
        let mac = try DeviceID(bytes: Data(repeating: 2, count: 32))
        let folder = directory.appendingPathComponent("Resume")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let first = Data(repeating: 3, count: BlockLayout.minimumBlockSize)
        let second = Data(repeating: 4, count: BlockLayout.minimumBlockSize)
        let bytes = first + second
        let layout = BlockLayout.blocks(for: bytes)
        let version = VersionVector(counters: [VersionCounter(id: phone.shortID, value: 1)])
        let file = BEPFileInfo(name: "archive.zip", size: Int64(bytes.count), modifiedS: 1_700_000_000,
            modifiedBy: phone.shortID, noPermissions: true, version: version,
            blockSize: Int32(layout.blockSize), blocks: layout.blocks,
            blocksHash: BlockLayout.blocksHash(layout.blocks))
        let nameHash = SHA256Digest.hash(Data(file.name.utf8)).map { String(format: "%02x", $0) }.joined()
        let versionHash = SHA256Digest.hash(version.storageBytes).map { String(format: "%02x", $0) }.joined()
        let partial = folder.appendingPathComponent(".luna-upload-\(nameHash)-\(versionHash)")
        try first.write(to: partial)
        let index = try CompanionIndex(databaseURL: directory.appendingPathComponent("ResumeIndex.sqlite"))
        let macDelegate = CompanionBEPDelegate(rootURL: folder, index: index, localDevice: mac, folderID: "vault")
        let phoneDelegate = SecondBlockOnlyDelegate(bytes: second)
        let (phoneStream, macStream) = PipeByteStream.pair()
        let phoneConnection = BEPConnection(stream: phoneStream, peerDevice: mac,
            localHello: BEPHello(deviceName: "Phone", clientName: "Test", clientVersion: "1"), delegate: phoneDelegate)
        let macConnection = BEPConnection(stream: macStream, peerDevice: phone,
            localHello: BEPHello(deviceName: "Mac", clientName: "Test", clientVersion: "1"), delegate: macDelegate)
        async let hello = macConnection.start()
        try await phoneConnection.start()
        _ = try await hello
        try await phoneConnection.send(clusterConfig: BEPClusterConfig(folders: []))
        try await macConnection.send(clusterConfig: BEPClusterConfig(folders: []))
        macDelegate.startServing(macConnection)
        try await phoneConnection.send(index: BEPIndex(folder: "vault", files: [file], isUpdate: true))
        let destination = folder.appendingPathComponent(file.name)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline && !FileManager.default.fileExists(atPath: destination.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertFalse(phoneDelegate.requestedFirstBlock)
        XCTAssertTrue(phoneDelegate.resumedBlockIndexes.contains(0))
        await phoneConnection.close(reason: "Test ended")
        await macConnection.close(reason: "Test ended")
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

private final class SlowDelegate: BEPConnectionDelegate, @unchecked Sendable {
    func connection(_ connection: BEPConnection, didReceive clusterConfig: BEPClusterConfig) async {}
    func connection(_ connection: BEPConnection, didReceive index: BEPIndex) async {}
    func connection(_ connection: BEPConnection, serve request: BEPRequest) async -> Result<Data, BEPErrorCode> {
        try? await Task.sleep(for: .seconds(1))
        return .success(Data([7]))
    }
    func connection(_ connection: BEPConnection, didCloseWith error: Error?) async {}
}

private final class SecondBlockOnlyDelegate: BEPConnectionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let bytes: Data
    private var firstRequested = false
    private var resumed: [Int] = []
    init(bytes: Data) { self.bytes = bytes }
    var requestedFirstBlock: Bool { lock.lock(); defer { lock.unlock() }; return firstRequested }
    var resumedBlockIndexes: [Int] { lock.lock(); defer { lock.unlock() }; return resumed }
    func connection(_ connection: BEPConnection, didReceive clusterConfig: BEPClusterConfig) async {}
    func connection(_ connection: BEPConnection, didReceive index: BEPIndex) async {}
    func connection(_ connection: BEPConnection, didReceive downloadProgress: BEPDownloadProgress) async {
        lock.withLock { resumed += downloadProgress.updates.flatMap(\.blockIndexes) }
    }
    func connection(_ connection: BEPConnection, serve request: BEPRequest) async -> Result<Data, BEPErrorCode> {
        if request.blockNo == 0 {
            lock.withLock { firstRequested = true }
            return .failure(.noSuchFile)
        }
        return .success(bytes)
    }
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

private actor TransferWindowProbe {
    let bytes: Data
    var active = 0
    var peak = 0
    var firstCompleted = false
    var refilledBeforeFirstCompleted = false
    init(bytes: Data) { self.bytes = bytes }
    func read(_ index: Int, block: BlockInfo) async throws -> Data {
        active += 1
        peak = max(peak, active)
        defer { active -= 1 }
        if index >= BEPBlockTransfer.maximumOutstandingRequests, !firstCompleted {
            refilledBeforeFirstCompleted = true
        }
        try await Task.sleep(for: .milliseconds(index == 0 ? 200 : 10))
        if index == 0 { firstCompleted = true }
        return bytes.subdata(in: Int(block.offset)..<(Int(block.offset) + Int(block.size)))
    }
}

private final class ControlledWriteStream: BEPByteStream, @unchecked Sendable {
    enum Mode { case normal, fail, stall }
    private let base: any BEPByteStream
    private let lock = NSLock()
    private var storedMode: Mode = .normal
    private var closed = false
    private var pending: [CheckedContinuation<Void, Error>] = []
    var mode: Mode {
        get { lock.withLock { storedMode } }
        set { lock.withLock { storedMode = newValue } }
    }
    init(base: any BEPByteStream) { self.base = base }
    func read(exactly count: Int) async throws -> Data { try await base.read(exactly: count) }
    func write(_ data: Data) async throws {
        switch mode {
        case .normal: try await base.write(data)
        case .fail: throw BEPStreamError.closed
        case .stall:
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock {
                    if closed { continuation.resume(throwing: BEPStreamError.closed) }
                    else { pending.append(continuation) }
                }
            }
        }
    }
    func close() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            closed = true
            defer { pending.removeAll() }
            return pending
        }
        base.close()
        waiters.forEach { $0.resume(throwing: BEPStreamError.closed) }
    }
}

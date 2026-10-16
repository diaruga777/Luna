import XCTest
import UIKit
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

    func testFolderPromptHasBoundedErrorAndRecoversAfterPermissionIsGranted() async throws {
        let release = DispatchSemaphore(value: 0)
        let entered = expectation(description: "Read started")
        let access = CompanionFileAccess(timeout: 0.05, readDirectory: { _ in
            entered.fulfill(); release.wait(); return []
        })
        defer { release.signal() }
        do { try await access.checkDirectory(directory); XCTFail("A blocked read must not leave an infinite spinner") }
        catch { XCTAssertTrue(error.localizedDescription.contains("macOS permission prompt")) }
        await fulfillment(of: [entered], timeout: 1)
        XCTAssertTrue(access.statusMessage?.contains(directory.path) == true)
        // A retry reuses the blocked probe instead of starting another TCC call.
        do { try await access.checkDirectory(directory); XCTFail("Still waiting for permission") }
        catch { XCTAssertTrue(error.localizedDescription.contains("macOS permission prompt")) }
        release.signal()
        for _ in 0..<100 where access.statusMessage != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(access.statusMessage)
    }
    func testRecursiveAccessChecksProtectedDescendantsAndSkipsLinks() async throws {
        let protected = directory.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: protected, withIntermediateDirectories: true)
        let alias = directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: protected)
        let access = CompanionFileAccess(readDirectory: { url in
            if url.lastPathComponent == "Documents" { throw NSError(domain: NSPOSIXErrorDomain, code: 13) }
            if url.lastPathComponent == "alias" { throw CodeFailureForTest() }
            return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        })
        do { try await access.checkTree(directory); XCTFail("Expected protected descendant error") }
        catch { XCTAssertTrue(error.localizedDescription.contains("macOS denied Luna Mac access")) }
        XCTAssertTrue(access.statusMessage?.contains(protected.path) == true)
    }
    private struct CodeFailureForTest: Error {}

    func testDeniedFolderAccessHasPrivacySettingsRecovery() async throws {
        let access = CompanionFileAccess(readDirectory: { _ in throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError) })
        do { try await access.checkDirectory(directory); XCTFail("Expected denied access") }
        catch {
            XCTAssertTrue(error.localizedDescription.contains("macOS denied Luna Mac"))
            XCTAssertTrue(error.localizedDescription.contains("Privacy & Security"))
        }
        XCTAssertTrue(access.statusMessage?.contains("Privacy & Security") == true)
        let readable = CompanionFileAccess(timeout: 0.05)
        try await readable.checkDirectory(directory)
        XCTAssertNil(readable.statusMessage)
        // Old timeout callbacks cannot fail a subsequent fast check.
        try await Task.sleep(for: .milliseconds(60))
        try await readable.checkDirectory(directory)
        XCTAssertNil(readable.statusMessage)
    }

    func testMacBrowserDownloadsOutsideVaultWithoutIndexingOrMutating() async throws {
        let folder = directory.appendingPathComponent("Vault")
        let outside = directory.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let expected = Data(repeating: 83, count: VaultMacBrowseProtocol.chunkSize * 2 + 37)
        let source = outside.appendingPathComponent("Résumé 🌓.bin")
        try expected.write(to: source)
        let server = try await LocalMacPeer(root: directory.appendingPathComponent("Mac"), folder: folder)
        defer { server.close() }
        let store = try VaultFolderStore(rootURL: directory.appendingPathComponent("Phone"))
        let transport = LunaVaultGoTransport(configuration: .init(stateDirectory: store.identityDirectory))
        let runtime = try VaultConnectedRuntime(store: store, dialer: transport, lookup: nil, localID: transport.identity())
        try await runtime.pair(code: server.code.text)
        let page = try await runtime.macDirectory(path: outside.path, offset: 0, showHidden: false)
        XCTAssertEqual(page.entries.map(\.name), [source.lastPathComponent])
        let url = try await runtime.macFileURL(path: source.path)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertEqual(try Data(contentsOf: url), expected)
        XCTAssertEqual(try Data(contentsOf: source), expected)
        XCTAssertTrue(try store.liveFiles().isEmpty)
        XCTAssertTrue(try store.pendingLocalChanges().isEmpty)
        let search = try await runtime.search("Résumé", limit: 100)
        XCTAssertTrue(search.isEmpty)
        let downloads = try await runtime.downloadedFiles()
        XCTAssertTrue(downloads.isEmpty, "External previews must not enter Vault's cache/index")
        for invalid in [source.path, "../Documents/" + source.lastPathComponent] {
            do { try await runtime.deleteItem(named: invalid); XCTFail("Accepted deletion outside Vault") } catch { }
            do { try await runtime.importFile(at: source, named: invalid); XCTFail("Accepted upload outside Vault") } catch { }
        }
        XCTAssertEqual(try Data(contentsOf: source), expected)
        await runtime.stop()
    }

    func testMacBrowserPaginationHiddenFilesSymlinksAndChangedFile() throws {
        let browser = CompanionMacBrowser(homeURL: directory)
        for index in 0..<260 { try Data([1, 2, 3]).write(to: directory.appendingPathComponent(String(format: "%03d.txt", index))) }
        try Data([4]).write(to: directory.appendingPathComponent(".hidden"))
        let first = try browser.perform(.init(.list, path: directory.path))
        XCTAssertEqual(first.entries.count, 256)
        let second = try browser.perform(.init(.list, path: directory.path, offset: XCTUnwrap(first.nextOffset)))
        XCTAssertEqual(second.entries.count, 4)
        XCTAssertNil(second.nextOffset)
        XCTAssertEqual(Set((first.entries + second.entries).map(\.name)).count, 260)
        let hidden = try browser.perform(.init(.list, path: directory.path, showHidden: true))
        XCTAssertTrue(hidden.entries.contains { $0.name == ".hidden" })
        let alias = directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        let links = try browser.perform(.init(.list, path: directory.path, offset: 256))
        XCTAssertTrue(links.entries.contains { $0.name == "alias" && $0.isDirectory })
        let source = directory.appendingPathComponent("000.txt")
        let metadata = try XCTUnwrap(browser.perform(.init(.stat, path: source.path)).entries.first)
        let read = try browser.perform(.init(.read, path: source.path, length: 3, version: metadata.version))
        XCTAssertEqual(read.data, Data([1, 2, 3]))
        XCTAssertThrowsError(try browser.perform(.init(.read, path: source.path, offset: -1, length: 1, version: metadata.version)))
        XCTAssertThrowsError(try browser.perform(.init(.read, path: source.path, length: VaultMacBrowseProtocol.chunkSize + 1, version: metadata.version)))
        try Data([9, 8, 7]).write(to: source, options: .atomic)
        XCTAssertThrowsError(try browser.perform(.init(.read, path: source.path, length: 3, version: metadata.version)))
        XCTAssertThrowsError(try browser.perform(.init(.stat, path: "/dev/null")))
        XCTAssertThrowsError(try browser.perform(.init(.list, path: "relative")))
        XCTAssertThrowsError(try browser.perform(.init(.list, path: directory.appendingPathComponent("missing").path)))
    }

    func testMacBrowserRequiresApprovedPeerAndIgnoresBrowserIndexes() async throws {
        let mac = try DeviceID(bytes: Data(repeating: 2, count: 32))
        let phone = try DeviceID(bytes: Data(repeating: 1, count: 32))
        let index = try CompanionIndex(databaseURL: directory.appendingPathComponent("index.sqlite"))
        let delegate = CompanionBEPDelegate(rootURL: directory, index: index, localDevice: mac, folderID: "vault")
        let streams = PipeByteStream.pair()
        let connection = BEPConnection(stream: streams.0, peerDevice: phone,
            localHello: BEPHello(deviceName: "Mac", clientName: "Test", clientVersion: "1"), delegate: delegate)
        let request = BEPRequest(id: 1, folder: VaultMacBrowseProtocol.folder,
            name: try VaultMacBrowseRequest(.list, path: directory.path).encodedName(), offset: 0, size: 0, hash: Data())
        let denied = await delegate.connection(connection, serve: request)
        if case .success = denied { XCTFail("Read before pairing approval") }
        delegate.startServing(connection)
        let allowed = await delegate.connection(connection, serve: request)
        if case .failure = allowed { XCTFail("Approved peer could not browse") }
        await delegate.connection(connection, didReceive: BEPIndex(folder: VaultMacBrowseProtocol.folder,
            files: [BEPFileInfo(name: "must-not-create", type: .directory)], isUpdate: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("must-not-create").path))
        XCTAssertTrue(try index.all().isEmpty)
        await delegate.connection(connection, didCloseWith: nil)
        let closed = await delegate.connection(connection, serve: request)
        if case .success = closed { XCTFail("Read after disconnect") }
        streams.0.close(); streams.1.close()
    }

    func testCodeRequestsRequireSharedPairingAndStopAfterDisconnect() async throws {
        let mac = try DeviceID(bytes: Data(repeating: 2, count: 32))
        let phone = try DeviceID(bytes: Data(repeating: 1, count: 32))
        let index = try CompanionIndex(databaseURL: directory.appendingPathComponent("index.sqlite"))
        let payload = Data("code request".utf8)
        let delegate = CompanionBEPDelegate(rootURL: directory, index: index, localDevice: mac, folderID: "vault", codeHandler: { $0 })
        let streams = PipeByteStream.pair()
        let connection = BEPConnection(stream: streams.0, peerDevice: phone,
            localHello: BEPHello(deviceName: "Mac", clientName: "Test", clientVersion: "1"), delegate: delegate)
        let request = BEPRequest(id: 1, folder: "luna-code-v1", name: payload.base64EncodedString(), offset: 0, size: 0, hash: Data())
        if case .success = await delegate.connection(connection, serve: request) { XCTFail("Code ran before pairing approval") }
        delegate.startServing(connection)
        let result = await delegate.connection(connection, serve: request)
        switch result { case .success(let bytes): XCTAssertEqual(bytes, payload); case .failure: XCTFail("Approved Code request failed") }
        await delegate.connection(connection, didCloseWith: nil)
        if case .success = await delegate.connection(connection, serve: request) { XCTFail("Code ran after disconnect") }
        streams.0.close(); streams.1.close()
    }

    func testInvalidBlockLayoutsFailBeforeRequestOrWrite() async throws {
        let hash = SHA256Digest.hash(Data([1]))
        let invalid: [[BlockInfo]] = [
            [],
            [.init(offset: -1, size: 1, hash: hash)],
            [.init(offset: 0, size: -1, hash: hash)],
            [.init(offset: 0, size: Int32(BlockLayout.maximumBlockSize + 1), hash: hash)],
            [.init(offset: 0, size: 1, hash: Data())],
            [.init(offset: 0, size: 0, hash: hash)],
            [.init(offset: 0, size: 1, hash: hash), .init(offset: 0, size: 1, hash: hash)],
            [.init(offset: 0, size: 1, hash: hash), .init(offset: 2, size: 1, hash: hash)]
        ]
        for blocks in invalid {
            do {
                try await BEPBlockTransfer.receive(blocks: blocks, request: { _, _ in
                    XCTFail("Invalid metadata must never reach the network")
                    return Data()
                }, write: { _, _, _ in XCTFail("Invalid metadata must never reach disk") })
                XCTFail("Accepted malformed blocks")
            } catch is BEPProtocolError { }
        }
        let empty = BlockLayout.blocks(for: Data()).blocks
        XCTAssertEqual(try BlockLayout.validate(empty, fileSize: 0), 0)
        XCTAssertThrowsError(try BlockLayout.validate(empty, fileSize: 1))
        for start in [-1, 2] {
            do {
                try await BEPBlockTransfer.receive(blocks: empty, startingAt: start,
                    request: { _, _ in XCTFail("Invalid resume position"); return Data() },
                    write: { _, _, _ in XCTFail("Invalid resume position") })
                XCTFail("Accepted invalid resume position")
            } catch is BEPProtocolError { }
        }
    }

    func testInvalidIndexRollsBackWithoutReplacingLibrary() throws {
        let store = try VaultFolderStore(rootURL: directory.appendingPathComponent("Phone"))
        try store.savePeer(VaultPeerRecord(deviceID: DeviceID(bytes: Data(repeating: 4, count: 32)), name: "Mac", folderID: "vault"))
        let blocks = BlockLayout.blocks(for: Data([1])).blocks
        let valid = BEPFileInfo(name: "keep.txt", size: 1, blocks: blocks)
        _ = try store.applyIndex(BEPIndex(folder: "vault", files: [valid], isUpdate: false), ourShortID: 1)
        var invalid = valid
        invalid.name = "bad.txt"
        invalid.size = 100
        XCTAssertThrowsError(try store.applyIndex(BEPIndex(folder: "vault", files: [invalid], isUpdate: false), ourShortID: 1))
        XCTAssertNotNil(try store.file(named: "keep.txt"))
        XCTAssertNil(try store.file(named: "bad.txt"))
    }

    func testDownloadsAndRecentLimitsUseCurrentLocalCopies() async throws {
        let store = try VaultFolderStore(rootURL: directory.appendingPathComponent("Phone"))
        let local = try DeviceID(bytes: Data(repeating: 3, count: 32))
        try store.savePeer(VaultPeerRecord(deviceID: DeviceID(bytes: Data(repeating: 4, count: 32)),
            name: "Mac", folderID: "vault", lastConnectedAt: Date()))
        let runtime = try VaultConnectedRuntime(store: store, dialer: RejectingDialer(), lookup: nil, localID: local)
        let source = directory.appendingPathComponent("note.txt")
        try Data("offline copy".utf8).write(to: source)
        try await runtime.importFile(at: source)
        let downloads = try await runtime.downloadedFiles()
        XCTAssertEqual(downloads.map(\.name), ["note.txt"])
        XCTAssertTrue(downloads[0].isDownloaded)
        let zero = try await runtime.recentFiles(limit: 0)
        let negative = try await runtime.recentFiles(limit: -1)
        XCTAssertTrue(zero.isEmpty)
        XCTAssertTrue(negative.isEmpty)
        try FileManager.default.removeItem(at: store.cacheFileURL(for: "note.txt"))
        let missing = try await runtime.downloadedFiles()
        XCTAssertTrue(missing.isEmpty)
    }

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

    func testMacPullOfMultiBlockFile() async throws {
        let folder = directory.appendingPathComponent("LargeShared")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let expected = Data((0..<(BlockLayout.minimumBlockSize * 10)).map { UInt8($0 % 251) })
        try expected.write(to: folder.appendingPathComponent("From Mac.bin"))
        let server = try await LocalMacPeer(root: directory.appendingPathComponent("LargeMac"), folder: folder)
        defer { server.close() }
        let store = try VaultFolderStore(rootURL: directory.appendingPathComponent("LargePhone"))
        let transport = LunaVaultGoTransport(configuration: .init(stateDirectory: store.identityDirectory))
        let runtime = try VaultConnectedRuntime(store: store, dialer: transport, lookup: nil,
            localID: try transport.identity())
        try await runtime.pair(code: server.code.text)
        let pulled = try await runtime.fileURL(named: "From Mac.bin")
        XCTAssertEqual(try Data(contentsOf: pulled), expected)
        await runtime.stop()
    }

    func testPhotoFormatSettingsPersist() async throws {
        let store = try VaultFolderStore(rootURL: directory.appendingPathComponent("PhotoSettingsPhone"))
        let runtime = try VaultConnectedRuntime(store: store, dialer: RejectingDialer(), lookup: nil,
            localID: try DeviceID(bytes: Data(repeating: 1, count: 32)))
        let defaults = try await runtime.photoExportFormats()
        XCTAssertEqual(defaults.0, .jpeg)
        XCTAssertEqual(defaults.1, .mp4)
        try await runtime.setPhotoImageFormat(.original)
        try await runtime.setPhotoVideoFormat(.original)
        let reopened = try VaultFolderStore(rootURL: store.rootURL)
        XCTAssertEqual(try reopened.settings().photoImageFormat, .original)
        XCTAssertEqual(try reopened.settings().photoVideoFormat, .original)
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

    init(root: URL, folder: URL, account: CompanionAccountGate? = nil, clients: ClientStartupRecorder? = nil) async throws {
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
                    if let account {
                        guard account.allows(peer.device, pairingOpen: true),
                              account.approve(peer.device, generation: account.generation) else { peer.stream.close(); continue }
                    }
                    let index = try CompanionIndex(databaseURL: root.appendingPathComponent("index.sqlite"))
                    try index.replace(with: CompanionFolderScanner(rootURL: folder, deviceShortID: identity.shortID).scan())
                    let delegate = CompanionBEPDelegate(rootURL: folder, index: index, localDevice: identity, folderID: "vault", clientStarted: { clients?.record($0) })
                    let connection = BEPConnection(stream: peer.stream, peerDevice: peer.device,
                        localHello: BEPHello(deviceName: "Mac", clientName: "Test", clientVersion: "1"), delegate: delegate)
                    self.retain(connection, delegate)
                    _ = try await connection.start()
                    try await connection.send(clusterConfig: BEPClusterConfig(folders: [BEPFolder(id: "vault", label: "Vault",
                        devices: [BEPDevice(id: identity, name: "Mac"), BEPDevice(id: peer.device, name: "Phone")])]))
                    let files = try index.all()
                    delegate.startServing(connection)
                    try await connection.send(index: BEPIndex(folder: "vault", files: files,
                        lastSequence: files.map(\.sequence).max() ?? 0, isUpdate: false))
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


private final class MemoryMacCredentials: LunaMacCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: LunaMacCredentials?
    func load() throws -> LunaMacCredentials? { lock.withLock { stored } }
    func save(_ credentials: LunaMacCredentials) throws { lock.withLock { stored = credentials } }
}

private final class ClientStartupRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = Set<LunaMacClient>()
    var clients: Set<LunaMacClient> { lock.withLock { stored } }
    func record(_ client: LunaMacClient) { lock.withLock { _ = stored.insert(client) } }
}

final class UnifiedMacConnectionTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("UnifiedMacTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testTwoDevicesRestoreOneIdentityAnnounceAppsRejectOutsiderAndShareDisconnect() async throws {
        let credentials = MemoryMacCredentials(), account = CompanionAccountGate(), clients = ClientStartupRecorder()
        let folder = root.appendingPathComponent("Files")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let mac = try await LocalMacPeer(root: root.appendingPathComponent("Mac"), folder: folder, account: account, clients: clients)
        defer { mac.close() }
        let firstStore = try VaultFolderStore(rootURL: root.appendingPathComponent("iPhone"))
        let first = try LunaMacConnection.makeRuntime(client: .vault, store: firstStore, credentials: credentials)
        try await first.pair(code: mac.code.text)
        let firstSnapshot = try await first.pairingSnapshot()
        XCTAssertEqual(account.trustedDevice?.description, firstSnapshot.localDeviceID)
        // A second physical device has a different filesystem and no local pairing.
        let secondStore = try VaultFolderStore(rootURL: root.appendingPathComponent("iPad"))
        let second = try LunaMacConnection.makeRuntime(client: .music, store: secondStore, credentials: credentials)
        let secondSnapshot = try await second.pairingSnapshot()
        XCTAssertTrue(secondSnapshot.isPaired)
        XCTAssertEqual(secondSnapshot.localDeviceID, firstSnapshot.localDeviceID)
        await second.reconnect()
        let secondStatus = await second.connectionStatus()
        XCTAssertEqual(secondStatus, .connected)
        XCTAssertEqual(clients.clients, [.vault, .music])
        let code = try LunaMacConnection.makeRuntime(client: .code, store: secondStore, credentials: credentials)
        await code.reconnect()
        XCTAssertEqual(clients.clients, Set(LunaMacClient.allCases))
        // A different iCloud Keychain cannot replace the approved identity.
        let outsider = try LunaMacConnection.makeRuntime(client: .code,
            store: VaultFolderStore(rootURL: root.appendingPathComponent("OtherAccount")), credentials: MemoryMacCredentials())
        do { try await outsider.pair(code: mac.code.text); XCTFail("Allowed a second account") } catch { }
        XCTAssertEqual(account.trustedDevice?.description, firstSnapshot.localDeviceID)
        try await first.removePairing()
        let disconnected = try await second.pairingSnapshot()
        XCTAssertFalse(disconnected.isPaired)
        XCTAssertNil(try secondStore.peer())
        XCTAssertNil(try credentials.load()?.pairing)
        // Code shares this iPad's SQLite store with Music but still has its
        // own live session: the missing row must revoke that session too.
        do { _ = try await code.codeRequest(Data()); XCTFail("Code retained access after shared disconnect") } catch { }
        let codeStatus = await code.connectionStatus()
        XCTAssertEqual(codeStatus, .notPaired)
        await first.stop(); await second.stop(); await code.stop(); await outsider.stop()
    }

    func testCredentialsArrivingWhileAppIsOpenRestoreWithoutResettingLocalCursors() async throws {
        let credentials = MemoryMacCredentials()
        let secondStore = try VaultFolderStore(rootURL: root.appendingPathComponent("Second"))
        let second = try LunaMacConnection.makeRuntime(client: .code, store: secondStore, credentials: credentials)
        let original = try await second.pairingSnapshot()
        XCTAssertFalse(original.isPaired)
        let source = root.appendingPathComponent("SourceIdentity")
        let transport = LunaVaultGoTransport(configuration: .init(stateDirectory: source))
        let sharedID = try transport.identity()
        let peer = VaultPeerRecord(deviceID: try DeviceID(bytes: Data(repeating: 44, count: 32)), name: "My Mac",
            manualAddresses: [.tcp(host: "127.0.0.1", port: 49200)], folderID: "vault", folderLabel: "Vault", lastConnectedAt: Date())
        let identity = LunaMacIdentityStore(root: root, credentials: credentials)
        try identity.publish(peer: peer, identityDirectory: source, expectedID: sharedID)
        let restored = try await second.pairingSnapshot()
        XCTAssertTrue(restored.isPaired)
        XCTAssertNotEqual(original.localDeviceID, restored.localDeviceID)
        XCTAssertEqual(restored.localDeviceID, sharedID.description)
        var local = try XCTUnwrap(secondStore.peer())
        local.theirIndexID = 123; local.theirMaxSequence = 99; local.ourIndexID = 456
        try secondStore.savePeer(local)
        try identity.publish(peer: peer, identityDirectory: source, expectedID: sharedID)
        _ = try await second.pairingSnapshot()
        XCTAssertEqual(try secondStore.peer()?.theirIndexID, 123)
        XCTAssertEqual(try secondStore.peer()?.theirMaxSequence, 99)
        XCTAssertEqual(try secondStore.peer()?.ourIndexID, 456)
        await second.stop()
    }

    func testOnlyVerifiedPairingsCanBePublishedAndCloudIdentityCannotBeOverwritten() throws {
        let credentials = MemoryMacCredentials()
        let identity = LunaMacIdentityStore(root: root, credentials: credentials)
        let source = root.appendingPathComponent("Identity")
        let transport = LunaVaultGoTransport(configuration: .init(stateDirectory: source))
        let id = try transport.identity()
        var peer = VaultPeerRecord(deviceID: try DeviceID(bytes: Data(repeating: 3, count: 32)), name: "Mac")
        XCTAssertThrowsError(try identity.publish(peer: peer, identityDirectory: source, expectedID: id))
        XCTAssertNil(try credentials.load())
        peer.lastConnectedAt = Date()
        try identity.publish(peer: peer, identityDirectory: source, expectedID: id)
        let outsider = root.appendingPathComponent("OtherIdentity")
        let other = LunaVaultGoTransport(configuration: .init(stateDirectory: outsider))
        XCTAssertThrowsError(try identity.publish(peer: peer, identityDirectory: outsider, expectedID: other.identity()))
        XCTAssertEqual(try identity.restore()?.1.identity(), id)
    }

    func testStartupRequiresApprovalValidatesVersionAndCannotResumeAfterRevocation() async throws {
        let clients = ClientStartupRecorder()
        let mac = try DeviceID(bytes: Data(repeating: 7, count: 32))
        let phone = try DeviceID(bytes: Data(repeating: 8, count: 32))
        let index = try CompanionIndex(databaseURL: root.appendingPathComponent("startup.sqlite"))
        let delegate = CompanionBEPDelegate(rootURL: root, index: index, localDevice: mac,
            folderID: "vault", clientStarted: { clients.record($0) })
        let streams = PipeByteStream.pair()
        defer { streams.0.close(); streams.1.close() }
        let connection = BEPConnection(stream: streams.0, peerDevice: phone,
            localHello: BEPHello(deviceName: "Mac", clientName: "Luna Mac", clientVersion: "1"), delegate: delegate)
        let startup = try JSONEncoder().encode(LunaMacClientStartup(client: .code))
        let request = BEPRequest(id: 1, folder: LunaMacClientStartup.folder,
            name: startup.base64EncodedString(), offset: 0, size: 0, hash: Data())
        if case .success = await delegate.connection(connection, serve: request) { XCTFail("Startup before approval") }
        XCTAssertTrue(clients.clients.isEmpty)
        delegate.startServing(connection)
        let unknown = BEPRequest(id: 2, folder: LunaMacClientStartup.folder,
            name: Data(#"{"version":2,"client":"code"}"#.utf8).base64EncodedString(), offset: 0, size: 0, hash: Data())
        if case .success = await delegate.connection(connection, serve: unknown) { XCTFail("Accepted unsupported protocol") }
        XCTAssertTrue(clients.clients.isEmpty)
        if case .failure = await delegate.connection(connection, serve: request) { XCTFail("Approved startup failed") }
        XCTAssertEqual(clients.clients, [.code])
        delegate.revoke()
        delegate.startServing(connection)
        if case .success = await delegate.connection(connection, serve: request) { XCTFail("Revoked delegate reauthorized") }
    }

    func testAccountGateRequiresExplicitResetAndRejectsStaleApproval() throws {
        let first = try DeviceID(bytes: Data(repeating: 1, count: 32))
        let second = try DeviceID(bytes: Data(repeating: 2, count: 32))
        let gate = CompanionAccountGate()
        XCTAssertFalse(gate.allows(first, pairingOpen: false))
        let generation = gate.generation
        XCTAssertTrue(gate.approve(first, generation: generation))
        XCTAssertTrue(gate.allows(first, pairingOpen: false))
        XCTAssertFalse(gate.allows(second, pairingOpen: true))
        XCTAssertFalse(gate.approve(second, generation: generation))
        gate.reset()
        XCTAssertFalse(gate.approve(first, generation: generation))
        XCTAssertTrue(gate.approve(second, generation: gate.generation))
    }

    @MainActor func testEveryAppFirstLaunchShowsRestoredConnectionAndOnlyVaultShowsVaultSettings() async throws {
        let credentials = MemoryMacCredentials()
        let source = root.appendingPathComponent("Identity")
        let transport = LunaVaultGoTransport(configuration: .init(stateDirectory: source))
        let peer = VaultPeerRecord(deviceID: try DeviceID(bytes: Data(repeating: 4, count: 32)), name: "Studio Mac",
            folderID: "vault", folderLabel: "Vault", lastConnectedAt: Date())
        try LunaMacIdentityStore(root: root, credentials: credentials).publish(peer: peer, identityDirectory: source, expectedID: transport.identity())
        for client in LunaMacClient.allCases {
            let store = try VaultFolderStore(rootURL: root.appendingPathComponent(client.rawValue))
            let runtime = try LunaMacConnection.makeRuntime(client: client, store: store, credentials: credentials)
            let domain = "UnifiedMacUITests." + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
            defer { defaults.removePersistentDomain(forName: domain) }
            let content = UIViewController()
            let launch = LunaMacLaunchViewController(runtime: runtime, client: client, content: content, defaults: defaults)
            launch.loadViewIfNeeded()
            let navigation = try XCTUnwrap(launch.children.first as? UINavigationController)
            let connection = try XCTUnwrap(navigation.topViewController as? LunaMacConnectionViewController)
            connection.loadViewIfNeeded(); connection.beginAppearanceTransition(true, animated: false); connection.endAppearanceTransition()
            for _ in 0..<100 where connection.tableView.numberOfSections == 0 { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(connection.tableView.numberOfSections, client == .vault ? 5 : 2)
            XCTAssertEqual(connection.title, "Luna Mac")
            XCTAssertTrue(allLabels(connection.tableView.tableHeaderView).contains("Already connected"))
            connection.onContinue?()
            XCTAssertTrue(launch.children.first === content)
            await runtime.stop()
        }
    }
    @MainActor private func allLabels(_ view: UIView?) -> [String] {
        guard let view else { return [] }
        return (view as? UILabel).flatMap(\.text).map { [$0] } ?? view.subviews.flatMap { allLabels($0) }
    }
}

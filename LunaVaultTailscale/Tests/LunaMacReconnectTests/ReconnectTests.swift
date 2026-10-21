import XCTest
import LunaVaultBEP
import LunaVaultMacPeer
@testable import LunaVaultMacCompanion

final class ReconnectTests: XCTestCase {
    private let hello = BEPHello(deviceName: "Test", clientName: "Test", clientVersion: "1")

    private func connection(_ stream: any BEPByteStream, delegate: EmptyDelegate,
                            timing: BEPConnectionTiming) throws -> BEPConnection {
        BEPConnection(stream: stream, peerDevice: try DeviceID(bytes: Data(repeating: 1, count: 32)),
                      localHello: hello, delegate: delegate, timing: timing)
    }

    func testHelloDeadlineIncludesBlockedWrite() async throws {
        let (base, peer) = PipeByteStream.pair()
        let stream = StallingStream(base)
        let delegate = EmptyDelegate()
        var timing = BEPConnectionTiming(); timing.helloTimeout = 0.05
        let session = try connection(stream, delegate: delegate, timing: timing)
        stream.stall()
        // Rescue a regression without leaving the suite waiting forever.
        let rescue = Task { try? await Task.sleep(for: .milliseconds(500)); stream.close() }
        defer { rescue.cancel(); peer.close() }
        let began = Date()
        do { try await session.start(); XCTFail("A stalled Hello must fail") } catch { }
        XCTAssertLessThan(Date().timeIntervalSince(began), 0.4)
        let closed = await session.isClosed
        XCTAssertTrue(closed)
    }

    func testBlockedIndexWriteClosesSessionWithoutManualReconnect() async throws {
        let (base, peer) = PipeByteStream.pair()
        let stream = StallingStream(base)
        let delegate = EmptyDelegate()
        var timing = BEPConnectionTiming(); timing.writeTimeout = 0.05
        let session = try connection(stream, delegate: delegate, timing: timing)
        try await peer.write(BEPFraming.encodeHello(hello))
        try await session.start()
        try await session.send(clusterConfig: BEPClusterConfig(folders: []))
        stream.stall()
        let rescue = Task { try? await Task.sleep(for: .milliseconds(500)); stream.close() }
        defer { rescue.cancel(); peer.close() }
        let began = Date()
        do {
            try await session.send(index: BEPIndex(folder: "vault", files: [], lastSequence: 0, isUpdate: false))
            XCTFail("A stalled index must fail")
        } catch { }
        XCTAssertLessThan(Date().timeIntervalSince(began), 0.4)
        let closed = await session.isClosed
        XCTAssertTrue(closed)
    }

    func testBlockedPingCannotDisableDeadPeerCleanup() async throws {
        let (base, peer) = PipeByteStream.pair()
        let stream = StallingStream(base)
        let delegate = EmptyDelegate()
        var timing = BEPConnectionTiming()
        timing.pingInterval = 0.02; timing.timerTick = 0.01
        timing.writeTimeout = 0.05; timing.receiveTimeout = 0.15
        let session = try connection(stream, delegate: delegate, timing: timing)
        try await peer.write(BEPFraming.encodeHello(hello))
        try await session.start()
        try await session.send(clusterConfig: BEPClusterConfig(folders: []))
        stream.stall()
        defer { stream.close(); peer.close() }
        for _ in 0..<40 {
            if await session.isClosed { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let closed = await session.isClosed
        XCTAssertTrue(closed, "A blocked keepalive must not pin the receive-timeout task forever")
    }

    func testInitialExchangeEnablesCodeBeforeAnyFolderScan() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let localID = try DeviceID(bytes: Data(repeating: 2, count: 32))
        let index = try CompanionIndex(databaseURL: directory.appendingPathComponent("index.sqlite"))
        let layout = BlockLayout.blocks(for: Data([1]))
        let saved = BEPFileInfo(name: "saved.txt", size: 1,
            version: VersionVector(counters: [VersionCounter(id: 2, value: 1)]),
            blockSize: Int32(layout.blockSize), blocks: layout.blocks, blocksHash: BlockLayout.blocksHash(layout.blocks))
        try index.upsert(CompanionFileRecord(info: saved))
        // The Vault directory is intentionally absent. No disk scan or access
        // probe can complete before this shared service handshake.
        let delegate = CompanionBEPDelegate(rootURL: directory.appendingPathComponent("unavailable"),
            index: index, localDevice: localID, folderID: "vault", codeHandler: { $0 })
        let (macStream, phoneStream) = PipeByteStream.pair()
        let phoneDelegate = IndexDelegate()
        let mac = BEPConnection(stream: macStream, peerDevice: localID, localHello: hello, delegate: delegate)
        let phone = BEPConnection(stream: phoneStream, peerDevice: localID, localHello: hello, delegate: phoneDelegate)
        async let macHello = mac.start()
        try await phone.start(); _ = try await macHello
        try await phone.send(clusterConfig: BEPClusterConfig(folders: []))
        try await CompanionInitialExchange.send(connection: mac, delegate: delegate, index: index,
            config: BEPClusterConfig(folders: []))
        for _ in 0..<100 {
            if await phoneDelegate.names == ["saved.txt"] { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let names = await phoneDelegate.names
        XCTAssertEqual(names, ["saved.txt"])
        let payload = Data("Code remains usable during a slow Vault rescan".utf8)
        let reply = try await phone.codeRequest(payload)
        XCTAssertEqual(reply, payload)
        await phone.close(reason: "Test finished")
        await mac.close(reason: "Test finished")
    }

    func testSavedSnapshotIsRetainedForReconnectAndClearedForDifferentFolder() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = try CompanionIndex(databaseURL: directory.appendingPathComponent("index.sqlite"))
        let first = directory.appendingPathComponent("First")
        try index.prepareSnapshot(root: first)
        try index.upsert(CompanionFileRecord(info: BEPFileInfo(name: "private", type: .directory)))
        try index.prepareSnapshot(root: first)
        XCTAssertEqual(try index.all().map(\.name), ["private"])
        try index.prepareSnapshot(root: directory.appendingPathComponent("Second"))
        XCTAssertTrue(try index.all().isEmpty)
    }

    func testRepeatedNetworkChangesAdmitNewestSessionAndKeepOtherApps() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let localID = try DeviceID(bytes: Data(repeating: 2, count: 32))
        let index = try CompanionIndex(databaseURL: directory.appendingPathComponent("index.sqlite"))
        var sessions = CompanionSessions()
        var ids: [UUID] = []
        var connections: [BEPConnection] = []
        for attempt in 0..<24 {
            let (stream, peer) = PipeByteStream.pair()
            // Deliberately retain sessions whose peers vanished, as after Wi-Fi loss.
            peer.close()
            let delegate = CompanionBEPDelegate(rootURL: directory, index: index, localDevice: localID, folderID: "vault")
            let session = BEPConnection(stream: stream, peerDevice: localID, localHello: hello, delegate: delegate)
            let id = UUID(); ids.append(id); connections.append(session)
            let retired = sessions.insert((session, delegate), for: id)
            if attempt < 8 { XCTAssertNil(retired) }
            else {
                XCTAssertTrue(retired?.0 === connections[attempt - 8])
                XCTAssertNil(sessions[ids[attempt - 8]])
            }
            XCTAssertTrue(sessions[id]?.0 === session)
            XCTAssertEqual(sessions.values.count, min(attempt + 1, 8))
        }
        // Delayed cleanup from a retired task cannot remove its replacement.
        sessions.removeValue(forKey: ids[0])
        XCTAssertTrue(sessions[ids[23]]?.0 === connections[23])
        sessions.removeAll()
        XCTAssertTrue(sessions.isEmpty)
    }
}

private final class EmptyDelegate: BEPConnectionDelegate, @unchecked Sendable {
    func connection(_ connection: BEPConnection, didReceive clusterConfig: BEPClusterConfig) async {}
    func connection(_ connection: BEPConnection, didReceive index: BEPIndex) async {}
    func connection(_ connection: BEPConnection, serve request: BEPRequest) async -> Result<Data, BEPErrorCode> { .failure(.noSuchFile) }
    func connection(_ connection: BEPConnection, didCloseWith error: Error?) async {}
}

/// Models a network bridge whose output buffer stopped draining. Cancellation
/// alone cannot wake the write; closing the transport must do that.
private final class StallingStream: BEPByteStream, @unchecked Sendable {
    private let base: any BEPByteStream
    private let lock = NSLock()
    private var stalled = false
    private var closed = false
    private var waiters: [CheckedContinuation<Void, Error>] = []
    init(_ base: any BEPByteStream) { self.base = base }
    func stall() { lock.lock(); stalled = true; lock.unlock() }
    func read(exactly count: Int) async throws -> Data { try await base.read(exactly: count) }
    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if closed { lock.unlock(); continuation.resume(throwing: BEPStreamError.closed) }
            else if stalled { waiters.append(continuation); lock.unlock() }
            else { lock.unlock(); continuation.resume() }
        }
        try await base.write(data)
    }
    func close() {
        lock.lock(); closed = true
        let pending = waiters; waiters.removeAll(); lock.unlock()
        base.close()
        for waiter in pending { waiter.resume(throwing: BEPStreamError.closed) }
    }
}

private actor IndexDelegate: BEPConnectionDelegate {
    var names: [String] = []
    func connection(_ connection: BEPConnection, didReceive clusterConfig: BEPClusterConfig) async {}
    func connection(_ connection: BEPConnection, didReceive index: BEPIndex) async { names = index.files.map(\.name) }
    func connection(_ connection: BEPConnection, serve request: BEPRequest) async -> Result<Data, BEPErrorCode> { .failure(.noSuchFile) }
    func connection(_ connection: BEPConnection, didCloseWith error: Error?) async {}
}

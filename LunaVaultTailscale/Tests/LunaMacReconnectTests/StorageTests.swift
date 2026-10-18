import XCTest
import LunaVaultBEP
import LunaVaultMacPeer

final class StorageTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func write(_ name: String, in root: URL) throws {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((0..<16_384).map { UInt8($0 % 251) }).write(to: url)
    }
    func testMeasuresCategoriesAndCompanionStateOnTheCorrectVolume() throws {
        let base = try directory(), root = base.appendingPathComponent("Vault"), state = base.appendingPathComponent("State")
        for name in ["Music/Album/song.FLAC", "photo.HEIC", "movie.mov", "document.pdf", ".luna-music-index.json"] { try write(name, in: root) }
        try write("companion.sqlite", in: state)
        try write("Code/Jobs/build.log", in: state)
        let snapshot = try CompanionStorageScanner(rootURL: root, stateURL: state).scan()
        XCTAssertEqual(snapshot.volumes.count, 1)
        let volume = try XCTUnwrap(snapshot.volumes.first)
        for category in LunaMacStorageCategory.allCases { XCTAssertGreaterThan(volume.categories[category, default: 0], 0, category.title) }
        XCTAssertEqual(volume.lunaBytes + volume.otherBytes + volume.freeBytes, volume.totalBytes)
        let capacity = try root.resourceValues(forKeys: [.volumeTotalCapacityKey]).volumeTotalCapacity
        XCTAssertEqual(volume.totalBytes, capacity.map(Int64.init))
        XCTAssertEqual(try JSONDecoder().decode(LunaMacStorageSnapshot.self, from: JSONEncoder().encode(snapshot)), snapshot)
    }
    func testHardLinksSymlinksAndOverlappingRootsAreNotCountedTwice() throws {
        let root = try directory(), state = root.appendingPathComponent("State")
        try write("song.mp3", in: root); try write("photo.jpg", in: root); try write("database.sqlite", in: state)
        let scanner = CompanionStorageScanner(rootURL: root, stateURL: state)
        let before = try XCTUnwrap(scanner.scan().volumes.first)
        try FileManager.default.linkItem(at: root.appendingPathComponent("song.mp3"), to: root.appendingPathComponent("another.mp3"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked.jpg"), withDestinationURL: root.appendingPathComponent("photo.jpg"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("loop"), withDestinationURL: root)
        let after = try XCTUnwrap(scanner.scan().volumes.first)
        XCTAssertEqual(after.categories[.music], before.categories[.music])
        XCTAssertEqual(after.categories[.photos], before.categories[.photos])
        XCTAssertEqual(after.categories[.files, default: 0], 0, "The nested state database belongs to App Data, once")
        let single = try XCTUnwrap(CompanionStorageScanner(rootURL: state, stateURL: state).scan().volumes.first)
        XCTAssertEqual(single.categories[.files, default: 0], 0)
    }
    func testManualRefreshBypassesCachedMeasurement() async throws {
        let root = try directory()
        try write("song.mp3", in: root)
        let service = CompanionStorageService(rootURL: root)
        let first = try JSONDecoder().decode(LunaMacStorageResponse.self, from: await service.response())
        try write("photo.heic", in: root)
        let cached = try JSONDecoder().decode(LunaMacStorageResponse.self, from: await service.response())
        XCTAssertEqual(cached.snapshot, first.snapshot)
        let refreshed = try JSONDecoder().decode(LunaMacStorageResponse.self, from: await service.response(refresh: true))
        XCTAssertNil(refreshed.error)
        XCTAssertGreaterThan(try XCTUnwrap(refreshed.snapshot?.volumes.first).categories[.photos, default: 0], 0)
    }

    func testMissingFolderReportsFailureInsteadOfZeroUsage() throws {
        let root = try directory().appendingPathComponent("Missing")
        XCTAssertThrowsError(try CompanionStorageScanner(rootURL: root).scan())
    }
    func testRejectsInvalidCapacityNegativeAndOverflowingCategories() {
        for value in [
            LunaMacStorageVolume(id: "disk", name: "Disk", totalBytes: 0, freeBytes: 0, categories: [:]),
            LunaMacStorageVolume(id: "disk", name: "Disk", totalBytes: 100, freeBytes: 101, categories: [:]),
            LunaMacStorageVolume(id: "disk", name: "Disk", totalBytes: 100, freeBytes: 0, categories: [.files: -1]),
            LunaMacStorageVolume(id: "disk", name: "Disk", totalBytes: .max, freeBytes: 0, categories: [.files: .max, .music: 1]),
            LunaMacStorageVolume(id: "disk", name: "Disk", totalBytes: 100, freeBytes: 50, categories: [.files: 51])
        ] { XCTAssertThrowsError(try value.validate()) }
    }
    func testStorageRPCRequiresApprovalAndRejectsMalformedRequests() async throws {
        let root = try directory()
        try write("Music/song.mp3", in: root)
        let index = try CompanionIndex(databaseURL: root.appendingPathComponent("companion.sqlite"))
        let id = try DeviceID(bytes: Data(repeating: 7, count: 32))
        let delegate = CompanionBEPDelegate(rootURL: root, index: index, localDevice: id, folderID: "vault")
        let (a, b) = PipeByteStream.pair()
        defer { a.close(); b.close() }
        let hello = BEPHello(deviceName: "Test", clientName: "Test", clientVersion: "1")
        let phoneDelegate = StorageEmptyDelegate()
        defer { withExtendedLifetime(phoneDelegate) {} }
        let mac = BEPConnection(stream: a, peerDevice: id, localHello: hello, delegate: delegate)
        let phone = BEPConnection(stream: b, peerDevice: id, localHello: hello, delegate: phoneDelegate)
        let valid = BEPRequest(id: 1, folder: LunaMacStorageProtocol.folder, name: "", offset: 0, size: 0, hash: Data())
        let denied = await delegate.connection(mac, serve: valid)
        if case .success = denied { XCTFail("Storage must be private before approval") }
        delegate.startServing(mac)
        let malformed = BEPRequest(id: 2, folder: LunaMacStorageProtocol.folder, name: "/arbitrary/path", offset: 0, size: 0, hash: Data())
        let rejected = await delegate.connection(mac, serve: malformed)
        if case .success = rejected { XCTFail("Storage must not accept a client-supplied path") }
        async let start = mac.start()
        try await phone.start(); _ = try await start
        try await phone.send(clusterConfig: BEPClusterConfig(folders: []))
        try await mac.send(clusterConfig: BEPClusterConfig(folders: []))
        let snapshot = try await phone.macStorage()
        XCTAssertGreaterThan(try XCTUnwrap(snapshot.volumes.first).categories[.music, default: 0], 0)
        delegate.revoke()
        do { _ = try await phone.macStorage(); XCTFail("Revoked clients must lose storage access") } catch { }
        await phone.close(reason: "Done"); await mac.close(reason: "Done")
    }
    func testOlderCompanionReturnsAnUpdateMessage() async throws {
        let (a, b) = PipeByteStream.pair()
        defer { a.close(); b.close() }
        let id = try DeviceID(bytes: Data(repeating: 8, count: 32))
        let hello = BEPHello(deviceName: "Test", clientName: "Test", clientVersion: "1")
        let macDelegate = StorageEmptyDelegate(), phoneDelegate = StorageEmptyDelegate()
        defer { withExtendedLifetime((macDelegate, phoneDelegate)) {} }
        let mac = BEPConnection(stream: a, peerDevice: id, localHello: hello, delegate: macDelegate)
        let phone = BEPConnection(stream: b, peerDevice: id, localHello: hello, delegate: phoneDelegate)
        async let start = mac.start()
        try await phone.start(); _ = try await start
        try await phone.send(clusterConfig: BEPClusterConfig(folders: []))
        try await mac.send(clusterConfig: BEPClusterConfig(folders: []))
        do { _ = try await phone.macStorage(); XCTFail("Unsupported storage must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Update and reopen Luna Mac")) }
        await phone.close(reason: "Done"); await mac.close(reason: "Done")
    }
}
private final class StorageEmptyDelegate: BEPConnectionDelegate, @unchecked Sendable {
    func connection(_ connection: BEPConnection, didReceive clusterConfig: BEPClusterConfig) async {}
    func connection(_ connection: BEPConnection, didReceive index: BEPIndex) async {}
    func connection(_ connection: BEPConnection, serve request: BEPRequest) async -> Result<Data, BEPErrorCode> { .failure(.noSuchFile) }
    func connection(_ connection: BEPConnection, didCloseWith error: Error?) async {}
}

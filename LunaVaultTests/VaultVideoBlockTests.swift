import XCTest
import AVKit
import UIKit
import LunaVaultBEP
import LunaVaultStore
import LunaAppConfig
import LunaVaultSync
import LunaVaultUI

private actor VideoBlockReadSpy {
    var ranges: [(Int64, Int)] = []
    let bytes: Data
    init(_ bytes: Data) { self.bytes = bytes }
    func read(_ offset: Int64, _ length: Int) -> Data {
        ranges.append((offset, length))
        return bytes.subdata(in: Int(offset)..<(Int(offset) + length))
    }
}

final class VaultVideoBlockTests: XCTestCase {
    func testRemoteSeekAboveFourGBOnlyRequestsNeededBlockAndReusesIt() async throws {
        let data = Data(repeating: 37, count: BlockLayout.maximumBlockSize)
        let hash = SHA256Digest.hash(data)
        let blocks = (0..<513).map { BlockInfo(offset: Int64($0 * data.count), size: Int32(data.count), hash: hash) }
        let spy = VideoBlockReadSpy(data)
        let reader = try VaultMediaBlockReader(blocks: blocks, size: Int64(blocks.count * data.count)) { _, block in
            await spy.read(0, Int(block.size))
        }
        let offset = blocks[500].offset + 101
        XCTAssertGreaterThan(offset, Int64(UInt32.max))
        let first = try await reader.read(offset: offset, length: 100)
        let second = try await reader.read(offset: offset + 100, length: 100)
        XCTAssertEqual(first, Data(repeating: 37, count: 100)); XCTAssertEqual(second, first)
        let requests = await spy.ranges
        XCTAssertEqual(requests.count, 1)
        // Three 16-MiB blocks exceed the memory budget; the oldest must be fetched again.
        for index in [501, 502, 500] {
            _ = try await reader.read(offset: blocks[index].offset, length: 100)
        }
        let afterEviction = await spy.ranges
        XCTAssertEqual(afterEviction.count, 4)
    }
    func testCrossBlockSliceAndCorruptBlockRejection() async throws {
        let data = Data((0..<300_000).map { UInt8($0 % 251) })
        let blocks = BlockLayout.blocks(for: data).blocks
        let spy = VideoBlockReadSpy(data)
        let reader = try VaultMediaBlockReader(blocks: blocks, size: Int64(data.count)) { _, block in
            await spy.read(block.offset, Int(block.size))
        }
        let slice = try await reader.read(offset: 131_000, length: 1000)
        XCTAssertEqual(slice, data.subdata(in: 131_000..<132_000))
        let requests = await spy.ranges
        XCTAssertEqual(requests.count, 2)
        let corrupt = try VaultMediaBlockReader(blocks: blocks, size: Int64(data.count)) { _, block in Data(repeating: 0, count: Int(block.size)) }
        do { _ = try await corrupt.read(offset: 0, length: 100); XCTFail("Accepted corrupt media") }
        catch { XCTAssertEqual(error as? BEPRequestError, .hashMismatch) }
    }
    func testCancelledReadStopsAndInvalidRangeDoesNotRequestBytes() async throws {
        let data = Data(repeating: 42, count: 128 * 1024)
        let blocks = BlockLayout.blocks(for: data).blocks
        let reader = try VaultMediaBlockReader(blocks: blocks, size: Int64(data.count)) { _, _ in
            try await Task.sleep(for: .seconds(30)); return data
        }
        let work = Task { try await reader.read(offset: 0, length: 100) }
        work.cancel()
        do { _ = try await work.value; XCTFail("Cancelled read succeeded") } catch { XCTAssertTrue(error is CancellationError) }
        do { _ = try await reader.read(offset: Int64(data.count), length: 1); XCTFail("Accepted past EOF") }
        catch { XCTAssertEqual(error as? VaultBlockFetchError, .invalidFile) }
    }
}


final class VaultAutomationTests: XCTestCase {
    func testPeerEventsDescribeVisibleObjectsAndResurrection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "VaultAutomationTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let journal = AppAutomation(app: .vault, directory: root, defaults: defaults)
        let store = try VaultFolderStore(rootURL: root.appendingPathComponent("Vault"), automationJournal: journal)
        try store.savePeer(VaultPeerRecord(deviceID: DeviceID(bytes: Data(repeating: 1, count: 32)), name: "Mac", folderID: "vault"))
        func apply(_ name: String = "article.txt", version: UInt64, deleted: Bool = false, invalid: Bool = false, folder: Bool = false) throws {
            let blocks = folder || deleted || invalid ? [] : BlockLayout.blocks(for: Data()).blocks
            let file = BEPFileInfo(name: name, type: folder ? .directory : .file, deleted: deleted, invalid: invalid,
                version: VersionVector(counters: [.init(id: 1, value: version)]), sequence: Int64(version), blocks: blocks)
            _ = try store.applyIndex(BEPIndex(folder: "vault", files: [file], isUpdate: true), ourShortID: 2)
        }
        try apply("unknown.txt", version: 1, deleted: true)
        try apply(version: 1)
        try apply(version: 1)
        try store.setCachePinned(name: "article.txt", pinned: false)
        try apply(version: 2, deleted: true)
        try apply(version: 3)
        try apply(version: 4, invalid: true)
        try apply(version: 5, invalid: true)
        XCTAssertEqual(try journal.changes().changes.map(\.notificationTitle), [
            "Luna.vault.file.created", "Luna.vault.file.deleted", "Luna.vault.file.created", "Luna.vault.file.deleted"
        ])
        XCTAssertTrue(try store.automationItems().isEmpty)
    }

    func testFullIndexPurgePublishesDeletionForMissingObjects() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "VaultAutomationTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let journal = AppAutomation(app: .vault, directory: root, defaults: defaults)
        let store = try VaultFolderStore(rootURL: root.appendingPathComponent("Vault"), automationJournal: journal)
        try store.savePeer(VaultPeerRecord(deviceID: DeviceID(bytes: Data(repeating: 1, count: 32)), name: "Mac", folderID: "vault"))
        let version = VersionVector(counters: [.init(id: 1, value: 1)])
        _ = try store.applyIndex(BEPIndex(folder: "vault", files: [BEPFileInfo(name: "Empty", type: .directory, version: version)], isUpdate: false), ourShortID: 2)
        let token = try journal.changes().nextToken
        _ = try store.applyIndex(BEPIndex(folder: "vault", files: [], isUpdate: false), ourShortID: 2)
        XCTAssertEqual(try store.purgeStaleGenerations(), ["Empty"])
        XCTAssertEqual(try journal.changes(after: token).changes.map(\.notificationTitle), ["Luna.vault.folder.deleted"])
    }
}

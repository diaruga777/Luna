import XCTest
import AVKit
import UIKit
import LunaVaultBEP
import LunaVaultStore
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


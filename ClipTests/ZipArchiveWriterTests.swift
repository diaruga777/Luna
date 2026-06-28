//
//  ZipArchiveWriterTests.swift
//  ClipTests
//

import ClipModels
import XCTest
@testable import Clip

final class ZipArchiveWriterTests: XCTestCase {

    func testCRC32MatchesStandardCheckValue() {
        // The canonical CRC-32 check: "123456789" → 0xCBF43926.
        XCTAssertEqual(ZipArchiveWriter.crc32(of: Data("123456789".utf8)), 0xCBF43926)
    }

    func testFirstEntryIsStoredAtArchiveStart() {
        var writer = ZipArchiveWriter()
        writer.addEntry(path: "mimetype", data: Data("application/epub+zip".utf8))
        writer.addEntry(path: "META-INF/container.xml", data: Data("<container/>".utf8))
        let archive = writer.archiveData()

        // Local header signature at byte 0.
        XCTAssertEqual(archive.prefix(4), Data([0x50, 0x4B, 0x03, 0x04]))
        // Compression method (offset 8) is 0 = stored.
        XCTAssertEqual(archive[8], 0)
        XCTAssertEqual(archive[9], 0)
        // Name "mimetype" follows the 30-byte header immediately.
        XCTAssertEqual(archive.subdata(in: 30..<38), Data("mimetype".utf8))
        // Then the uncompressed bytes.
        XCTAssertEqual(archive.subdata(in: 38..<(38 + 20)), Data("application/epub+zip".utf8))
    }

    func testCentralDirectoryListsAllEntries() throws {
        var writer = ZipArchiveWriter()
        writer.addEntry(path: "a.txt", data: Data("alpha".utf8))
        writer.addEntry(path: "dir/b.txt", data: Data("bravo".utf8))
        let archive = writer.archiveData()

        // End-of-central-directory record: last 22 bytes (no comment).
        let eocd = archive.suffix(22)
        XCTAssertEqual(eocd.prefix(4), Data([0x50, 0x4B, 0x05, 0x06]))
        let totalEntries = UInt16(eocd[eocd.startIndex + 10])
            | (UInt16(eocd[eocd.startIndex + 11]) << 8)
        XCTAssertEqual(totalEntries, 2)

        // Both names appear in the central directory region.
        let directoryOffset = UInt32(eocd[eocd.startIndex + 16])
            | (UInt32(eocd[eocd.startIndex + 17]) << 8)
            | (UInt32(eocd[eocd.startIndex + 18]) << 16)
            | (UInt32(eocd[eocd.startIndex + 19]) << 24)
        let directory = archive.subdata(in: Int(directoryOffset)..<(archive.count - 22))
        XCTAssertNotNil(directory.firstRange(of: Data("a.txt".utf8)))
        XCTAssertNotNil(directory.firstRange(of: Data("dir/b.txt".utf8)))
        XCTAssertEqual(directory.prefix(4), Data([0x50, 0x4B, 0x01, 0x02]))
    }

    func testArchiveRoundTripsThroughSystemUnzipStructures() {
        var writer = ZipArchiveWriter()
        let payload = Data((0..<1000).map { UInt8($0 % 251) })
        writer.addEntry(path: "blob.bin", data: payload)
        let archive = writer.archiveData()

        // CRC in the local header (offset 14) matches the payload's CRC.
        let crc = UInt32(archive[14]) | (UInt32(archive[15]) << 8)
            | (UInt32(archive[16]) << 16) | (UInt32(archive[17]) << 24)
        XCTAssertEqual(crc, ZipArchiveWriter.crc32(of: payload))
    }
}

//
//  ZipArchiveWriter.swift
//  ReaderKit
//

import Foundation

/// Minimal ZIP archive writer: stored (uncompressed) entries only, which is all
/// an EPUB needs. Entries appear in the archive in the order they were added —
/// EPUB requires `mimetype` to be the first, uncompressed entry.
public struct ZipArchiveWriter {

    private struct Entry {
        let path: String
        let data: Data
        let crc32: UInt32
        let localHeaderOffset: UInt32
    }

    private var entries: [Entry] = []
    private var body = Data()

    public init() {}

    /// Appends one file to the archive. `path` uses forward slashes.
    public mutating func addEntry(path: String, data: Data) {
        let pathBytes = Data(path.utf8)
        let crc = Self.crc32(of: data)
        let offset = UInt32(body.count)

        // Local file header.
        body.appendLittleEndian(UInt32(0x04034b50))
        body.appendLittleEndian(UInt16(20))        // version needed to extract
        body.appendLittleEndian(UInt16(0))         // flags
        body.appendLittleEndian(UInt16(0))         // method: stored
        body.appendLittleEndian(UInt16(0))         // mod time
        body.appendLittleEndian(UInt16(0x21))      // mod date (1980-01-01)
        body.appendLittleEndian(crc)
        body.appendLittleEndian(UInt32(data.count))  // compressed size
        body.appendLittleEndian(UInt32(data.count))  // uncompressed size
        body.appendLittleEndian(UInt16(pathBytes.count))
        body.appendLittleEndian(UInt16(0))         // extra field length
        body.append(pathBytes)
        body.append(data)

        entries.append(Entry(path: path, data: data, crc32: crc, localHeaderOffset: offset))
    }

    /// The complete archive bytes (central directory built on each call).
    public func archiveData() -> Data {
        var archive = body
        let centralDirectoryOffset = UInt32(archive.count)

        for entry in entries {
            let pathBytes = Data(entry.path.utf8)
            archive.appendLittleEndian(UInt32(0x02014b50))
            archive.appendLittleEndian(UInt16(20))     // version made by
            archive.appendLittleEndian(UInt16(20))     // version needed
            archive.appendLittleEndian(UInt16(0))      // flags
            archive.appendLittleEndian(UInt16(0))      // method: stored
            archive.appendLittleEndian(UInt16(0))      // mod time
            archive.appendLittleEndian(UInt16(0x21))   // mod date
            archive.appendLittleEndian(entry.crc32)
            archive.appendLittleEndian(UInt32(entry.data.count))
            archive.appendLittleEndian(UInt32(entry.data.count))
            archive.appendLittleEndian(UInt16(pathBytes.count))
            archive.appendLittleEndian(UInt16(0))      // extra length
            archive.appendLittleEndian(UInt16(0))      // comment length
            archive.appendLittleEndian(UInt16(0))      // disk number
            archive.appendLittleEndian(UInt16(0))      // internal attributes
            archive.appendLittleEndian(UInt32(0))      // external attributes
            archive.appendLittleEndian(entry.localHeaderOffset)
            archive.append(pathBytes)
        }

        let centralDirectorySize = UInt32(archive.count) - centralDirectoryOffset

        // End of central directory record.
        archive.appendLittleEndian(UInt32(0x06054b50))
        archive.appendLittleEndian(UInt16(0))          // disk number
        archive.appendLittleEndian(UInt16(0))          // central directory disk
        archive.appendLittleEndian(UInt16(entries.count))
        archive.appendLittleEndian(UInt16(entries.count))
        archive.appendLittleEndian(centralDirectorySize)
        archive.appendLittleEndian(centralDirectoryOffset)
        archive.appendLittleEndian(UInt16(0))          // comment length

        return archive
    }

    // MARK: - CRC32

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? (0xEDB88320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    public static func crc32(of data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}

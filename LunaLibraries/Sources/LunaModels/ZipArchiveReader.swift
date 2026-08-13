//
//  ZipArchiveReader.swift
//  LunaModels
//

import Compression
import Foundation

/// Minimal ZIP archive reader — the counterpart to `ZipArchiveWriter`, and what
/// lets Luna IMPORT the two container formats it already exports: EPUB and
/// `.docx`. Stored and deflated entries, which between them is every entry any
/// real ebook or Word document uses.
///
/// It reads the CENTRAL DIRECTORY rather than walking local headers from the
/// front. A local header may carry zeroes for both sizes and defer them to a
/// data descriptor that sits AFTER the compressed bytes (the streaming-writer
/// case), so the front of the file cannot always say where an entry ends; the
/// central directory always can.
///
/// Not supported, deliberately: ZIP64 (an ebook that needs 4GiB offsets is not
/// a saved item), encryption, and multi-disk archives. Each returns nil
/// rather than a partial read.
public struct ZipArchiveReader {

    private let bytes: [UInt8]
    /// Central-directory records, in the order the directory lists them.
    private let entries: [Entry]

    private struct Entry {
        let path: String
        let compressionMethod: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    /// Fails on anything that isn't a readable, non-ZIP64 zip.
    public init?(data: Data) {
        let bytes = [UInt8](data)
        guard let directory = Self.readCentralDirectory(bytes) else { return nil }
        self.bytes = bytes
        self.entries = directory
    }

    /// Every entry path, in central-directory order.
    public var paths: [String] { entries.map(\.path) }

    /// The decompressed bytes of one entry, or nil when it is absent or cannot
    /// be read. Paths are matched exactly — zip paths are already normalized to
    /// forward slashes with no leading one.
    public func data(at path: String) -> Data? {
        guard let entry = entries.first(where: { $0.path == path }) else { return nil }
        return data(for: entry)
    }

    /// The decompressed bytes of one entry as UTF-8 text, tolerating a leading
    /// BOM (which XML writers emit and `XMLParser`/SwiftSoup then trip over) and
    /// falling back to Latin-1, which cannot fail — one bad byte should not cost
    /// the reader a whole chapter.
    public func text(at path: String) -> String? {
        guard let data = data(at: path) else { return nil }
        let stripped = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data[...]
        if let utf8 = String(data: stripped, encoding: .utf8) { return utf8 }
        return String(data: stripped, encoding: .isoLatin1)
    }

    private func data(for entry: Entry) -> Data? {
        // The central directory records where the LOCAL header starts, not where
        // its payload does — and the two headers may declare different extra-field
        // lengths, so the payload offset has to come from the local one.
        let header = entry.localHeaderOffset
        guard header >= 0, header + 30 <= bytes.count,
              Self.readUInt32(bytes, at: header) == 0x0403_4b50
        else { return nil }
        let nameLength = Int(Self.readUInt16(bytes, at: header + 26))
        let extraLength = Int(Self.readUInt16(bytes, at: header + 28))
        let start = header + 30 + nameLength + extraLength
        let end = start + entry.compressedSize
        guard start >= 0, end <= bytes.count, start <= end else { return nil }
        let payload = bytes[start..<end]

        switch entry.compressionMethod {
        case 0: return Data(payload)
        case 8: return Self.inflate(payload, expectedSize: entry.uncompressedSize)
        default: return nil
        }
    }

    // MARK: - Central directory

    private static func readCentralDirectory(_ bytes: [UInt8]) -> [Entry]? {
        guard let eocd = endOfCentralDirectoryOffset(bytes) else { return nil }
        let directoryOffset = Int(readUInt32(bytes, at: eocd + 16))
        // 0xFFFFFFFF is the ZIP64 escape: the real offset lives in a record this
        // reader doesn't parse, so stop rather than seek to a bogus place.
        guard directoryOffset != 0xFFFF_FFFF, directoryOffset < bytes.count else { return nil }

        var entries: [Entry] = []
        var cursor = directoryOffset
        // Walked until the signature stops matching rather than for the record
        // count in the EOCD, which is a UInt16 and saturates at 0xFFFF.
        while cursor + 46 <= bytes.count, readUInt32(bytes, at: cursor) == 0x0201_4b50 {
            let nameLength = Int(readUInt16(bytes, at: cursor + 28))
            let extraLength = Int(readUInt16(bytes, at: cursor + 30))
            let commentLength = Int(readUInt16(bytes, at: cursor + 32))
            let nameStart = cursor + 46
            let nameEnd = nameStart + nameLength
            guard nameEnd <= bytes.count else { return entries.isEmpty ? nil : entries }

            let path = String(decoding: bytes[nameStart..<nameEnd], as: UTF8.self)
            // A directory record (trailing slash, no payload) is not an entry.
            if !path.hasSuffix("/") {
                entries.append(Entry(
                    path: path,
                    compressionMethod: readUInt16(bytes, at: cursor + 10),
                    compressedSize: Int(readUInt32(bytes, at: cursor + 20)),
                    uncompressedSize: Int(readUInt32(bytes, at: cursor + 24)),
                    localHeaderOffset: Int(readUInt32(bytes, at: cursor + 42))))
            }
            cursor = nameEnd + extraLength + commentLength
        }
        return entries.isEmpty ? nil : entries
    }

    /// The end-of-central-directory record, found by scanning backwards for its
    /// signature. It sits at the very end unless the archive carries a trailing
    /// comment, which is at most 0xFFFF bytes — so the search is bounded.
    private static func endOfCentralDirectoryOffset(_ bytes: [UInt8]) -> Int? {
        let minimum = 22
        guard bytes.count >= minimum else { return nil }
        let lowest = max(0, bytes.count - minimum - 0xFFFF)
        var offset = bytes.count - minimum
        while offset >= lowest {
            if readUInt32(bytes, at: offset) == 0x0605_4b50 { return offset }
            offset -= 1
        }
        return nil
    }

    // MARK: - Inflate

    /// Raw DEFLATE — which is what `COMPRESSION_ZLIB` means in Apple's
    /// compression library (no zlib header, no trailer), and exactly what a zip
    /// entry holds.
    ///
    /// `expectedSize` comes from the central directory and is almost always
    /// right; a writer that left it at zero gets a doubling search instead,
    /// because `compression_decode_buffer` reports a truncated result and a
    /// perfectly-filled buffer identically.
    private static func inflate(_ payload: ArraySlice<UInt8>, expectedSize: Int) -> Data? {
        if expectedSize > 0 {
            return decode(payload, capacity: expectedSize).flatMap {
                $0.count == expectedSize ? $0 : nil
            }
        }
        var capacity = max(payload.count * 4, 64 * 1024)
        while capacity <= 64 * 1024 * 1024 {
            guard let decoded = decode(payload, capacity: capacity) else { return nil }
            if decoded.count < capacity { return decoded }
            capacity *= 2
        }
        return nil
    }

    private static func decode(_ payload: ArraySlice<UInt8>, capacity: Int) -> Data? {
        guard capacity > 0, !payload.isEmpty else { return Data() }
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress
            else { return 0 }
            return payload.withUnsafeBufferPointer { source -> Int in
                guard let sourceBase = source.baseAddress else { return 0 }
                return compression_decode_buffer(
                    destinationBase, capacity, sourceBase, source.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return output.prefix(written)
    }

    // MARK: - Little-endian reads

    private static func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}

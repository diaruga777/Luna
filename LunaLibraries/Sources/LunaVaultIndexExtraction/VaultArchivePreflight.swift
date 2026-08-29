import Foundation

/// Reads only the ZIP central directory. No entry is decompressed until all
/// entry-count, size and compression-ratio limits pass.
public struct VaultZIPArchivePreflight: VaultArchivePreflighting {
    public init() {}

    public func validate(_ data: Data, policy: VaultExtractionPolicy) throws {
        guard data.count >= 22, let eocd = endOfCentralDirectory(in: data) else {
            throw VaultExtractionError.unsafeArchive("missing central directory")
        }
        let entryCount = Int(try data.leUInt16(at: eocd + 10))
        let centralSize = Int(try data.leUInt32(at: eocd + 12))
        let centralOffset = Int(try data.leUInt32(at: eocd + 16))
        guard entryCount <= policy.maximumArchiveEntries else { throw VaultExtractionError.unsafeArchive("entry count") }
        guard centralOffset >= 0, centralSize >= 0, centralOffset <= data.count,
              centralSize <= data.count - centralOffset else { throw VaultExtractionError.unsafeArchive("central directory bounds") }

        var cursor = centralOffset
        var total: Int64 = 0
        for _ in 0..<entryCount {
            guard cursor <= data.count - 46, try data.leUInt32(at: cursor) == 0x02014B50 else {
                throw VaultExtractionError.unsafeArchive("invalid central entry")
            }
            let flags = try data.leUInt16(at: cursor + 8)
            guard flags & 0x0001 == 0 else { throw VaultExtractionError.protectedDocument }
            let compressed = Int64(try data.leUInt32(at: cursor + 20))
            let uncompressed = Int64(try data.leUInt32(at: cursor + 24))
            guard compressed != Int64(UInt32.max), uncompressed != Int64(UInt32.max) else {
                throw VaultExtractionError.unsafeArchive("ZIP64 unsupported")
            }
            guard uncompressed <= policy.maximumArchiveEntryBytes else { throw VaultExtractionError.unsafeArchive("entry size") }
            total = try total.addingWithoutOverflow(uncompressed)
            guard total <= policy.maximumArchiveTotalBytes else { throw VaultExtractionError.unsafeArchive("total size") }
            let ratio = Double(uncompressed) / Double(max(1, compressed))
            guard ratio <= policy.maximumArchiveCompressionRatio else { throw VaultExtractionError.unsafeArchive("compression ratio") }
            let nameLength = Int(try data.leUInt16(at: cursor + 28))
            let extraLength = Int(try data.leUInt16(at: cursor + 30))
            let commentLength = Int(try data.leUInt16(at: cursor + 32))
            let advance = 46 + nameLength + extraLength + commentLength
            guard advance >= 46, cursor <= data.count - advance else { throw VaultExtractionError.unsafeArchive("entry bounds") }
            cursor += advance
        }
        guard cursor <= centralOffset + centralSize else { throw VaultExtractionError.unsafeArchive("central directory overflow") }
    }

    private func endOfCentralDirectory(in data: Data) -> Int? {
        let minimum = max(0, data.count - 65_557)
        guard data.count >= 4 else { return nil }
        for offset in stride(from: data.count - 4, through: minimum, by: -1) {
            if (try? data.leUInt32(at: offset)) == 0x06054B50 { return offset }
        }
        return nil
    }
}

private extension Data {
    func leUInt16(at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset <= count - 2 else { throw VaultExtractionError.unsafeArchive("integer bounds") }
        return UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }
    func leUInt32(at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset <= count - 4 else { throw VaultExtractionError.unsafeArchive("integer bounds") }
        return UInt32(self[offset]) | UInt32(self[offset + 1]) << 8 |
            UInt32(self[offset + 2]) << 16 | UInt32(self[offset + 3]) << 24
    }
}

private extension Int64 {
    func addingWithoutOverflow(_ other: Int64) throws -> Int64 {
        let (value, overflow) = addingReportingOverflow(other)
        guard !overflow else { throw VaultExtractionError.unsafeArchive("size overflow") }
        return value
    }
}

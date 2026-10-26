import Foundation
import LunaVaultBEP

/// A seekable media source. Remote bytes live only in a bounded memory cache;
/// opening media never installs it in the full-file download cache.
public struct VaultMediaSource: Sendable {
    public let identity: String
    public let name: String
    public let size: Int64
    public let localURL: URL?
    public let read: @Sendable (Int64, Int) async throws -> Data

    public init(identity: String, name: String, size: Int64, localURL: URL? = nil,
                read: @escaping @Sendable (Int64, Int) async throws -> Data) {
        self.identity = identity; self.name = name; self.size = size
        self.localURL = localURL; self.read = read
    }
}

/// Verifies complete BEP blocks before exposing a requested slice. One cache
/// per player, independent of file length (including files larger than 4 GB).
public actor VaultMediaBlockReader {
    public static let cacheLimit = 32 * 1_024 * 1_024
    private let blocks: [BlockInfo]
    private let size: Int64
    private let request: @Sendable (Int, BlockInfo) async throws -> Data
    private var cache: [Int: Data] = [:]
    private var order: [Int] = []
    private var cachedBytes = 0

    public init(blocks: [BlockInfo], size: Int64,
                request: @escaping @Sendable (Int, BlockInfo) async throws -> Data) throws {
        try BlockLayout.validate(blocks, fileSize: size)
        self.blocks = blocks; self.size = size; self.request = request
    }

    public func read(offset: Int64, length: Int) async throws -> Data {
        guard offset >= 0, length > 0, length <= 1_024 * 1_024,
              offset < size, Int64(length) <= size - offset else {
            throw VaultBlockFetchError.invalidFile
        }
        let end = offset + Int64(length)
        var result = Data()
        // Binary search keeps seeks cheap even for very large block lists.
        var low = 0, high = blocks.count
        while low < high {
            let mid = (low + high) / 2
            if blocks[mid].offset + Int64(blocks[mid].size) <= offset { low = mid + 1 }
            else { high = mid }
        }
        var index = low
        while index < blocks.count, blocks[index].offset < end {
            try Task.checkCancellation()
            let block = blocks[index]
            let data: Data
            if let existing = cache[index] { data = existing }
            else {
                data = try await request(index, block)
                try Task.checkCancellation()
                guard data.count == Int(block.size), SHA256Digest.hash(data) == block.hash else {
                    throw BEPRequestError.hashMismatch
                }
                if cache[index] == nil { cache[index] = data; cachedBytes += data.count }
            }
            order.removeAll { $0 == index }; order.append(index)
            while cachedBytes > Self.cacheLimit, let first = order.first {
                order.removeFirst(); cachedBytes -= cache.removeValue(forKey: first)?.count ?? 0
            }
            let start = Int(max(offset, block.offset) - block.offset)
            let stop = Int(min(end, block.offset + Int64(block.size)) - block.offset)
            result.append(data.subdata(in: start..<stop))
            index += 1
        }
        guard result.count == length else { throw VaultBlockFetchError.invalidFile }
        return result
    }
}

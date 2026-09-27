import CryptoKit
import Foundation

/// One block of a file: its offset, length and SHA-256.
public struct BlockInfo: Hashable, Sendable, Codable {
    public var offset: Int64
    public var size: Int32
    public var hash: Data

    public init(offset: Int64, size: Int32, hash: Data) {
        self.offset = offset
        self.size = size
        self.hash = hash
    }
}

/// Block size selection and block-list hashing
/// (`claudedocs/vault-bep-reference.md` §B).
public enum BlockLayout {
    public static let minimumBlockSize = 128 * 1024
    public static let maximumBlockSize = 16 * 1024 * 1024
    public static let desiredBlocksPerFile = 2000
    public static let maximumRequestSize = 2 * maximumBlockSize

    /// SHA-256 of zero bytes: the single block of an empty file.
    public static let emptyBlockHash = SHA256Digest.hash(Data())

    /// The smallest valid power-of-two block size giving fewer than 2000 blocks.
    public static func blockSize(forFileSize size: Int64) -> Int {
        var candidate = minimumBlockSize
        while candidate < maximumBlockSize {
            if size < Int64(desiredBlocksPerFile) * Int64(candidate) { return candidate }
            candidate *= 2
        }
        return maximumBlockSize
    }

    public static func isValidBlockSize(_ size: Int) -> Bool {
        size >= minimumBlockSize && size <= maximumBlockSize && (size & (size - 1)) == 0
    }

    /// Validate peer metadata before allocating buffers or seeking in a file.
    /// Blocks must cover one contiguous file; only an empty file has a zero block.
    @discardableResult
    public static func validate(_ blocks: [BlockInfo], fileSize: Int64? = nil) throws -> Int64 {
        guard !blocks.isEmpty else { throw BEPProtocolError.invalidFileInfo("file has no blocks") }
        var end: Int64 = 0
        for block in blocks {
            guard block.offset == end, block.size >= 0,
                  block.size <= maximumBlockSize, block.hash.count == 32,
                  block.size > 0 || (blocks.count == 1 && block.hash == emptyBlockHash) else {
                throw BEPProtocolError.invalidFileInfo("invalid block layout")
            }
            let (next, overflow) = end.addingReportingOverflow(Int64(block.size))
            guard !overflow else { throw BEPProtocolError.invalidFileInfo("file is too large") }
            end = next
        }
        if let fileSize, fileSize != end {
            throw BEPProtocolError.invalidFileInfo("blocks do not match file size")
        }
        return end
    }

    /// Hashes a file into blocks. An empty file yields one zero-length block.
    public static func blocks(forFileAt url: URL, blockSize: Int? = nil) throws -> (blockSize: Int, blocks: [BlockInfo]) {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let chosen = blockSize ?? BlockLayout.blockSize(forFileSize: fileSize)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var result: [BlockInfo] = []
        var offset: Int64 = 0
        while true {
            let chunk = try handle.read(upToCount: chosen) ?? Data()
            if chunk.isEmpty {
                if offset == 0 { result.append(BlockInfo(offset: 0, size: 0, hash: emptyBlockHash)) }
                break
            }
            result.append(BlockInfo(offset: offset, size: Int32(chunk.count), hash: SHA256Digest.hash(chunk)))
            offset += Int64(chunk.count)
            if chunk.count < chosen { break }
        }
        return (chosen, result)
    }

    public static func blocks(for data: Data, blockSize: Int? = nil) -> (blockSize: Int, blocks: [BlockInfo]) {
        let chosen = blockSize ?? BlockLayout.blockSize(forFileSize: Int64(data.count))
        if data.isEmpty { return (chosen, [BlockInfo(offset: 0, size: 0, hash: emptyBlockHash)]) }
        var result: [BlockInfo] = []
        var offset = 0
        while offset < data.count {
            let end = min(offset + chosen, data.count)
            let slice = data[(data.startIndex + offset)..<(data.startIndex + end)]
            result.append(BlockInfo(offset: Int64(offset), size: Int32(end - offset), hash: SHA256Digest.hash(bytes: slice)))
            offset = end
        }
        return (chosen, result)
    }

    /// SHA-256 over the concatenated block hashes.
    public static func blocksHash(_ blocks: [BlockInfo]) -> Data {
        var hasher = SHA256()
        for block in blocks { hasher.update(data: block.hash) }
        return Data(hasher.finalize())
    }

    /// Reconstructs the block list from stored hashes plus the size rule.
    public static func blocks(fromConcatenatedHashes hashes: Data, fileSize: Int64, blockSize: Int) -> [BlockInfo] {
        guard hashes.count % 32 == 0, fileSize >= 0,
              blockSize > 0, blockSize <= maximumBlockSize else { return [] }
        let count = hashes.count / 32
        let expected = fileSize == 0 ? 1 : fileSize / Int64(blockSize) + (fileSize % Int64(blockSize) == 0 ? 0 : 1)
        guard Int64(count) == expected else { return [] }
        var result: [BlockInfo] = []
        result.reserveCapacity(count)
        var offset: Int64 = 0
        for index in 0..<count {
            let start = hashes.startIndex + index * 32
            let hash = Data(hashes[start..<(start + 32)])
            let remaining = fileSize - offset
            let size = Int32(min(Int64(blockSize), max(0, remaining)))
            result.append(BlockInfo(offset: offset, size: size, hash: hash))
            offset += Int64(size)
        }
        return result
    }

    public static func concatenatedHashes(_ blocks: [BlockInfo]) -> Data {
        var data = Data(capacity: blocks.count * 32)
        for block in blocks { data.append(block.hash) }
        return data
    }
}

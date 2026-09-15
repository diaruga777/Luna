import Foundation

/// A bounded per-file semantic index. Float16 keeps the eight-chunk ceiling
/// small enough for the phone: a 384-dimensional model is roughly 6 KB/file.
public struct VaultChunkEmbedding: Equatable, Sendable {
    public let chunk: Int
    public let values: [Float]

    public init(chunk: Int, values: [Float]) {
        self.chunk = max(0, chunk); self.values = values
    }
}

public enum VaultChunkEmbeddingCodec {
    public static let maximumChunksPerFile = 8

    public static func encode(_ embeddings: [VaultChunkEmbedding]) -> Data {
        var data = Data()
        let bounded = embeddings.sorted { $0.chunk < $1.chunk }.prefix(maximumChunksPerFile)
        for embedding in bounded {
            var chunk = UInt16(clamping: embedding.chunk).littleEndian
            var dimension = UInt16(clamping: embedding.values.count).littleEndian
            withUnsafeBytes(of: &chunk) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &dimension) { data.append(contentsOf: $0) }
            for value in embedding.values {
                var bits = Float16(value).bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
            }
        }
        return data
    }

    public static func decode(_ data: Data) -> [VaultChunkEmbedding] {
        var offset = 0
        var result: [VaultChunkEmbedding] = []
        while offset + 4 <= data.count, result.count < maximumChunksPerFile {
            let chunk = Int(UInt16(littleEndian: data.read(UInt16.self, at: offset))); offset += 2
            let dimension = Int(UInt16(littleEndian: data.read(UInt16.self, at: offset))); offset += 2
            guard dimension > 0, offset + dimension * 2 <= data.count else { return [] }
            var values: [Float] = []; values.reserveCapacity(dimension)
            for _ in 0..<dimension {
                let bits = UInt16(littleEndian: data.read(UInt16.self, at: offset)); offset += 2
                values.append(Float(Float16(bitPattern: bits)))
            }
            result.append(VaultChunkEmbedding(chunk: chunk, values: values))
        }
        return offset == data.count ? result : []
    }
}

private extension Data {
    func read<T>(_ type: T.Type, at offset: Int) -> T {
        withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
    }
}

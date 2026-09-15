import CryptoKit
import Foundation

/// SHA-256 helpers shared by device IDs, block lists and request checks.
public enum SHA256Digest {
    public static func hash(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    public static func hash<T: DataProtocol>(bytes: T) -> Data {
        Data(SHA256.hash(data: bytes))
    }

    /// Streams a file through SHA-256 in `chunkSize` reads.
    public static func hash(fileAt url: URL, chunkSize: Int = 1 << 20) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize())
    }
}

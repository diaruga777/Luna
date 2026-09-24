import Foundation

/// A rolling, memory-bounded request window. Refill each completed request
/// immediately, even when an earlier block is slow. The sink writes by offset.
public enum BEPBlockTransfer {
    public static let maximumOutstandingRequests = 8
    public static let maximumBufferedBytes = 32 * 1024 * 1024

    public static func receive(
        blocks: [BlockInfo], startingAt start: Int = 0,
        request: @escaping @Sendable (Int, BlockInfo) async throws -> Data,
        write: (Int, BlockInfo, Data) throws -> Void
    ) async throws {
        guard start < blocks.count else { return }
        let largest = max(1, blocks.map { Int($0.size) }.max() ?? 1)
        let window = max(1, min(maximumOutstandingRequests, maximumBufferedBytes / largest))
        try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            func enqueue(_ index: Int) {
                let block = blocks[index]
                group.addTask {
                    try Task.checkCancellation()
                    let bytes = try await request(index, block)
                    guard bytes.count == Int(block.size), SHA256Digest.hash(bytes) == block.hash else {
                        throw BEPRequestError.hashMismatch
                    }
                    return (index, bytes)
                }
            }
            var next = start
            for _ in 0..<min(window, blocks.count - start) {
                enqueue(next)
                next += 1
            }
            while let (index, bytes) = try await group.next() {
                try Task.checkCancellation()
                try write(index, blocks[index], bytes)
                if next < blocks.count {
                    enqueue(next)
                    next += 1
                }
            }
        }
    }
}

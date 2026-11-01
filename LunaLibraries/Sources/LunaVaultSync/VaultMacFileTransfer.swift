import Foundation
import LunaVaultBEP

/// Temporary, unindexed Mac preview. Bounded concurrent ranges hide network
/// round-trip latency while keeping memory independent of the file's size.
public enum VaultMacFileTransfer {
    public static let maximumOutstandingRequests = 8

    public static func receive(path: String, progress: VaultTransferProgressHandler? = nil,
                               request: @escaping @Sendable (VaultMacBrowseRequest) async throws -> VaultMacBrowseResponse) async throws -> URL {
        try Task.checkCancellation()
        let response = try await request(VaultMacBrowseRequest(.stat, path: path))
        guard let file = response.entries.first, !file.isDirectory, file.size >= 0,
              !file.version.isEmpty, file.path == URL(fileURLWithPath: path).standardizedFileURL.path else {
            throw VaultMacBrowseError("The Mac returned invalid file information.")
        }
        await progress?(VaultTransferProgress(completedBytes: 0, totalBytes: file.size))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VaultPreview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let capacity = try FileManager.default.attributesOfFileSystem(forPath: directory.path)[.systemFreeSize] as? NSNumber
            guard let capacity, file.size <= max(0, capacity.int64Value - 200 * 1_024 * 1_024) else {
                throw VaultMacBrowseError("There isn’t enough space on this iPhone to transfer this file. Free some space and try again.")
            }
            let destination = directory.appendingPathComponent((path as NSString).lastPathComponent)
            guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
            #endif
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            try await withThrowingTaskGroup(of: (Int64, Data).self) { group in
                var nextOffset: Int64 = 0
                var completed: Int64 = 0
                func enqueue() {
                    let offset = nextOffset
                    let length = Int(min(Int64(VaultMacBrowseProtocol.chunkSize), file.size - offset))
                    nextOffset += Int64(length)
                    group.addTask {
                        try Task.checkCancellation()
                        let chunk = try await request(VaultMacBrowseRequest(.read, path: path, offset: offset,
                            length: length, version: file.version))
                        guard let bytes = chunk.data, bytes.count == length else {
                            throw VaultMacBrowseError("The Mac returned an incomplete file.")
                        }
                        return (offset, bytes)
                    }
                }
                for _ in 0..<maximumOutstandingRequests where nextOffset < file.size { enqueue() }
                while let (offset, bytes) = try await group.next() {
                    try Task.checkCancellation()
                    try handle.seek(toOffset: UInt64(offset))
                    try handle.write(contentsOf: bytes)
                    completed += Int64(bytes.count)
                    if nextOffset < file.size { enqueue() }
                    await progress?(VaultTransferProgress(completedBytes: completed, totalBytes: file.size))
                }
            }
            try handle.synchronize()
            let final = try await request(VaultMacBrowseRequest(.stat, path: path))
            guard final.entries.first?.version == file.version else {
                throw VaultMacBrowseError("This file changed during transfer. Open it again.")
            }
            try Task.checkCancellation()
            return destination
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}

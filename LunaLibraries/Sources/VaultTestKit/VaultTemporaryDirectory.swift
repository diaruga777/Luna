import Foundation

public final class VaultTemporaryDirectory: @unchecked Sendable {
    public let url: URL
    private let fileManager: FileManager

    public init(
        name: String,
        baseURL: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) throws {
        precondition(!name.isEmpty && !name.contains("/"), "Use one safe path component")
        self.fileManager = fileManager
        let root = baseURL.appendingPathComponent("luna-vault-tests", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        url = root.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        // createDirectory is the atomic claim. A UUID collision fails instead
        // of deleting or reusing a directory owned by another concurrent test.
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
    }

    public func cleanUp() throws {
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    deinit {
        try? cleanUp()
    }
}

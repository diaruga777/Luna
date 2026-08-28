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
        url = baseURL.appendingPathComponent("luna-vault-tests-\(name)", isDirectory: true)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
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

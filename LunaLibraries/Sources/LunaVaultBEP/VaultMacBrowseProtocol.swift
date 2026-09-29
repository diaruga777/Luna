import Foundation

/// Luna-only, read-only RPC carried in BEP Request/Response on the authenticated
/// peer connection. This namespace is never advertised as a sync folder.
public enum VaultMacBrowseProtocol {
    public static let folder = "luna-mac-browser-v1"
    public static let chunkSize = 1_024 * 1_024
    public static let maximumResponseSize = 2 * 1_024 * 1_024
    public static let pageSize = 256
}

public struct VaultMacBrowseRequest: Codable, Sendable {
    public enum Operation: String, Codable, Sendable { case locations, list, stat, read }
    public var operation: Operation
    public var path: String
    public var offset: Int64
    public var length: Int
    public var version: String?
    public var showHidden: Bool

    public init(_ operation: Operation, path: String = "", offset: Int64 = 0,
                length: Int = 0, version: String? = nil, showHidden: Bool = false) {
        self.operation = operation; self.path = path; self.offset = offset
        self.length = length; self.version = version; self.showHidden = showHidden
    }
    public func encodedName() throws -> String {
        try JSONEncoder().encode(self).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
    }
    public init(encodedName: String) throws {
        guard encodedName.utf8.count <= 32_768,
              let data = Data(base64Encoded: encodedName.replacingOccurrences(of: "_", with: "/").replacingOccurrences(of: "-", with: "+")) else {
            throw VaultMacBrowseError("Invalid Mac browser request.")
        }
        self = try JSONDecoder().decode(Self.self, from: data)
    }
}

public struct VaultMacBrowseEntry: Codable, Equatable, Sendable {
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public let size: Int64
    public let modifiedAt: Date
    public let version: String
    public init(path: String, name: String, isDirectory: Bool, size: Int64, modifiedAt: Date, version: String = "") {
        self.path = path; self.name = name; self.isDirectory = isDirectory
        self.size = size; self.modifiedAt = modifiedAt; self.version = version
    }
}

public struct VaultMacBrowseResponse: Codable, Sendable {
    public var entries: [VaultMacBrowseEntry] = []
    public var nextOffset: Int64?
    public var data: Data?
    public var error: String?
    public init(entries: [VaultMacBrowseEntry] = [], nextOffset: Int64? = nil, data: Data? = nil, error: String? = nil) {
        self.entries = entries; self.nextOffset = nextOffset; self.data = data; self.error = error
    }
}
public struct VaultMacBrowseError: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

import Foundation

public struct VaultLogRecord: Equatable, Sendable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

public final class VaultRedactingLoggerSpy: @unchecked Sendable {
    private let lock = NSLock()
    private let secrets: [String]
    private var storedRecords: [VaultLogRecord] = []

    public init(secrets: [String]) {
        self.secrets = secrets.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
    }

    public func log(_ message: String) {
        var redacted = message
        for secret in secrets {
            redacted = redacted.replacingOccurrences(of: secret, with: "<redacted>")
        }
        lock.withLock {
            storedRecords.append(VaultLogRecord(message: redacted))
        }
    }

    public var records: [VaultLogRecord] {
        lock.withLock { storedRecords }
    }
}

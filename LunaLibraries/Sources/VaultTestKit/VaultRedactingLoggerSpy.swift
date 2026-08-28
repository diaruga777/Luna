import Foundation

public struct VaultLogRecord: Equatable, Sendable {
    public let message: String
    public let metadata: [String: String]

    public init(message: String, metadata: [String: String] = [:]) {
        self.message = message
        self.metadata = metadata
    }
}

public final class VaultRedactingLoggerSpy: @unchecked Sendable {
    private let lock = NSLock()
    private let secretVariants: [String]
    private var storedRecords: [VaultLogRecord] = []

    public init(secrets: [String]) {
        secretVariants = Array(Set(secrets.flatMap(Self.variants(for:))))
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
    }

    public func log(_ message: String, metadata: [String: String] = [:]) {
        let redactedMessage = redact(message)
        let redactedMetadata = metadata.mapValues(redact)
        lock.withLock {
            storedRecords.append(VaultLogRecord(message: redactedMessage, metadata: redactedMetadata))
        }
    }

    public var records: [VaultLogRecord] {
        lock.withLock { storedRecords }
    }

    private func redact(_ value: String) -> String {
        secretVariants.reduce(value) { partial, secret in
            partial.replacingOccurrences(of: secret, with: "<redacted>")
        }
    }

    private static func variants(for secret: String) -> [String] {
        guard !secret.isEmpty else { return [] }
        let data = Data(secret.utf8)
        let percentEncoded = secret.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        let hex = data.map { String(format: "%02x", $0) }.joined()
        return [secret, data.base64EncodedString(), percentEncoded, hex].compactMap { $0 }
    }
}

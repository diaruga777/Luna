import Foundation

/// One shape for every Luna Writer identity: a UUID that codes as a bare
/// string, so a SQLite TEXT column and a JSON payload hold the same bytes.
public protocol WriterIdentifier: Hashable, Codable, Sendable, CustomStringConvertible {
    var rawValue: UUID { get }
    init(_ rawValue: UUID)
}

extension WriterIdentifier {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let uuid = UUID(uuidString: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a UUID: \(text)")
        }
        self.init(uuid)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue.uuidString)
    }

    /// The form written to SQLite and read back.
    public var storageValue: String { rawValue.uuidString }

    public var description: String { rawValue.uuidString }

    /// Reads an identity back from a database column. An unreadable column
    /// gives nil, so the caller drops the row rather than inventing an id.
    public init?(storageValue: String) {
        guard let uuid = UUID(uuidString: storageValue) else { return nil }
        self.init(uuid)
    }
}

public struct DocumentID: WriterIdentifier {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct GroupID: WriterIdentifier {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct NoteID: WriterIdentifier {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct AnnotationID: WriterIdentifier {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct FilterID: WriterIdentifier {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

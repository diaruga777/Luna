import Foundation

/// Who wrote a run of text. The editor keeps one list per sheet and shows
/// the foreign runs apart from the author's own.
public struct AuthorshipSpan: Codable, Equatable, Sendable {
    public enum Source: Codable, Equatable, Sendable {
        case author
        case pasted
        case ai(model: String)

        /// The `source` column. `model` is a second column, filled for `.ai`.
        public var storageKind: String {
            switch self {
            case .author: return "author"
            case .pasted: return "pasted"
            case .ai: return "ai"
            }
        }

        public var modelIdentifier: String? {
            if case .ai(let model) = self { return model }
            return nil
        }

        /// Reads the two columns back. An unknown kind reads as `.author`,
        /// the safe default, because four schema versions may share a file.
        public init(storageKind: String, model: String?) {
            switch storageKind {
            case "pasted": self = .pasted
            case "ai": self = .ai(model: model ?? "")
            default: self = .author
            }
        }

        private enum CodingKeys: String, CodingKey { case kind, model }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let kind = try container.decode(String.self, forKey: .kind)
            let model = try container.decodeIfPresent(String.self, forKey: .model)
            self.init(storageKind: kind, model: model)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(storageKind, forKey: .kind)
            try container.encodeIfPresent(modelIdentifier, forKey: .model)
        }
    }

    public var range: TextRange
    public var source: Source
    public var createdAt: Date

    public init(range: TextRange, source: Source, createdAt: Date = Date()) {
        self.range = range
        self.source = source
        self.createdAt = createdAt
    }

    public init(range: NSRange, source: Source, createdAt: Date = Date()) {
        self.init(range: TextRange(range), source: source, createdAt: createdAt)
    }
}

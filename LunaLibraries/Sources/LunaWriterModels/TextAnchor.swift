import Foundation

/// Web-Annotation style anchor: the offsets a range had when it was saved,
/// then the quote and its context so the range can be found again after the
/// text moves. `TextAnchorResolver` in LunaWriterText reads it.
public struct TextAnchor: Codable, Equatable, Sendable {
    /// UTF-16 offsets at save time.
    public var start: Int
    public var end: Int
    /// The anchored text, capped at `exactLimit`.
    public var exact: String
    public var prefix: String
    public var suffix: String

    /// Caps `TextAnchorResolver` applies when it makes an anchor.
    public static let exactLimit = 512
    public static let contextLimit = 32

    public init(start: Int, end: Int, exact: String, prefix: String = "", suffix: String = "") {
        self.start = start
        self.end = end
        self.exact = exact
        self.prefix = prefix
        self.suffix = suffix
    }

    public var range: NSRange { NSRange(location: start, length: max(0, end - start)) }
}

/// A UTF-16 half-open range, `[start, end)`, in a form that codes.
public struct TextRange: Codable, Equatable, Sendable {
    public var start: Int
    public var end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }

    public init(_ range: NSRange) {
        self.start = range.location
        self.end = range.location + range.length
    }

    public var length: Int { max(0, end - start) }
    public var nsRange: NSRange { NSRange(location: start, length: length) }
    public var isEmpty: Bool { end <= start }
}

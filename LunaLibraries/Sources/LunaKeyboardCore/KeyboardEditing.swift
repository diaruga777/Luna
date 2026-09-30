import Foundation

/// A correction belongs to one exact cursor context and expires quickly.
/// No document text is retained beyond the current edit.
public struct KeyboardCorrection {
  public let original: String
  public let replacement: String
  public var suffix: String
  public let created: TimeInterval
  public init(original: String, replacement: String, suffix: String = "", created: TimeInterval) {
    self.original = original
    self.replacement = replacement
    self.suffix = suffix
    self.created = created
  }
  public func canUndo(before: String, now: TimeInterval) -> Bool {
    now - created < 1 && before.hasSuffix(replacement + suffix)
  }
}

public enum KeyboardEditing {
  public static func isClosingPunctuation(_ text: String) -> Bool {
    [".", ",", "!", "?", ";", ":", "…", ")", "]", "}", "”", "»"].contains(text)
  }
  public static func smartQuote(_ quote: String, before: String) -> String {
    guard quote == "\"" || quote == "'" else { return quote }
    let opening = before.isEmpty || before.last?.isWhitespace == true
      || before.last.map { "([{—–“.".contains($0) } == true
    return quote == "\"" ? (opening ? "“" : "”") : (opening ? "‘" : "’")
  }
  public static func deleteSuffix(_ before: String, count: Int) -> String {
    String(before.suffix(max(0, count)))
  }
}

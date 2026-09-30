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
  public static func protectsFromCorrection(_ word: String) -> Bool {
    if word.contains(where: { $0.isNumber }) { return true }
    var last: Character?
    var run = 0
    for c in word.lowercased() {
      run = c == last ? run + 1 : 1
      if c.isLetter && run >= 4 { return true }
      last = c
    }
    return false
  }
  public static func startsSentence(after preceding: String) -> Bool {
    if preceding.isEmpty || preceding.hasSuffix("\n") { return true }
    guard preceding.last?.isWhitespace == true else { return false }
    let trimmed = preceding.trimmingCharacters(in: .whitespaces).styleErased.lowercased()
    let abbreviations = ["e.g.", "i.e.", "etc.", "mr.", "mrs.", "ms.", "dr.", "prof.", "vs."]
    if abbreviations.contains(where: { abbreviation in
      trimmed == abbreviation || (trimmed.hasSuffix(abbreviation) && trimmed.dropLast(abbreviation.count).last?.isLetter != true)
    }) { return false }
    return trimmed.last.map { ".!?".contains($0) } == true
  }
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

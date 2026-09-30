import Foundation
import LunaStorage
import UIKit

public struct KeyboardSuggestion: Equatable {
  public enum Kind: Equatable { case word, shortcut, emoji, link, video, media }
  public let title: String
  public let text: String
  public let replacing: String
  public let kind: Kind
  public let shortcut: KeyboardShortcut?
  public let autoApply: Bool
  public init(
    title: String? = nil, text: String, replacing: String = "", kind: Kind = .word,
    shortcut: KeyboardShortcut? = nil, autoApply: Bool = false
  ) {
    self.title = title ?? text
    self.text = text
    self.replacing = replacing
    self.kind = kind
    self.shortcut = shortcut
    self.autoApply = autoApply
  }
}

public enum KeyboardRanking {
  public static func center(_ letter: Character) -> CGPoint? {
    let rows = [("qwertyuiop", 0.0), ("asdfghjkl", 0.25), ("zxcvbnm", 0.75)]
    let normalized = String(letter).folding(
      options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US"))
    guard let c = normalized.first else { return nil }
    for (y, row) in rows.enumerated() {
      if let x = Array(row.0).firstIndex(of: c) {
        return CGPoint(x: Double(x) + row.1, y: Double(y))
      }
    }
    return nil
  }
  public static func substitutionCost(_ a: Character, _ b: Character) -> Double {
    if a == b { return 0 }
    guard let p = center(a), let q = center(b) else { return 1 }
    return hypot(p.x - q.x, p.y - q.y) <= 1.3 ? 0.45 : 1.0
  }
  /// Weighted edit distance. Adjacent key substitutions win over distant ones;
  /// the text checker's probability ordering remains the tie breaker.
  public static func distance(_ typed: String, _ candidate: String) -> Double {
    let a = Array(typed.lowercased().prefix(64))
    let b = Array(candidate.lowercased().prefix(64))
    var prev = Array(0...b.count).map(Double.init)
    for (i, x) in a.enumerated() {
      var current = [Double(i + 1)] + Array(repeating: 0.0, count: b.count)
      for (j, y) in b.enumerated() {
        current[j + 1] = min(prev[j + 1] + 1, current[j] + 1, prev[j] + substitutionCost(x, y))
      }
      prev = current
    }
    return prev[b.count]
  }
  public static func rank(_ candidates: [String], for typed: String) -> [String] {
    var seen = Set<String>()
    return candidates.enumerated().filter { seen.insert($0.element.lowercased()).inserted }.sorted {
      let a = distance(typed, $0.element)
      let b = distance(typed, $1.element)
      return abs(a - b) > 0.001 ? a < b : $0.offset < $1.offset
    }.map(\.element)
  }
}

/// UIKit uses UTF-16 ranges. The bounded preceding context includes emoji and
/// composed characters without offsetting the partial-word range incorrectly.
public struct KeyboardTextContext {
  public let text: String
  public let word: String
  public let range: NSRange
  public init(before: String) {
    text = String(before.suffix(256))
    // Quotes belong to a word only when surrounded by letters (don't, l'acqua).
    // Closing quotes and punctuation must never become replacement characters.
    let chars = Array(text)
    var start = chars.count
    while start > 0 {
      let i = start - 1
      if chars[i].isLetter { start -= 1; continue }
      if (chars[i] == "'" || chars[i] == "’"), i > 0, i + 1 < chars.count,
        chars[i - 1].isLetter, chars[i + 1].isLetter { start -= 1; continue }
      break
    }
    word = String(chars[start...])
    range = NSRange(location: text.utf16.count - word.utf16.count, length: word.utf16.count)
  }
}

public final class KeyboardPrediction {
  private var checker: UITextChecker?
  public let catalog = KeyboardCatalog()
  public init() {}
  public func releaseMemory() { checker = nil }
  public func suggestions(
    before: String, preferences: KeyboardPreferences, store: KeyboardStore?,
    lexicon: [String: String] = [:]
  ) -> [KeyboardSuggestion] {
    let before = String(before.suffix(256))
    let context = KeyboardTextContext(before: before.styleErased)
    let originalWord = String(before.suffix(context.word.count))
    var result: [KeyboardSuggestion] = []
    // Longest shortcut suffix first, including multiword and punctuation keys.
    let chunks = before.split(separator: " ", omittingEmptySubsequences: false)
    for length in (1...max(1, min(5, chunks.count))).reversed() {
      let suffix = chunks.suffix(length).joined(separator: " ")
      guard !suffix.isEmpty else { continue }
      for entry in (try? store?.shortcuts(matching: suffix, limit: 8)) ?? [] {
        result.append(
          .init(
            title: entry.text, text: entry.text, replacing: suffix,
            kind: entry.kind == "text" ? .shortcut : .media, shortcut: entry,
            autoApply: entry.kind == "text"))
      }
      if !result.isEmpty { break }
    }
    let rawToken =
      before.last?.isWhitespace == true
      ? "" : String(before.split(whereSeparator: { $0.isWhitespace }).last ?? "")
    if !rawToken.isEmpty {
      result += catalog.glyphs(for: rawToken, limit: 6).map {
        .init(title: $0.text, text: $0.text, replacing: rawToken, kind: .emoji)
      }
      let (unwrapped, styler) = MarkdownStyler.removeBoundingStylers(from: rawToken)
      if let styler {
        result.append(
          .init(
            text: MarkdownStyler.style(unwrapped, with: styler), replacing: rawToken,
            kind: .shortcut, autoApply: true))
      }
    }
    guard !context.word.isEmpty else {
      return fallback(result, preferences: preferences, store: store)
    }
    if let text = lexicon[context.word.lowercased()], text != context.word {
      result.insert(
        .init(text: text, replacing: originalWord, kind: .shortcut, autoApply: true), at: 0)
    }
    let languages = [preferences.language, preferences.secondaryLanguage].compactMap { $0 }
    for language in languages {
      let learned =
        (try? store?.dictionary(language: language, prefix: context.word, limit: 6)) ?? []
      result += learned.filter { $0 != context.word }.map {
        .init(text: $0, replacing: originalWord)
      }
    }
    if preferences.enabled("autocomplete") || preferences.enabled("spellcheck") {
      if checker == nil { checker = UITextChecker() }
      if let checker {
        for language in languages {
          let code = language == "en" ? "en_US" : language.replacingOccurrences(of: "-", with: "_")
          guard
            UITextChecker.availableLanguages.contains(code)
              || UITextChecker.availableLanguages.contains(language)
          else { continue }
          let selected = UITextChecker.availableLanguages.contains(code) ? code : language
          let misspelled =
            checker.rangeOfMisspelledWord(
              in: context.text, range: context.range, startingAt: context.range.location,
              wrap: false, language: selected
            ).location != NSNotFound
          var candidates: [String] = []
          if preferences.enabled("spellcheck") && misspelled {
            candidates += Array(
              (checker.guesses(forWordRange: context.range, in: context.text, language: selected)
                ?? []).prefix(24))
          }
          if preferences.enabled("autocomplete") {
            candidates += Array(
              (checker.completions(
                forPartialWordRange: context.range, in: context.text, language: selected) ?? [])
                .prefix(24))
          }
          let personal =
            (try? store?.dictionary(language: language, prefix: context.word, limit: 1)) ?? []
          let isPersonal = personal.contains {
            $0.caseInsensitiveCompare(context.word) == .orderedSame
          }
          result += KeyboardRanking.rank(candidates, for: context.word).prefix(8).filter {
            $0 != context.word
          }.map {
            .init(
              text: $0, replacing: originalWord,
              autoApply: misspelled && !isPersonal
                && KeyboardRanking.distance(context.word, $0) < 1.1)
          }
        }
      }
    }
    var seen = Set<String>()
    result = result.filter { seen.insert($0.text).inserted }
    return fallback(Array(result.prefix(12)), preferences: preferences, store: store)
  }
  private func fallback(
    _ result: [KeyboardSuggestion], preferences: KeyboardPreferences, store: KeyboardStore?
  ) -> [KeyboardSuggestion] {
    guard result.isEmpty, preferences.enabled("lunaSuggestions"),
      let links = try? store?.recentLinks()
    else { return result }
    return links.map {
      .init(
        title: ($0.isVideo ? "▶ " : "") + $0.title, text: $0.url, kind: $0.isVideo ? .video : .link)
    }
  }
}

public struct SwipeSample: Equatable {
  public var point: CGPoint
  public var letter: Character
  public init(point: CGPoint, letter: Character) {
    self.point = point
    self.letter = letter
  }
}

/// Compares the actual finger path to each word's key-center path. Interior keys
/// passed on the way to another letter need not be characters of the word.
public enum KeyboardSwipeDecoder {
  public static func decode(
    _ samples: [SwipeSample], catalog: KeyboardCatalog, language: String,
    centers: [Character: CGPoint]
  ) -> [String] {
    guard samples.count >= 3, let start = samples.first, let end = samples.last else { return [] }
    let trace = resample(samples.map(\.point), count: 24)
    let width = max(1, abs((centers["w"]?.x ?? 1) - (centers["q"]?.x ?? 0)))
    var ranked: [(String, Double)] = []
    for (word, frequency) in catalog.swipeWords(
      language: language, first: String(start.letter), last: String(end.letter))
    {
      let points = word.folding(
        options: .diacriticInsensitive, locale: Locale(identifier: language)
      ).compactMap { centers[$0] }
      guard points.count >= 2 else { continue }
      let path = resample(points, count: 24)
      let error =
        zip(trace, path).reduce(0.0) { $0 + hypot($1.0.x - $1.1.x, $1.0.y - $1.1.y) / width } / 24
      ranked.append((word, error - log(Double(max(1, frequency))) * 0.035))
    }
    return ranked.sorted { $0.1 < $1.1 }.prefix(3).map(\.0)
  }
  static func resample(_ points: [CGPoint], count: Int) -> [CGPoint] {
    guard let first = points.first else { return [] }
    var lengths = [CGFloat(0)]
    for i in 1..<points.count {
      lengths.append(
        lengths.last! + hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y))
    }
    guard let total = lengths.last, total > 0 else { return Array(repeating: first, count: count) }
    var result: [CGPoint] = []
    var segment = 1
    for i in 0..<count {
      let target = total * CGFloat(i) / CGFloat(count - 1)
      while segment < points.count - 1 && lengths[segment] < target { segment += 1 }
      let span = max(0.001, lengths[segment] - lengths[segment - 1])
      let t = (target - lengths[segment - 1]) / span
      result.append(
        CGPoint(
          x: points[segment - 1].x + (points[segment].x - points[segment - 1].x) * t,
          y: points[segment - 1].y + (points[segment].y - points[segment - 1].y) * t))
    }
    return result
  }
}

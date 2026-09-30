import Foundation

/// A bounded arithmetic parser. Typed text is never evaluated as code.
public enum KeyboardCalculator {
  public static func suggestion(before: String) -> KeyboardSuggestion? {
    let line = String(before.split(separator: "\n", omittingEmptySubsequences: false).last ?? "")
    let allowed = Set("0123456789.+-−*/×÷()% =")
    let suffix = String(line.reversed().prefix { allowed.contains($0) }.reversed())
    // Do not calculate a numeric suffix inside an identifier, URL or ordinal.
    if suffix.count < line.count, suffix.first?.isWhitespace != true { return nil }
    let expression = suffix.trimmingCharacters(in: .whitespaces)
    guard !expression.isEmpty, expression.count <= 128 else { return nil }
    let input = expression.hasSuffix("=") ? String(expression.dropLast()) : expression
    guard input.range(of: #"[0-9.]\s+[0-9.]"#, options: .regularExpression) == nil else { return nil }
    var parser = Parser(input)
    guard let value = parser.expression(), parser.index == parser.chars.count,
      parser.operations > 0, value.isFinite, abs(value) < 1e15 else { return nil }
    let result = String(format: "%.12g", locale: Locale(identifier: "en_US_POSIX"), value == 0 ? 0 : value)
    return .init(title: "= " + result, text: result, replacing: String(suffix.drop(while: { $0.isWhitespace })), kind: .calculation,
                 accessibilityLabel: expression + " equals " + result)
  }
  private struct Parser {
    let chars: [Character]
    var index = 0
    var operations = 0
    init(_ text: String) { chars = Array(text.filter { !$0.isWhitespace }) }
    mutating func take(_ options: String) -> Character? {
      guard index < chars.count, options.contains(chars[index]) else { return nil }
      defer { index += 1 }; return chars[index]
    }
    mutating func expression() -> Double? {
      guard var value = term() else { return nil }
      while let op = take("+-−") {
        guard let rhs = term() else { return nil }; operations += 1
        value = op == "+" ? value + rhs : value - rhs
      }
      return value
    }
    mutating func term() -> Double? {
      guard var value = factor() else { return nil }
      while let op = take("*/×÷") {
        guard let rhs = factor(), !("/÷".contains(op) && rhs == 0) else { return nil }
        operations += 1; value = "*×".contains(op) ? value * rhs : value / rhs
      }
      return value
    }
    mutating func factor() -> Double? {
      let sign = take("+-−")
      var value: Double
      if take("(") != nil {
        guard let inner = expression(), take(")") != nil else { return nil }; value = inner
      } else {
        let start = index
        while index < chars.count, "0123456789.".contains(chars[index]) { index += 1 }
        guard index > start, let number = Double(String(chars[start..<index])) else { return nil }
        value = number
      }
      if take("%") != nil { value /= 100; operations += 1 }
      return sign == "-" || sign == "−" ? -value : value
    }
  }
}

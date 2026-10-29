import Foundation
import LunaStorage

public struct KeyboardPreferences {
  public var values: [String: String]
  public init(values: [String: String] = [:]) { self.values = values }
  public static let toggles: [(String, String, Bool)] = [
    ("autoCapitalize", "Auto-Capitalization", true), ("autocorrect", "Auto-Correction", true),
    ("capsLock", "Enable Caps Lock", true), ("characterPopup", "Character Preview", true),
    ("spellcheck", "Check Spelling", true),
    ("autocomplete", "Predictive Text", true), ("swipeTyping", "Slide to Type", true),
    ("haptics", "Haptic Feedback", false), ("sound", "Key Sounds", true),
    ("smartPunctuation", "Smart Quotes and Punctuation", true),
    ("rememberStyle", "Remember Text Style", true),
    ("compactSearch", "Compact Media Search", false),
    ("blankKeycaps", "Blank Keycaps", false),
    ("lunaSuggestions", "Suggest Saved Luna Links and Videos", true),
  ]
  public func enabled(_ key: String) -> Bool {
    values[key].map { $0 == "true" } ?? Self.toggles.first { $0.0 == key }?.2 ?? false
  }
  public var theme: KeyboardTheme { KeyboardTheme(rawValue: values["theme"] ?? "") ?? .system }
  public var language: String { values["language"] ?? "en" }
  public var secondaryLanguage: String? {
    guard let v = values["secondaryLanguage"], !v.isEmpty else { return nil }
    return v
  }
  public var style: TextStyle {
    enabled("rememberStyle") ? TextStyle(rawValue: values["textStyle"] ?? "") ?? .regular : .regular
  }
  /// Public settings exist even before the user changes them. Unknown stored
  /// keys are implementation details rather than automatable preferences.
  public var automationValues: [String: String] {
    var result = Dictionary(uniqueKeysWithValues: Self.toggles.map { ($0.0, String(enabled($0.0))) })
    result["theme"] = theme.rawValue
    result["language"] = language
    result["secondaryLanguage"] = secondaryLanguage ?? ""
    result["textStyle"] = (TextStyle(rawValue: values["textStyle"] ?? "") ?? .regular).rawValue
    return result
  }

  public static func validatedAutomationValue(_ value: String, for key: String) throws -> String {
    let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if toggles.contains(where: { $0.0 == key }), ["true", "false"].contains(value.lowercased()) { return value.lowercased() }
    if key == "theme", let theme = KeyboardTheme.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(value) == .orderedSame }) { return theme.rawValue }
    if key == "language" || key == "secondaryLanguage" {
      if key == "secondaryLanguage", value.isEmpty { return "" }
      if let language = languages.first(where: { $0.0.caseInsensitiveCompare(value) == .orderedSame }) { return language.0 }
    }
    if key == "textStyle", let style = TextStyle.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(value) == .orderedSame }) { return style.rawValue }
    throw PreferenceError.invalidValue
  }

  public enum PreferenceError: LocalizedError {
    case invalidValue
    public var errorDescription: String? { "Choose a supported keyboard setting and value." }
  }
  public static let languages = [
    ("en", "English"), ("es", "Español"), ("es-419", "Español (Latinoamérica)"), ("it", "Italiano"),
  ]
}

public enum NumbersAndSymbols {
  public static func altSymbols(for key: String) -> [String] {
    switch key {
    case "0": return ["°"]
    case "\"": return ["”", "“", "„", "»", "«"]
    case "&": return ["§"]
    case "$": return ["¢", "€", "£", "¥", "₩", "₽"]
    case "/": return ["\\"]
    case "-": return ["–", "—", "•"]
    case ".": return ["…"]
    case "?": return ["¿"]
    case "!": return ["¡"]
    case "'": return ["`", "‘", "’"]
    case "=": return ["≠", "≈"]
    case "%": return ["‰"]
    default: return []
    }
  }
}

public enum KeyboardResources {
  public static func url(_ name: String, extension ext: String) -> URL? {
    Bundle.module.url(forResource: name, withExtension: ext)
  }
}

public enum KeyboardTheme: String, CaseIterable {
  case system = "System", moonlight = "Moonlight", ocean = "Ocean", highContrast = "High Contrast"
}

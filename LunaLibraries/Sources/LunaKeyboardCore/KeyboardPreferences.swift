import Foundation
import LunaStorage

public struct KeyboardPreferences {
  public var values: [String: String]
  public init(values: [String: String] = [:]) { self.values = values }
  public static let toggles: [(String, String, Bool)] = [
    ("autoCapitalize", "Auto-Capitalization", true), ("autocorrect", "Auto-Correction", true),
    ("capsLock", "Enable Caps Lock", true), ("characterPopup", "Character Preview", true),
    ("periodShortcut", "Double-Space Period", true), ("spellcheck", "Check Spelling", true),
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
  public var language: String { values["language"] ?? "en" }
  public var secondaryLanguage: String? {
    guard let v = values["secondaryLanguage"], !v.isEmpty else { return nil }
    return v
  }
  public var style: TextStyle {
    enabled("rememberStyle") ? TextStyle(rawValue: values["textStyle"] ?? "") ?? .regular : .regular
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

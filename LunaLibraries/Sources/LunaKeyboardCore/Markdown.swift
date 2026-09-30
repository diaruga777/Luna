//
//  Markdown.swift
//  LunaKeyboardCore
//
//  Created by Harry Sanabria on 9/12/21.
//

import Foundation

public class MarkdownStyler {

  public enum Stylers: String {
    case quotes = "\""
    case singleQuotes = "'"
    case italic = "_"
    case bold = "*"
    case strikethrough = "-"

    public var textStyle: TextStyle? {
      switch self {
      case .bold:
        return .bold
      case .italic:
        return .italic
      case .strikethrough:
        return .strikethrough
      default:
        return nil
      }
    }
  }

  public static func styler(_ string: String) -> Stylers? {
    return Stylers(rawValue: string)
  }

  public static func style(_ text: String, with styler: Stylers) -> String {
    switch styler {
    case .quotes:
      return "\"\(text)\""
    case .singleQuotes:
      return "'\(text)'"
    case .italic:
      return TextStyle.italic.style(text)
    case .bold:
      return TextStyle.bold.style(text)
    case .strikethrough:
      return TextStyle.strikethrough.style(text)
    }
  }

  public static func removeBoundingStylers(from str: String) -> (String, Stylers?) {
    guard
      str.count > 2,
      let first = str.first,
      let last = str.last,
      first == last,
      let styler = Stylers(rawValue: String(first))
    else {
      return (str, nil)
    }
    return (
      String(
        str[str.index(after: str.startIndex)..<str.index(before: str.endIndex)]
      ),
      styler
    )
  }
}

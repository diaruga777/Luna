import Foundation
import SwiftSoup

/// Generic text decoding for the HTML capability. Semantic price/date parsing
/// lives in plugin-owned JavaScript helpers.
public enum PluginTextParsing {
    // MARK: - clean

    /// Entities decoded, tags dropped, every whitespace run — a `&nbsp;` run
    /// included — collapsed to one space, and the result trimmed.
    ///
    /// It reads the text out of an HTML parse, the same way `luna.html.text`
    /// does, so a scraped label carrying stray markup cleans up rather than
    /// showing its tags.
    public static func clean(_ raw: String) -> String {
        let stripped = (try? SwiftSoup.parse(raw))
            .flatMap { try? $0.text() } ?? raw
        return collapseWhitespace(stripped)
    }

    /// Any run of Unicode whitespace becomes one space. `Character
    /// .isWhitespace` follows the Unicode White_Space property, so a
    /// no-break space collapses like a plain one.
    public static func collapseWhitespace(_ text: String) -> String {
        var out = ""
        var pendingSpace = false
        for character in text {
            if character.isWhitespace {
                pendingSpace = !out.isEmpty
                continue
            }
            if pendingSpace { out.append(" ") }
            pendingSpace = false
            out.append(character)
        }
        return out
    }
}

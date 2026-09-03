import Foundation
import LunaWriterModels
import LunaWriterText

/// The listing fields a sheet derives from its text: title (first heading,
/// else first line, else the localized "Untitled"), snippet and counts.
enum DocumentTextSummary {
    struct Summary { let title: String; let snippet: String; let words: Int; let characters: Int }

    static func summarize(_ text: String) -> Summary {
        let string = text as NSString
        let derived = TitleDeriver.derive(from: string)
        let statistics = TextStatistics.measure(string)
        return Summary(
            title: derived?.text ?? L10nWriterStorage.untitledDocumentTitle,
            snippet: TitleDeriver.snippet(of: string, after: derived),
            words: statistics.words, characters: statistics.characters)
    }
}

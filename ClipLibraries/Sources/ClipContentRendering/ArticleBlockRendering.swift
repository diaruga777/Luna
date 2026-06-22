import Foundation

public enum ArticleBlockRendering {
    public static func plainText<S: Sequence>(blocks: S) -> String where S.Element == String {
        blocks.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}

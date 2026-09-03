//
//  PluginDraftSource.swift
//  LunaPluginKit
//

import Foundation

public enum PluginDraftSourceError: Error, Equatable, LocalizedError {
    case empty
    case mixedMarkdown

    public var errorDescription: String? {
        switch self {
        case .empty:
            return "Paste the complete JavaScript plugin first."
        case .mixedMarkdown:
            return "Paste one JavaScript file only. Remove explanations or extra code blocks."
        }
    }
}

/// Accepts the common response from a chat app without guessing among blocks.
/// Plain source is preserved byte-for-byte apart from surrounding whitespace;
/// one outer `js`/`javascript` fence is removed only when it encloses everything.
public enum PluginDraftSource {
    public static func normalize(_ input: String) throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PluginDraftSourceError.empty }
        guard trimmed.hasPrefix("```") else {
            guard !trimmed.contains("```") else { throw PluginDraftSourceError.mixedMarkdown }
            return trimmed
        }

        let lines = trimmed.components(separatedBy: .newlines)
        guard lines.count >= 3,
              let opener = lines.first?.lowercased(),
              ["```", "```js", "```javascript"].contains(opener),
              lines.last == "```" else {
            throw PluginDraftSourceError.mixedMarkdown
        }
        let body = lines.dropFirst().dropLast().joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw PluginDraftSourceError.empty }
        guard !body.contains("```") else { throw PluginDraftSourceError.mixedMarkdown }
        return body
    }
}

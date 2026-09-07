//
//  TranscriptArticleBuilder.swift
//  LunaTranscribe
//

import Foundation
import LunaModels

/// Turns timed segments into the reader article a transcript becomes
/// (`claudedocs/plans/transcription-plugins.md` §5.2). Pure.
///
/// The transcript plugins paragraph their captions by the same two rules, so a
/// captioned and a transcribed video read alike.
public enum TranscriptArticleBuilder {

    /// A silence at least this long between two segments starts a paragraph.
    public static let paragraphGap: TimeInterval = 2.0
    /// A paragraph past this many words ends at the next sentence end.
    public static let paragraphWordLimit = 90

    /// The article: the request's lead blocks, then one paragraph block per
    /// group of segments. Throws `TranscriptionError.noSpeech` when the
    /// segments hold no words at all.
    public static func make(
        segments: [TranscriptSegment], request: TranscriptionRequest
    ) throws -> ArticleContent {
        let paragraphs = self.paragraphs(from: segments)
        guard !paragraphs.isEmpty else { throw TranscriptionError.noSpeech }
        var blocks = request.leadContent?.blocks ?? []
        blocks += paragraphs.map {
            ArticleContent.Block(kind: .paragraph, text: $0, links: [])
        }
        return ArticleContent(title: request.title, author: request.author, blocks: blocks)
    }

    /// The paragraph texts alone.
    public static func paragraphs(from segments: [TranscriptSegment]) -> [String] {
        var paragraphs: [String] = []
        var current: [String] = []
        var currentWords = 0
        var previousEnd: TimeInterval?

        func flush() {
            let text = current.joined(separator: " ")
            if !text.isEmpty { paragraphs.append(text) }
            current = []
            currentWords = 0
        }

        for segment in segments {
            let text = normalized(segment.text)
            guard !text.isEmpty else { continue }
            if let previousEnd, !current.isEmpty, segment.start - previousEnd >= paragraphGap {
                flush()
            }
            current.append(text)
            currentWords += text.split(separator: " ").count
            previousEnd = max(segment.end, segment.start)
            if currentWords >= paragraphWordLimit, endsSentence(text) {
                flush()
            }
        }
        flush()
        return paragraphs
    }

    /// Trimmed, with every run of whitespace collapsed to one space.
    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
    }

    static func endsSentence(_ text: String) -> Bool {
        guard let last = text.unicodeScalars.last(where: { !CharacterSet(charactersIn: "\"')]»”’").contains($0) })
        else { return false }
        return CharacterSet(charactersIn: ".?!…").contains(last)
    }
}

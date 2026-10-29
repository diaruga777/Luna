import AVFoundation
import Foundation
import NaturalLanguage
import Speech

/// Recovery uses measured speech timing, never a words-per-minute estimate.
/// A mismatch stops the match; uncertain text is regenerated from the previous
/// confirmed sentence rather than silently omitted from the article.
enum GeminiSpeechAlignment {
    struct Span: Sendable {
        let text: String
        let start: Double
        let end: Double
    }
    struct Boundary: Codable, Equatable, Sendable {
        let textEnd: Int
        let frames: Int
    }
    typealias Recognize = (URL, String) async throws -> [Span]

    static func measure(_ url: URL, text: String, recognize: @escaping Recognize) async throws -> [Span] {
        try await withThrowingTaskGroup(of: [Span].self) { group in
            group.addTask { try await recognize(url, text) }
            group.addTask {
                try await Task.sleep(nanoseconds: 30_000_000_000)
                throw GeminiSpeechError.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private static func tokens(_ text: String) -> [(word: String, end: Int)] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        return tokenizer.tokens(for: text.startIndex..<text.endIndex).map {
            (String(text[$0]).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")),
             $0.upperBound.utf16Offset(in: text))
        }
    }

    static func boundaries(text: String, spans: [Span], frames: Int) -> [Boundary] {
        let expected = tokens(text)
        let sentences = GeminiSpeechSentences.ranges(in: text)
        var matched = 0, previousEnd = 0.0
        var result: [Boundary] = []
        for span in spans {
            guard span.start.isFinite, span.end.isFinite, span.start >= previousEnd,
                  span.end > span.start, span.end * 24_000 <= Double(frames) else { break }
            let words = tokens(span.text)
            guard !words.isEmpty else { continue }
            for word in words {
                guard matched < expected.count, expected[matched].word == word.word else { return result }
                matched += 1
            }
            previousEnd = span.end
            // Only the end of a timed run is known. Never interpolate a sentence
            // boundary inside a multiword run or trust a cut-off final word.
            let covered = expected[matched - 1].end
            for sentence in sentences {
                let end = NSMaxRange(sentence)
                let sentenceLastWord = expected.lastIndex(where: { $0.end <= end })
                guard sentenceLastWord == matched - 1, covered <= end,
                      Double(frames) / 24_000 - span.end >= 0.15 else { continue }
                let boundary = Boundary(textEnd: end, frames: Int((span.end * 24_000).rounded(.up)))
                if result.last?.textEnd != end { result.append(boundary) }
            }
        }
        return result
    }

    static func recognize(_ url: URL, text: String) async throws -> [Span] {
        guard #available(iOS 26, macOS 26, *), SpeechTranscriber.isAvailable else { return [] }
        let language = NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue
        let installed = await SpeechTranscriber.installedLocales
        guard let locale = installed.first(where: { $0.language.languageCode?.identifier == language }) else { return [] }
        // Recovery must also work offline. Do not install models, prompt for
        // microphone access, or send this audio to another cloud service.
        let module = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        let analyzer = SpeechAnalyzer(modules: [module])
        let file = try AVAudioFile(forReading: url)
        return try await withTaskCancellationHandler {
            try await collect(analyzer: analyzer, module: module, file: file)
        } onCancel: {
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    @available(iOS 26, macOS 26, *)
    private static func collect(analyzer: SpeechAnalyzer, module: SpeechTranscriber, file: AVAudioFile) async throws -> [Span] {
        try await withThrowingTaskGroup(of: [Span].self) { group in
            group.addTask {
                var spans: [Span] = []
                for try await result in module.results {
                    for run in result.text.runs {
                        guard let time = run.audioTimeRange else { continue }
                        spans.append(Span(text: String(result.text[run.range].characters), start: time.start.seconds, end: time.end.seconds))
                    }
                }
                return spans
            }
            group.addTask {
                _ = try await analyzer.analyzeSequence(from: file)
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                return []
            }
            do {
                var spans: [Span] = []
                for try await value in group { spans += value }
                return spans
            } catch {
                group.cancelAll()
                await analyzer.cancelAndFinishNow()
                throw error
            }
        }
    }
}

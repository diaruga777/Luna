import Foundation

/// Cuts a long capture into notes before any of it is routed.
///
/// A dictated or shared capture is often several unrelated thoughts. Routed
/// whole it lands on one sheet and half of it is in the wrong place, so it is
/// cut on the seams the writer already made — blank lines first, then sentence
/// boundaries inside a paragraph that is still too long.
///
/// Nothing is dropped: every chunk is a slice of the input, in order, and the
/// tail is merged into the last note rather than discarded when the sub-note
/// count would exceed the cap.
public enum NoteCaptureSplitter {
    /// Captures at or under this stay one note.
    public static let splitThreshold = 500
    /// A chunk shorter than this joins a neighbour instead of standing alone.
    public static let fragmentLength = 80
    /// Target size when a paragraph has to be packed from its sentences.
    public static let packTarget = 600
    /// Hard cap on one note.
    public static let maximumNoteLength = 4_000
    /// Hard cap on the notes one capture can become.
    public static let maximumSubNotes = 10

    public static func split(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard trimmed.count > splitThreshold else { return [trimmed] }

        var chunks: [String] = []
        for paragraph in paragraphs(of: trimmed) {
            if paragraph.count > packTarget {
                chunks.append(contentsOf: packSentences(of: paragraph))
            } else {
                chunks.append(paragraph)
            }
        }
        chunks = folded(chunks)
        chunks = chunks.flatMap(hardSplit)
        return capped(chunks)
    }

    private static func paragraphs(of text: String) -> [String] {
        text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Sentences packed up to `packTarget`. A single sentence longer than the
    /// target stands alone rather than being cut mid-thought.
    private static func packSentences(of paragraph: String) -> [String] {
        let string = paragraph as NSString
        let ranges = SentenceSegmenter()
            .sentences(in: NSRange(location: 0, length: string.length), of: paragraph)
        guard !ranges.isEmpty else { return [paragraph] }
        var chunks: [String] = []
        var current = ""
        for range in ranges {
            let sentence = string.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sentence.isEmpty else { continue }
            if !current.isEmpty, current.count + 1 + sentence.count > packTarget {
                chunks.append(current)
                current = sentence
            } else {
                current = current.isEmpty ? sentence : current + " " + sentence
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// A fragment joins the chunk before it, or the one after it when it is
    /// first — a short opening line belongs with what it introduces.
    private static func folded(_ chunks: [String]) -> [String] {
        guard chunks.count > 1 else { return chunks }
        var result: [String] = []
        var pendingLead: String?
        for chunk in chunks {
            if let lead = pendingLead {
                result.append(lead + "\n\n" + chunk)
                pendingLead = nil
                continue
            }
            if chunk.count < fragmentLength {
                if let last = result.last {
                    result[result.count - 1] = last + "\n\n" + chunk
                } else {
                    pendingLead = chunk
                }
                continue
            }
            result.append(chunk)
        }
        if let lead = pendingLead { result.append(lead) }
        return result
    }

    private static func hardSplit(_ chunk: String) -> [String] {
        guard chunk.count > maximumNoteLength else { return [chunk] }
        var remaining = Substring(chunk)
        var parts: [String] = []
        while remaining.count > maximumNoteLength {
            let limit = remaining.index(remaining.startIndex, offsetBy: maximumNoteLength)
            // Prefer the last space in the last tenth, so a cut lands between
            // words rather than inside one.
            let searchStart = remaining.index(
                remaining.startIndex, offsetBy: maximumNoteLength * 9 / 10)
            let cut = remaining[searchStart..<limit].lastIndex(where: \.isWhitespace)
                .map { remaining.index(after: $0) } ?? limit
            parts.append(String(remaining[remaining.startIndex..<cut])
                .trimmingCharacters(in: .whitespacesAndNewlines))
            remaining = remaining[cut...]
        }
        let tail = String(remaining).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { parts.append(tail) }
        return parts
    }

    /// Everything past the cap joins the last note. The cap limits how many
    /// sheets one capture can touch; it is not a licence to lose text.
    private static func capped(_ chunks: [String]) -> [String] {
        guard chunks.count > maximumSubNotes else { return chunks }
        var kept = Array(chunks.prefix(maximumSubNotes - 1))
        kept.append(chunks.dropFirst(maximumSubNotes - 1).joined(separator: "\n\n"))
        return kept
    }
}

/// The phrases that mean "put this somewhere new" rather than "file this".
///
/// Deterministic on purpose: an App Intent runs with no UI, so the writer must
/// be able to say what happens rather than discover it afterwards.
public enum ExplicitNewDocumentPhrase {
    /// Longest first, so "create a new document" is not read as "new document".
    public static let phrases = [
        "create a new document",
        "start a new document",
        "fresh concept:",
        "new document:",
        "new idea:",
        "new doc:",
    ]

    /// The title the capture asks for, or nil when it asks for nothing. An
    /// empty string means the phrase was there with no title after it.
    public static func match(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        for phrase in phrases where lowered.hasPrefix(phrase) {
            let remainder = trimmed.dropFirst(phrase.count)
            return String(remainder)
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t\n:-–—"))
        }
        return nil
    }
}

/// A sheet title made from the first words of a capture.
public enum TitleFromWords {
    public static func make(_ text: String, count: Int) -> String {
        let words = text
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ")
            .map { $0.trimmingCharacters(in: CharacterSet.alphanumerics.inverted) }
            .filter { !$0.isEmpty }
            .prefix(count)
        guard !words.isEmpty else { return L10nWriterStorage.untitledDocumentTitle }
        // A word the writer already capitalised keeps its shape, so "AI" and
        // "iPhone" survive the title case.
        return words
            .map { $0 == $0.lowercased() ? $0.prefix(1).uppercased() + $0.dropFirst() : $0 }
            .joined(separator: " ")
    }
}

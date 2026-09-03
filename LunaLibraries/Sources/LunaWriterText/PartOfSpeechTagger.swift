import Foundation
import NaturalLanguage

/// The word classes iA-style syntax colouring paints.
public enum POSClass: String, Codable, Sendable, CaseIterable {
    case noun, verb, adjective, adverb, pronoun, conjunction, preposition, determiner, other
}

public struct POSSpan: Equatable, Sendable {
    public var range: NSRange
    public var pos: POSClass

    public init(range: NSRange, pos: POSClass) {
        self.range = range
        self.pos = pos
    }
}

/// Tags one paragraph. `POSTaggingService` holds one of these; a test holds
/// a stand-in with fixed answers.
///
/// `POSTaggingService` calls `tags(ofParagraph:)` from its own work queue, so
/// a conforming type must be safe to call from a thread other than main.
public protocol ParagraphTagging: AnyObject {
    /// Tags a standalone paragraph. The ranges start at zero.
    func tags(ofParagraph body: String) -> [POSSpan]
}

/// Tags one paragraph with `NLTagger`. A language whose model carries no
/// lexical classes gets no tags at all, so colouring simply stays off there
/// rather than painting the wrong words.
public final class PartOfSpeechTagger: ParagraphTagging {
    private let tagger = NLTagger(tagSchemes: [.lexicalClass])
    private let options: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .omitOther, .joinNames]
    /// Set once this instance's document proves unsupported, so every later
    /// paragraph skips language recognition rather than repeating the answer.
    private var documentUnsupported = false

    public init() {}

    /// Tags a standalone paragraph. The ranges start at zero, which is what
    /// the tagging service caches.
    public func tags(ofParagraph body: String) -> [POSSpan] {
        guard !body.isEmpty, !documentUnsupported else { return [] }
        guard PartOfSpeechTagger.supportsTagging(body) else {
            documentUnsupported = true
            return []
        }
        tagger.string = body
        var out: [POSSpan] = []
        tagger.enumerateTags(in: body.startIndex..<body.endIndex, unit: .word, scheme: .lexicalClass, options: options) { tag, range in
            guard let tag else { return true }
            let nsRange = NSRange(range, in: body)
            if nsRange.length > 0 { out.append(POSSpan(range: nsRange, pos: PartOfSpeechTagger.map(tag))) }
            return true
        }
        return out
    }

    /// True when this text's language carries lexical classes on this
    /// device. False means colouring stays off: an iOS simulator, and any
    /// language without the model, tag every word as "other".
    public static func supportsTagging(_ body: String) -> Bool {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(body)
        guard let language = recognizer.dominantLanguage else { return false }
        return cachedSchemeAvailability(for: language)
    }

    /// Scheme availability by language, process-wide: the recognizer still
    /// runs on every call (the text differs), but the scheme lookup for a
    /// language already seen is a dictionary read.
    private static let availabilityLock = NSLock()
    private static var availabilityCache: [NLLanguage: Bool] = [:]

    private static func cachedSchemeAvailability(for language: NLLanguage) -> Bool {
        availabilityLock.lock()
        if let cached = availabilityCache[language] {
            availabilityLock.unlock()
            return cached
        }
        availabilityLock.unlock()
        let supported = NLTagger.availableTagSchemes(for: .word, language: language).contains(.lexicalClass)
        availabilityLock.lock()
        availabilityCache[language] = supported
        availabilityLock.unlock()
        return supported
    }

    static func map(_ tag: NLTag) -> POSClass {
        switch tag {
        case .noun, .personalName, .placeName, .organizationName: return .noun
        case .verb: return .verb
        case .adjective: return .adjective
        case .adverb: return .adverb
        case .pronoun: return .pronoun
        case .conjunction: return .conjunction
        case .preposition: return .preposition
        case .determiner: return .determiner
        default: return .other
        }
    }
}

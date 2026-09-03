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

    public init() {}

    public func tags(in paragraph: NSRange, of text: NSString) -> [POSSpan] {
        guard paragraph.length > 0, NSMaxRange(paragraph) <= text.length else { return [] }
        return tags(ofParagraph: text.substring(with: paragraph)).map {
            POSSpan(range: NSRange(location: $0.range.location + paragraph.location, length: $0.range.length), pos: $0.pos)
        }
    }

    public func tags(in paragraph: NSRange, of text: String) -> [POSSpan] {
        tags(in: paragraph, of: text as NSString)
    }

    /// Tags a standalone paragraph. The ranges start at zero, which is what
    /// the tagging service caches.
    public func tags(ofParagraph body: String) -> [POSSpan] {
        guard !body.isEmpty, PartOfSpeechTagger.supportsTagging(body) else { return [] }
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
        return NLTagger.availableTagSchemes(for: .word, language: language).contains(.lexicalClass)
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

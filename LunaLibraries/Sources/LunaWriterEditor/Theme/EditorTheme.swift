//
//  EditorTheme.swift
//  LunaWriterEditor
//

import UIKit
import LunaDesignSystem
import LunaWriterModels
import LunaWriterText

/// Every colour the editor draws with.
///
/// All of them are dynamic over `LunaSkyTrait`, so a view that caches a
/// resolved colour must `registerForTraitChanges([LunaSkyTrait.self])` — a
/// style change never arrives again (see `claudedocs/visual-effects.md`).
public enum EditorTheme {

    // MARK: - Text

    /// Body text.
    public static let ink = LunaColors.primaryText

    /// Markup characters: the `#`, the `*`, the fence. Present but quiet.
    public static let markup = LunaColors.quaternaryText

    /// Everything outside the focus range.
    public static let dimmed = UIColor { traits in
        LunaColors.primaryText.resolvedColor(with: traits).withAlphaComponent(traits.lunaSky == .night ? 0.26 : 0.30)
    }

    /// iA blue, the Writer surface's own identity colour.
    public static let caret = LunaSurfacePalette.baseColor(for: .writer)

    public static let selection = UIColor { traits in
        caret.resolvedColor(with: traits).withAlphaComponent(0.30)
    }

    public static let codeForeground = UIColor { traits in
        LunaColors.secondaryText.resolvedColor(with: traits)
    }

    public static let codeBackground = UIColor { traits in
        LunaColors.tertiaryBackground.resolvedColor(with: traits).withAlphaComponent(0.9)
    }

    public static let quoteBar = LunaColors.tertiaryText

    // MARK: - Syntax

    /// The part-of-speech colours. Classes the writer does not ask about stay
    /// ink, so a coloured document still reads as text.
    public static func syntaxColour(for pos: POSClass) -> UIColor? {
        switch pos {
        case .noun: return syntaxNoun
        case .verb: return syntaxVerb
        case .adjective: return syntaxAdjective
        case .adverb: return syntaxAdverb
        case .conjunction: return syntaxConjunction
        case .pronoun, .preposition, .determiner, .other: return nil
        }
    }

    public static let syntaxNoun = lifted(0x4F8FD6)
    public static let syntaxVerb = lifted(0xD6604A)
    public static let syntaxAdjective = lifted(0x3F9D59)
    public static let syntaxAdverb = lifted(0x8A4FD6)
    public static let syntaxConjunction = lifted(0xC79A2E)

    // MARK: - Authorship

    /// Nothing tints the writer's own text; a tint means the words came from
    /// somewhere else.
    public static func authorshipColour(for source: AuthorshipSpan.Source) -> UIColor? {
        switch source {
        case .author: return nil
        case .pasted: return authorshipPasted
        case .ai: return authorshipAI
        }
    }

    public static let authorshipPasted = LunaColors.secondaryText

    public static let authorshipAI = UIColor { traits in
        LunaSurfacePalette.blended(
            LunaSurfacePalette.baseColor(for: .writer).resolvedColor(with: traits),
            toward: .white, amount: traits.lunaSky == .night ? 0.18 : 0.12)
    }

    // MARK: - Annotations

    /// gazeread's five, lifted for the night sky.
    public static func annotationColour(for kind: Annotation.Kind) -> UIColor {
        switch kind {
        case .needsWork: return annotationNeedsWork
        case .expand: return annotationExpand
        case .cut: return annotationCut
        case .keep: return annotationKeep
        case .comment: return annotationComment
        }
    }

    public static let annotationNeedsWork = lifted(0x8A4FD6)
    public static let annotationExpand = lifted(0x2F7FD6)
    public static let annotationCut = lifted(0xD64A3C)
    public static let annotationKeep = lifted(0x3F9D59)
    public static let annotationComment = lifted(0xE0B400)

    /// The wash under a comment's words.
    public static func annotationWash(for kind: Annotation.Kind) -> UIColor {
        UIColor { traits in
            annotationColour(for: kind).resolvedColor(with: traits).withAlphaComponent(0.16)
        }
    }

    // MARK: - Reading

    /// The band ReadAlong paints behind the sentence being read.
    public static let readingBand = UIColor { traits in
        LunaSurfacePalette.baseColor(for: .writer).resolvedColor(with: traits)
            .withAlphaComponent(traits.lunaSky == .night ? 0.18 : 0.14)
    }

    // MARK: - Lifting

    /// A hex authored for paper, raised toward white so it holds on a
    /// near-black sky. The predawn sky is already one notch up, so it needs
    /// less of the lift than true black does.
    static func lifted(_ hex: UInt32) -> UIColor {
        UIColor { traits in
            LunaSurfacePalette.blended(
                colour(hex), toward: .white, amount: traits.lunaSky == .night ? 0.10 : 0.06)
        }
    }

    static func colour(_ hex: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }
}

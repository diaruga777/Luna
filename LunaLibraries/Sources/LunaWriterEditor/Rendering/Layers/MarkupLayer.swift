//
//  MarkupLayer.swift
//  LunaWriterEditor
//

import UIKit
import LunaWriterText

/// Greys the Markdown characters the caret revealed and tints code, so the
/// markup stays readable without competing with the prose.
///
/// A marker outside the reveal range lays out zero points wide (the styler
/// collapses it), so it gets no colour: the grey belongs to the paragraph
/// being edited.
public final class MarkupLayer: RenderingAttributeLayer {

    public let identifier: LayerID = .markup
    private let storage: MarkdownTextStorage

    public init(storage: MarkdownTextStorage) {
        self.storage = storage
    }

    public func contributions(in range: NSRange, text: NSString) -> [RangedAttributes] {
        let model = storage.model
        let reveal = storage.revealRange
        var out: [RangedAttributes] = []
        for scan in model.blocksAndInlines(in: range) {
            let revealed = LayoutAttributeStyler.reveals(reveal, scan.block.lineRange)
            let hidden = revealed ? [] : LayoutAttributeStyler.hiddenMarkers(of: scan)
            for markup in scan.block.markupRanges where !covered(markup, by: hidden) {
                out.append(RangedAttributes(range: markup, attributes: [.foregroundColor: EditorTheme.markup]))
            }
            switch scan.block.kind {
            case .fencedCode, .fenceDelimiter:
                out.append(RangedAttributes(
                    range: scan.block.lineRange,
                    attributes: [
                        .foregroundColor: EditorTheme.codeForeground,
                        .backgroundColor: EditorTheme.codeBackground,
                    ]))
            default:
                break
            }
            for inline in scan.inlines {
                for markup in inline.markupRanges where !covered(markup, by: hidden) {
                    out.append(RangedAttributes(range: markup, attributes: [.foregroundColor: EditorTheme.markup]))
                }
                switch inline.kind {
                case .code:
                    out.append(RangedAttributes(
                        range: inline.contentRange,
                        attributes: [
                            .foregroundColor: EditorTheme.codeForeground,
                            .backgroundColor: EditorTheme.codeBackground,
                        ]))
                case .link, .image, .autolink:
                    out.append(RangedAttributes(
                        range: inline.contentRange,
                        attributes: [.foregroundColor: EditorTheme.caret]))
                default:
                    break
                }
            }
        }
        return out
    }

    private func covered(_ markup: NSRange, by hidden: [NSRange]) -> Bool {
        hidden.contains { NSIntersectionRange($0, markup).length > 0 }
    }
}

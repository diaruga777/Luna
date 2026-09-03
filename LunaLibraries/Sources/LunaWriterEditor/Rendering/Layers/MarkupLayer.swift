//
//  MarkupLayer.swift
//  LunaWriterEditor
//

import UIKit
import LunaWriterText

/// Greys the Markdown characters and tints code, so the markup stays readable
/// without competing with the prose.
public final class MarkupLayer: RenderingAttributeLayer {

    public let identifier: LayerID = .markup
    private let model: MarkdownDocumentModel

    public init(model: MarkdownDocumentModel) {
        self.model = model
    }

    public func contributions(in range: NSRange, text: NSString) -> [RangedAttributes] {
        var out: [RangedAttributes] = []
        for scan in model.blocksAndInlines(in: range) {
            for markup in scan.block.markupRanges {
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
                for markup in inline.markupRanges {
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
}

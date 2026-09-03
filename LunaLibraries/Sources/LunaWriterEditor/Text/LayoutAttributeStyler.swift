//
//  LayoutAttributeStyler.swift
//  LunaWriterEditor
//

import UIKit
import LunaDesignSystem
import LunaWriterText

/// Writes the attributes that change geometry: the font of each block and
/// inline run, and the paragraph style that indents it.
///
/// Colour is never written here. A colour that lived in the storage would be
/// re-applied on every edit and would fight the rendering layers, which is why
/// the two channels are split (writer-app.md §6.1).
public struct LayoutAttributeStyler: Equatable {

    public var metrics: EditorMetrics
    public var font: ReaderFont

    public init(metrics: EditorMetrics = EditorMetrics(), font: ReaderFont = .system) {
        self.metrics = metrics
        self.font = font
    }

    public var bodyFont: UIFont { font.font(size: metrics.bodySize, weight: .regular) }

    public var codeFont: UIFont {
        UIFont.monospacedSystemFont(ofSize: metrics.codeSize, weight: .regular)
    }

    public var bodyAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .paragraphStyle: paragraphStyle(for: .paragraph)]
    }

    /// Styles every line the range touches. The caller passes the range the
    /// document model rescanned, so a fence that changed the lines under it
    /// restyles them too.
    public func apply(_ model: MarkdownDocumentModel, to text: NSMutableAttributedString, in range: NSRange) {
        let length = text.length
        guard length > 0 else { return }
        let clamped = NSRange(
            location: min(max(0, range.location), length),
            length: min(range.length, max(0, length - min(max(0, range.location), length))))
        let firstLine = model.lineIndex(at: clamped.location)
        let lastLine = model.lineIndex(at: max(clamped.location, NSMaxRange(clamped) - 1))
        guard firstLine <= lastLine else { return }

        for index in firstLine...lastLine {
            let scan = model.lineScan(at: index)
            let lineRange = model.lineRange(at: index)
            guard lineRange.length > 0, NSMaxRange(lineRange) <= length else { continue }
            let base = blockFont(for: scan.block.kind)
            text.setAttributes(
                [.font: base, .paragraphStyle: paragraphStyle(for: scan.block.kind)],
                range: lineRange)
            for inline in scan.inlines {
                applyInline(inline, to: text, base: base, limit: length)
            }
        }
    }

    private func applyInline(
        _ inline: InlineToken, to text: NSMutableAttributedString, base: UIFont, limit: Int
    ) {
        let content = inline.contentRange
        guard content.length > 0, NSMaxRange(content) <= limit else { return }
        switch inline.kind {
        case .code:
            text.addAttribute(.font, value: codeFont, range: content)
        case .strong:
            addTraits(.traitBold, to: text, in: content, base: base)
        case .emphasis:
            addTraits(.traitItalic, to: text, in: content, base: base)
        case .strikethrough, .highlight, .link, .image, .autolink, .footnoteReference, .hardBreak:
            break
        }
    }

    /// Adds a face trait to whatever font the run already carries, so a bold
    /// run inside an italic one keeps both.
    private func addTraits(
        _ traits: UIFontDescriptor.SymbolicTraits, to text: NSMutableAttributedString,
        in range: NSRange, base: UIFont
    ) {
        text.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
            let current = (value as? UIFont) ?? base
            var symbolic = current.fontDescriptor.symbolicTraits
            symbolic.insert(traits)
            guard let descriptor = current.fontDescriptor.withSymbolicTraits(symbolic) else { return }
            text.addAttribute(.font, value: UIFont(descriptor: descriptor, size: current.pointSize), range: subrange)
        }
    }

    public func blockFont(for kind: BlockKind) -> UIFont {
        switch kind {
        case .heading(let level):
            return font.font(size: metrics.headingSize(forLevel: level), weight: .bold)
        case .fencedCode, .fenceDelimiter:
            return codeFont
        case .paragraph, .blockquote, .listItem, .thematicBreak, .tableRow, .tableDelimiter,
             .footnoteDefinition, .blank:
            return bodyFont
        }
    }

    public func paragraphStyle(for kind: BlockKind) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = metrics.lineHeightMultiple
        style.paragraphSpacing = metrics.paragraphSpacing
        switch kind {
        case .heading(let level):
            style.paragraphSpacingBefore = metrics.headingSpacingBefore(level: level)
            style.paragraphSpacing = (metrics.paragraphSpacing * 0.5).rounded()
        case .blockquote(let depth):
            let indent = metrics.quoteIndent * CGFloat(max(1, depth))
            style.firstLineHeadIndent = indent
            style.headIndent = indent
            style.paragraphSpacing = 0
        case .listItem(_, let indent, _):
            let step = metrics.listIndent
            style.firstLineHeadIndent = step * CGFloat(indent)
            style.headIndent = step * CGFloat(indent + 1)
            style.paragraphSpacing = 0
        case .fencedCode, .fenceDelimiter:
            style.firstLineHeadIndent = metrics.codeIndent
            style.headIndent = metrics.codeIndent
            style.lineHeightMultiple = 1.2
            style.paragraphSpacing = 0
        case .paragraph, .thematicBreak, .tableRow, .tableDelimiter, .footnoteDefinition, .blank:
            break
        }
        return style
    }
}

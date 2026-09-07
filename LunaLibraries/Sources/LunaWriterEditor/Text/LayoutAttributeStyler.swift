//
//  LayoutAttributeStyler.swift
//  LunaWriterEditor
//
//  `hiddenMarkerAttributes` ports the hidden-run recipe from
//  nodes-app/swift-markdown-engine (Apache 2.0) — see THIRD_PARTY_NOTICES.md.
//

import UIKit
import LunaDesignSystem
import LunaWriterText

/// Writes the attributes that change geometry: the font of each block and
/// inline run, and the paragraph style that indents it. It also writes the
/// one colour the storage must carry, `EditorTheme.ink`: TextKit draws a run
/// with no foreground colour in black, and the rendering layers only paint
/// the ranges they have something to say about, so body text needs its ink
/// in the storage. Every other colour is a rendering attribute
/// (writer-app.md §6.1).
///
/// It also hides Markdown markers. A marker outside the reveal range keeps
/// its characters but gets a 0.1 pt font and a per-character kern that
/// cancels that font's own width, so the run lays out zero points wide and
/// every character offset in the document still maps one to one. The reveal
/// range belongs to `MarkdownTextStorage` and arrives as a call argument, so
/// two stylers with the same metrics and font stay equal.
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

    /// The size a hidden marker run is set to. Small enough that its width
    /// rounds away, large enough that CoreText still lays the run out.
    public static let hiddenMarkerSize: CGFloat = 0.1

    public var hiddenMarkerFont: UIFont {
        font.font(size: Self.hiddenMarkerSize, weight: .regular)
    }

    public var bodyAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .paragraphStyle: paragraphStyle(for: .paragraph), .foregroundColor: EditorTheme.ink]
    }

    /// Styles every line the range touches. The caller passes the range the
    /// document model rescanned, so a fence that changed the lines under it
    /// restyles them too. `revealing` is the caret's paragraph, whose markers
    /// stay at full size.
    public func apply(
        _ model: MarkdownDocumentModel, to text: NSMutableAttributedString, in range: NSRange,
        revealing reveal: NSRange? = nil
    ) {
        let length = text.length
        guard length > 0 else { return }
        let clamped = NSRange(
            location: min(max(0, range.location), length),
            length: min(range.length, max(0, length - min(max(0, range.location), length))))
        let firstLine = model.lineIndex(at: clamped.location)
        let lastLine = model.lineIndex(at: max(clamped.location, NSMaxRange(clamped) - 1))
        guard firstLine <= lastLine else { return }

        let nsText = text.mutableString
        for index in firstLine...lastLine {
            let scan = model.lineScan(at: index)
            let lineRange = model.lineRange(at: index)
            guard lineRange.length > 0, NSMaxRange(lineRange) <= length else { continue }
            let revealed = Self.reveals(reveal, lineRange)
            let base = blockFont(for: scan.block.kind)
            let markerWidth = revealed ? Self.blockMarkerWidth(of: scan.block, in: nsText, font: base) : 0
            text.setAttributes(
                [.font: base,
                 .paragraphStyle: paragraphStyle(
                    for: scan.block.kind, hidingMarkers: !revealed, revealedMarkerWidth: markerWidth),
                 .foregroundColor: EditorTheme.ink],
                range: lineRange)
            for inline in scan.inlines {
                applyInline(inline, to: text, base: base, limit: length)
            }
            guard !revealed else { continue }
            for marker in Self.hiddenMarkers(of: scan) {
                hide(marker, in: text, nsText: nsText, limit: length)
            }
        }
    }

    /// True when the reveal range touches the line. A caret inside the line,
    /// including the position before its terminator, counts.
    public static func reveals(_ reveal: NSRange?, _ line: NSRange) -> Bool {
        guard let reveal else { return false }
        if NSIntersectionRange(reveal, line).length > 0 { return true }
        return reveal.length == 0 && NSLocationInRange(reveal.location, line)
    }

    // MARK: - Hidden markers

    /// Every marker range on the line that collapses while the caret is
    /// elsewhere.
    ///
    /// A fence delimiter and the lines inside a fence keep their characters:
    /// the backticks are the code. An ordered list item keeps its `1.`,
    /// which nothing paints in its place. A footnote reference is its own
    /// markup — hiding `[^1]` would leave nothing at all.
    public static func hiddenMarkers(of scan: LineScan) -> [NSRange] {
        var out = hiddenBlockMarkers(of: scan.block)
        for inline in scan.inlines {
            if case .footnoteReference = inline.kind { continue }
            out += inline.markupRanges
        }
        return out.filter { $0.length > 0 }
    }

    static func hiddenBlockMarkers(of block: BlockToken) -> [NSRange] {
        switch block.kind {
        case .heading:
            // The scanner claims the hashes; the space between them and the
            // text belongs to neither the markup nor the content, and a
            // heading that kept it would start one space in.
            var out = block.markupRanges
            if let lead = out.first, block.contentRange.location > NSMaxRange(lead) {
                out[0] = NSRange(
                    location: lead.location, length: block.contentRange.location - lead.location)
            }
            return out
        case .blockquote, .thematicBreak:
            return block.markupRanges
        case .listItem(let ordered, _, _):
            return ordered ? [] : block.markupRanges
        case .paragraph, .fencedCode, .fenceDelimiter, .tableRow, .tableDelimiter,
             .footnoteDefinition, .blank:
            return []
        }
    }

    private func hide(
        _ range: NSRange, in text: NSMutableAttributedString, nsText: NSMutableString, limit: Int
    ) {
        guard range.length > 0, NSMaxRange(range) <= limit else { return }
        text.addAttributes(
            hiddenMarkerAttributes(for: nsText.substring(with: range)), range: range)
    }

    /// The attributes that collapse a run to zero width.
    ///
    /// `.kern` applies to EVERY character in the range, so a run of `n`
    /// characters lays out `width + n * kern` wide. The kern is therefore one
    /// character's share of the run's own width at the hidden size, not the
    /// whole width: feeding it the whole width makes a long run `(n - 1)`
    /// widths too negative, which poisons the container's usage bounds.
    public func hiddenMarkerAttributes(for run: String) -> [NSAttributedString.Key: Any] {
        let hidden = hiddenMarkerFont
        return [
            .font: hidden,
            .kern: NSNumber(value: Double(-Self.hiddenRunKern(run, font: hidden))),
            .foregroundColor: UIColor.clear,
        ]
    }

    /// One character's share of the run's width, for `.kern`.
    public static func hiddenRunKern(_ run: String, font: UIFont) -> CGFloat {
        let count = max(1, (run as NSString).length)
        let width = (run as NSString).size(withAttributes: [.font: font]).width
        return width / CGFloat(count)
    }

    // MARK: - Inline faces

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

    /// The width the revealed block marker (`- `, `- [ ] `, `> `) takes at
    /// the block font, so a revealed line can hang it in the gutter and keep
    /// its text where the collapsed line had it.
    static func blockMarkerWidth(of block: BlockToken, in text: NSString, font: UIFont) -> CGFloat {
        hiddenBlockMarkers(of: block).reduce(0) { width, range in
            guard range.length > 0, NSMaxRange(range) <= text.length else { return width }
            return width + text.substring(with: range).size(withAttributes: [.font: font]).width
        }
    }

    /// `revealedMarkerWidth` is the block marker's width when the line is
    /// revealed; the first line starts that much before the text column, so
    /// revealing a list item or a quote never moves its words.
    public func paragraphStyle(
        for kind: BlockKind, hidingMarkers hidden: Bool = false, revealedMarkerWidth: CGFloat = 0
    ) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = metrics.lineHeightMultiple
        style.paragraphSpacing = metrics.paragraphSpacing
        switch kind {
        case .heading(let level):
            style.paragraphSpacingBefore = metrics.headingSpacingBefore(level: level)
            style.paragraphSpacing = (metrics.paragraphSpacing * 0.5).rounded()
            style.minimumLineHeight = metrics.collapsedLineHeight
        case .blockquote(let depth):
            let indent = metrics.quoteIndent * CGFloat(max(1, depth))
            style.firstLineHeadIndent = max(0, indent - revealedMarkerWidth)
            style.headIndent = indent
            style.paragraphSpacing = 0
            style.minimumLineHeight = metrics.collapsedLineHeight
        case .listItem(let ordered, let indent, _):
            let step = metrics.listIndent
            // A hidden marker takes no width, so the first line starts where
            // the wrapped lines hang and the fragment paints the bullet or
            // the checkbox in the gutter that leaves. A revealed marker hangs
            // in that same gutter.
            let textColumn = step * CGFloat(indent + 1)
            if ordered {
                style.firstLineHeadIndent = step * CGFloat(indent)
            } else {
                style.firstLineHeadIndent = hidden ? textColumn : max(step * CGFloat(indent), textColumn - revealedMarkerWidth)
            }
            style.headIndent = textColumn
            style.paragraphSpacing = 0
            style.minimumLineHeight = metrics.collapsedLineHeight
        case .fencedCode, .fenceDelimiter:
            style.firstLineHeadIndent = metrics.codeIndent
            style.headIndent = metrics.codeIndent
            style.lineHeightMultiple = 1.2
            style.paragraphSpacing = 0
        case .thematicBreak:
            // Every character on the line collapses, so the line box needs a
            // floor of its own for the rule to be drawn in.
            style.minimumLineHeight = metrics.collapsedLineHeight
        case .paragraph, .tableRow, .tableDelimiter, .footnoteDefinition, .blank:
            break
        }
        return style
    }
}

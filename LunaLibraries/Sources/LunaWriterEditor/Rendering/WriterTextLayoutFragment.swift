//
//  WriterTextLayoutFragment.swift
//  LunaWriterEditor
//
//  The decoration set and the gutter drawing are ported from
//  nodes-app/swift-markdown-engine (Apache 2.0) — see THIRD_PARTY_NOTICES.md.
//

import UIKit
import LunaWriterText

/// What a decorated paragraph paints in place of its collapsed markers.
enum WriterBlockDecoration: Equatable {
    case bullet
    case task(TaskState)
    case quote(depth: Int)
    case rule
}

/// Builds the editor's layout fragments and answers where a task item's
/// painted checkbox is.
///
/// A paragraph whose markers collapse needs something drawn in the gutter
/// they left. Fonts and paragraph styles stay attributes in the storage;
/// only the glyphs that have no character behind them are painted here.
public final class WriterLayoutFragmentProvider: NSObject, NSTextLayoutManagerDelegate {

    private weak var storage: MarkdownTextStorage?
    public var metrics: EditorMetrics

    public init(storage: MarkdownTextStorage, metrics: EditorMetrics) {
        self.storage = storage
        self.metrics = metrics
        super.init()
    }

    /// The decoration the block at `offset` paints, or nil when it paints
    /// nothing. An ordered list item keeps its own `1.`, so it has none.
    func decoration(at offset: Int) -> WriterBlockDecoration? {
        guard let storage, storage.length > 0 else { return nil }
        let model = storage.model
        let index = model.lineIndex(at: min(offset, max(0, storage.length - 1)))
        switch model.blockKind(at: index) {
        case .listItem(let ordered, _, let task):
            guard !ordered else { return nil }
            guard let task else { return .bullet }
            return .task(task)
        case .blockquote(let depth):
            return .quote(depth: max(1, depth))
        case .thematicBreak:
            return .rule
        default:
            return nil
        }
    }

    /// True while the caret is on the block at `offset`, which is when the
    /// raw markers are what the writer sees and edits.
    func isRevealed(at offset: Int) -> Bool {
        guard let storage, storage.length > 0 else { return false }
        let model = storage.model
        let line = model.lineRange(at: model.lineIndex(at: min(offset, max(0, storage.length - 1))))
        return LayoutAttributeStyler.reveals(storage.revealRange, line)
    }

    /// True when a tap at `containerX` — measured from the text container's
    /// left edge — landed on the checkbox painted for the task item at
    /// `offset`.
    public func hitsTaskMarker(at offset: Int, containerX: CGFloat) -> Bool {
        guard case .task = decoration(at: offset), !isRevealed(at: offset) else { return false }
        guard let storage else { return false }
        let model = storage.model
        let index = model.lineIndex(at: min(offset, max(0, storage.length - 1)))
        guard case .listItem(_, let indent, _) = model.blockKind(at: index) else { return false }
        let textX = metrics.listIndent * CGFloat(indent + 1)
        return containerX <= textX && containerX >= textX - metrics.markerSlot - 8
    }

    // MARK: - NSTextLayoutManagerDelegate

    public func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        textLayoutFragmentFor location: NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        let plain = NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
        guard let contentManager = textLayoutManager.textContentManager else { return plain }
        let offset = contentManager.offset(from: contentManager.documentRange.location, to: location)
        guard decoration(at: offset) != nil else { return plain }
        let fragment = WriterTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
        fragment.provider = self
        return fragment
    }
}

/// Paints what a collapsed marker left behind: a bullet, a checkbox, one bar
/// per blockquote level, a rule for a thematic break.
///
/// Everything is read live at draw time, so a caret move that reveals the
/// paragraph takes the decoration down without rebuilding the fragment.
final class WriterTextLayoutFragment: NSTextLayoutFragment {

    weak var provider: WriterLayoutFragmentProvider?

    private static var symbols: [String: UIImage] = [:]

    /// The gutter and the full column sit outside the glyphs TextKit would
    /// otherwise reserve, so it would clip them.
    override var renderingSurfaceBounds: CGRect {
        var bounds = super.renderingSurfaceBounds
        let containerWidth = textLayoutManager?.textContainer?.size.width ?? bounds.width
        bounds.origin.x = min(bounds.origin.x, -layoutFragmentFrame.origin.x)
        bounds.size.width = max(bounds.size.width, containerWidth)
        return bounds
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        super.draw(at: point, in: context)
        guard let provider, let offset = documentOffset else { return }
        guard let decoration = provider.decoration(at: offset), !provider.isRevealed(at: offset) else { return }
        let metrics = provider.metrics
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        switch decoration {
        case .bullet:
            drawMarkerGlyph("\u{2022}", at: point, metrics: metrics)
        case .task(let state):
            drawCheckbox(state, at: point, metrics: metrics)
        case .quote(let depth):
            drawQuoteBars(depth: depth, at: point, metrics: metrics)
        case .rule:
            drawRule(at: point, metrics: metrics)
        }
    }

    // MARK: - Geometry

    private var documentOffset: Int? {
        guard let contentManager = textLayoutManager?.textContentManager else { return nil }
        return contentManager.offset(
            from: contentManager.documentRange.location, to: rangeInElement.location)
    }

    /// Where the first character of the paragraph draws, in fragment
    /// coordinates. A collapsed marker sits exactly there, so the gutter is
    /// everything left of it.
    private func firstGlyphOrigin() -> CGPoint? {
        guard let line = textLineFragments.first else { return nil }
        let inLine = line.locationForCharacter(at: 0)
        return CGPoint(
            x: line.typographicBounds.origin.x + inLine.x,
            y: line.typographicBounds.origin.y)
    }

    private var containerPadding: CGFloat {
        textLayoutManager?.textContainer?.lineFragmentPadding ?? 0
    }

    // MARK: - Painting

    private func drawMarkerGlyph(_ glyph: String, at point: CGPoint, metrics: EditorMetrics) {
        guard let line = textLineFragments.first, let origin = firstGlyphOrigin() else { return }
        let font = UIFont.systemFont(ofSize: metrics.bodySize)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: EditorTheme.markup,
        ]
        let size = (glyph as NSString).size(withAttributes: attributes)
        let height = line.typographicBounds.height
        let x = point.x + origin.x - metrics.markerSlot + (metrics.markerSlot - size.width) / 2
        let y = point.y + origin.y + (height - size.height) / 2
        (glyph as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: attributes)
    }

    private func drawCheckbox(_ state: TaskState, at point: CGPoint, metrics: EditorMetrics) {
        guard let line = textLineFragments.first, let origin = firstGlyphOrigin() else { return }
        let side = (metrics.bodySize * 0.86).rounded()
        guard let image = Self.symbol(
            state == .checked ? "checkmark.square" : "square", size: side)
        else { return }
        let height = line.typographicBounds.height
        let box = CGRect(
            x: point.x + origin.x - metrics.markerSlot + (metrics.markerSlot - image.size.width) / 2,
            y: point.y + origin.y + (height - image.size.height) / 2,
            width: image.size.width,
            height: image.size.height)
        image.withTintColor(
            state == .checked ? EditorTheme.caret : EditorTheme.markup,
            renderingMode: .alwaysOriginal
        ).draw(in: box)
    }

    private func drawQuoteBars(depth: Int, at point: CGPoint, metrics: EditorMetrics) {
        guard let origin = firstGlyphOrigin() else { return }
        let indent = metrics.quoteIndent
        let width = metrics.quoteBarWidth
        EditorTheme.quoteBar.setFill()
        for level in 1...depth {
            let gutter = origin.x - indent * CGFloat(depth - level + 1)
            let x = point.x + gutter + (indent - width) / 2
            for line in textLineFragments {
                let bounds = line.typographicBounds
                UIRectFill(CGRect(
                    x: x, y: point.y + bounds.origin.y, width: width, height: bounds.height))
            }
        }
    }

    private func drawRule(at point: CGPoint, metrics: EditorMetrics) {
        guard let line = textLineFragments.first else { return }
        let containerWidth = textLayoutManager?.textContainer?.size.width ?? 0
        let padding = containerPadding
        let width = max(0, containerWidth - padding * 2)
        guard width > 0 else { return }
        let bounds = line.typographicBounds
        EditorTheme.markup.setFill()
        UIRectFill(CGRect(
            x: point.x + padding,
            y: (point.y + bounds.midY - metrics.ruleThickness / 2).rounded(),
            width: width,
            height: metrics.ruleThickness))
    }

    /// SF Symbols images are cached per size: `draw` runs for every visible
    /// task line on every frame that scrolls.
    private static func symbol(_ name: String, size: CGFloat) -> UIImage? {
        let key = "\(name)|\(size)"
        if let cached = symbols[key] { return cached }
        let configuration = UIImage.SymbolConfiguration(pointSize: size, weight: .regular)
        guard let image = UIImage(systemName: name, withConfiguration: configuration) else { return nil }
        symbols[key] = image
        return image
    }
}

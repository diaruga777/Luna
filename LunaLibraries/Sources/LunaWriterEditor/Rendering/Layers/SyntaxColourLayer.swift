//
//  SyntaxColourLayer.swift
//  LunaWriterEditor
//

import UIKit
import LunaWriterText

/// Colours words by part of speech, iA's syntax control.
///
/// Tagging runs off the main thread, so a paragraph is asked for once and
/// coloured when the answer arrives. A device with no lexical-class model —
/// every simulator, and any unsupported language — tags nothing, and the
/// layer then contributes nothing rather than painting one flat colour.
public final class SyntaxColourLayer: RenderingAttributeLayer, POSTaggingObserving {

    public let identifier: LayerID = .syntax

    private let service: POSTaggingService
    private let storage: MarkdownTextStorage
    /// Tags by the paragraph's start offset.
    private var tags: [Int: [POSSpan]] = [:]

    public weak var invalidator: LayerInvalidating?

    public var isEnabled: Bool = true {
        didSet {
            guard isEnabled != oldValue else { return }
            if !isEnabled { service.cancelAll() }
            invalidator?.invalidate(nil)
        }
    }

    /// True when this device can name a word's part of speech at all. Every
    /// simulator answers false, and so does any language with no model, which
    /// is what the settings toggle asks before it offers the switch.
    public static func isSupported(sampleText: String) -> Bool {
        PartOfSpeechTagger.supportsTagging(sampleText)
    }

    public init(service: POSTaggingService, storage: MarkdownTextStorage) {
        self.service = service
        self.storage = storage
        service.observer = self
    }

    /// Forgets what was tagged, after the text under it changed.
    public func invalidateTags(in range: NSRange?) {
        guard let range else {
            tags.removeAll()
            service.cancelAll()
            return
        }
        // A rescan moves every paragraph after it, so the ones past the range
        // are as stale as the ones inside it.
        for start in tags.keys where start >= range.location {
            tags.removeValue(forKey: start)
            service.cancelParagraph(at: start)
        }
    }

    public func contributions(in range: NSRange, text: NSString) -> [RangedAttributes] {
        guard isEnabled, range.length > 0 else { return [] }
        var out: [RangedAttributes] = []
        var location = range.location
        while location < NSMaxRange(range) {
            let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
            defer { location = max(NSMaxRange(paragraph), location + 1) }
            guard paragraph.length > 0 else { continue }
            if let spans = tags[paragraph.location] {
                for span in spans {
                    guard let colour = EditorTheme.syntaxColour(for: span.pos) else { continue }
                    out.append(RangedAttributes(range: span.range, attributes: [.foregroundColor: colour]))
                }
            } else {
                service.requestTags(forParagraphIn: paragraph, of: text, revision: storage.revision)
            }
        }
        return out
    }

    // MARK: - POSTaggingObserving

    public func posTagging(
        _ service: POSTaggingService, didTag spans: [POSSpan], forParagraphIn range: NSRange, revision: Int
    ) {
        guard revision == storage.revision else { return }
        tags[range.location] = spans
        guard !spans.isEmpty else { return }
        invalidator?.invalidate(range)
    }
}

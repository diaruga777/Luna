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

    /// Tags by the paragraph's own text, offset-relative to its own start.
    /// Content survives an earlier paragraph's edit shifting this one's
    /// offset, so an untouched paragraph is never retagged just because
    /// something before it changed.
    private var tags: [String: [POSSpan]] = [:]
    /// Content currently awaiting an answer, so a paragraph is asked for at
    /// most once no matter how many render passes see it before that answer
    /// lands.
    private var requestedBodies: Set<String> = []
    /// The exact range a request was issued for, kept to find the content it
    /// was about when the answer comes back — `NSRange` values are plain
    /// numbers, so this stays correct even if the document has shifted in
    /// the meantime.
    private var pendingRequests: [NSRange: String] = [:]

    public weak var invalidator: LayerInvalidating?

    public var isEnabled: Bool = true {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled {
                invalidateTags(in: nil)
            } else {
                service.cancelAll()
            }
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

    /// A rescan touched `range`: ask for the tags of every paragraph it
    /// covers that isn't already known or already asked for. `nil` forgets
    /// everything and re-asks for the whole document, which is what a
    /// settings toggle needs after tagging was off for a while.
    public func invalidateTags(in range: NSRange?) {
        let text = storage.nsText
        let target: NSRange
        if let range {
            target = NSRange(location: range.location, length: min(range.length, text.length - range.location))
        } else {
            tags.removeAll()
            requestedBodies.removeAll()
            pendingRequests.removeAll()
            service.cancelAll()
            target = NSRange(location: 0, length: text.length)
        }
        guard target.length > 0, isEnabled else { return }
        var location = target.location
        let end = NSMaxRange(target)
        while location < end {
            let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
            defer { location = max(NSMaxRange(paragraph), location + 1) }
            guard paragraph.length > 0 else { continue }
            requestIfNeeded(paragraph, of: text)
        }
    }

    /// Pure read: contributes whatever is already known and asks for
    /// nothing, so a render pass never triggers a tagging job by itself.
    public func contributions(in range: NSRange, text: NSString) -> [RangedAttributes] {
        guard isEnabled, range.length > 0 else { return [] }
        var out: [RangedAttributes] = []
        var location = range.location
        while location < NSMaxRange(range) {
            let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
            defer { location = max(NSMaxRange(paragraph), location + 1) }
            guard paragraph.length > 0 else { continue }
            guard let spans = tags[text.substring(with: paragraph)] else { continue }
            for span in absolute(spans, at: paragraph.location) {
                guard let colour = EditorTheme.syntaxColour(for: span.pos) else { continue }
                out.append(RangedAttributes(range: span.range, attributes: [.foregroundColor: colour]))
            }
        }
        return out
    }

    private func requestIfNeeded(_ paragraph: NSRange, of text: NSString) {
        let body = text.substring(with: paragraph)
        guard tags[body] == nil, !requestedBodies.contains(body) else { return }
        if let cached = service.cachedTags(forParagraphIn: paragraph, of: text) {
            tags[body] = relative(cached, from: paragraph.location)
            return
        }
        requestedBodies.insert(body)
        pendingRequests[paragraph] = body
        service.requestTags(forParagraphIn: paragraph, of: text, revision: storage.revision)
    }

    // MARK: - POSTaggingObserving

    /// Correlates the answer by the exact request it answers, not by the
    /// document's revision: continuous typing bumps that on every keystroke
    /// anywhere in the document, which would drop a perfectly good answer
    /// about a paragraph nobody touched.
    public func posTagging(
        _ service: POSTaggingService, didTag spans: [POSSpan], forParagraphIn range: NSRange, revision: Int
    ) {
        guard let body = pendingRequests.removeValue(forKey: range) else { return }
        requestedBodies.remove(body)
        tags[body] = relative(spans, from: range.location)
        guard !spans.isEmpty else { return }
        invalidator?.invalidate(range)
    }

    private func relative(_ spans: [POSSpan], from location: Int) -> [POSSpan] {
        spans.map { POSSpan(range: NSRange(location: $0.range.location - location, length: $0.range.length), pos: $0.pos) }
    }

    private func absolute(_ spans: [POSSpan], at location: Int) -> [POSSpan] {
        spans.map { POSSpan(range: NSRange(location: $0.range.location + location, length: $0.range.length), pos: $0.pos) }
    }
}

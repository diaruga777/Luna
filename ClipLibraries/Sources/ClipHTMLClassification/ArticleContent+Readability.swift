//
//  ArticleContent+Readability.swift
//  Clip
//
//  Readability judgments that depend on the HTML-classification layer
//  (ArticleExtraction / PaywallDetector). Kept out of the ClipModels model so
//  the base model stays a pure value type; this extension lives alongside those
//  detectors and migrates into ClipHTMLClassification when that module extracts.
//

import ClipModels
import Foundation

public extension ArticleContent {
    /// Enough body text to be worth reading rather than a paywall stub — the
    /// text-only convenience reading of the shared `ArticleExtraction.isReadableArticle`
    /// predicate (no source HTML, so the publisher-declared lock signal isn't applied).
    /// Callers holding the source HTML should use `ArticleExtraction.isReadableArticle`
    /// for the stronger, HTML-aware judgment.
    public var hasReadableBody: Bool {
        ArticleExtraction.isReadableArticle(self, html: nil)
    }

    /// Whether this extracted text reads as a subscription wall / metered teaser
    /// rather than the real article. Delegates to the shared `PaywallDetector`
    /// (text-only here — callers with the source HTML should use
    /// `PaywallDetector.looksPaywalled(content:html:)` for the stronger signal).
    public var looksPaywalled: Bool {
        PaywallDetector.textLooksPaywalled(wholeText, bodyLength: bodyTextLength)
    }
}

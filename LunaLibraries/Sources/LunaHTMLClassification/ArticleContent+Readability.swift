//
//  ArticleContent+Readability.swift
//  Luna
//
//  This extension depends on ArticleExtraction and PaywallDetector, so it lives
//  here instead of on the LunaModels value type. That keeps the base model
//  free of HTML-classification logic.
//

import LunaModels
import Foundation

public extension ArticleContent {
    /// True when the article has enough body text to read, not just a paywall
    /// stub. This is the text-only reading of
    /// `ArticleExtraction.isReadableArticle`: it has no HTML, so it can't see
    /// the publisher's lock signal. Callers that hold the source HTML should
    /// call `ArticleExtraction.isReadableArticle` directly for the stronger,
    /// HTML-aware check.
    var hasReadableBody: Bool {
        ArticleExtraction.isReadableArticle(self, html: nil)
    }

    /// True when the extracted text reads as a paywall or metered-teaser
    /// stub, not a full article. This is the text-only reading of
    /// `PaywallDetector`. Callers that hold the source HTML should call
    /// `PaywallDetector.looksPaywalled(content:html:)` for the stronger check.
    var looksPaywalled: Bool {
        PaywallDetector.textLooksPaywalled(wholeText, bodyLength: bodyTextLength)
    }
}

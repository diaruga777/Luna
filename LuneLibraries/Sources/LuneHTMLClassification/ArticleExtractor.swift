//
//  ArticleExtractor.swift
//  Lune
//

import LuneModels
import Foundation
import SwiftSoup

/// Pulls formatted article text out of raw HTML — a small readability heuristic:
/// strip chrome elements, find the container with the most paragraph text, and
/// emit its block elements in order, preserving inline links.
public struct ArticleExtractor {

    public init() {}

    public enum ExtractError: Error {
        case noContent
    }

    /// Extraction is layered, never failing while ANY text exists:
    /// 1. refined — aggressive junk stripping + trailing-boilerplate trimming
    /// 2. basic   — structural-tags-only stripping (the original extractor)
    /// 3. raw     — every paragraph in the body, or the body's plain text
    /// The refined result is used only when it's substantial AND didn't eat
    /// most of what the basic pass found (junk classes sometimes match the
    /// main content container on real sites).
    public func extract(html: String, baseURL: URL) throws -> ArticleContent {
        let document = try SwiftSoup.parse(html, baseURL.absoluteString)
        let title = extractTitle(from: document)
        let author = extractAuthor(from: document)

        let refined = (try? refinedBlocks(html: html, baseURL: baseURL)) ?? []
        let basic = (try? basicBlocks(html: html, baseURL: baseURL)) ?? []
        let refinedLength = totalTextLength(refined)
        let basicLength = totalTextLength(basic)

        // Thresholds arbitrate BETWEEN layers; a short page keeps its
        // structured (basic) extraction rather than degrading to raw text.
        //
        // A SUBSTANTIAL refined result is trusted outright, even when `basic` is
        // much larger: on comment-heavy pages (e.g. an archived WSJ article) the
        // extra `basic` text is the comment thread + subscription promos that
        // refined correctly strips — the old `refined*3 >= basic` guard wrongly
        // fell back to that soup and dropped the article body. The guard still
        // applies for a MEDIUM refined result (350–600), where a small refined
        // more likely means refined's junk-class stripping ate the real content.
        var chosen: [ArticleContent.Block]
        let substantialRefinedLength = ArticleContent.readableBodyThreshold   // 1200
        if refinedLength >= substantialRefinedLength
            || (refinedLength >= 350 && refinedLength * 3 >= basicLength) {
            chosen = refined
        } else if !basic.isEmpty {
            chosen = basic
        } else {
            chosen = refined
        }

        // Some sites ship the article body as JSON-LD metadata while the DOM
        // is JS-rendered scaffolding — if that text dwarfs what the DOM gave
        // us, it IS the article (loses inline links/images, gains the text).
        let ldBody = ldJSONBlocks(from: document)
        if totalTextLength(ldBody) > 2 * totalTextLength(chosen) {
            chosen = ldBody
        }
        if chosen.isEmpty {
            chosen = rawBlocks(from: document)
        }
        guard !chosen.isEmpty else { throw ExtractError.noContent }
        // Publisher hero art is commonly declared only in Open Graph metadata,
        // outside the scored article container. Treat it as the lead block so it
        // appears directly under the title instead of being silently limited to
        // the reading-list thumbnail.
        prependLeadImage(from: document, to: &chosen, baseURL: baseURL)
        return ArticleContent(title: title, author: author, blocks: chosen)
    }

    /// Pulls `articleBody` out of any JSON-LD script blocks.
    private func ldJSONBlocks(from document: Document) -> [ArticleContent.Block] {
        guard let body = firstArticleBody(in: document), body.count > 200 else { return [] }
        return Self.blocks(fromArticleBody: body)
    }

    /// Forces the JSON-LD `articleBody` layer on `html`, even when the rendered DOM
    /// looked paywalled — many publishers ship `isAccessibleForFree:false` alongside
    /// a fully-populated `articleBody` (Bloomberg, Telegraaf, Les Échos, NZ Herald).
    /// Pure (parse only, no network). Returns nil when no `articleBody` is present.
    /// Truncated bodies are still returned — the caller's `hasReadableBody` length
    /// gate is the final arbiter, so a teaser-only body is rejected downstream.
    public func extractFromJSONLD(html: String, baseURL: URL) -> ArticleContent? {
        guard let document = try? SwiftSoup.parse(html, baseURL.absoluteString),
              let body = firstArticleBody(in: document)
        else { return nil }
        let blocks = Self.blocks(fromArticleBody: body)
        guard !blocks.isEmpty else { return nil }
        let title = extractTitle(from: document)
        let author = extractAuthor(from: document)
        return ArticleContent(title: title, author: author, blocks: blocks)
    }

    /// The first `articleBody` string found across the document's JSON-LD scripts
    /// (recursing through `@graph` arrays and `hasPart`/nested nodes), or nil.
    private func firstArticleBody(in document: Document) -> String? {
        guard let scripts = try? document.select("script[type=application/ld+json]") else {
            return nil
        }
        for script in scripts {
            guard let data = script.data().data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) else { continue }
            if let body = findArticleBody(in: parsed) { return body }
        }
        return nil
    }

    /// Splits a JSON-LD `articleBody` string into paragraph blocks on newlines.
    private static func blocks(fromArticleBody body: String) -> [ArticleContent.Block] {
        body
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { ArticleContent.Block(kind: .paragraph, text: $0, links: []) }
    }

    private func findArticleBody(in object: Any) -> String? {
        if let dictionary = object as? [String: Any] {
            if let body = dictionary["articleBody"] as? String { return body }
            for value in dictionary.values {
                if let found = findArticleBody(in: value) { return found }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let found = findArticleBody(in: value) { return found }
            }
        }
        return nil
    }

    private func totalTextLength(_ blocks: [ArticleContent.Block]) -> Int {
        blocks.reduce(0) { $0 + $1.text.count }
    }

    /// Layer 1: junk-stripped extraction (parses its own copy of the document).
    private func refinedBlocks(html: String, baseURL: URL) throws -> [ArticleContent.Block] {
        let document = try SwiftSoup.parse(html, baseURL.absoluteString)

        // Page chrome by tag/role, plus the usual junk-by-class suspects:
        // footers, social/share bars, related-article rails, comments,
        // newsletter prompts. Class matching is substring-based, so this is a
        // heuristic — author/byline classes are deliberately NOT stripped.
        let strippedSelectors = """
        script, style, noscript, nav, header, footer, aside, form, iframe, svg, button, \
        [role=navigation], [role=banner], [role=contentinfo], [role=complementary], \
        [class*=footer], [id*=footer], [class*=sidebar], [class*=related], \
        [class*=share], [class*=social], [class*=comment], [class*=Comment], \
        [id*=comment], [class*=disqus], [class*=conversation], [class*=discussion], \
        [data-module*=comment], [data-testid*=comment], \
        [class*=newsletter], [class*=subscribe], [class*=Subscribe], [class*=promo], \
        [class*=paywall], [class*=Paywall], [class*=breadcrumb], \
        [class*=cookie], [class*=advert], [class*=popup], \
        [class*=recommend], [class*=trending], [class*=more-stories], \
        [class*=video], [id*=video], [class*=player], [id*=player], \
        [aria-live], [role=slider], [role=menu], [role=menubar]
        """
        for element in try document.select(strippedSelectors) {
            try element.remove()
        }
        try removeVisuallyHiddenElements(in: document)

        let container = try bestContainer(in: document)
        var blocks = try extractBlocks(from: container, baseURL: baseURL)
        if totalTextLength(blocks) < 200, let body = document.body() {
            blocks = try extractBlocks(from: body, baseURL: baseURL)
        }
        return trimTrailingJunk(blocks)
    }

    /// Removes screen-reader-only / off-screen elements. Archived pages (and
    /// many sites) ship visually-hidden labels — player state ("Playing"),
    /// timecodes, sr-only captions — via the classic clip/1px-box idiom; those
    /// are UI accessibility text, never article prose, so they must not surface
    /// once paragraph-like `<div>`s are captured.
    private func removeVisuallyHiddenElements(in document: Document) throws {
        // Signatures are pre-normalized (lowercase, no spaces) to match the
        // normalized style string regardless of the author's whitespace.
        let hiddenStyleSignatures = [
            "clip:rect(1px", "clip:rect(0px", "clip:rect(0,", "clip:rect(0)",
            "clip-path:inset(50%)", "clip-path:inset(100%)",
            "width:1px;height:1px", "height:1px;width:1px",
        ]
        for element in try document.select("[style]") {
            let style = ((try? element.attr("style")) ?? "")
                .lowercased().replacingOccurrences(of: " ", with: "")
            if hiddenStyleSignatures.contains(where: style.contains) {
                try element.remove()
            }
        }
    }

    /// Layer 2: the original conservative extraction — structural tags only.
    private func basicBlocks(html: String, baseURL: URL) throws -> [ArticleContent.Block] {
        let document = try SwiftSoup.parse(html, baseURL.absoluteString)
        let structuralTags = "script, style, noscript, nav, header, footer, aside, form, iframe, svg, button"
        for element in try document.select(structuralTags) {
            try element.remove()
        }
        let container = try bestContainer(in: document)
        var blocks = try extractBlocks(from: container, baseURL: baseURL)
        if totalTextLength(blocks) < 200, let body = document.body() {
            blocks = try extractBlocks(from: body, baseURL: baseURL)
        }
        return blocks
    }

    /// Layer 3: dumbest possible — whatever text the body holds, as one block.
    private func rawBlocks(from document: Document) -> [ArticleContent.Block] {
        guard let body = document.body() else { return [] }
        let text = ((try? body.text()) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let capped = String(text.prefix(40_000))
        return [ArticleContent.Block(kind: .paragraph, text: capped, links: [])]
    }

    /// Footers that survive class-stripping are mostly links and boilerplate:
    /// peel blocks off the end while they're link-dense or match footer phrases.
    private func trimTrailingJunk(_ blocks: [ArticleContent.Block]) -> [ArticleContent.Block] {
        var trimmed = blocks
        while let last = trimmed.last, isJunkBlock(last) {
            trimmed.removeLast()
        }
        return trimmed
    }

    private func isJunkBlock(_ block: ArticleContent.Block) -> Bool {
        if block.kind == .image { return false }
        let length = block.text.utf16.count
        guard length > 0 else { return true }

        let linkedLength = block.links.reduce(0) { $0 + $1.length }
        let linkDensity = Double(linkedLength) / Double(length)
        if linkDensity > 0.7, block.text.count < 400 { return true }

        let junkPhrases = [
            "all rights reserved", "privacy policy", "terms of service",
            "terms of use", "cookie policy", "subscribe to", "sign up for",
            "follow us", "originally published", "related articles", "©",
        ]
        let lowered = block.text.lowercased()
        if block.text.count < 200, junkPhrases.contains(where: { lowered.contains($0) }) {
            return true
        }
        return false
    }

    // MARK: - Author

    /// Best-effort byline: meta tag first, then visible byline/author elements.
    private func extractAuthor(from document: Document) -> String? {
        if let meta = try? document.select("meta[name=author]").first()?.attr("content"),
           !meta.isEmpty, meta.count < 100 {
            return meta
        }
        for selector in ["[rel=author]", "[class*=byline]", "[class*=author]"] {
            if let text = try? document.select(selector).first()?.text(),
               !text.isEmpty, text.count < 100 {
                return text
            }
        }
        return nil
    }

    // MARK: - Title

    private func extractTitle(from document: Document) -> String {
        if let og = try? document.select("meta[property=og:title]").first()?.attr("content"),
           !og.isEmpty {
            return og
        }
        if let title = try? document.title(), !title.isEmpty {
            return title
        }
        if let h1 = try? document.select("h1").first()?.text(), !h1.isEmpty {
            return h1
        }
        return "Untitled"
    }

    // MARK: - Container scoring

    /// Readability-style scoring: each paragraph credits its ancestors with
    /// decaying weight, so the common article container wins even when every
    /// paragraph is wrapped in its own div (common on React-rendered sites).
    private func bestContainer(in document: Document) throws -> Element {
        // Prefer an explicit article-body container (schema.org `articleBody`,
        // or a CMS body class) when it holds real text. These markers point at
        // exactly the prose and exclude the comment threads / subscription
        // promos that would otherwise outscore the body on comment-heavy pages
        // (e.g. an archived WSJ article, where comments dwarf the article text).
        let articleBodySelectors = [
            "[itemprop=articleBody]", "[class*=article-body]", "[class*=articleBody]",
            "[class*=article__body]", "[class*=ArticleBody]", "[class*=article-content]",
        ]
        for selector in articleBodySelectors {
            if let candidate = try? document.select(selector).first(),
               paragraphTextLength(in: candidate) >= 400 {
                return candidate
            }
        }

        var scores: [ObjectIdentifier: Double] = [:]
        var elements: [ObjectIdentifier: Element] = [:]
        for paragraph in paragraphLikeElements(in: document) {
            let textCount = (try? paragraph.text().count) ?? 0
            guard textCount > 20 else { continue }
            var ancestor = paragraph.parent()
            var weight = 1.0
            var depth = 0
            while let current = ancestor, depth < 3, current.tagName() != "body" {
                let key = ObjectIdentifier(current)
                scores[key, default: 0] += Double(textCount) * weight
                elements[key] = current
                ancestor = current.parent()
                weight /= 2
                depth += 1
            }
        }
        guard var container = scores.max(by: { $0.value < $1.value })
            .flatMap({ elements[$0.key] }) else {
            return document.body() ?? document
        }

        // Some CMSs split the article body across sibling containers, so the
        // top-scoring one holds only a fraction of the text. Widen upward
        // until the container covers most of the document's paragraph text.
        let documentParagraphLength = max(1, paragraphTextLength(in: document))
        var coverage = Double(paragraphTextLength(in: container)) / Double(documentParagraphLength)
        while coverage < 0.6,
              let parent = container.parent(),
              parent.tagName() != "html", parent.tagName() != "#root" {
            container = parent
            coverage = Double(paragraphTextLength(in: container)) / Double(documentParagraphLength)
        }
        return container
    }

    private func paragraphTextLength(in element: Element) -> Int {
        var total = 0
        for paragraph in paragraphLikeElements(in: element) {
            let length = (try? paragraph.text().count) ?? 0
            if length > 20 { total += length }
        }
        return total
    }

    /// `<p>` plus "paragraph-like" `<div>`/`<section>` leaves — containers whose
    /// content is entirely inline/text (no block-level child element). Many news
    /// sites — and archive.today's rewritten DOM — render every body paragraph as
    /// a styled `<div>` with no `<p>` at all; treating those as paragraphs is what
    /// lets the scorer and block extractor see the real article body instead of
    /// only the stray `<p>`s (a summary box, a caption) elsewhere on the page.
    private func paragraphLikeElements(in root: Element) -> [Element] {
        guard let candidates = try? root.select("p, div, section") else { return [] }
        return candidates.array().filter { element in
            element.tagName() == "p" || isParagraphLikeContainer(element)
        }
    }

    /// True for a `<div>`/`<section>` with no block-level child element, i.e. all
    /// of its content is inline/text — so it reads as a single paragraph.
    private func isParagraphLikeContainer(_ element: Element) -> Bool {
        let tag = element.tagName()
        guard tag == "div" || tag == "section" else { return false }
        for child in element.children() where blockLevelChildTags.contains(child.tagName()) {
            return false
        }
        return true
    }

    // MARK: - Block extraction

    private let blockTags: Set<String> = ["p", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "li", "pre"]

    /// Child tags that disqualify a `<div>`/`<section>` from being a single
    /// paragraph (their presence means the element is a structural container).
    private let blockLevelChildTags: Set<String> = [
        "div", "p", "section", "article", "aside", "header", "footer", "nav", "main",
        "ul", "ol", "li", "table", "thead", "tbody", "tr", "td", "blockquote",
        "figure", "figcaption", "form", "pre", "h1", "h2", "h3", "h4", "h5", "h6",
    ]

    private func extractBlocks(from container: Element, baseURL: URL) throws -> [ArticleContent.Block] {
        var blocks: [ArticleContent.Block] = []
        for element in try container.select(blockTags.joined(separator: ", ") + ", div, section, img") {
            if element.tagName() == "img" {
                // Standalone images (inside divs/figures); images nested in a
                // paragraph are collected by that paragraph's walk below.
                if hasBlockAncestor(element, within: container) { continue }
                if let imageBlock = makeImageBlock(from: element, baseURL: baseURL) {
                    blocks.append(imageBlock)
                }
                continue
            }
            // Structural <div>/<section> wrappers are skipped; only paragraph-like
            // ones (pure inline/text) are emitted, as a paragraph. A paragraph-like
            // container has no block-level children, so it can't nest another, and
            // its text isn't double-counted by a descendant block. The >20-char
            // gate matches the scoring threshold: a bare text <div> that short is
            // UI chrome (a timecode, "Up Next", a label), not article prose —
            // explicit <p>/heading/list/quote tags keep their any-length behavior.
            if element.tagName() == "div" || element.tagName() == "section" {
                guard isParagraphLikeContainer(element),
                      ((try? element.text().count) ?? 0) > 20 else { continue }
            }
            // Skip elements nested inside another matched block (e.g. p inside
            // blockquote) so the same text isn't emitted twice.
            if hasBlockAncestor(element, within: container) { continue }
            let (block, nestedImages) = makeBlock(from: element, baseURL: baseURL)
            if let block {
                blocks.append(block)
            }
            blocks.append(contentsOf: nestedImages)
        }
        return blocks
    }

    // MARK: - Images

    /// Inserts the highest-priority Open Graph/Twitter lead image at the top of
    /// the article. If the same image was already found in the body, move it
    /// rather than showing the hero twice.
    private func prependLeadImage(
        from document: Document, to blocks: inout [ArticleContent.Block], baseURL: URL
    ) {
        guard let leadURL = leadImageURL(from: document, baseURL: baseURL) else { return }
        let leadString = leadURL.absoluteString
        if let index = blocks.firstIndex(where: {
            $0.kind == .image && normalizedImageURL($0.imageURLString) == leadString
        }) {
            blocks.insert(blocks.remove(at: index), at: 0)
        } else {
            blocks.insert(
                ArticleContent.Block(kind: .image, text: "", links: [], imageURLString: leadString), at: 0)
        }
    }

    /// Metadata selectors are deliberately attribute-order independent. Several
    /// publishers use `og:image:secure_url`, and large images are often only in
    /// `twitter:image:src`, neither of which was covered by the old body-only
    /// extraction.
    private func leadImageURL(from document: Document, baseURL: URL) -> URL? {
        let acceptedMetaNames = [
            "og:image", "og:image:url", "og:image:secure_url",
            "twitter:image", "twitter:image:src",
        ]
        let metas = (try? document.select("meta[property], meta[name]").array()) ?? []
        for name in acceptedMetaNames {
            guard let meta = metas.first(where: {
                let property = (try? $0.attr("property"))?.lowercased()
                let metaName = (try? $0.attr("name"))?.lowercased()
                return property == name || metaName == name
            }), let raw = try? meta.attr("content"), let url = resolvedImageURL(raw, baseURL: baseURL)
            else { continue }
            return url
        }
        // Schema.org is the other common home for a lead image. NYT and several
        // CMSes omit og:image on their reader response but keep JSON-LD's `image`.
        if let scripts = try? document.select("script[type=application/ld+json]") {
            for script in scripts {
                guard let data = script.data().data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data),
                      let raw = firstImageURL(inJSONLD: object),
                      let url = resolvedImageURL(raw, baseURL: baseURL)
                else { continue }
                return url
            }
        }
        // Some reader endpoints supply their hero only as a preloaded resource.
        if let preload = try? document.select("link[rel=preload][as=image]").first(),
           let raw = try? preload.attr("href"), let url = resolvedImageURL(raw, baseURL: baseURL) {
            return url
        }
        let links = (try? document.select("link[rel]").array()) ?? []
        guard let link = links.first(where: {
            (try? $0.attr("rel"))?.lowercased().split(separator: " ").contains("image_src") == true
        }), let raw = try? link.attr("href")
        else { return nil }
        return resolvedImageURL(raw, baseURL: baseURL)
    }

    private func firstImageURL(inJSONLD object: Any) -> String? {
        if let dictionary = object as? [String: Any] {
            for key in ["image", "thumbnailUrl", "thumbnailURL"] {
                if let value = dictionary[key], let found = imageURLString(inJSONLDValue: value) {
                    return found
                }
            }
            for value in dictionary.values {
                if let found = firstImageURL(inJSONLD: value) { return found }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let found = firstImageURL(inJSONLD: value) { return found }
            }
        }
        return nil
    }

    private func imageURLString(inJSONLDValue value: Any) -> String? {
        if let string = value as? String { return string }
        if let array = value as? [Any] {
            return array.lazy.compactMap(imageURLString(inJSONLDValue:)).first
        }
        if let dictionary = value as? [String: Any] {
            for key in ["url", "contentUrl", "@id"] {
                if let string = dictionary[key] as? String { return string }
            }
        }
        return nil
    }

    /// Article-image heuristic: skip obvious ad/tracking/chrome images and
    /// anything declared tiny.
    private func makeImageBlock(from element: Element, baseURL: URL) -> ArticleContent.Block? {
        guard var urlString = imageURLString(from: element, baseURL: baseURL) else { return nil }
        if urlString.hasSuffix(".svg") || urlString.hasSuffix(".gif") { return nil }

        // Token-exact matching: substring matching would reject legitimate
        // URLs (e.g. "ads" inside WordPress's "/wp-content/uploads/").
        let junkTokens: Set<String> = [
            "ad", "ads", "advert", "adsystem", "sponsor", "sponsored",
            "track", "tracking", "tracker", "pixel", "beacon",
            "avatar", "gravatar", "logo", "icon", "badge", "button", "emoji",
        ]
        let classAndID = ((try? element.attr("class")) ?? "") + " "
            + ((try? element.attr("id")) ?? "")
        let tokens = Set(
            (urlString + " " + classAndID).lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init))
        guard tokens.isDisjoint(with: junkTokens) else { return nil }

        for dimension in ["width", "height"] {
            if let value = try? element.attr(dimension),
               let pixels = Int(value), pixels > 0, pixels < 140 {
                return nil
            }
        }

        // Strip URL fragments that confuse file-extension detection later.
        if let hash = urlString.firstIndex(of: "#") {
            urlString = String(urlString[..<hash])
        }
        return ArticleContent.Block(kind: .image, text: "", links: [], imageURLString: urlString)
    }

    /// Resolves standard, lazy-load, and responsive image attributes. `src` is
    /// frequently a 1px placeholder while the real URL is in `data-srcset` or a
    /// sibling `<source>`; choosing the largest responsive candidate avoids that
    /// particular failure mode for article headers.
    private func imageURLString(from element: Element, baseURL: URL) -> String? {
        // Responsive source sets are often the only real image URL; `src` is a
        // tiny placeholder. Prefer them before any direct attribute.
        let sourceAttributes = ["data-srcset", "data-lazy-srcset", "srcset"]
        for attribute in sourceAttributes {
            if let raw = try? element.attr(attribute),
               let url = largestImageURL(in: raw, baseURLString: baseURL.absoluteString) {
                return url.absoluteString
            }
        }
        let attributes = ["data-src", "data-original", "data-lazy-src", "data-image", "src"]
        for attribute in attributes {
            if let raw = try? element.attr(attribute),
               let url = resolvedImageURL(raw, baseURL: baseURL) {
                return url.absoluteString
            }
        }
        if let parent = element.parent(),
           let source = try? parent.select("source").first() {
            for attribute in sourceAttributes {
                if let raw = try? source.attr(attribute),
                   let url = largestImageURL(in: raw, baseURLString: baseURL.absoluteString) {
                    return url.absoluteString
                }
            }
        }
        return nil
    }

    private func largestImageURL(in srcset: String, baseURLString: String) -> URL? {
        let candidates = srcset.split(separator: ",").compactMap { entry -> (URL, Int)? in
            let parts = entry.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
            guard let raw = parts.first,
                  let url = resolvedImageURL(String(raw), baseURLString: baseURLString)
            else { return nil }
            let width = parts.dropFirst().first.flatMap { Int($0.dropLast()) } ?? 0
            return (url, width)
        }
        return candidates.max(by: { $0.1 < $1.1 })?.0
    }

    private func resolvedImageURL(_ raw: String, baseURL: URL) -> URL? {
        resolvedImageURL(raw, baseURLString: baseURL.absoluteString)
    }

    private func resolvedImageURL(_ raw: String, baseURLString: String) -> URL? {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "&amp;", with: "&")
        guard !cleaned.isEmpty, !cleaned.hasPrefix("data:"),
              let url = URL(string: cleaned, relativeTo: URL(string: baseURLString))?.absoluteURL,
              url.scheme == "http" || url.scheme == "https"
        else { return nil }
        return url
    }

    private func normalizedImageURL(_ urlString: String?) -> String? {
        guard let urlString, let url = URL(string: urlString) else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.url?.absoluteString
    }

    private func hasBlockAncestor(_ element: Element, within container: Element) -> Bool {
        var parent = element.parent()
        while let current = parent, current !== container {
            if blockTags.contains(current.tagName()) { return true }
            parent = current.parent()
        }
        return false
    }

    /// Builds a block by walking the element's nodes in order, collapsing
    /// whitespace incrementally so the recorded UTF-16 link ranges stay valid.
    /// Images found inside the block are returned separately, in order.
    private func makeBlock(
        from element: Element, baseURL: URL
    ) -> (ArticleContent.Block?, [ArticleContent.Block]) {
        var text = ""
        var links: [ArticleContent.Link] = []
        var nestedImages: [ArticleContent.Block] = []

        func appendCollapsed(_ raw: String) -> (start: Int, length: Int) {
            var addition = ""
            var lastWasSpace = text.isEmpty || text.hasSuffix(" ")
            for character in raw {
                if character.isWhitespace {
                    if !lastWasSpace {
                        addition.append(" ")
                        lastWasSpace = true
                    }
                } else {
                    addition.append(character)
                    lastWasSpace = false
                }
            }
            let start = text.utf16.count
            text += addition
            return (start, addition.utf16.count)
        }

        func walk(_ node: Node, linkURL: String?) {
            if let textNode = node as? TextNode {
                let range = appendCollapsed(textNode.getWholeText())
                if let linkURL, range.length > 0 {
                    // Extend an adjacent run of the same link instead of fragmenting.
                    if var last = links.last, last.urlString == linkURL,
                       last.start + last.length == range.start {
                        last.length += range.length
                        links[links.count - 1] = last
                    } else {
                        links.append(ArticleContent.Link(
                            start: range.start, length: range.length, urlString: linkURL))
                    }
                }
                return
            }
            guard let child = node as? Element else { return }
            if child.tagName() == "img" {
                if let imageBlock = makeImageBlock(from: child, baseURL: baseURL) {
                    nestedImages.append(imageBlock)
                }
                return
            }
            var childLink = linkURL
            if child.tagName() == "a",
               let href = try? child.attr("abs:href"), href.hasPrefix("http") {
                childLink = href
            }
            for grandchild in child.getChildNodes() {
                walk(grandchild, linkURL: childLink)
            }
        }

        for node in element.getChildNodes() {
            walk(node, linkURL: nil)
        }

        // Only trailing whitespace can exist (leading is collapsed away), so
        // trimming doesn't shift link offsets; just clamp ranges to be safe.
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > 1 else { return (nil, nestedImages) }
        let limit = text.utf16.count
        links = links.compactMap { link in
            guard link.start < limit else { return nil }
            var clamped = link
            clamped.length = min(link.length, limit - link.start)
            return clamped.length > 0 ? clamped : nil
        }

        let kind: ArticleContent.Block.Kind
        switch element.tagName() {
        case "h1", "h2", "h3", "h4", "h5", "h6": kind = .heading
        case "blockquote": kind = .quote
        case "li": kind = .listItem
        default: kind = .paragraph
        }
        return (ArticleContent.Block(kind: kind, text: text, links: links), nestedImages)
    }
}

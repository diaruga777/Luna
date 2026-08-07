//
//  ArticleExtractor.swift
//  Luna
//

import LunaModels
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
        // A SUBSTANTIAL refined result (≥1200 chars) is trusted outright even when
        // `basic` is larger — comment-heavy pages (e.g. an archived WSJ article)
        // inflate `basic` with the comment thread + subscription promos that refined
        // correctly strips. A MEDIUM refined result (350–600) additionally requires
        // `refined*3 >= basic`, since a small refined result more likely means
        // refined's junk-class stripping ate real content.
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

        // A basic-layer win hasn't been through any trailing-junk trimming (it only
        // strips structural chrome tags), so a comment thread — or an ad label, or an
        // in-body recirc rail — on a page whose refined pass wasn't substantial enough
        // to win arbitration leaks straight through. So the position-independent,
        // shape-only rules run here, on WHICHEVER layer won: inline junk lines (ad
        // labels, "Related:" teasers, own-content card rails) and the safest
        // (comment) tier of the terminator. Left out is everything that leans on
        // refined's junk-class stripping to stay free of false positives — the recirc
        // terminator tier and the reverse trim.
        chosen = removeInlineJunkLines(chosen)
        chosen = applyTerminatorHardStop(chosen, commentTierOnly: true)
        guard !chosen.isEmpty else { throw ExtractError.noContent }
        // Publisher hero art is commonly declared only in Open Graph metadata,
        // outside the scored article container. Treat it as the lead block so it
        // appears directly under the title instead of being silently limited to
        // the reading-list thumbnail.
        prependLeadImage(from: document, to: &chosen, baseURL: baseURL)
        // Last, on the blocks that actually survived every trimming pass: a table
        // of contents whose destinations were trimmed away must not keep offering
        // jumps to them.
        chosen = InPageAnchors.resolvingAnchors(chosen)
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
        // Before anything is stripped: the page's own chapter marks are a
        // link-dense list inside (often) a `<nav>` — i.e. exactly the shape both
        // the selector strip below and `cleanConditionally` delete.
        let anchors = InPageAnchors.prepare(document: document, baseURL: baseURL)

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
        [class*=AuthorModule], [class*=author-module], [class*=breadcrumb], \
        [class*=cookie], [class*=advert], [class*=popup], \
        [class*=recommend], [class*=trending], [class*=more-stories], \
        [class*=video], [id*=video], [class*=player], [id*=player], \
        [aria-live], [role=slider], [role=menu], [role=menubar], \
        [class*=outbrain], [class*=taboola], [class*=revcontent], [class*=mgid], \
        [class*=zergnet], [class*=sponsor], [id*=sponsor], [class*=recirc], [id*=recirc], \
        [class*=read-next], [class*=read-more], [class*=more-from], \
        [class*=most-popular], [class*=most-read], [class*=you-may-also-like], \
        [class*=around-the-web], [class*=tag-list], [class*=pagination], [class*=pager], \
        [class*=endslate], [class*=livefyre], [class*=coral-], [class*=spot-im], \
        [class*=syndication], [id*=disqus_thread], #respond
        """
        // Class matching is by SUBSTRING, so a junk name also hits the layout
        // wrapper that merely makes room for the rail it names. Two shapes of that:
        // CMSs put layout-state classes on <body>/<html> (WordPress emits e.g.
        // `sidebar-right has-sidebar`), and grid wrappers name their columns (NY
        // Post lays an article out in `<div class="layout layout--sidebar">`, whose
        // two columns are the story and the sidebar). Removing either takes the
        // ENTIRE article with it — zeroing this refined layer and forcing the
        // untrimmed `basic` layer (which keeps every ad label and recirc rail) to
        // win. New Statesman hit the first; NY Post the second (13 chars survived).
        let wrappers = articleWrapperChain(in: document)
        for element in try document.select(strippedSelectors)
        where !isPageRoot(element) && !isArticleWrapper(element, chain: wrappers)
            && !InPageAnchors.isProtected(element) {
            try element.remove()
        }
        try removePaywallJunk(in: document)
        try removeVisuallyHiddenElements(in: document)

        let container = try bestContainer(in: document)
        try cleanConditionally(in: container)
        var blocks = try extractBlocks(from: container, baseURL: baseURL, anchors: anchors)
        if totalTextLength(blocks) < 200, let body = document.body() {
            blocks = try extractBlocks(from: body, baseURL: baseURL, anchors: anchors)
        }
        return trimTrailingJunk(blocks)
    }

    /// The document root elements a class-substring strip must never delete, however
    /// their class reads — removing `<body>`/`<html>` would take the whole page with it.
    private func isPageRoot(_ element: Element) -> Bool {
        let tag = element.tagName().lowercased()
        return tag == "body" || tag == "html"
    }

    /// The STRICT ancestors of the document's densest prose container, identified
    /// BEFORE any stripping: the chain of layout wrappers that a junk-class match
    /// must not delete wholesale, because deleting one deletes the article.
    ///
    /// Strictness is what keeps this safe on a page whose junk outweighs its story.
    /// When a comment thread is what scores highest pre-strip, its own container
    /// still matches `[class*=comment]` and is still removed — only the shared
    /// layout wrappers ABOVE it are spared, and every junk child of those is still
    /// matched and removed individually. So the rule never keeps junk that used to
    /// go; it only replaces "delete the wrapper" with "delete the wrapper's junk".
    private func articleWrapperChain(in document: Document) -> Set<ObjectIdentifier> {
        guard let container = try? bestContainer(in: document) else { return [] }
        var chain: Set<ObjectIdentifier> = []
        var parent = container.parent()
        while let current = parent {
            chain.insert(ObjectIdentifier(current))
            parent = current.parent()
        }
        return chain
    }

    private func isArticleWrapper(_ element: Element, chain: Set<ObjectIdentifier>) -> Bool {
        chain.contains(ObjectIdentifier(element))
    }

    /// Removes actual subscription walls while preserving unlocked article bodies
    /// that still carry a stale paywall class. WSJ renders the readable post-unlock
    /// body inside `.paywall ... PaywalledContent`; deleting every paywall-class node
    /// erases most of the story and leaves nearby author boilerplate to win scoring.
    private func removePaywallJunk(in document: Document) throws {
        for element in try document.select("[class*=paywall], [class*=Paywall]") {
            if isArticleHeavyPaywallWrapper(element) { continue }
            try element.remove()
        }
    }

    private func isArticleHeavyPaywallWrapper(_ element: Element) -> Bool {
        let paragraphCount = paragraphLikeElements(in: element).filter {
            ((try? $0.text().count) ?? 0) > 40
        }.count
        return paragraphCount >= 4 && paragraphTextLength(in: element) >= 800
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
        let anchors = InPageAnchors.prepare(document: document, baseURL: baseURL)
        let structuralTags = "script, style, noscript, nav, header, footer, aside, form, iframe, svg, button"
        for element in try document.select(structuralTags)
        where !InPageAnchors.isProtected(element) {
            try element.remove()
        }
        let container = try bestContainer(in: document)
        var blocks = try extractBlocks(from: container, baseURL: baseURL, anchors: anchors)
        if totalTextLength(blocks) < 200, let body = document.body() {
            blocks = try extractBlocks(from: body, baseURL: baseURL, anchors: anchors)
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

    /// Trailing/embedded boilerplate — comments, ads, recirc rails, newsletter
    /// promos, trailing image dumps — surviving class-stripping is handled in three
    /// passes, each modeled on a known readability-library rule:
    ///   1. inline junk-line removal (any position): mid-article single-line recirc
    ///      teasers and bare "Advertisement" labels (Readability's `adWords` rule).
    ///   2. a terminator hard stop (boilerpipe `TerminatingBlocksFinder` /
    ///      `IgnoreBlocksAfterContentFilter`): once the body has said enough, a short
    ///      heading/line naming a comment section or recirc rail truncates everything
    ///      from there on.
    ///   3. a strengthened reverse trim (trafilatura's list-density rule + a trailing
    ///      image-dump rule) that pops footer-shaped blocks off the very end.
    private func trimTrailingJunk(_ blocks: [ArticleContent.Block]) -> [ArticleContent.Block] {
        var result = removeInlineJunkLines(blocks)
        result = applyTerminatorHardStop(result, commentTierOnly: false)
        result = reverseTrim(result)
        return result
    }

    // MARK: - Phase 1: inline junk-line removal (any position)

    /// A mid-article single-line recirc teaser ("Related: <link>") reads as a short,
    /// link-dense line that isn't itself the end of the article — dropping it (rather
    /// than waiting for the reverse trim, which only looks at the tail) keeps whatever
    /// follows intact.
    private let recircLeadIns = [
        "related:", "read more:", "read also:", "see also:", "more:", "watch:", "also read",
    ]

    /// Readability's `adWords` rule: a block whose ENTIRE text is an ad label — the
    /// caption an ad slot prints above itself, left behind whenever the slot's own
    /// markup names itself something the junk-class strip doesn't recognise (NY Post
    /// ships nine `<p class="ad__label">Advertisement</p>` inside `<div class="ad">`,
    /// which no `advert`/`sponsor` substring matches). Matching is on the block's
    /// WHOLE text, so a paragraph that merely mentions advertising is untouched.
    private let adLabelPhrases: Set<String> = [
        "ad", "ads", "advert", "adverts", "advertisement", "advertisements",
        "sponsored", "sponsored content", "sponsored links", "sponsored story",
        "paid content", "paid post", "promoted content", "promoted stories",
        "story continues below", "story continues below advertisement",
        "article continues below", "article continues below advertisement",
        "advertisement story continues below", "continue reading below",
        "advertisement continue reading below", "continues below advertisement",
        "scroll to continue", "scroll to continue with content",
    ]

    private func removeInlineJunkLines(_ blocks: [ArticleContent.Block]) -> [ArticleContent.Block] {
        let filtered = blocks.filter { !isMidArticleRecircLine($0) && !isAdLabelBlock($0) }
        return removeInlineRecircModules(filtered)
    }

    private func isMidArticleRecircLine(_ block: ArticleContent.Block) -> Bool {
        // A ToC row is short and 100% link by construction; it has already been
        // positively identified, so none of the junk heuristics apply to it. Nor to
        // a caption, which is already excluded from the word stream.
        guard block.kind != .image, block.kind != .tableOfContents, block.kind != .caption,
              block.text.count < 200, linkDensity(of: block) > 0.6
        else {
            return false
        }
        let normalized = block.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return recircLeadIns.contains { normalized.hasPrefix($0) }
    }

    private func isAdLabelBlock(_ block: ArticleContent.Block) -> Bool {
        guard block.kind != .image else { return false }
        var normalized = block.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while let last = normalized.last, ".!:".contains(last) { normalized.removeLast() }
        return adLabelPhrases.contains(normalized.trimmingCharacters(in: .whitespaces))
    }

    // MARK: - Phase 1b: in-body recirc modules

    /// A publisher's in-body ad for its OWN content — NY Post drops an "Explore More"
    /// card rail between two body paragraphs — is recognised by SHAPE, not by the
    /// wrapper's class (which is what the strip above already tries, and misses as
    /// soon as a site names the module something new): a run of adjacent blocks whose
    /// text is essentially nothing but hyperlink (card titles are never prose),
    /// optionally introduced by a short label naming the rail.
    ///
    /// Unlike the terminator below it removes the module IN PLACE, because the
    /// article continues underneath it.
    ///
    /// Two independent gates keep a genuine link roundup — "the five posts to read
    /// this week", where each item legitimately IS a linked heading — intact: a run
    /// of TWO OR MORE adjacent fully-linked blocks is a rail on its own evidence,
    /// while a LONE fully-linked block goes only when a recirc label introduces it.
    /// In a roundup the linked headings are separated by the author's prose, so every
    /// run is length 1 and unlabelled, and nothing is touched.
    ///
    /// A dropped run takes its heading with it. For a multi-block run the heading
    /// needs no recognised wording — a short heading whose entire body WAS a card
    /// rail is that rail's heading, whatever the section is called ("More from
    /// Business") — which is what stops an orphan label being left behind.
    private func removeInlineRecircModules(
        _ blocks: [ArticleContent.Block]
    ) -> [ArticleContent.Block] {
        var doomed = Set<Int>()
        var index = 0
        while index < blocks.count {
            guard isFullyLinkedCard(blocks[index]) else {
                index += 1
                continue
            }
            var end = index
            while end + 1 < blocks.count, isFullyLinkedCard(blocks[end + 1]) { end += 1 }
            let previous = index > 0 ? blocks[index - 1] : nil
            let isRun = end > index
            let heading = previous.flatMap { block -> Int? in
                if isRun, isShortBareHeading(block) { return index - 1 }
                return isRecircLabel(block) ? index - 1 : nil
            }
            if isRun || heading != nil {
                if let heading { doomed.insert(heading) }
                for card in index...end { doomed.insert(card) }
            }
            index = end + 1
        }
        guard !doomed.isEmpty else { return blocks }
        return blocks.enumerated().filter { !doomed.contains($0.offset) }.map(\.element)
    }

    /// A heading short enough to be a rail's title rather than a section of prose.
    /// Restricted to headings: a `<p>` this short could be a real one-line sentence.
    private func isShortBareHeading(_ block: ArticleContent.Block) -> Bool {
        block.kind == .heading && block.links.isEmpty && wordCount(block.text) <= 6
    }

    /// A recirc card title: a short block that is (essentially) nothing but one
    /// outbound hyperlink. In-page jumps are excluded — a blog that links its own
    /// section headings to their permalink anchor is not a rail — as are captions
    /// and rows of an already-identified table of contents.
    private func isFullyLinkedCard(_ block: ArticleContent.Block) -> Bool {
        switch block.kind {
        case .heading, .listItem, .paragraph: break
        case .image, .caption, .quote, .tableOfContents: return false
        }
        guard !block.links.isEmpty, block.text.count < 200,
              linkDensity(of: block) > 0.9,
              block.links.allSatisfy({ !$0.isInPageAnchor })
        else { return false }
        return true
    }

    /// Short labels a site prints above a rail of its own stories. Deliberately a
    /// superset of `recircTerminatorPhrases`: a match here only ever removes the
    /// label itself plus an adjacent all-link run, so it can afford to be broader
    /// than the list that truncates the whole remainder of the article. Matched
    /// EXACTLY (bar a trailing colon), never as a substring.
    private let recircLabelPhrases: Set<String> = [
        "explore more", "more from", "more on", "more in", "more stories",
        "related", "related articles", "related stories", "related coverage",
        "read more", "read next", "up next", "what to read next",
        "recommended", "recommended for you", "you may also like",
        "you might also like", "don't miss", "in case you missed it",
        "most popular", "most read", "trending", "trending now",
        "editor's picks", "editors' picks", "popular stories",
        "around the web", "further reading", "see also",
        "sponsored content", "from our partners", "paid content",
    ]

    private func isRecircLabel(_ block: ArticleContent.Block) -> Bool {
        guard block.kind == .heading || block.kind == .paragraph,
              block.links.isEmpty, wordCount(block.text) <= 6
        else { return false }
        var normalized = block.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while let last = normalized.last, ":.…".contains(last) { normalized.removeLast() }
        return recircLabelPhrases.contains(normalized.trimmingCharacters(in: .whitespaces))
    }

    // MARK: - Phase 2, step 1: terminator hard stop

    /// Comment-section markers: truncate unconditionally once they appear after
    /// substantial body text — a comment thread is never part of the article.
    private let commentTerminatorPhrases: Set<String> = [
        "comments", "post a comment", "leave a reply", "add your comment",
        "join the conversation", "have your say", "reader comments",
        "show comments", "view comments",
    ]

    private static let commentCountRegex = try! NSRegularExpression(
        pattern: "^[0-9]+\\s+comments?\\.?$")

    /// Recirc-rail markers: only truncate if nothing that looks like real article
    /// prose follows — a false-positive heading match (e.g. a genuine "More on this")
    /// subheading ahead of more body text) must not eat the rest of the article.
    private let recircTerminatorPhrases = [
        "related articles", "related stories", "related coverage",
        "recommended for you", "you may also like", "more from", "more on",
        "read next", "up next", "most popular", "most read", "trending",
        "trending now", "editor's picks", "popular stories", "around the web",
        "sponsored content", "further reading",
    ]

    /// Walks blocks in order; once ≥60 words of body text have accumulated, a SHORT
    /// (<15-word) block matching a terminator pattern truncates it and everything
    /// after. `commentTierOnly` scopes this to just the safest (comment) tier, for
    /// the post-arbitration pass applied to every chosen layer, not only refined's.
    private func applyTerminatorHardStop(
        _ blocks: [ArticleContent.Block], commentTierOnly: Bool
    ) -> [ArticleContent.Block] {
        var cumulativeWords = 0
        for index in blocks.indices {
            let block = blocks[index]
            // A ToC row naming a section ("More on this") must never truncate the
            // article, and its words aren't body text that arms the terminator. A
            // caption is skipped for the same two reasons: a photo credit reading
            // "Related Press" is not a rail, and caption words aren't body prose.
            if block.kind == .tableOfContents || block.kind == .caption { continue }
            let words = wordCount(block.text)
            if cumulativeWords >= 60, words < 15 {
                if matchesCommentTerminator(block.text) {
                    return Array(blocks[..<index])
                }
                if !commentTierOnly, matchesRecircTerminator(block.text) {
                    let tail = blocks[(index + 1)...]
                    if !tail.contains(where: { isStrongParagraph($0, minLength: 140) }) {
                        return Array(blocks[..<index])
                    }
                }
            }
            cumulativeWords += words
        }
        return blocks
    }

    private func matchesCommentTerminator(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        if commentTerminatorPhrases.contains(normalized) { return true }
        let range = NSRange(normalized.startIndex..., in: normalized)
        return Self.commentCountRegex.firstMatch(in: normalized, range: range) != nil
    }

    private func matchesRecircTerminator(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        return recircTerminatorPhrases.contains { normalized.contains($0) }
    }

    private func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    // MARK: - Phase 2, step 2: reverse trim

    /// Existing footer/boilerplate phrases, plus recirc/newsletter/account phrases
    /// that show up specifically as the LAST blocks of a page.
    private let reverseTrimJunkPhrases = [
        "all rights reserved", "privacy policy", "terms of service",
        "terms of use", "cookie policy", "subscribe to", "sign up for",
        "follow us", "originally published", "related articles", "©",
        "download our app", "get the newsletter", "sign in", "log in",
        "share this article", "tags:", "topics:",
    ]

    /// From the end: strip a trailing image dump (a run of ≥2 image blocks with no
    /// strong paragraph after or between them), then pop footer-shaped blocks one at
    /// a time, stopping at the first strong paragraph (Readability's sibling-P rule).
    private func reverseTrim(_ blocks: [ArticleContent.Block]) -> [ArticleContent.Block] {
        var trimmed = stripTrailingImageRun(blocks)
        while trimmed.count > 1, isReverseTrimPoppable(trimmed[trimmed.count - 1]) {
            trimmed.removeLast()
        }
        return trimmed
    }

    /// A block clears "strong paragraph" — real prose, not a caption/label/link
    /// list — at `minLength`: long enough, low link density, ends a sentence. Two
    /// callers use two different lengths: 140 chars gates whether a recirc terminator
    /// or a trailing image run may truncate/trim; 80 chars is the (shorter) bar the
    /// reverse trim stops at, matching Readability's sibling-paragraph rule.
    private func isStrongParagraph(_ block: ArticleContent.Block, minLength: Int) -> Bool {
        // A long caption often reads exactly like prose (it ends in a full stop and
        // links nothing), but it belongs to a picture — so it must not be what stops
        // a trailing image dump from being swept, or the dump survives behind it.
        guard block.kind != .image, block.kind != .caption,
              block.text.count >= minLength, linkDensity(of: block) < 0.25
        else { return false }
        return hasSentenceEndingPunctuation(block.text)
    }

    /// Finds the maximal trailing run of blocks that are either images or non-strong
    /// (weak/junk) text — stopping at the first strong (≥140-char) paragraph or the
    /// hero at index 0 — and removes the whole run if it holds ≥2 images. A run with
    /// 0 or 1 images is left alone: a single trailing image (a legit closing photo,
    /// especially one right after the last real paragraph) is never swept by this rule.
    private func stripTrailingImageRun(_ blocks: [ArticleContent.Block]) -> [ArticleContent.Block] {
        guard blocks.count > 1 else { return blocks }
        var zoneStart = blocks.count
        var index = blocks.count - 1
        while index > 0 {
            let block = blocks[index]
            if block.kind != .image, isStrongParagraph(block, minLength: 140) { break }
            zoneStart = index
            index -= 1
        }
        guard zoneStart < blocks.count else { return blocks }
        let imagesInZone = blocks[zoneStart...].filter { $0.kind == .image }.count
        guard imagesInZone >= 2 else { return blocks }
        return Array(blocks[..<zoneStart])
    }

    /// Any image reaching this point already survived `stripTrailingImageRun`
    /// (a lone trailing image, or one preceded by a strong paragraph), so it's kept.
    private func isReverseTrimPoppable(_ block: ArticleContent.Block) -> Bool {
        if block.kind == .image { return false }
        // Some blogs close with their chapter marks; the link-density rules below
        // would pop an identified ToC off row by row.
        if block.kind == .tableOfContents { return false }
        // A caption is bound to the image above it, which by this point has already
        // been kept — popping the caption alone would leave that picture unexplained.
        // (Photo credits routinely carry a "©", which the phrase list below matches.)
        if block.kind == .caption { return false }
        let trimmedText = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedText.isEmpty { return true }
        if block.kind == .heading { return true } // trailing headings are junk (trafilatura)

        let density = linkDensity(of: block)
        if block.text.count < 200, density > 0.33 { return true }
        if block.text.count < 400, density > 0.5 { return true }

        let lowered = trimmedText.lowercased()
        if block.text.count < 200, reverseTrimJunkPhrases.contains(where: lowered.contains) {
            return true
        }
        if block.kind == .listItem, block.text.count < 80, !block.links.isEmpty { return true }
        return false
    }

    // MARK: - Shared block metrics

    private func linkDensity(of block: ArticleContent.Block) -> Double {
        let length = block.text.utf16.count
        guard length > 0 else { return 0 }
        let linkedLength = block.links.reduce(0) { $0 + $1.length }
        return Double(linkedLength) / Double(length)
    }

    /// True when `text`, trimmed of trailing quote/bracket punctuation, ends in a
    /// sentence terminator — the other half of "strong paragraph".
    private func hasSentenceEndingPunctuation(_ text: String) -> Bool {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = trimmed.last, "\"')]".contains(last) { trimmed.removeLast() }
        guard let last = trimmed.last else { return false }
        return ".!?".contains(last)
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
        return L10n.string("Common_untitled")
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

    // MARK: - Conditional container cleaning

    /// A conservative pass (Readability's `cleanConditionally` / trafilatura's
    /// list-density rule) run on the chosen container BEFORE block emission, so a
    /// link-farm list or an image grid never becomes a block at all: a `<ul>`/`<ol>`
    /// that's mostly links and barely any text, or a `<div>`/`<section>` that's an
    /// image grid with almost no accompanying prose. Anything inside a `<figure>` is
    /// left alone — a caption belongs with its image. Both gates are deliberately
    /// tight (total text length, own text length) so a real editorial list or a
    /// figure-free photo-and-caption block survives untouched.
    private func cleanConditionally(in container: Element) throws {
        for list in try container.select("ul, ol") {
            if isInsideFigure(list) { continue }
            // A table of contents IS a link-dense short list — the one such list
            // that is content rather than a link farm.
            if InPageAnchors.isProtected(list) || InPageAnchors.isInsideTableOfContents(list) {
                continue
            }
            let text = (try? list.text()) ?? ""
            guard !text.isEmpty, text.count < 500 else { continue }
            guard listLinkDensity(of: list, text: text) > 0.8 else { continue }
            try list.remove()
        }
        for element in try container.select("div, section") {
            if isInsideFigure(element) { continue }
            let imageCount = (try? element.select("img").count) ?? 0
            guard imageCount > 1 else { continue }
            let paragraphCount = (try? element.select("p").count) ?? 0
            guard Double(paragraphCount) / Double(imageCount) < 0.5 else { continue }
            let ownText = (try? element.text()) ?? ""
            guard ownText.count < 200 else { continue }
            try element.remove()
        }
    }

    private func isInsideFigure(_ element: Element) -> Bool {
        var parent = element.parent()
        while let current = parent {
            if current.tagName() == "figure" { return true }
            parent = current.parent()
        }
        return false
    }

    private func listLinkDensity(of list: Element, text: String) -> Double {
        guard !text.isEmpty else { return 0 }
        let linkText = ((try? list.select("a").array()) ?? [])
            .reduce("") { $0 + (((try? $1.text()) ?? "")) }
        return Double(linkText.count) / Double(text.count)
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

    /// `figcaption` is a block like any other so that a picture's caption becomes a
    /// block of its own (emitted right after its image, since `select` walks the
    /// document in order) instead of being dropped on the floor — it is in no other
    /// selector, so before this the reader silently lost every caption on the page.
    /// Listing it here also means a `<p>` or `<img>` nested inside a caption is
    /// skipped by `hasBlockAncestor` rather than emitted a second time.
    private let blockTags: Set<String> = [
        "p", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "li", "pre", "figcaption",
    ]

    /// Child tags that disqualify a `<div>`/`<section>` from being a single
    /// paragraph (their presence means the element is a structural container).
    private let blockLevelChildTags: Set<String> = [
        "div", "p", "section", "article", "aside", "header", "footer", "nav", "main",
        "ul", "ol", "li", "table", "thead", "tbody", "tr", "td", "blockquote",
        "figure", "figcaption", "form", "pre", "h1", "h2", "h3", "h4", "h5", "h6",
    ]

    /// Tags that END the line they appear on, so the text on either side of them is
    /// never visually adjacent. A block's walk concatenates the text nodes it finds,
    /// and markup routinely puts no whitespace character around these — Paris Review
    /// separates the paragraphs of a quoted passage with `…his feeling.<br><br>The
    /// discipline…`, and a `<p>` nested in a `<blockquote>` is walked as part of that
    /// one quote block — so without a synthesized boundary the reader showed
    /// "feeling.The discipline". `img` is here because images are lifted out into
    /// their own blocks, which leaves the text that surrounded them adjacent.
    private static let lineBreakingTags: Set<String> = [
        "br", "hr", "img", "p", "div", "section", "article", "aside", "header",
        "footer", "nav", "main", "figure", "figcaption", "blockquote", "pre",
        "ul", "ol", "li", "dl", "dt", "dd", "table", "thead", "tbody", "tfoot",
        "tr", "td", "th", "caption", "h1", "h2", "h3", "h4", "h5", "h6",
        "address", "fieldset", "form", "hgroup", "details", "summary",
    ]

    private func extractBlocks(
        from container: Element, baseURL: URL, anchors: Set<String> = []
    ) throws -> [ArticleContent.Block] {
        var blocks: [ArticleContent.Block] = []
        /// Destination ids are handed out once, so a `<section id="intro">`'s
        /// anchor lands on its heading instead of on every paragraph inside it.
        var claimedAnchors = Set<String>()
        let selector = blockTags.joined(separator: ", ")
            + ", div, section, img, [\(InPageAnchors.marker)]"
        for element in try container.select(selector) {
            // The page's own chapter marks, emitted one row per jump straight from
            // the anchors — the generic walk below would collapse a two-level ToC
            // into a single bullet, because a nested <li> has a block ancestor.
            if InPageAnchors.isTableOfContentsRoot(element) {
                blocks.append(contentsOf: InPageAnchors.blocks(
                    forTableOfContentsRoot: element, baseURL: baseURL, resolvable: anchors))
                continue
            }
            if InPageAnchors.isInsideTableOfContents(element) { continue }
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
            var (block, nestedImages) = makeBlock(from: element, baseURL: baseURL, anchors: anchors)
            if block != nil {
                block?.anchorID = InPageAnchors.anchorID(
                    for: element, within: container,
                    resolvable: anchors, claimed: &claimedAnchors)
            }
            if let block {
                blocks.append(block)
            }
            blocks.append(contentsOf: nestedImages)
        }
        return blocks
    }

    // MARK: - Images

    /// Roughly two screen heights of reader prose, measured in characters. The
    /// extractor has no typography, and the lead-image rule below only needs an
    /// order-of-magnitude answer to "does this article open on a wall of text".
    private static let leadImageProseBudget = 1400

    /// Inserts the highest-priority Open Graph/Twitter lead image at the top of
    /// the article — but ONLY when the body has no picture of its own in its first
    /// couple of screens. A hero stacked directly above (or a few lines from) the
    /// same photo in the content reads as a rendering glitch, and an unrelated
    /// second picture that close is no better. If the lead image only appears
    /// deeper down, it's moved up rather than shown twice.
    private func prependLeadImage(
        from document: Document, to blocks: inout [ArticleContent.Block], baseURL: URL
    ) {
        guard let leadURL = leadImageURL(from: document, baseURL: baseURL),
              !hasImageNearTop(of: blocks)
        else { return }
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

    /// Whether an image block falls within the first ~two screen heights of content.
    private func hasImageNearTop(of blocks: [ArticleContent.Block]) -> Bool {
        var prose = 0
        for block in blocks {
            if block.kind == .image { return true }
            prose += block.text.count
            if prose >= Self.leadImageProseBudget { return false }
        }
        return false
    }

    /// Metadata selectors are deliberately attribute-order independent. Several
    /// publishers use `og:image:secure_url`; large images are often only in
    /// `twitter:image:src`.
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
        // SVGs cannot be decoded by the offline raster-image pipeline. GIFs are
        // deliberately retained: the reader stores their original animation and
        // presents it inline (including when metadata promotes one to lead art).
        if URL(string: urlString)?.pathExtension.lowercased() == "svg" { return nil }

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
        let dimensions = declaredImageDimensions(from: element)
        return ArticleContent.Block(
            kind: .image, text: "", links: [], imageURLString: urlString,
            imageWidth: dimensions?.width, imageHeight: dimensions?.height)
    }

    private func declaredImageDimensions(from element: Element) -> (width: Int, height: Int)? {
        let width = declaredImageDimension(from: element, names: ["width", "data-width"])
        let height = declaredImageDimension(from: element, names: ["height", "data-height"])
        guard let width, let height, width >= 140, height >= 140 else { return nil }
        return (width, height)
    }

    private func declaredImageDimension(from element: Element, names: [String]) -> Int? {
        for name in names {
            guard let raw = try? element.attr(name), !raw.isEmpty else { continue }
            let digits = raw.prefix { $0.isNumber }
            if let value = Int(digits), value > 0 { return value }
        }
        return nil
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
        from element: Element, baseURL: URL, anchors: Set<String> = []
    ) -> (ArticleContent.Block?, [ArticleContent.Block]) {
        var text = ""
        var links: [ArticleContent.Link] = []
        var nestedImages: [ArticleContent.Block] = []
        /// In-page destination per link URL, for the anchors this block links to.
        /// A footnote marker in prose is the same mechanism as a ToC row, and gets
        /// the same treatment: a jump, not a navigation back to the live page.
        var anchorIDsByURL: [String: String] = [:]

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

        /// Stands in for a line break the markup expressed structurally rather than
        /// with a whitespace character. Collapses against what's already there, so
        /// real whitespace on either side of the break still yields ONE space, and
        /// it never leads the block. Appended between text nodes, so it shifts no
        /// already-recorded link range.
        func appendLineBreak() {
            guard !text.isEmpty, !text.hasSuffix(" ") else { return }
            text += " "
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
            let breaksLine = Self.lineBreakingTags.contains(child.tagName())
            if breaksLine { appendLineBreak() }
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
                if let fragment = InPageAnchors.fragment(ofLink: child, baseURL: baseURL),
                   anchors.contains(fragment) {
                    anchorIDsByURL[href] = fragment
                }
            }
            for grandchild in child.getChildNodes() {
                walk(grandchild, linkURL: childLink)
            }
            if breaksLine { appendLineBreak() }
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
            clamped.anchorID = anchorIDsByURL[link.urlString]
            return clamped.length > 0 ? clamped : nil
        }

        let kind: ArticleContent.Block.Kind
        switch element.tagName() {
        case "figcaption": kind = .caption
        case "h1", "h2", "h3", "h4", "h5", "h6": kind = .heading
        case "blockquote": kind = .quote
        case "li": kind = .listItem
        // Text sitting inside a `<figure>` IS that figure's caption, whatever tag
        // carries it — WordPress and several CMSs emit `<figure><p class=…-caption>`
        // rather than a `<figcaption>`. Structural, so there is no wording to guess.
        default: kind = isInsideFigure(element) ? .caption : .paragraph
        }
        return (ArticleContent.Block(kind: kind, text: text, links: links), nestedImages)
    }
}

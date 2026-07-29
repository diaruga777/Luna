//
//  XPostExtractor.swift
//  LunaArticleIngest
//

import LunaModels
import Foundation

/// Turns a decoded `XPostPayload` into reader `ArticleContent` — or nil when the
/// post isn't long enough to be worth reading. Pure: no network, no UIKit, so the
/// whole policy is unit-testable from fixtures (`XPostExtractorTests`).
///
/// ## Two long-form tiers, in order
///
/// 1. **X Article** (`post.article`) — the premium long-form editor. It carries a
///    real title and a Draft.js body, so its presence alone establishes long-form
///    and the length threshold is not applied.
/// 2. **Post text** (a single long post, or an unrolled self-thread) — accepted
///    only when the assembled body reaches `minimumBodyTextLength`.
///
/// ## Why `is_note_tweet` is not the gate
///
/// X does expose a long/short flag, and deferring to the platform's own
/// distinction would be preferable to a length heuristic — but measured against
/// live posts the flag does not carry that meaning. `is_note_tweet` marks "composed
/// in the note editor", which X now sets for ordinary posts too: a 280-character
/// one-liner comes back `is_note_tweet: true`, i.e. the flag is true at the exact
/// length an ordinary tweet caps out at. It therefore cannot separate a readable
/// essay from a quip, and a length threshold on the assembled body is the honest
/// gate. The flag is left decoded (it is genuine platform signal) but is not read
/// as a decision.
public enum XPostExtractor {

    /// Minimum assembled body length for a text post to become a reader item.
    ///
    /// Deliberately far above X's 280-character ordinary-post cap, so no
    /// single normal tweet can clear it no matter how it was composed, while a
    /// genuine long-form post or a short chained thread does. Image blocks
    /// contribute no text, so this measures prose only.
    ///
    /// Distinct from `ArticleContent.readableBodyThreshold` (1200), which
    /// calibrates "did HTML extraction get a real article or a paywall stub" —
    /// a different question about a different input. A 700-character standalone
    /// essay post is a legitimate reader item; a 700-character *web page*
    /// extraction is usually a stub.
    public static let minimumBodyTextLength = 600

    /// Builds reader content for the post `url` names, or nil when the payload
    /// carries nothing (long enough) to read.
    public static func article(from payload: XPostPayload, url: URL) -> ArticleContent? {
        let posts = authorThread(in: payload)
        guard !posts.isEmpty else { return nil }

        // A post the user shared BECAUSE it holds a video stays media: turning it
        // into a reader article would strip the download the save was for. Judged on
        // the post the URL actually named, not the whole chain — a long essay thread
        // that happens to contain one clip further down is still an essay, and its
        // own video remains reachable from the post itself.
        if payload.sharedPost?.media?.hasMotionMedia == true { return nil }

        let byline = payload.rootAuthor?.byline ?? posts.first?.author?.byline

        // Tier 1 — an X Article anywhere in the chain (the URL may name the post
        // that introduces it). Its own title and body win outright.
        if let hosted = posts.compactMap(\.article).first,
           let content = draftBlocks(from: hosted.content), !content.isEmpty {
            let title = hosted.title?.trimmedNonEmptyValue
                ?? derivedTitle(from: content, fallbackURL: url)
            return ArticleContent(title: title, author: byline, blocks: content)
        }

        // Tier 2 — the post text / unrolled thread, gated on length.
        let texts = strippingThreadCounters(posts.map { $0.text ?? "" })
        var blocks: [ArticleContent.Block] = []
        for (post, text) in zip(posts, texts) {
            blocks.append(contentsOf: textBlocks(from: text))
            blocks.append(contentsOf: imageBlocks(from: post))
        }
        guard !blocks.isEmpty else { return nil }

        let candidate = ArticleContent(
            title: derivedTitle(from: blocks, fallbackURL: url), author: byline, blocks: blocks)
        guard candidate.bodyTextLength >= minimumBodyTextLength else { return nil }
        return candidate
    }

    // MARK: - Thread assembly

    /// The chain to read: the payload's posts in order, de-duplicated by id and
    /// limited to the ROOT AUTHOR's own posts.
    ///
    /// `/2/thread` already unrolls author-only and in order, from any member of the
    /// chain — but the author filter is kept as a guard so a payload that ever
    /// includes other people's replies (a conversation response, a future shape
    /// change) can't splice strangers' text into someone's saved article.
    static func authorThread(in payload: XPostPayload) -> [XPostPayload.Post] {
        let posts = payload.posts
        guard let root = payload.rootAuthor ?? posts.first?.author else { return posts }
        var seen = Set<String>()
        return posts.filter { post in
            guard sameAuthor(post.author, root) else { return false }
            guard let id = post.id else { return true }
            return seen.insert(id).inserted
        }
    }

    /// Author identity by id when both sides carry one (handles are renameable),
    /// else by case-insensitive handle. A post with no author at all is kept: a
    /// single-post payload often omits the per-post author.
    private static func sameAuthor(_ lhs: XPostPayload.Author?, _ rhs: XPostPayload.Author) -> Bool {
        guard let lhs else { return true }
        if let left = lhs.id?.trimmedNonEmptyValue, let right = rhs.id?.trimmedNonEmptyValue {
            return left == right
        }
        guard let left = lhs.screen_name?.trimmedNonEmptyValue,
              let right = rhs.screen_name?.trimmedNonEmptyValue else { return true }
        return left.caseInsensitiveCompare(right) == .orderedSame
    }

    // MARK: - Thread counter stripping ("1/n", "3/5", 🧵)

    /// Removes the poster's own position markers from each post of a chain, so an
    /// assembled thread reads as continuous prose instead of "… 1/7" between every
    /// paragraph. People without a long-form composer number threads by hand, in
    /// the tweet body, which is the only place this information lives.
    ///
    /// Two shapes, with deliberately different confidence:
    ///
    ///   • **Open-ended** (`1/`, `2/n`, `4/?`) — a numerator over no denominator is
    ///     never prose, so it is always stripped.
    ///   • **Closed** (`3/5`, `(2/7)`, `1.`) — indistinguishable from an ordinary
    ///     fraction ("1/2 cup", "9/11"), so it is stripped ONLY when the chain
    ///     shows a real scheme: at least two posts carry one AND their numerators
    ///     strictly ascend. A lone "1/2" in one post is left as written.
    ///
    /// Only the very start and very end of a post are considered — a marker mid-
    /// sentence is prose.
    static func strippingThreadCounters(_ texts: [String]) -> [String] {
        var closedNumerators: [Int] = []
        for text in texts {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let match = counterMatch(in: trimmed), !match.isOpenEnded {
                closedNumerators.append(match.numerator)
            }
        }
        let ascending = closedNumerators.count >= 2
            && zip(closedNumerators, closedNumerators.dropFirst()).allSatisfy { $0 < $1 }

        return texts.map { text in
            var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // A post can carry a marker at both ends; strip until neither end has one.
            for _ in 0..<2 {
                guard let match = counterMatch(in: result) else { break }
                guard match.isOpenEnded || ascending else { break }
                result = (result as NSString).replacingCharacters(in: match.range, with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return stripThreadOrnaments(result)
        }
    }

    /// One position marker found at the start or end of `text`.
    struct CounterMatch {
        let range: NSRange
        let numerator: Int
        /// `1/`, `2/n`, `3/?` — no denominator, so unambiguous.
        let isOpenEnded: Bool
    }

    /// `<num>/<denominator-or-n-or-nothing>`, optionally bracketed, anchored to
    /// either end of the string. The leading form also accepts a bare ordinal
    /// ("1." / "2)"), which only ever strips under the ascending-scheme rule.
    private static let counterPatterns: [String] = [
        // Leading "1/7", "(2/n)", "3/" + optional trailing punctuation.
        #"^[\(\[]?\s*(\d{1,3})\s*/\s*(\d{1,3}|[nNxX?])?\s*[\)\]]?\s*(?:[–—\-.:)]|\s)\s*"#,
        // Leading bare ordinal "1." / "2)".
        #"^(\d{1,3})()\s*[.)]\s+"#,
        // Trailing "… 4/7", "… (5/n)", "… 6/".
        #"[\s–—\-\(\[]+(\d{1,3})\s*/\s*(\d{1,3}|[nNxX?])?\s*[\)\]]?\s*[.]?\s*$"#,
    ]

    private static let counterExpressions: [NSRegularExpression] = counterPatterns.compactMap {
        try? NSRegularExpression(pattern: $0)
    }

    private static func counterMatch(in text: String) -> CounterMatch? {
        let subject = text as NSString
        let whole = NSRange(location: 0, length: subject.length)
        for expression in counterExpressions {
            guard let match = expression.firstMatch(in: text, range: whole) else { continue }
            guard let numerator = Int(subject.substring(with: match.range(at: 1))) else { continue }
            // Stripping must never consume the entire post.
            guard match.range.length < subject.length else { continue }
            let denominator = match.range(at: 2).location == NSNotFound
                ? "" : subject.substring(with: match.range(at: 2))
            if let total = Int(denominator), numerator > total { continue }
            let isOpenEnded = denominator.isEmpty || Int(denominator) == nil
            return CounterMatch(range: match.range, numerator: numerator, isOpenEnded: isOpenEnded)
        }
        return nil
    }

    /// Thread furniture that carries no meaning once the chain is one document:
    /// the thread emoji and an explicit end marker.
    private static func stripThreadOrnaments(_ text: String) -> String {
        var result = text
        for pattern in [#"^\s*🧵\s*"#, #"\s*🧵\s*$"#, #"\s*/{1,2}(?:end|fin|END|FIN)\s*[.!]?\s*$"#] {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(location: 0, length: (result as NSString).length)
            guard let match = expression.firstMatch(in: result, range: range),
                  match.range.length < (result as NSString).length else { continue }
            result = (result as NSString).replacingCharacters(in: match.range, with: "")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Post text → blocks

    /// One post's text as reader blocks: each non-empty line becomes a block,
    /// since posts use hard line breaks where prose would use paragraphs.
    static func textBlocks(from text: String) -> [ArticleContent.Block] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { line in
                let (kind, stripped) = listItem(in: line)
                return ArticleContent.Block(
                    kind: kind, text: stripped, links: inlineLinks(in: stripped))
            }
    }

    /// A bulleted line → `.listItem` with the marker removed. Numeric markers are
    /// deliberately NOT treated as bullets: they overlap with thread counters.
    private static func listItem(in line: String) -> (ArticleContent.Block.Kind, String) {
        for marker in ["- ", "– ", "— ", "• ", "* ", "‣ ", "· "] where line.hasPrefix(marker) {
            let stripped = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            if !stripped.isEmpty { return (.listItem, stripped) }
        }
        return (.paragraph, line)
    }

    /// Still images attached to a post, in order. Videos are skipped — a video
    /// attachment is the Downloader's content, not reader prose.
    static func imageBlocks(from post: XPostPayload.Post) -> [ArticleContent.Block] {
        (post.media?.photos ?? []).compactMap { photo in
            guard let url = photo.url?.trimmedNonEmptyValue else { return nil }
            return ArticleContent.Block(
                kind: .image, text: "", links: [], imageURLString: url,
                imageWidth: photo.width, imageHeight: photo.height)
        }
    }

    /// Bare URLs in a post's text, as inline links. fxtwitter has already expanded
    /// every `t.co` in place, so the visible text IS the destination and the ranges
    /// line up with what the reader renders.
    static func inlineLinks(in text: String) -> [ArticleContent.Link] {
        guard let expression = try? NSRegularExpression(pattern: #"https?://[^\s<>"]+"#) else { return [] }
        let subject = text as NSString
        return expression
            .matches(in: text, range: NSRange(location: 0, length: subject.length))
            .compactMap { match in
                var range = match.range
                // Don't swallow sentence punctuation that merely follows the URL.
                while range.length > 0,
                      let last = subject.substring(with: NSRange(location: range.location + range.length - 1, length: 1)).last,
                      ".,;:!?)]\"'".contains(last) {
                    range.length -= 1
                }
                guard range.length > 0 else { return nil }
                return ArticleContent.Link(
                    start: range.location, length: range.length,
                    urlString: subject.substring(with: range))
            }
    }

    // MARK: - X Article (Draft.js) → blocks

    /// Draft.js raw content as reader blocks, mapping block types onto the reader's
    /// own kinds and resolving `entityRanges` against the entity table for links.
    static func draftBlocks(from content: XPostPayload.DraftContent?) -> [ArticleContent.Block]? {
        guard let content, let blocks = content.blocks else { return nil }
        let linkURLs = content.linkURLsByKey
        let mapped: [ArticleContent.Block] = blocks.compactMap { block in
            guard let raw = block.text else { return nil }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            // Entity offsets are relative to the UNTRIMMED text, so trimming the
            // leading whitespace shifts each of them by that prefix's UTF-16 width.
            let shift = raw.prefix { $0.isWhitespace || $0.isNewline }
                .unicodeScalars.reduce(0) { $0 + UTF16.width($1) }
            return ArticleContent.Block(
                kind: draftKind(block.type), text: text,
                links: draftLinks(in: block, text: text, shift: shift, linkURLs: linkURLs))
        }
        return mapped.isEmpty ? nil : mapped
    }

    private static func draftKind(_ type: String?) -> ArticleContent.Block.Kind {
        switch type?.lowercased() {
        case "header-one", "header-two", "header-three",
             "header-four", "header-five", "header-six":
            return .heading
        case "blockquote", "pullquote":
            return .quote
        case "unordered-list-item", "ordered-list-item":
            return .listItem
        default:
            return .paragraph
        }
    }

    /// A Draft.js block's `LINK` entity ranges, plus any bare URL left in the text.
    /// Draft offsets are UTF-16 code units, matching `ArticleContent.Link`; `shift`
    /// is the UTF-16 width of the leading whitespace the caller trimmed off `text`.
    /// A range that lands outside the trimmed text is dropped rather than clamped —
    /// a wrong link range would mislink visible words.
    private static func draftLinks(
        in block: XPostPayload.DraftBlock, text: String, shift: Int, linkURLs: [Int: String]
    ) -> [ArticleContent.Link] {
        let length = (text as NSString).length
        var links: [ArticleContent.Link] = (block.entityRanges ?? []).compactMap { range in
            guard let key = range.key, let urlString = linkURLs[key],
                  let offset = range.offset, let span = range.length, span > 0 else { return nil }
            let start = offset - shift
            guard start >= 0, start + span <= length else { return nil }
            return ArticleContent.Link(start: start, length: span, urlString: urlString)
        }
        // An X Article can also carry a plain URL in its text with no entity behind
        // it; add those, skipping any that would overlap an entity link.
        for bare in inlineLinks(in: text)
        where !links.contains(where: { $0.start < bare.start + bare.length && bare.start < $0.start + $0.length }) {
            links.append(bare)
        }
        return links.sorted { $0.start < $1.start }
    }

    // MARK: - Title

    /// Posts have no title, so one is derived: the first sentence of the opening
    /// paragraph, capped to a card-sized length. Falls back to the author's handle
    /// from the URL when there is no usable prose (an image-only opener).
    static func derivedTitle(from blocks: [ArticleContent.Block], fallbackURL: URL) -> String {
        let opening = blocks.first { $0.kind != .image && !$0.text.isEmpty }?.text
        guard let opening, !opening.isEmpty else { return fallbackTitle(for: fallbackURL) }

        // First sentence, when it ends early enough to read as a title.
        if let end = opening.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?")) {
            let sentence = String(opening[opening.startIndex..<end.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if (12...maximumTitleLength).contains(sentence.count) { return sentence }
        }
        guard opening.count > maximumTitleLength else { return opening }
        // Otherwise cut on a word boundary.
        let clipped = opening.prefix(maximumTitleLength)
        let boundary = clipped.lastIndex(of: " ") ?? clipped.endIndex
        return String(clipped[clipped.startIndex..<boundary])
            .trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private static let maximumTitleLength = 90

    /// "Post by @handle" — used only when a post opens with no readable prose.
    private static func fallbackTitle(for url: URL) -> String {
        let segments = Array(url.pathComponents.dropFirst())
        guard let statusIndex = segments.firstIndex(where: { $0 == "status" || $0 == "statuses" }),
              statusIndex >= 1, !segments[statusIndex - 1].isEmpty else { return "Post on X" }
        return "Post by @\(segments[statusIndex - 1])"
    }
}

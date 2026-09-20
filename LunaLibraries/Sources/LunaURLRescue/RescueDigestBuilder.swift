//
//  RescueDigestBuilder.swift
//  LunaURLRescue
//

import Foundation
import LunaModels
import LunaHTMLClassification
import SwiftSoup

/// A character budget for a digest, sized to a model tier's context window. The
/// on-device window is ~4096 tokens (8192 on newer OS); PCC is ~32k. Using a
/// crude chars/4 token estimate, `.onDevice` leaves generous headroom for the
/// static instructions + the model's own reply.
public struct RescueDigestBudget: Equatable {
    public let maxCharacters: Int
    public init(maxCharacters: Int) { self.maxCharacters = maxCharacters }

    /// ~2.2k tokens — safe inside the 4096-token on-device window.
    public static let onDevice = RescueDigestBudget(maxCharacters: 9_000)
    /// ~20k tokens — inside the ~32k PCC window with room for the article reply.
    public static let privateCloud = RescueDigestBudget(maxCharacters: 80_000)

    public static func estimatedTokens(forCharacters n: Int) -> Int { (n + 3) / 4 }

    var halved: RescueDigestBudget { RescueDigestBudget(maxCharacters: max(1_000, maxCharacters / 2)) }
}

/// Reduces arbitrary page HTML to a token-budgeted, model-readable digest.
/// Pure and never-throws (degrades to a raw-text prefix on parse failure).
///
/// Section order + proportional budgets (unused budget rolls forward):
///   1. head metadata (10%)   — title, description, og/twitter, canonical, amp, alternate
///   2. JSON-LD (30%)         — Product/Article/VideoObject ranked first
///   3. embedded app JSON (20%) — __NEXT_DATA__ / application/json, plus grepped media URLs
///   4. visible text (30%)    — body text minus script/style/nav/footer/header/aside/form
///   5. candidate URLs (10%)  — canonical/amp/og:video/iframe/video/source + same-host amp|print|embed|oembed links
public struct RescueDigestBuilder {
    public init() {}

    public func buildDigest(
        url: URL, html: String, budget: RescueDigestBudget
    ) -> String {
        guard let document = try? SwiftSoup.parse(html, url.absoluteString) else {
            return String(html.prefix(budget.maxCharacters))
        }

        let total = budget.maxCharacters
        // Each section gets its proportional share PLUS whatever earlier sections
        // left unused (carry), all clamped to the global remaining budget.
        let plan: [(title: String, body: String, share: Double)] = [
            ("METADATA", headMetadata(document), 0.10),
            ("STRUCTURED DATA (JSON-LD)", jsonLD(document), 0.30),
            ("EMBEDDED JSON", embeddedJSON(document, html: html), 0.20),
            ("VISIBLE TEXT", visibleText(document), 0.30),
            ("CANDIDATE URLS", candidateURLs(document, pageURL: url), 0.10),
        ]

        var sections: [String] = []
        var used = 0
        var carry = 0
        for entry in plan {
            let remaining = total - used
            guard remaining > 0 else { break }
            let allowance = Int(Double(total) * entry.share) + carry
            let cap = min(max(allowance, 0), remaining)
            let trimmed = String(entry.body.prefix(cap))
            let clean = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.isEmpty {
                // Nothing here — its whole allowance carries forward.
                carry = allowance
                continue
            }
            sections.append("## \(entry.title)\n\(trimmed)")
            used += trimmed.count
            carry = max(0, allowance - trimmed.count)
        }

        let digest = sections.joined(separator: "\n\n")
        return digest.isEmpty ? String(html.prefix(total)) : String(digest.prefix(total))
    }

    // MARK: - Sections

    private func headMetadata(_ document: Document) -> String {
        var lines: [String] = []
        if let title = try? document.title(), !title.isEmpty { lines.append("title: \(title)") }
        func meta(_ selector: String, attr: String = "content", labelAttr: String? = nil, label: String? = nil) {
            guard let els = try? document.select(selector) else { return }
            for el in els {
                let value = ((try? el.attr(attr)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { continue }
                let key: String
                if let labelAttr, let l = try? el.attr(labelAttr), !l.isEmpty { key = l }
                else { key = label ?? selector }
                lines.append("\(key): \(value)")
            }
        }
        meta("meta[name=description]", label: "description")
        meta("meta[property^=og:]", labelAttr: "property")
        meta("meta[name^=twitter:]", labelAttr: "name")
        meta("link[rel=canonical]", attr: "href", label: "canonical")
        meta("link[rel=amphtml]", attr: "href", label: "amphtml")
        meta("link[rel=alternate]", attr: "href", label: "alternate")
        return lines.joined(separator: "\n")
    }

    private func jsonLD(_ document: Document) -> String {
        guard let scripts = try? document.select("script[type=application/ld+json]") else { return "" }
        var blobs: [(rank: Int, text: String)] = []
        for script in scripts {
            let raw = ((try? script.html()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { continue }
            let collapsed = collapseWhitespace(raw)
            let rank = jsonLDRank(collapsed)
            blobs.append((rank, collapsed))
        }
        return blobs.sorted { $0.rank < $1.rank }.map(\.text).joined(separator: "\n")
    }

    private func jsonLDRank(_ text: String) -> Int {
        if text.contains("\"Product\"") || text.contains("\"offers\"") { return 0 }
        if text.contains("\"NewsArticle\"") || text.contains("\"Article\"") { return 1 }
        if text.contains("\"VideoObject\"") { return 2 }
        return 3
    }

    private func embeddedJSON(_ document: Document, html: String) -> String {
        var parts: [String] = []
        // Surface likely media URLs first — grep the raw HTML for the tokens
        // public downloaders key on. The model cannot classify a page as media
        // if the digest never shows it the media, and the lines are cheap
        // (capped at 20).
        let mediaLines = html.split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { String($0) }
            .filter { line in
                ["mp4", "m3u8", "playable_url", "video_url", "hd_src", "sd_src"].contains { line.contains($0) }
            }
            .prefix(20)
        if !mediaLines.isEmpty { parts.append(mediaLines.joined(separator: "\n")) }
        let blobs = EmbeddedJSONBlobs.nextDataAndJSONScripts(in: document)
            .map { collapseWhitespace($0) }
        parts.append(contentsOf: blobs)
        return parts.joined(separator: "\n")
    }

    private func visibleText(_ document: Document) -> String {
        guard let body = document.body() else { return "" }
        // Work on a clone so we don't mutate the document other sections read.
        guard let clone = body.copy() as? Element else {
            return collapseWhitespace((try? body.text()) ?? "")
        }
        if let junk = try? clone.select("script, style, nav, footer, header, aside, form, noscript") {
            _ = try? junk.remove()
        }
        return collapseWhitespace((try? clone.text()) ?? "")
    }

    private func candidateURLs(_ document: Document, pageURL: URL) -> String {
        var seen = Set<String>()
        var lines: [String] = []
        let host = pageURL.host?.lowercased() ?? ""

        func add(_ tag: String, _ value: String?) {
            guard let value, !value.isEmpty, seen.insert(value).inserted else { return }
            lines.append("\(tag): \(value)")
        }
        func absURLs(_ selector: String, attr: String, tag: String) {
            guard let els = try? document.select(selector) else { return }
            for el in els {
                let v = (try? el.absUrl(attr)) ?? ((try? el.attr(attr)) ?? "")
                add(tag, v)
                if lines.count >= 30 { return }
            }
        }
        add("canonical", try? document.select("link[rel=canonical]").first()?.absUrl("href"))
        add("amphtml", try? document.select("link[rel=amphtml]").first()?.absUrl("href"))
        add("og:video", try? document.select("meta[property=og:video]").first()?.attr("content"))
        add("og:video:url", try? document.select("meta[property=og:video:url]").first()?.attr("content"))
        add("og:image", try? document.select("meta[property=og:image]").first()?.attr("content"))
        absURLs("iframe[src]", attr: "src", tag: "iframe")
        absURLs("video[src]", attr: "src", tag: "video")
        absURLs("source[src]", attr: "src", tag: "source")

        if lines.count < 30, let anchors = try? document.select("a[href]") {
            for a in anchors {
                let href = (try? a.absUrl("href")) ?? ""
                guard !href.isEmpty, let u = URL(string: href), (u.host?.lowercased() ?? "") == host || (u.host?.lowercased() ?? "").hasSuffix(host) else { continue }
                let lower = href.lowercased()
                guard ["amp", "print", "embed", "/api/", "oembed"].contains(where: { lower.contains($0) }) else { continue }
                add("link", href)
                if lines.count >= 30 { break }
            }
        }
        return lines.prefix(30).joined(separator: "\n")
    }

    // MARK: - Helpers

    private func collapseWhitespace(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

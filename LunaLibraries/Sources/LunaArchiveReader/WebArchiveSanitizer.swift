//
//  WebArchiveSanitizer.swift
//  Luna
//

import Foundation
import LunaModels
import SwiftSoup

/// Turns a rendered WebKit archive into a stable document snapshot.
///
/// `createWebArchiveData` persists the post-layout DOM *and* the publisher's script
/// tags. Replaying those scripts lets a React/paywall bundle hydrate again, replace
/// the readable snapshot, or navigate back to the live page. Luna only needs the
/// rendered HTML, injected styles, and archived subresources, so publisher execution
/// is removed from the main resource before saving and again before replaying legacy
/// archives. A small final stylesheet supplies an opaque, contrast-safe canvas when
/// a publisher relied on transparent page colors.
public enum WebArchiveSanitizer {
    private static let executablePatterns = [
        #"(?is)<script\b[^>]*>.*?</script\s*>"#,
        #"(?is)<script\b[^>]*/\s*>"#,
        #"(?is)<meta\b[^>]*\bhttp-equiv\s*=\s*([\"']?)refresh\1[^>]*>"#,
        #"(?is)<meta\b[^>]*\bhttp-equiv\s*=\s*([\"']?)content-security-policy\1[^>]*>"#,
        #"(?is)<(?:iframe|object|embed)\b[^>]*>.*?</(?:iframe|object|embed)\s*>"#,
        #"(?is)<(?:iframe|object|embed)\b[^>]*/?\s*>"#,
    ]

    private static let inlineHandlerPattern =
        #"(?is)\s+on[a-z0-9_-]+\s*=\s*(?:\"[^\"]*\"|'[^']*'|[^\s>]+)"#

    /// Returns a valid archive whose main HTML resource cannot re-run publisher
    /// code. Non-HTML or malformed archives return nil so callers can retain the
    /// original data rather than corrupting an artifact.
    public static func sanitized(_ archiveData: Data) -> Data? {
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard var archive = try? PropertyListSerialization.propertyList(
            from: archiveData, options: [], format: &format) as? [String: Any],
              var main = archive["WebMainResource"] as? [String: Any],
              let resourceData = main["WebResourceData"] as? Data,
              var html = decodedHTML(resourceData, encodingName: main["WebResourceTextEncodingName"] as? String)
        else { return nil }

        for pattern in executablePatterns {
            html = replacing(pattern, in: html, with: "")
        }
        html = replacing(inlineHandlerPattern, in: html, with: "")
        html = injectingSafetyStyle(into: html)
        main["WebResourceData"] = Data(html.utf8)
        main["WebResourceTextEncodingName"] = "UTF-8"
        archive["WebMainResource"] = main
        if let resources = archive["WebSubresources"] as? [[String: Any]] {
            archive["WebSubresources"] = resources.filter { resource in
                let mime = (resource["WebResourceMIMEType"] as? String)?.lowercased() ?? ""
                return !mime.contains("javascript") && !mime.contains("ecmascript")
            }
        }
        // Main HTML no longer contains frames. Dropping subframe archives removes
        // another independent document in which publisher code could survive.
        archive["WebSubframeArchives"] = []
        return try? PropertyListSerialization.data(
            fromPropertyList: archive, format: format, options: 0)
    }

    /// Checks that an archive holds the article Luna saved, rather than a publisher
    /// shell, a metered teaser, or a different revision of the page. This is
    /// intentionally content-based: a large navigation document can be many kilobytes
    /// while containing no story.
    ///
    /// The test is CONTIGUOUS and spread across the whole article, because word
    /// overlap can't separate a teaser from the real thing — a teaser IS the
    /// article's opening, and English prose reuses vocabulary heavily enough that a
    /// live capture holding only the first 28% of a 5,000-word interview still
    /// matched 68% of the distinct words sampled from its END (measured on the Paris
    /// Review Steinbeck interview). Verbatim probes from blocks across the article
    /// separate them completely: that same capture contained none of them.
    ///
    /// Comparison runs on letters and digits only, with separators removed entirely,
    /// so whitespace the two sides serialize differently — a `<br>`, a `&nbsp;`, a
    /// collapsed newline — can never fail an otherwise identical passage.
    public static func containsReadableArticle(
        _ archiveData: Data,
        content: ArticleContent
    ) -> Bool {
        guard let html = mainHTML(in: archiveData),
              let pageText = try? SwiftSoup.parse(html).text()
        else { return false }

        let page = condensed(pageText)
        let probes = proseProbes(in: content)
        guard !probes.isEmpty else {
            let title = condensed(content.title)
            return !title.isEmpty && page.contains(title)
        }
        let matched = probes.reduce(into: 0) { count, probe in
            if page.contains(probe) { count += 1 }
        }
        return Double(matched) / Double(probes.count) >= probeMatchThreshold
    }

    /// Condensed characters per probe (~9 words of English prose) — long enough that
    /// a coincidental match is not a real possibility.
    private static let probeLength = 48
    /// How many places across the article to sample.
    private static let probeCount = 8
    /// Share of probes an archive must contain. Below 1.0 so one block the page
    /// renders from different markup (a pull quote, a caption promoted into prose)
    /// doesn't reject an otherwise complete capture.
    private static let probeMatchThreshold = 0.6

    /// Verbatim samples of the saved prose, taken from text blocks spread evenly
    /// across the article so a capture holding only its opening fails. Each probe
    /// comes from INSIDE a single block: a window spanning two blocks isn't
    /// contiguous on the page, where a caption, byline, or ad label can sit between
    /// them.
    private static func proseProbes(in content: ArticleContent) -> [String] {
        let candidates = content.blocks
            .filter { $0.kind != .image }
            .map { condensed($0.text) }
            .filter { $0.count >= probeLength }
        guard let last = candidates.indices.last else { return [] }
        // Spread from the first block to the LAST one inclusive — sampling a prefix
        // of the blocks would accept exactly the teaser this is meant to reject.
        var indices: [Int] = []
        for slot in 0..<probeCount {
            let index = probeCount == 1 ? 0 : slot * last / (probeCount - 1)
            if indices.last != index { indices.append(index) }
        }
        return indices.map { String(candidates[$0].prefix(probeLength)) }
    }

    /// Lowercased letters and digits, nothing else — no spaces to disagree about.
    private static func condensed(_ source: String) -> String {
        source.lowercased().unicodeScalars.reduce(into: "") { result, scalar in
            if CharacterSet.alphanumerics.contains(scalar) {
                result.append(Character(scalar))
            }
        }
    }

    static func mainHTML(in archiveData: Data) -> String? {
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let archive = try? PropertyListSerialization.propertyList(
            from: archiveData, options: [], format: &format) as? [String: Any],
              let main = archive["WebMainResource"] as? [String: Any],
              let resourceData = main["WebResourceData"] as? Data
        else { return nil }
        return decodedHTML(
            resourceData, encodingName: main["WebResourceTextEncodingName"] as? String)
    }

    private static let safetyStyle = """
    <meta name="color-scheme" content="light dark">
    <style id="luna-archive-safety">
      :root { color-scheme: light dark; background: Canvas; color: CanvasText; }
      html, body {
        min-height: 100%;
        background-color: Canvas !important;
        color: CanvasText;
      }
      body { overflow: visible !important; }
      aside[class*="Paywall"], [role="dialog"][class*="paywall"],
      [role="dialog"][id*="paywall"], [class*="PaywallOverlay"],
      [class*="paywall-modal"], [class*="paywall-bar"],
      [data-testid*="PaywallInlineBarrier"] { display: none !important; }
      @media (prefers-color-scheme: dark) {
        :where(article, main, [class*="article"], [class*="body"])
        :where(p, li, h1, h2, h3, h4, blockquote, figcaption) {
          color: CanvasText !important;
        }
        a { color: LinkText; }
      }
    </style>
    """

    private static func injectingSafetyStyle(into html: String) -> String {
        guard !html.contains("id=\"luna-archive-safety\"") else { return html }
        guard let headEnd = html.range(
            of: "</head", options: [.caseInsensitive, .backwards])
        else { return safetyStyle + html }
        var result = html
        result.insert(contentsOf: safetyStyle, at: headEnd.lowerBound)
        return result
    }

    private static func decodedHTML(_ data: Data, encodingName: String?) -> String? {
        let name = encodingName?.lowercased() ?? ""
        let preferred: String.Encoding
        switch name {
        case let value where value.contains("utf-16"): preferred = .utf16
        case let value where value.contains("1252"): preferred = .windowsCP1252
        case let value where value.contains("latin"), let value where value.contains("8859"):
            preferred = .isoLatin1
        default: preferred = .utf8
        }
        return String(data: data, encoding: preferred)
            ?? String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
    }

    private static func replacing(_ pattern: String, in source: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return source }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.stringByReplacingMatches(
            in: source, options: [], range: range, withTemplate: replacement)
    }
}

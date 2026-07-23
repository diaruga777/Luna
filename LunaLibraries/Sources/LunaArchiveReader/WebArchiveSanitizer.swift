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

    /// Checks that an archive contains the article Luna saved, rather than only a
    /// publisher shell or subscription prompt. This is intentionally content-based:
    /// a large navigation document can be many kilobytes while containing no story.
    public static func containsReadableArticle(
        _ archiveData: Data,
        content: ArticleContent
    ) -> Bool {
        guard let html = mainHTML(in: archiveData),
              let pageText = try? SwiftSoup.parse(html).text()
        else { return false }

        let pageWords = Set(words(in: pageText))
        let articleWords = words(in: content.blocks
            .filter { $0.kind != .image }
            .map(\.text)
            .joined(separator: " "))
        guard articleWords.count >= 40 else {
            return normalize(pageText).contains(normalize(content.title))
        }
        let sample = Array(articleWords.prefix(240))
        let matched = sample.reduce(into: 0) { count, word in
            if pageWords.contains(word) { count += 1 }
        }
        return Double(matched) / Double(sample.count) >= 0.42
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

    private static func words(in source: String) -> [String] {
        normalize(source).split(separator: " ").map(String.init).filter { $0.count >= 4 }
    }

    private static func normalize(_ source: String) -> String {
        source.lowercased()
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character(String($0)) : " " }
            .reduce(into: "") { $0.append($1) }
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func replacing(_ pattern: String, in source: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return source }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.stringByReplacingMatches(
            in: source, options: [], range: range, withTemplate: replacement)
    }
}

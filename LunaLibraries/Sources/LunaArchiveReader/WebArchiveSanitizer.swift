//
//  WebArchiveSanitizer.swift
//  Luna
//

import Foundation

/// Turns a rendered WebKit archive into a stable document snapshot.
///
/// `createWebArchiveData` persists the post-layout DOM *and* the publisher's script
/// tags. Replaying those scripts lets a React/paywall bundle hydrate again, replace
/// the readable snapshot, or navigate back to the live page. Luna only needs the
/// rendered HTML, injected styles, and archived subresources, so publisher execution
/// is removed from the main resource before saving and again before replaying legacy
/// archives.
public enum WebArchiveSanitizer {
    private static let executablePatterns = [
        #"(?is)<script\b[^>]*>.*?</script\s*>"#,
        #"(?is)<script\b[^>]*/\s*>"#,
        #"(?is)<meta\b[^>]*\bhttp-equiv\s*=\s*([\"']?)refresh\1[^>]*>"#,
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
              var html = String(data: resourceData, encoding: .utf8)
        else { return nil }

        for pattern in executablePatterns {
            html = replacing(pattern, in: html, with: "")
        }
        html = replacing(inlineHandlerPattern, in: html, with: "")
        main["WebResourceData"] = Data(html.utf8)
        main["WebResourceTextEncodingName"] = "UTF-8"
        archive["WebMainResource"] = main
        return try? PropertyListSerialization.data(
            fromPropertyList: archive, format: format, options: 0)
    }

    private static func replacing(_ pattern: String, in source: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return source }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.stringByReplacingMatches(
            in: source, options: [], range: range, withTemplate: replacement)
    }
}

//
//  RegexCapture.swift
//  LunaURLClassification
//

import Foundation

/// The one first-capture-group regex helper (was quadruplicated across the
/// aggregator unwrapper, product detector/extractor, and lead-image extractor).
public enum RegexCapture {
    /// The first capture group of `pattern` in `text`, or nil when the pattern
    /// is invalid or doesn't match.
    public static func first(
        in text: String, pattern: String, options: NSRegularExpression.Options = []
    ) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options)
        else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges >= 2 else { return nil }
        return ns.substring(with: match.range(at: 1))
    }
}

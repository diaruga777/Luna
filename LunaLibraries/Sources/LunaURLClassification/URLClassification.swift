import Foundation
import LunaModels

public enum URLClassification {
    /// Query parameters that never identify a different document, so they are dropped
    /// when canonicalizing. Two families:
    ///
    /// - **Tracking/campaign tags** — pure attribution noise.
    /// - **In-page pointers** (`comment`, `commentId`) — a deep link to one comment
    ///   *within* an article, the same class of thing as the fragment
    ///   `canonicalURL` already discards. This matters for more than tidiness: an
    ///   archive lookup is keyed on the exact URL, and neither the Wayback CDX nor
    ///   archive.today's TimeMap has ever captured `…/p/story?comment=308157614`, so a
    ///   Substack-style comment link made the whole archive tier answer "no captures"
    ///   for an article with perfectly good snapshots under its bare URL. Dropping
    ///   them also merges two saves of the same article that differ only by comment id.
    public static let trackingParameterNames: Set<String> = [
        "mod", "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
        "fbclid", "gclid", "igshid", "ref", "cmpid", "ocid", "spm", "smid",
        "comment", "commentid",
    ]

    public static func canonicalURL(_ url: URL) -> URL {
        if URLBehaviorPolicy.pluginsOnly { return url }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.fragment = nil
        components.queryItems = components.queryItems?
            .filter { !trackingParameterNames.contains($0.name.lowercased()) }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        return components.url ?? url
    }

}

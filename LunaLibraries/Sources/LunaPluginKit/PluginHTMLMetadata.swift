import Foundation
import SwiftSoup

/// JSON-LD syntax access. Document interpretation lives in plugin-owned JS.
public enum PluginHTMLMetadata {
    /// Every `<script type="application/ld+json">` body, parse errors skipped
    /// and a `@graph` array flattened one level, so a caller looks for its
    /// `@type` in one flat list rather than in two shapes.
    public static func jsonLD(in element: Element) -> [Any] {
        guard let scripts = try? element.select("script[type=application/ld+json]") else {
            return []
        }
        var out: [Any] = []
        for script in scripts.array() {
            let source = script.data().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty,
                  let parsed = try? JSONSerialization.jsonObject(
                    with: Data(source.utf8), options: [.fragmentsAllowed])
            else { continue }
            append(parsed, to: &out)
        }
        return out
    }

    /// A top-level array is spread, and so is one `@graph` inside an object.
    /// Deeper nesting is left as the page wrote it.
    private static func append(_ value: Any, to out: inout [Any]) {
        if let list = value as? [Any] {
            for entry in list { appendFlattenedGraph(entry, to: &out) }
            return
        }
        appendFlattenedGraph(value, to: &out)
    }

    private static func appendFlattenedGraph(_ value: Any, to out: inout [Any]) {
        if let object = value as? [String: Any], let graph = object["@graph"] as? [Any] {
            out.append(contentsOf: graph)
            return
        }
        out.append(value)
    }

}

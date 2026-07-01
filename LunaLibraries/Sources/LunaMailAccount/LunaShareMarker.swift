//
//  LunaShareMarker.swift
//  LunaMailAccount
//

import Foundation

/// The machine-readable identifier Luna stamps on every share email so a
/// recipient's Luna app can recognise it and import the URL. Carried two ways
/// for robustness: an `X-Luna-Share` header (read back reliably from the raw
/// IMAP fetch / Graph `internetMessageHeaders`) and a hidden HTML block in the
/// body as a fallback if a provider ever strips the header.
public struct LunaShareMarker: Codable, Equatable {
    /// Schema version, so future readers can adapt.
    public var v: Int
    /// The shared content's canonical URL.
    public var url: String
    /// The content title (may be empty; readers fall back to the URL).
    public var title: String
    /// The Luna `ContentKind` description (e.g. "article", "video") — advisory.
    public var kind: String
    /// The sender's display name at send time (advisory; the From header wins).
    public var sender: String?

    public init(v: Int = 1, url: String, title: String, kind: String, sender: String? = nil) {
        self.v = v
        self.url = url
        self.title = title
        self.kind = kind
        self.sender = sender
    }

    public static let headerName = "X-Luna-Share"

    /// The header value: base64 (URL-safe padding-free) of the JSON payload.
    public func headerValue() -> String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return data.base64EncodedString()
    }

    /// Parses a marker from an `X-Luna-Share` header value.
    public static func from(headerValue value: String) -> LunaShareMarker? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: trimmed) else { return nil }
        return try? JSONDecoder().decode(LunaShareMarker.self, from: data)
    }

    /// The hidden HTML block embedded in the body as the header fallback. The
    /// token wraps the same base64 payload so `from(htmlBody:)` can recover it.
    public func hiddenHTMLBlock() -> String {
        "<div style=\"display:none;max-height:0;overflow:hidden\">"
            + "\(Self.bodyOpenToken)\(headerValue())\(Self.bodyCloseToken)</div>"
    }

    /// Recovers a marker from a body that carries the hidden block.
    public static func from(htmlBody body: String) -> LunaShareMarker? {
        guard let open = body.range(of: bodyOpenToken),
              let close = body.range(of: bodyCloseToken, range: open.upperBound..<body.endIndex)
        else { return nil }
        return from(headerValue: String(body[open.upperBound..<close.lowerBound]))
    }

    private static let bodyOpenToken = "[[luna-share:"
    private static let bodyCloseToken = ":luna-share]]"
}

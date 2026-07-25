//
//  ShareAttachmentRouter.swift
//  LunaShareSurface
//

import UniformTypeIdentifiers

/// Which incoming attachment a share/action extension consumes, and how.
public enum ShareAttachmentRoute: Equatable {
    /// A genuine web link at `index` — load it as a URL.
    case webURL(index: Int)
    /// A shared FILE at `index`, imported as a document of `type`.
    case document(index: Int, type: UTType)
    /// An in-memory TEXT payload at `index` (text the host typed out rather than
    /// a text FILE): a link inside it is the share, and wins over importing the
    /// text itself.
    case text(index: Int)
    /// Nothing readable was shared.
    case unsupported

    /// Compact form for the extension's diagnostic line.
    public var diagnosticLabel: String {
        switch self {
        case let .webURL(index): return "url@\(index)"
        case let .document(index, type): return "document@\(index)(\(type.identifier))"
        case let .text(index): return "text@\(index)"
        case .unsupported: return "unsupported"
        }
    }
}

/// Decides which shared attachment the extension surfaces consume, from what the
/// providers ADVERTISE (`registeredTypeIdentifiers`) — never from their loaded
/// values. Pure and value-typed, so the whole decision is unit-testable without a
/// share sheet (`NSExtensionContext` has no test seam) and identical in the share
/// and action extensions, which share one `ShareViewController`.
public enum ShareAttachmentRouter {

    /// Document file types accepted from the share sheet. `.text` (public.text)
    /// covers .txt, .md/.markdown, and most source/plain formats.
    public static let documentTypes: [UTType] = [.pdf, .rtf, .plainText, .text]

    /// The document types that are just TEXT, so an in-memory payload of one is a
    /// text share rather than a file (`.rtf` stays a document either way — rich
    /// text carries formatting a link extraction would throw away).
    private static let textTypes: [UTType] = [.plainText, .text]

    /// The route for `providerTypes` — each provider's registered type
    /// identifiers, in the order the host delivered them.
    ///
    /// A web link is matched FIRST, because a link item may also advertise a
    /// plain-text rendering of the same link and must not be mistaken for a text
    /// document. A shared file (PDF, .txt) advertises its file URL, so it is
    /// excluded from that first pass and imported as a document instead —
    /// otherwise the URL branch would grab it, see a non-http `file://` URL, and
    /// silently drop it. Plain text that is NOT a file routes to `.text`, where a
    /// link inside it wins over the text itself.
    public static func route(providerTypes: [[String]]) -> ShareAttachmentRoute {
        if let index = providerTypes.firstIndex(where: isWebLink) {
            return .webURL(index: index)
        }
        for (index, types) in providerTypes.enumerated() {
            guard let type = documentTypes.first(where: { conforms(types, to: $0) })
            else { continue }
            if textTypes.contains(type), !conforms(types, to: .fileURL) {
                return .text(index: index)
            }
            return .document(index: index, type: type)
        }
        // A file URL whose content type we don't recognize: `handleURL`'s
        // file-URL leg still imports it as a document.
        if let index = providerTypes.firstIndex(where: { conforms($0, to: .url) }) {
            return .webURL(index: index)
        }
        return .unsupported
    }

    /// The identifier a `.text` payload should be LOADED with: the text type the
    /// provider itself advertises (`public.plain-text`, `public.utf8-plain-text`,
    /// …), falling back to the generic `public.text` it merely conforms to —
    /// coercion between the two is the host's option, not a promise.
    public static func textTypeIdentifier(among types: [String]) -> String {
        types.first { UTType($0)?.conforms(to: .text) ?? false } ?? UTType.text.identifier
    }

    /// True when a provider advertises a WEB link: `public.url` without being a
    /// `public.file-url`.
    ///
    /// The `public.file-url` exclusion is what separates a link from a file —
    /// NOT "advertises no document type". A host may register ONE provider for
    /// both the link and a plain-text rendering of it, and treating that as a
    /// text document saved a shared video as a `.txt` file, which then dropped
    /// out of Luna Downloader as Reader-owned content.
    private static func isWebLink(_ types: [String]) -> Bool {
        conforms(types, to: .url) && !conforms(types, to: .fileURL)
    }

    /// Whether any advertised identifier conforms to `type` — the pure
    /// equivalent of `NSItemProvider.hasItemConformingToTypeIdentifier`.
    private static func conforms(_ types: [String], to type: UTType) -> Bool {
        types.contains { UTType($0)?.conforms(to: type) ?? false }
    }
}

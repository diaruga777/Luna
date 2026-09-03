//
//  PasteInterceptor.swift
//  LunaWriterEditor
//

import UIKit
import LunaWriterModels

/// Text on its way in from the pasteboard, with the authorship it earns.
public struct PastedText: Equatable {
    public var text: String
    public var source: AuthorshipSpan.Source

    public init(text: String, source: AuthorshipSpan.Source) {
        self.text = text
        self.source = source
    }
}

/// Turns a paste into text plus the source that text is recorded as.
///
/// Plain "Paste" is `.pasted`. "Paste as AI text" is `.ai`, which is how
/// writing produced somewhere else enters a sheet with its origin intact.
public final class PasteInterceptor {

    /// The model name recorded for text pasted as AI writing.
    public static let modelIdentifier = "pasteboard"

    public var pasteboard: PasteboardReading

    public init(pasteboard: PasteboardReading = SystemPasteboard()) {
        self.pasteboard = pasteboard
    }

    /// Whether the edit menu should offer "Paste as AI text", checked without
    /// reading the pasteboard's content.
    public var hasText: Bool { pasteboard.hasStrings }

    public func pasted() -> PastedText? {
        guard let text = pasteboard.pastedString, !text.isEmpty else { return nil }
        return PastedText(text: text, source: .pasted)
    }

    public func pastedAsAIText() -> PastedText? {
        guard let text = pasteboard.pastedString, !text.isEmpty else { return nil }
        return PastedText(text: text, source: .ai(model: Self.modelIdentifier))
    }
}

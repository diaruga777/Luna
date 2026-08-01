//
//  ArticleExportFormat.swift
//  LunaModels
//

import Foundation

/// A file format a saved article can be exported to for the system share sheet.
///
/// Lives in LunaModels — the bottom layer — because both ends need it and they
/// sit in different link groups: `LunaSend` (which builds the bytes) is an
/// article-kind module, while `LunaSocialUI` (which draws the "Export as…"
/// options) is universal. The enum carries the user-facing wording and the file
/// extension so the two can never disagree about either.
///
/// `allCases` is the SERIALIZER list, not the menu: `shareMenuFormats` is what
/// "Export as…" offers. They differ because `.richText` exists only as the
/// double-save return format (see claudedocs/double-save.md) and was
/// deliberately kept out of the share menu.
public enum ArticleExportFormat: String, CaseIterable, Codable, Sendable {
    /// EPUB 3 — reflowable, images embedded. What Send to Kindle also uses.
    case epub
    /// Paginated PDF — fixed layout, images embedded.
    case pdf
    /// CommonMark text — inline links preserved, images referenced by URL.
    case markdown
    /// Prose only — no markup, no URLs in the body.
    case plainText
    /// Rich Text (`.rtf`) — a styled, editable word-processor document with
    /// images embedded and links live. Chosen over `.odt`/`.docx` for the
    /// double-save "open a document" action because RTF is the open document
    /// format iOS Quick Look — what the Shortcuts "Quick Look" action shows —
    /// renders natively; ODT it will not preview at all.
    case richText

    /// What the article "Export as…" menu offers, in menu order: EPUB first
    /// (the ereader-universal default and the only format Luna offered before),
    /// then PDF, then the two text formats. `.richText` is intentionally absent.
    public static let shareMenuFormats: [ArticleExportFormat] =
        [.epub, .pdf, .markdown, .plainText]

    /// The extension the file is written with; also what the share sheet's
    /// `NSItemProvider` infers the content type from.
    public var fileExtension: String {
        switch self {
        case .epub: return "epub"
        case .pdf: return "pdf"
        case .markdown: return "md"
        case .plainText: return "txt"
        case .richText: return "rtf"
        }
    }

    /// The row/menu-item title, e.g. "PDF".
    public var displayName: String {
        switch self {
        case .epub: return L10n.string("EPUB")
        case .pdf: return L10n.string("PDF")
        case .markdown: return L10n.string("Markdown")
        case .plainText: return L10n.string("Plain Text")
        case .richText: return L10n.string("Rich Text Document")
        }
    }

    /// SF Symbol for the row/menu item.
    public var systemImage: String {
        switch self {
        case .epub: return "book"
        case .pdf: return "doc.richtext"
        case .markdown: return "chevron.left.forwardslash.chevron.right"
        case .plainText: return "doc.plaintext"
        case .richText: return "doc.text"
        }
    }
}

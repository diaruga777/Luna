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
/// "Export as…" offers. They differ because `.document` exists only as the
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
    /// Word document (`.docx`) — one regular, editable file with image bytes
    /// bundled and links live. Unlike directory-backed RTFD, it can be copied by
    /// the Files share extension as well as previewed by Quick Look.
    case document

    /// What the article "Export as…" menu offers, in menu order: EPUB first
    /// (the ereader-universal default and the only format Luna offered before),
    /// then PDF, then the two text formats. `.document` is intentionally absent.
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
        case .document: return "docx"
        }
    }

    /// The row/menu-item title, e.g. "PDF".
    public var displayName: String {
        switch self {
        case .epub: return L10n.string("EPUB")
        case .pdf: return L10n.string("PDF")
        case .markdown: return L10n.string("Markdown")
        case .plainText: return L10n.string("Plain Text")
        case .document: return L10n.string("Word Document")
        }
    }

    /// SF Symbol for the row/menu item.
    public var systemImage: String {
        switch self {
        case .epub: return "book"
        case .pdf: return "doc.richtext"
        case .markdown: return "chevron.left.forwardslash.chevron.right"
        case .plainText: return "doc.plaintext"
        case .document: return "doc.text"
        }
    }
}

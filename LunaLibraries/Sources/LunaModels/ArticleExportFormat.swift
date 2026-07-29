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
/// Order is the menu order: EPUB first (the ereader-universal default and the
/// only format Luna offered before), then PDF, then the two text formats.
public enum ArticleExportFormat: String, CaseIterable, Codable, Sendable {
    /// EPUB 3 — reflowable, images embedded. What Send to Kindle also uses.
    case epub
    /// Paginated PDF — fixed layout, images embedded.
    case pdf
    /// CommonMark text — inline links preserved, images referenced by URL.
    case markdown
    /// Prose only — no markup, no URLs in the body.
    case plainText

    /// The extension the file is written with; also what the share sheet's
    /// `NSItemProvider` infers the content type from.
    public var fileExtension: String {
        switch self {
        case .epub: return "epub"
        case .pdf: return "pdf"
        case .markdown: return "md"
        case .plainText: return "txt"
        }
    }

    /// The row/menu-item title, e.g. "PDF".
    public var displayName: String {
        switch self {
        case .epub: return L10n.string("EPUB")
        case .pdf: return L10n.string("PDF")
        case .markdown: return L10n.string("Markdown")
        case .plainText: return L10n.string("Plain Text")
        }
    }

    /// SF Symbol for the row/menu item.
    public var systemImage: String {
        switch self {
        case .epub: return "book"
        case .pdf: return "doc.richtext"
        case .markdown: return "chevron.left.forwardslash.chevron.right"
        case .plainText: return "doc.plaintext"
        }
    }
}

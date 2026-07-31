//
//  EmailContentRenderer.swift
//  LunaMailAccount
//

import Foundation
import LunaModels

/// A CID the HTML references, paired with the local image file the caller must
/// load and attach as an `InlineImage` with the same `contentID`.
public struct EmailImageRef: Equatable {
    public let contentID: String
    public let imageFileName: String
    public init(contentID: String, imageFileName: String) {
        self.contentID = contentID
        self.imageFileName = imageFileName
    }
}

/// The rendered body of a share email, ready to hand to `EmailMIMEBuilder`.
public struct RenderedEmailBody: Equatable {
    public let subject: String
    public let html: String
    public let plain: String
    /// Article image blocks the caller must resolve to file data + attach.
    public let imageRefs: [EmailImageRef]
    public init(subject: String, html: String, plain: String, imageRefs: [EmailImageRef]) {
        self.subject = subject
        self.html = html
        self.plain = plain
        self.imageRefs = imageRefs
    }
}

/// Renders Luna content into a human-readable HTML email (with a plaintext
/// alternative) that also carries the machine-readable `LunaShareMarker`. Pure
/// (no UIKit); the caller supplies image data and price-graph snapshots as
/// inline images keyed by the CIDs this returns.
public enum EmailContentRenderer {

    /// Subject line: `via Lu\u{200C}na: {title}`, falling back to the URL.
    public static func subject(title: String?, url: String) -> String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "\(FilterGuide.subjectPrefix)\(trimmed.isEmpty ? url : trimmed)"
    }

    /// Full article body: banner + original-content link + rendered blocks.
    public static func renderArticle(
        _ content: ArticleContent, originalURL: String, marker: LunaShareMarker
    ) -> RenderedEmailBody {
        var refs: [EmailImageRef] = []
        var bodyHTML = ""
        for block in content.blocks {
            switch block.kind {
            case .heading:
                bodyHTML += "<h2 style=\"font-size:20px;margin:20px 0 8px\">\(inlineHTML(block))</h2>"
            case .quote:
                bodyHTML += "<blockquote style=\"margin:12px 0;padding:0 0 0 14px;"
                    + "border-left:3px solid #ccc;color:#555;font-style:italic\">\(inlineHTML(block))</blockquote>"
            case .listItem:
                bodyHTML += "<p style=\"margin:4px 0 4px 18px\">&bull; \(inlineHTML(block))</p>"
            case .tableOfContents:
                // The page's own chapter marks. In mail they keep their absolute
                // hrefs, so a row opens the live article at that section.
                bodyHTML += "<p style=\"margin:3px 0 3px 18px;font-size:15px\">\(inlineHTML(block))</p>"
            case .image:
                if let fileName = block.imageFileName {
                    let cid = "img-\(refs.count)"
                    refs.append(EmailImageRef(contentID: cid, imageFileName: fileName))
                    bodyHTML += "<p style=\"margin:16px 0\"><img src=\"cid:\(cid)\" "
                        + "style=\"max-width:100%;height:auto;border-radius:6px\" alt=\"\"></p>"
                }
            case .caption:
                // Directly under its picture (mail clients honour no class names, so
                // the styling is inline like every other block here).
                bodyHTML += "<p style=\"margin:-8px 0 16px;font-size:13px;"
                    + "line-height:1.4;color:#666\">\(inlineHTML(block))</p>"
            case .paragraph:
                bodyHTML += "<p style=\"margin:12px 0;line-height:1.5\">\(inlineHTML(block))</p>"
            }
        }

        let title = content.title.isEmpty ? originalURL : content.title
        let html = document(
            title: title, originalURL: originalURL, byline: content.author,
            bodyHTML: bodyHTML, marker: marker)
        let plain = plainDocument(title: title, originalURL: originalURL, body: content.wholeText)
        return RenderedEmailBody(
            subject: subject(title: content.title, url: originalURL),
            html: html, plain: plain, imageRefs: refs)
    }

    /// A compact card for non-article shares (social post, video, product,
    /// document): banner + optional hero image (caller supplies its CID) +
    /// detail lines + the original link.
    public static func renderCard(
        title: String, originalURL: String, marker: LunaShareMarker,
        heroImageCID: String? = nil, detailLines: [String] = []
    ) -> RenderedEmailBody {
        var bodyHTML = ""
        if let cid = heroImageCID {
            bodyHTML += "<p style=\"margin:16px 0\"><a href=\"\(attr(originalURL))\">"
                + "<img src=\"cid:\(cid)\" style=\"max-width:100%;height:auto;border-radius:6px\" alt=\"\"></a></p>"
        }
        for line in detailLines {
            bodyHTML += "<p style=\"margin:8px 0;line-height:1.5\">\(escape(line))</p>"
        }
        bodyHTML += "<p style=\"margin:16px 0\"><a href=\"\(attr(originalURL))\" "
            + "style=\"color:#2b6cb0\">\(escape(L10n.string("Open the original →")))</a></p>"

        let displayTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? originalURL : title
        let html = document(
            title: displayTitle, originalURL: originalURL, byline: nil,
            bodyHTML: bodyHTML, marker: marker)
        let plain = plainDocument(
            title: displayTitle, originalURL: originalURL,
            body: detailLines.joined(separator: "\n"))
        return RenderedEmailBody(
            subject: subject(title: title, url: originalURL),
            html: html, plain: plain, imageRefs: [])
    }

    // MARK: - Document shell

    private static func document(
        title: String, originalURL: String, byline: String?,
        bodyHTML: String, marker: LunaShareMarker
    ) -> String {
        var header = "<div style=\"font-size:13px;color:#888;margin-bottom:4px\">\(escape(L10n.string("Shared with you via Luna")))</div>"
        header += "<h1 style=\"font-size:24px;margin:0 0 6px\">"
            + "<a href=\"\(attr(originalURL))\" style=\"color:#111;text-decoration:none\">\(escape(title))</a></h1>"
        if let byline, !byline.isEmpty {
            header += "<div style=\"font-size:14px;color:#666;margin-bottom:4px\">\(escape(byline))</div>"
        }
        header += "<div style=\"font-size:13px;margin-bottom:16px\">"
            + "<a href=\"\(attr(originalURL))\" style=\"color:#2b6cb0\">\(escape(originalURL))</a></div>"
        // Placed right alongside the original-source link, near the very start of the
        // body — NOT after `bodyHTML` — so a long article can't push it past the mail
        // fetch size cap on the receive side (`StreamIMAPClient.maxFetchBytes`), which
        // would otherwise clip the marker off a truncated fetch.
        header += marker.hiddenHTMLBlock()
        header += "<hr style=\"border:none;border-top:1px solid #eee;margin:0 0 16px\">"

        return "<!doctype html><html><body style=\"margin:0;padding:16px;"
            + "font-family:-apple-system,Helvetica,Arial,sans-serif;color:#111;"
            + "max-width:640px\">\(header)\(bodyHTML)</body></html>"
    }

    private static func plainDocument(title: String, originalURL: String, body: String) -> String {
        L10n.string("Shared with you via Luna\n\n\(title)\n\(originalURL)\n\n\(body)\n")
    }

    // MARK: - Inline HTML (escaping + link ranges)

    /// Renders a block's text as HTML, escaping it and wrapping any inline link
    /// ranges (UTF-16 offsets) in anchors.
    static func inlineHTML(_ block: ArticleContent.Block) -> String {
        let text = block.text
        guard !block.links.isEmpty else { return escape(text) }
        let utf16 = text.utf16
        var result = ""
        var cursor = utf16.startIndex
        func appendPlain(upTo end: String.UTF16View.Index) {
            if let lo = cursor.samePosition(in: text), let hi = end.samePosition(in: text) {
                result += escape(String(text[lo..<hi]))
            }
        }
        for link in block.links.sorted(by: { $0.start < $1.start }) {
            guard let start = utf16.index(utf16.startIndex, offsetBy: link.start,
                                          limitedBy: utf16.endIndex),
                  let end = utf16.index(start, offsetBy: link.length,
                                        limitedBy: utf16.endIndex),
                  start >= cursor else { continue }
            appendPlain(upTo: start)
            if let lo = start.samePosition(in: text), let hi = end.samePosition(in: text) {
                result += "<a href=\"\(attr(link.urlString))\" style=\"color:#2b6cb0\">"
                    + escape(String(text[lo..<hi])) + "</a>"
            }
            cursor = end
        }
        appendPlain(upTo: utf16.endIndex)
        return result
    }

    /// Escapes text for HTML element content.
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Escapes text for a double-quoted HTML attribute.
    static func attr(_ s: String) -> String {
        escape(s).replacingOccurrences(of: "\"", with: "&quot;")
    }
}

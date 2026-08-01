//
//  ArticleRTFBuilder.swift
//  Luna
//

import LunaModels
import UIKit

/// Renders extracted article content as a Rich Text with Attachments (`.rtfd`)
/// document package — the "View immediately" double-save format
/// (claudedocs/double-save.md).
///
/// Apple's flat-RTF writer explicitly omits attachments, and Apple's Quick Look
/// ignores standard inline `{\pict}` groups even though Word/LibreOffice render
/// them. RTFD is Apple's native rich-document package: `TXT.rtf` contains
/// relative `\NeXTGraphic` references and the same package contains a COPY of
/// every image's bytes. Nothing points back into Luna's container. Emitting the
/// RTF ourselves preserves live hyperlinks and records each attachment's display
/// width/height explicitly in twips.
///
/// Colours are hard-coded black-on-white, not `LunaColors`: the file leaves the
/// app and must not inherit Luna's near-black sky (both Luna appearances are
/// night — see claudedocs/visual-effects.md).
public struct ArticleRTFBuilder {

    public init() {}

    // MARK: - Geometry

    /// Text column width in twips (1/1440 inch): US Letter minus 1" margins.
    private static let columnWidthTwips = 9360
    /// An embedded image is never given more than this much vertical room, so a
    /// tall infographic doesn't push the prose off its own page.
    private static let maxImageHeightTwips = 7200

    // MARK: - Build

    /// Builds one self-contained RTFD file wrapper. `imagesDirectory` is where
    /// the ingestor saved the blocks' `imageFileName` files; each resolved image
    /// is copied into the returned wrapper. An image with no downloaded bytes
    /// falls back to a plain-text placeholder rather than being dropped, so the
    /// article's own captions still make sense.
    ///
    /// Heavy (loads/transcodes/copies every image) — call off the main thread.
    public func build(content: ArticleContent, sourceURLString: String,
                      imagesDirectory: URL) -> FileWrapper {
        var rtf = """
            {\\rtf1\\ansi\\ansicpg1252\\uc1\\deff0\
            {\\fonttbl{\\f0\\froman\\fcharset0 Times New Roman;}\
            {\\f1\\fswiss\\fcharset0 Helvetica;}}\
            {\\colortbl;\\red0\\green0\\blue0;\\red0\\green0\\blue238;\\red102\\green102\\blue102;}\
            \\viewkind4\\cf1

            """
        var fileWrappers: [String: FileWrapper] = [:]
        var imageNumber = 0

        rtf += paragraph(Self.escape(content.title), style: "\\sa160\\f1\\fs44\\b", closing: "\\b0")
        if let author = content.author, !author.isEmpty {
            rtf += paragraph(Self.escape(author), style: "\\sa120\\f1\\fs24\\i\\cf3", closing: "\\i0\\cf1")
        }
        if !sourceURLString.isEmpty {
            rtf += paragraph(
                Self.link(label: sourceURLString, urlString: sourceURLString),
                style: "\\sa160\\f1\\fs20")
        }
        // A rule under the header, matching the EPUB/Markdown front matter.
        rtf += "\\pard\\brdrb\\brdrs\\brdrw10\\brsp20\\sa180\\par\n"

        for block in content.blocks {
            switch block.kind {
            case .paragraph:
                rtf += paragraph(Self.inline(block), style: "\\sa180\\f0\\fs24\\ql")
            case .heading:
                rtf += paragraph(
                    Self.inline(block), style: "\\sb280\\sa140\\f1\\fs32\\b", closing: "\\b0")
            case .quote:
                rtf += paragraph(
                    Self.inline(block), style: "\\li720\\ri720\\sa180\\f0\\fs24\\i",
                    closing: "\\i0")
            case .listItem:
                // Hanging indent with an explicit bullet: RTF list tables are
                // reader-specific, a bullet + tab is not.
                rtf += paragraph(
                    "\\u8226 ?\\tab " + Self.inline(block),
                    style: "\\fi-360\\li720\\sa120\\f0\\fs24")
            case .tableOfContents:
                // The page's own chapter list. In-page `#anchor` jumps have no
                // destination in a standalone file, so it stays plain text.
                rtf += paragraph(
                    "\\u8226 ?\\tab " + Self.escape(block.text),
                    style: "\\fi-360\\li720\\sa120\\f0\\fs24")
            case .caption:
                rtf += paragraph(
                    Self.inline(block), style: "\\qc\\sa180\\f0\\fs20\\i\\cf3",
                    closing: "\\i0\\cf1")
            case .image:
                if let picture = Self.picture(for: block, imagesDirectory: imagesDirectory) {
                    imageNumber += 1
                    let fileName = String(
                        format: "LunaImage-%03d.%@", imageNumber, picture.fileExtension)
                    fileWrappers[fileName] = FileWrapper(
                        regularFileWithContents: picture.bytes)
                    rtf += paragraph(
                        Self.attachmentReference(fileName: fileName, picture: picture),
                        style: "\\qc\\sa180")
                } else {
                    rtf += missingImageParagraph(block)
                }
            }
        }

        rtf += "}"
        // RTF is 7-bit ASCII by construction (everything else is \uN-escaped),
        // so this encode cannot fail; `.utf8` is the belt-and-braces fallback.
        let rtfData = rtf.data(using: .ascii) ?? Data(rtf.utf8)
        fileWrappers["TXT.rtf"] = FileWrapper(regularFileWithContents: rtfData)
        return FileWrapper(directoryWithFileWrappers: fileWrappers)
    }

    // MARK: - Paragraphs

    private func paragraph(_ body: String, style: String, closing: String = "") -> String {
        "\\pard\(style) \(body)\(closing)\\par\n"
    }

    /// Italic placeholder when image bytes aren't on disk (never downloaded or
    /// pruned).
    private func missingImageParagraph(_ block: ArticleContent.Block) -> String {
        let alt = block.text.isEmpty ? L10n.string("Image") : block.text
        return paragraph(
            Self.escape("[\(alt)]"), style: "\\qc\\sa180\\f0\\fs20\\i\\cf3",
            closing: "\\i0\\cf1")
    }

    private struct Picture {
        let bytes: Data
        let fileExtension: String
        let widthTwips: Int
        let heightTwips: Int
    }

    /// RTFD's relative attachment reference. `\width` / `\height` are twips.
    /// The U+FFFC object-replacement character is emitted as signed RTF Unicode
    /// (`-4`) so the whole `TXT.rtf` stays ASCII.
    private static func attachmentReference(fileName: String, picture: Picture) -> String {
        "{{\\NeXTGraphic \(fileName) \\width\(picture.widthTwips)"
            + " \\height\(picture.heightTwips)}\\u-4?}"
    }

    /// Bytes and display geometry for the block's downloaded image. PNG and
    /// JPEG bytes are copied as-is; anything else — WebP, HEIC, AVIF, and
    /// **animated GIF** — is re-encoded as a PNG still, the format every RTFD
    /// reader supports. A GIF therefore embeds as its first frame rather than
    /// being dropped.
    ///
    /// The file is resolved through `ArticleImageFiles`, NOT from
    /// `block.imageFileName` alone: content is persisted before its images
    /// finish downloading, so a nil name routinely means "on disk, just not
    /// recorded yet".
    private static func picture(
        for block: ArticleContent.Block, imagesDirectory: URL
    ) -> Picture? {
        guard let fileURL = ArticleImageFiles.localFile(for: block, in: imagesDirectory),
              let data = try? Data(contentsOf: fileURL),
              !data.isEmpty
        else { return nil }

        let fileExtension: String
        let bytes: Data
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            fileExtension = "png"
            bytes = data
        } else if data.starts(with: [0xFF, 0xD8, 0xFF]) {
            fileExtension = "jpg"
            bytes = data
        } else if let png = UIImage(data: data)?.pngData(), !png.isEmpty {
            fileExtension = "png"
            bytes = png
        } else {
            return nil
        }

        guard let image = UIImage(data: bytes),
              image.size.width > 0, image.size.height > 0
        else { return nil }
        // Scale to the column, never up, and cap the height.
        let aspect = image.size.height / image.size.width
        var widthTwips = min(columnWidthTwips, Int(image.size.width * 15))
        var heightTwips = Int(Double(widthTwips) * aspect)
        if heightTwips > maxImageHeightTwips {
            heightTwips = maxImageHeightTwips
            widthTwips = Int(Double(heightTwips) / aspect)
        }
        guard widthTwips > 0, heightTwips > 0 else { return nil }

        return Picture(
            bytes: bytes, fileExtension: fileExtension,
            widthTwips: widthTwips, heightTwips: heightTwips)
    }

    // MARK: - Inline rendering

    /// A block's text with its outbound links as live RTF hyperlink fields. An
    /// in-page `#chapter` jump is emitted as plain text — there is no in-file
    /// destination to point it at.
    static func inline(_ block: ArticleContent.Block) -> String {
        let text = block.text as NSString
        let links = block.links
            .filter { !$0.isInPageAnchor && $0.length > 0 && $0.start >= 0 }
            .filter { $0.start + $0.length <= text.length }
            .sorted { $0.start < $1.start }

        var result = ""
        var cursor = 0
        for link in links {
            // Extraction can hand back overlapping ranges (nested anchors); the
            // first one wins and later overlaps are folded into plain text.
            guard link.start >= cursor else { continue }
            result += escape(text.substring(
                with: NSRange(location: cursor, length: link.start - cursor)))
            let label = text.substring(
                with: NSRange(location: link.start, length: link.length))
            result += self.link(label: label, urlString: link.urlString)
            cursor = link.start + link.length
        }
        result += escape(text.substring(from: cursor))
        return result
    }

    /// The RTF hyperlink field every reader understands, styled blue+underlined
    /// so it still reads as a link where the field itself isn't clickable.
    static func link(label: String, urlString: String) -> String {
        "{\\field{\\*\\fldinst{HYPERLINK \"\(escape(urlString))\"}}"
            + "{\\fldrslt{\\cf2\\ul \(escape(label))\\ulnone\\cf1}}}"
    }

    /// Escapes prose into RTF's 7-bit ASCII body: the three control characters,
    /// then every non-ASCII scalar as `\uN?` (signed 16-bit code units, matching
    /// the `\uc1` declared in the header, so a reader that can't decode `\u`
    /// shows `?` instead of dropping the run).
    static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "\\": result += "\\\\"
            case "{": result += "\\{"
            case "}": result += "\\}"
            case "\n", "\r", "\u{2028}", "\u{2029}": result += "\\line "
            case "\t": result += "\\tab "
            default:
                if character.isASCII {
                    result.append(character)
                } else {
                    for unit in String(character).utf16 {
                        // RTF's \u takes a SIGNED 16-bit value.
                        let signed = unit > 0x7FFF ? Int(unit) - 0x10000 : Int(unit)
                        result += "\\u\(signed)?"
                    }
                }
            }
        }
        return result
    }
}

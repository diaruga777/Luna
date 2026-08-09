//
//  EpubBuilder.swift
//  Luna
//

import ImageIO
import LunaModels
import Foundation
import UniformTypeIdentifiers

/// Builds a minimal EPUB 3 from extracted article content — the format Amazon
/// recommends for Send to Kindle (converted to AZW3 on their side). One chapter,
/// downloaded article images embedded.
public struct EpubBuilder {

    public init() {}

    /// Extensions a reading system is guaranteed to render: the EPUB 3 core
    /// image media types, minus SVG (which Luna never stores). An **animated
    /// GIF is embedded whole** — EPUB is the one export format that can keep the
    /// animation, so it does.
    private static let coreImageMediaTypes: [String: String] = [
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "png": "image/png",
        "gif": "image/gif",
    ]

    /// Anything else Luna may have stored (WebP, HEIC, AVIF, or the `img`
    /// unknown-type fallback) is TRANSCODED to a core type rather than dropped.
    /// WebP used to be embedded as-is and is not a core media type: Kindle's
    /// converter and most reading systems reject it, so those images silently
    /// vanished from the book.
    private static func transcodedToCoreType(_ data: Data) -> (data: Data, ext: String, mediaType: String)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let hasAlpha: Bool
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: hasAlpha = false
        default: hasAlpha = true
        }
        let type: UTType = hasAlpha ? .png : .jpeg
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(
            destination, image,
            (hasAlpha ? [:] : [kCGImageDestinationLossyCompressionQuality: 0.82]) as CFDictionary)
        guard CGImageDestinationFinalize(destination), (output as Data).count > 0
        else { return nil }
        return hasAlpha
            ? (output as Data, "png", "image/png")
            : (output as Data, "jpg", "image/jpeg")
    }

    /// Builds the EPUB and returns the bytes. `imagesDirectory` is where the
    /// ingestor saved the blocks' `imageFileName` files.
    public func build(content: ArticleContent, sourceURLString: String,
               imagesDirectory: URL) -> Data {
        var zip = ZipArchiveWriter()
        zip.addEntry(path: "mimetype", data: Data("application/epub+zip".utf8))
        zip.addEntry(path: "META-INF/container.xml", data: Data(Self.containerXML.utf8))

        let (images, entryNames) = embeddableImages(
            in: content, imagesDirectory: imagesDirectory)
        for image in images {
            zip.addEntry(path: "OEBPS/images/\(image.fileName)", data: image.data)
        }

        zip.addEntry(
            path: "OEBPS/content.opf",
            data: Data(packageDocument(content: content, images: images).utf8))
        zip.addEntry(path: "OEBPS/nav.xhtml", data: Data(Self.navXHTML.utf8))
        zip.addEntry(
            path: "OEBPS/chapter.xhtml",
            data: Data(chapterXHTML(
                content: content, sourceURLString: sourceURLString,
                imageEntryNames: entryNames).utf8))

        return zip.archiveData()
    }

    // MARK: - Pieces

    private struct EmbeddedImage {
        let fileName: String
        let mediaType: String
        let data: Data
    }

    /// Identifies an image across blocks: its source URL when it has one (two
    /// blocks pointing at the same picture share one zip entry), else whatever
    /// local file it recorded.
    private static func key(for block: ArticleContent.Block) -> String? {
        if let raw = block.imageURLString, !raw.isEmpty { return raw }
        return block.imageFileName
    }

    /// The zip entries to embed, plus the block-key → entry-name map the chapter
    /// needs (an entry name can differ from the block's recorded file name, both
    /// because the file is resolved by URL hash and because a non-core format is
    /// transcoded).
    ///
    /// Deduped: an image reused across blocks (a repeated logo) must produce ONE
    /// zip entry and ONE manifest item — duplicates make the EPUB invalid and
    /// Kindle conversion can reject it.
    private func embeddableImages(
        in content: ArticleContent, imagesDirectory: URL
    ) -> (images: [EmbeddedImage], entryNames: [String: String]) {
        var images: [EmbeddedImage] = []
        var entryNames: [String: String] = [:]
        var usedNames = Set<String>()

        for block in content.blocks where block.kind == .image {
            guard let key = Self.key(for: block) else { continue }
            if entryNames[key] != nil { continue }
            // Resolved through `ArticleImageFiles`, not `block.imageFileName`
            // alone: content is persisted before its images finish downloading,
            // so a nil name routinely means "on disk, just not recorded yet".
            guard let fileURL = ArticleImageFiles.localFile(for: block, in: imagesDirectory),
                  let data = try? Data(contentsOf: fileURL), !data.isEmpty
            else { continue }

            let fileName = fileURL.lastPathComponent
            let ext = (fileName as NSString).pathExtension.lowercased()
            let stem = (fileName as NSString).deletingPathExtension
            let embedded: EmbeddedImage
            if let mediaType = Self.coreImageMediaTypes[ext] {
                embedded = EmbeddedImage(fileName: fileName, mediaType: mediaType, data: data)
            } else if let converted = Self.transcodedToCoreType(data) {
                embedded = EmbeddedImage(
                    fileName: "\(stem).\(converted.ext)",
                    mediaType: converted.mediaType, data: converted.data)
            } else {
                continue
            }
            guard usedNames.insert(embedded.fileName).inserted else {
                entryNames[key] = embedded.fileName
                continue
            }
            entryNames[key] = embedded.fileName
            images.append(embedded)
        }
        return (images, entryNames)
    }

    private static let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """

    private static let navXHTML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><title>Contents</title></head>
        <body>
          <nav epub:type="toc"><ol><li><a href="chapter.xhtml">Article</a></li></ol></nav>
        </body>
        </html>
        """

    private func packageDocument(content: ArticleContent, images: [EmbeddedImage]) -> String {
        let imageItems = images.enumerated().map { index, image in
            """
              <item id="img\(index)" href="images/\(Self.escapeXML(image.fileName))" media-type="\(image.mediaType)"/>
            """
        }.joined(separator: "\n")

        let authorMeta = content.author.map {
            "<dc:creator>\(Self.escapeXML($0))</dc:creator>"
        } ?? ""

        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="bookid">urn:uuid:\(UUID().uuidString.lowercased())</dc:identifier>
                <dc:title>\(Self.escapeXML(content.title))</dc:title>
                <dc:language>en</dc:language>
                \(authorMeta)
                <meta property="dcterms:modified">\(Self.iso8601Now())</meta>
              </metadata>
              <manifest>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
            \(imageItems)
              </manifest>
              <spine>
                <itemref idref="chapter"/>
              </spine>
            </package>
            """
    }

    private func chapterXHTML(
        content: ArticleContent, sourceURLString: String,
        imageEntryNames: [String: String]
    ) -> String {
        var bodyParts: [String] = []
        bodyParts.append("<h1>\(Self.escapeXML(content.title))</h1>")
        if let author = content.author {
            bodyParts.append("<p><i>\(Self.escapeXML(author))</i></p>")
        }
        bodyParts.append(
            "<p><a href=\"\(Self.escapeXML(sourceURLString))\">\(Self.escapeXML(sourceURLString))</a></p>")
        bodyParts.append("<hr/>")

        var openList = false
        for block in content.blocks {
            if block.kind == .listItem && !openList {
                bodyParts.append("<ul>")
                openList = true
            } else if block.kind != .listItem && openList {
                bodyParts.append("</ul>")
                openList = false
            }

            // The whole article is one xhtml document, so a block the page's own
            // chapter marks point at keeps its id and the rows stay live
            // navigation inside the book.
            let id = block.anchorID.map { " id=\"\(Self.escapeXML($0))\"" } ?? ""
            switch block.kind {
            case .paragraph:
                bodyParts.append("<p\(id)>\(Self.escapeXML(block.text))</p>")
            case .heading:
                bodyParts.append("<h2\(id)>\(Self.escapeXML(block.text))</h2>")
            case .quote:
                bodyParts.append("<blockquote\(id)><p>\(Self.escapeXML(block.text))</p></blockquote>")
            case .listItem:
                bodyParts.append("<li\(id)>\(Self.escapeXML(block.text))</li>")
            case .tableOfContents:
                let text = Self.escapeXML(block.text)
                if let anchorID = block.links.first?.anchorID {
                    bodyParts.append(
                        "<p><a href=\"#\(Self.escapeXML(anchorID))\">\(text)</a></p>")
                } else {
                    bodyParts.append("<p>\(text)</p>")
                }
            case .caption:
                // Italic, because the book's stylesheet is the reading system's and
                // a class name it doesn't know would render as ordinary body text.
                bodyParts.append("<p\(id)><em>\(Self.escapeXML(block.text))</em></p>")
            case .image:
                guard let key = Self.key(for: block),
                      let entryName = imageEntryNames[key] else { break }
                bodyParts.append(
                    "<p><img src=\"images/\(Self.escapeXML(entryName))\" alt=\"\(Self.escapeXML(block.text))\"/></p>")
            }
        }
        if openList { bodyParts.append("</ul>") }

        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml">
            <head><title>\(Self.escapeXML(content.title))</title></head>
            <body>
            \(bodyParts.joined(separator: "\n"))
            </body>
            </html>
            """
    }

    private static func escapeXML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func iso8601Now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }
}

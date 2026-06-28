//
//  EpubBuilder.swift
//  Clip
//

import ClipModels
import Foundation

/// Builds a minimal EPUB 3 from extracted article content — the format Amazon
/// recommends for Send to Kindle (converted to AZW3 on their side). One chapter,
/// downloaded article images embedded.
public struct EpubBuilder {

    public init() {}

    /// Maps an image file extension to its EPUB media type; nil means the
    /// format isn't worth embedding (Kindle conversion may reject it).
    private static let imageMediaTypes: [String: String] = [
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "png": "image/png",
        "gif": "image/gif",
        "webp": "image/webp",
    ]

    /// Builds the EPUB and returns the bytes. `imagesDirectory` is where the
    /// ingestor saved the blocks' `imageFileName` files.
    public func build(content: ArticleContent, sourceURLString: String,
               imagesDirectory: URL) -> Data {
        var zip = ZipArchiveWriter()
        zip.addEntry(path: "mimetype", data: Data("application/epub+zip".utf8))
        zip.addEntry(path: "META-INF/container.xml", data: Data(Self.containerXML.utf8))

        let images = embeddableImages(in: content, imagesDirectory: imagesDirectory)
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
                embeddedImageFileNames: Set(images.map(\.fileName))).utf8))

        return zip.archiveData()
    }

    // MARK: - Pieces

    private struct EmbeddedImage {
        let fileName: String
        let mediaType: String
        let data: Data
    }

    private func embeddableImages(
        in content: ArticleContent, imagesDirectory: URL
    ) -> [EmbeddedImage] {
        content.blocks.compactMap { block in
            guard block.kind == .image,
                  let fileName = block.imageFileName,
                  let mediaType = Self.imageMediaTypes[
                    (fileName as NSString).pathExtension.lowercased()],
                  let data = try? Data(
                    contentsOf: imagesDirectory.appendingPathComponent(fileName))
            else { return nil }
            return EmbeddedImage(fileName: fileName, mediaType: mediaType, data: data)
        }
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
        embeddedImageFileNames: Set<String>
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

            switch block.kind {
            case .paragraph:
                bodyParts.append("<p>\(Self.escapeXML(block.text))</p>")
            case .heading:
                bodyParts.append("<h2>\(Self.escapeXML(block.text))</h2>")
            case .quote:
                bodyParts.append("<blockquote><p>\(Self.escapeXML(block.text))</p></blockquote>")
            case .listItem:
                bodyParts.append("<li>\(Self.escapeXML(block.text))</li>")
            case .image:
                guard let fileName = block.imageFileName,
                      embeddedImageFileNames.contains(fileName) else { break }
                bodyParts.append(
                    "<p><img src=\"images/\(Self.escapeXML(fileName))\" alt=\"\(Self.escapeXML(block.text))\"/></p>")
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

    public static func escapeXML(_ text: String) -> String {
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

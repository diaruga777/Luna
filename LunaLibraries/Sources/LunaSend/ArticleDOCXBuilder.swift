//
//  ArticleDOCXBuilder.swift
//  LunaSend
//

import Foundation
import LunaModels
import UIKit

/// Builds the App Intent's "View immediately" document as one regular `.docx`
/// file. Unlike RTFD, DOCX is a ZIP-backed file rather than a directory package,
/// so Shortcuts and the Files share extension can copy it without losing its
/// image attachments.
public struct ArticleDOCXBuilder {

    public init() {}

    public func build(
        content: ArticleContent, sourceURLString: String, imagesDirectory: URL
    ) -> Data {
        var composer = Composer(imagesDirectory: imagesDirectory)
        let document = composer.document(
            content: content, sourceURLString: sourceURLString)

        var zip = ZipArchiveWriter()
        zip.addEntry(path: "[Content_Types].xml", data: Data(Self.contentTypes.utf8))
        zip.addEntry(path: "_rels/.rels", data: Data(Self.rootRelationships.utf8))
        zip.addEntry(path: "word/document.xml", data: Data(document.utf8))
        zip.addEntry(
            path: "word/_rels/document.xml.rels",
            data: Data(composer.relationshipsXML.utf8))
        for media in composer.media {
            zip.addEntry(path: "word/media/\(media.fileName)", data: media.bytes)
        }
        return zip.archiveData()
    }

    // MARK: - OOXML package

    private static let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Default Extension="jpg" ContentType="image/jpeg"/>
          <Default Extension="png" ContentType="image/png"/>
          <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        </Types>
        """

    private static let rootRelationships = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        </Relationships>
        """

    private struct Composer {
        struct Media {
            let fileName: String
            let bytes: Data
        }

        private struct Relationship {
            let id: String
            let type: String
            let target: String
            let isExternal: Bool
        }

        let imagesDirectory: URL
        private(set) var media: [Media] = []
        private var relationships: [Relationship] = []
        private var nextRelationshipNumber = 1
        private var nextDrawingNumber = 1

        init(imagesDirectory: URL) {
            self.imagesDirectory = imagesDirectory
        }

        var relationshipsXML: String {
            let rows = relationships.map { relationship in
                let targetMode = relationship.isExternal ? " TargetMode=\"External\"" : ""
                return "<Relationship Id=\"\(relationship.id)\""
                    + " Type=\"\(relationship.type)\""
                    + " Target=\"\(ArticleDOCXBuilder.escapeAttribute(relationship.target))\""
                    + "\(targetMode)/>"
            }.joined(separator: "\n  ")
            return """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
                  \(rows)
                </Relationships>
                """
        }

        mutating func document(content: ArticleContent, sourceURLString: String) -> String {
            var body: [String] = []
            body.append(paragraph(
                runs: [run(content.title, bold: true, size: 40)],
                alignment: nil, before: 0, after: 180))
            if let author = content.author, !author.isEmpty {
                body.append(paragraph(
                    runs: [run(author, italic: true, size: 24, color: "666666")],
                    alignment: nil, before: 0, after: 120))
            }
            if !sourceURLString.isEmpty {
                body.append(paragraph(
                    runs: [hyperlink(label: sourceURLString, urlString: sourceURLString)],
                    alignment: nil, before: 0, after: 180))
            }

            for block in content.blocks {
                switch block.kind {
                case .paragraph:
                    body.append(paragraph(
                        runs: inline(block), alignment: nil, before: 0, after: 140))
                case .heading:
                    body.append(paragraph(
                        runs: [run(block.text, bold: true, size: 30)],
                        alignment: nil, before: 220, after: 100))
                case .quote:
                    body.append(paragraph(
                        runs: [run("“\(block.text)”", italic: true, color: "444444")],
                        alignment: nil, before: 80, after: 140, leftIndent: 360))
                case .listItem:
                    body.append(paragraph(
                        runs: [run("• \(block.text)")], alignment: nil,
                        before: 0, after: 70, leftIndent: 360, hangingIndent: 180))
                case .tableOfContents:
                    body.append(paragraph(
                        runs: inline(block), alignment: nil, before: 0, after: 70))
                case .caption:
                    body.append(paragraph(
                        runs: [run(block.text, italic: true, size: 18, color: "666666")],
                        alignment: "center", before: 0, after: 140))
                case .image:
                    if let image = imageParagraph(block) {
                        body.append(image)
                    } else {
                        let alt = block.text.isEmpty ? L10n.string("Reader_export_docx_imageAltText") : block.text
                        body.append(paragraph(
                            runs: [run("[\(alt)]", italic: true, color: "666666")],
                            alignment: "center", before: 0, after: 140))
                    }
                }
            }

            return """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
                  xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
                  xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
                  xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
                  xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
                  <w:body>
                    \(body.joined(separator: "\n    "))
                    <w:sectPr>
                      <w:pgSz w:w="12240" w:h="15840"/>
                      <w:pgMar w:top="1080" w:right="1080" w:bottom="1080" w:left="1080" w:header="720" w:footer="720" w:gutter="0"/>
                    </w:sectPr>
                  </w:body>
                </w:document>
                """
        }

        // MARK: Text

        private func paragraph(
            runs: [String], alignment: String?, before: Int, after: Int,
            leftIndent: Int? = nil, hangingIndent: Int? = nil
        ) -> String {
            var properties = "<w:spacing w:before=\"\(before)\" w:after=\"\(after)\"/>"
            if let alignment { properties += "<w:jc w:val=\"\(alignment)\"/>" }
            if let leftIndent {
                properties += "<w:ind w:left=\"\(leftIndent)\""
                if let hangingIndent { properties += " w:hanging=\"\(hangingIndent)\"" }
                properties += "/>"
            }
            return "<w:p><w:pPr>\(properties)</w:pPr>\(runs.joined())</w:p>"
        }

        private func run(
            _ text: String, bold: Bool = false, italic: Bool = false,
            size: Int = 22, color: String? = nil, underline: Bool = false
        ) -> String {
            var properties = "<w:sz w:val=\"\(size)\"/><w:szCs w:val=\"\(size)\"/>"
            if bold { properties += "<w:b/>" }
            if italic { properties += "<w:i/>" }
            if let color { properties += "<w:color w:val=\"\(color)\"/>" }
            if underline { properties += "<w:u w:val=\"single\"/>" }
            return "<w:r><w:rPr>\(properties)</w:rPr><w:t xml:space=\"preserve\">"
                + "\(ArticleDOCXBuilder.escapeText(text))</w:t></w:r>"
        }

        private mutating func inline(_ block: ArticleContent.Block) -> [String] {
            let text = block.text as NSString
            let links = block.links
                .filter { !$0.isInPageAnchor && $0.length > 0 && $0.start >= 0 }
                .filter { $0.start + $0.length <= text.length }
                .sorted { $0.start < $1.start }
            var result: [String] = []
            var cursor = 0
            for link in links where link.start >= cursor {
                if link.start > cursor {
                    result.append(run(text.substring(
                        with: NSRange(location: cursor, length: link.start - cursor))))
                }
                result.append(hyperlink(
                    label: text.substring(
                        with: NSRange(location: link.start, length: link.length)),
                    urlString: link.urlString))
                cursor = link.start + link.length
            }
            if cursor < text.length { result.append(run(text.substring(from: cursor))) }
            if result.isEmpty { result.append(run(block.text)) }
            return result
        }

        private mutating func hyperlink(label: String, urlString: String) -> String {
            let id = addRelationship(
                type: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink",
                target: urlString, isExternal: true)
            return "<w:hyperlink r:id=\"\(id)\">"
                + run(label, color: "0000EE", underline: true)
                + "</w:hyperlink>"
        }

        // MARK: Images

        private struct Picture {
            let bytes: Data
            let fileExtension: String
            let widthEMU: Int
            let heightEMU: Int
        }

        /// HTML dimensions are CSS pixels (96 dpi), so one pixel is 9,525 EMU.
        /// If the page omitted them, fall back to the decoded pixel size. A
        /// picture is capped at 3.5 × 4 inches but is never enlarged by the cap.
        private func picture(for block: ArticleContent.Block) -> Picture? {
            guard let fileURL = ArticleImageFiles.localFile(for: block, in: imagesDirectory),
                  let data = try? Data(contentsOf: fileURL), !data.isEmpty
            else { return nil }

            let bytes: Data
            let fileExtension: String
            if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
                bytes = data
                fileExtension = "png"
            } else if data.starts(with: [0xFF, 0xD8, 0xFF]) {
                bytes = data
                fileExtension = "jpg"
            } else if let png = UIImage(data: data)?.pngData(), !png.isEmpty {
                bytes = png
                fileExtension = "png"
            } else {
                return nil
            }

            guard let image = UIImage(data: bytes),
                  image.size.width > 0, image.size.height > 0
            else { return nil }
            let intrinsicAspect = Double(image.size.height / image.size.width)
            var width: Double
            var height: Double
            if let size = block.imageSize, size.width > 0, size.height > 0 {
                width = Double(size.width)
                height = Double(size.height)
            } else {
                width = Double(image.size.width)
                height = width * intrinsicAspect
            }
            let scale = min(1, 336 / width, 384 / height)
            width *= scale
            height *= scale
            guard width >= 1, height >= 1 else { return nil }
            return Picture(
                bytes: bytes, fileExtension: fileExtension,
                widthEMU: Int(width * 9_525), heightEMU: Int(height * 9_525))
        }

        private mutating func imageParagraph(_ block: ArticleContent.Block) -> String? {
            guard let picture = picture(for: block) else { return nil }
            let fileName = String(
                format: "image%03d.%@", media.count + 1, picture.fileExtension)
            media.append(Media(fileName: fileName, bytes: picture.bytes))
            let relationshipID = addRelationship(
                type: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image",
                target: "media/\(fileName)", isExternal: false)
            let drawingID = nextDrawingNumber
            nextDrawingNumber += 1
            let alt = ArticleDOCXBuilder.escapeAttribute(block.text)
            return """
                <w:p><w:pPr><w:jc w:val="center"/><w:spacing w:after="180"/></w:pPr><w:r><w:drawing>
                  <wp:inline distT="0" distB="0" distL="0" distR="0">
                    <wp:extent cx="\(picture.widthEMU)" cy="\(picture.heightEMU)"/>
                    <wp:effectExtent l="0" t="0" r="0" b="0"/>
                    <wp:docPr id="\(drawingID)" name="Picture \(drawingID)" descr="\(alt)"/>
                    <wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>
                    <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">
                      <pic:pic>
                        <pic:nvPicPr><pic:cNvPr id="0" name="\(fileName)"/><pic:cNvPicPr/></pic:nvPicPr>
                        <pic:blipFill><a:blip r:embed="\(relationshipID)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>
                        <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(picture.widthEMU)" cy="\(picture.heightEMU)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>
                      </pic:pic>
                    </a:graphicData></a:graphic>
                  </wp:inline>
                </w:drawing></w:r></w:p>
                """
        }

        private mutating func addRelationship(
            type: String, target: String, isExternal: Bool
        ) -> String {
            let id = "rId\(nextRelationshipNumber)"
            nextRelationshipNumber += 1
            relationships.append(Relationship(
                id: id, type: type, target: target, isExternal: isExternal))
            return id
        }
    }

    private static func escapeText(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeAttribute(_ text: String) -> String {
        escapeText(text)
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

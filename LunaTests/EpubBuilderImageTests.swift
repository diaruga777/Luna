//
//  EpubBuilderImageTests.swift
//  LunaTests
//
//  What actually ends up inside the book: an EPUB that lists an image in its
//  manifest but ships no zip entry (or ships a media type no reading system
//  renders) is an EPUB with no pictures.
//

import ImageIO
import LunaEpub
import LunaModels
import UIKit
import UniformTypeIdentifiers
import XCTest

final class EpubBuilderImageTests: XCTestCase {

    private var scratch: URL!

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("EpubImages-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    // MARK: - Fixtures

    private func encoded(as type: UTType) -> Data? {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 60, height: 40)).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 60, height: 40))
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image.cgImage!, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private func animatedGIF(frames: Int) -> Data {
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            output, UTType.gif.identifier as CFString, frames, nil)!
        for index in 0..<frames {
            let frame = UIGraphicsImageRenderer(size: CGSize(width: 30, height: 20)).image { context in
                (index % 2 == 0 ? UIColor.green : UIColor.blue).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 30, height: 20))
            }
            CGImageDestinationAddImage(destination, frame.cgImage!, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]
            ] as CFDictionary)
        }
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    private func block(
        fileName: String?, remote: String?, bytes: Data, onDiskAs diskName: String
    ) -> ArticleContent.Block {
        try? bytes.write(to: scratch.appendingPathComponent(diskName))
        return ArticleContent.Block(
            kind: .image, text: "Alt", links: [],
            imageURLString: remote, imageFileName: fileName)
    }

    private func build(_ blocks: [ArticleContent.Block]) -> Data {
        EpubBuilder().build(
            content: ArticleContent(title: "T", author: "A", blocks: blocks),
            sourceURLString: "https://example.com/a", imagesDirectory: scratch)
    }

    private func buildXteink(_ blocks: [ArticleContent.Block]) -> Data {
        EpubBuilder().build(
            content: ArticleContent(title: "T", author: "A", blocks: blocks),
            sourceURLString: "https://example.com/a", imagesDirectory: scratch,
            profile: .textOnly)
    }

    /// The zip's stored entry paths, read straight out of the central directory
    /// (`ZipArchiveWriter` stores everything uncompressed).
    private func entryPaths(in archive: Data) -> [String] {
        var paths: [String] = []
        let signature: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
        let bytes = [UInt8](archive)
        var index = 0
        while index + 30 <= bytes.count {
            guard Array(bytes[index..<index + 4]) == signature else { index += 1; continue }
            let nameLength = Int(bytes[index + 26]) | Int(bytes[index + 27]) << 8
            let extraLength = Int(bytes[index + 28]) | Int(bytes[index + 29]) << 8
            let start = index + 30
            guard start + nameLength <= bytes.count else { break }
            paths.append(String(decoding: bytes[start..<start + nameLength], as: UTF8.self))
            index = start + nameLength + extraLength
        }
        return paths
    }

    private func text(in archive: Data) -> String {
        String(decoding: archive, as: UTF8.self)
    }

    // MARK: - Tests

    func testEmbedsDownloadedImage() {
        let png = encoded(as: .png)!
        let archive = build([block(
            fileName: "pic.png", remote: "https://example.com/pic.png",
            bytes: png, onDiskAs: "pic.png")])
        XCTAssertTrue(entryPaths(in: archive).contains("OEBPS/images/pic.png"),
                      "\(entryPaths(in: archive))")
        XCTAssertTrue(text(in: archive).contains("<img src=\"images/pic.png\""))
        XCTAssertTrue(text(in: archive).contains("media-type=\"image/png\""))

        let jpeg = encoded(as: .jpeg)!
        let jpegArchive = build([block(
            fileName: "pic.jpg", remote: "https://example.com/pic.jpg",
            bytes: jpeg, onDiskAs: "pic.jpg")])
        XCTAssertTrue(text(in: jpegArchive).contains("media-type=\"image/jpeg\""))
    }

    func testTextOnlyProfileOmitsEveryImageButKeepsStandaloneCaptions() throws {
        let png = encoded(as: .png)!
        let archive = buildXteink([
            block(
                fileName: "pic.png", remote: "https://example.com/pic.png",
                bytes: png, onDiskAs: "pic.png"),
            ArticleContent.Block(kind: .caption, text: "A surviving caption", links: []),
        ])
        let reader = try XCTUnwrap(ZipArchiveReader(data: archive))
        XCTAssertTrue(reader.paths.filter { $0.hasPrefix("OEBPS/images/") }.isEmpty)
        let package = try XCTUnwrap(reader.text(at: "OEBPS/content.opf"))
        let chapter = try XCTUnwrap(reader.text(at: "OEBPS/chapter.xhtml"))
        XCTAssertFalse(package.contains("media-type=\"image/"))
        XCTAssertFalse(chapter.contains("<img"))
        XCTAssertTrue(chapter.contains("<em>Alt</em>"))
        XCTAssertTrue(chapter.contains("<em>A surviving caption</em>"))
    }

    func testCompactBannerIsMonochromeBoundedAndOnlyEmbeddedOnce() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let original = UIGraphicsImageRenderer(size: CGSize(width: 1800, height: 1200), format: format).image { ctx in
            for y in stride(from: 0, to: 1200, by: 10) {
                for x in stride(from: 0, to: 1800, by: 10) {
                    UIColor(hue: CGFloat((x * 31 + y * 17) % 360) / 360,
                            saturation: 1, brightness: 0.8, alpha: 1).setFill()
                    ctx.fill(CGRect(x: x, y: y, width: 10, height: 10))
                }
            }
        }
        let first = block(fileName: "large.png", remote: "https://example.com/large.png",
                          bytes: try XCTUnwrap(original.pngData()), onDiskAs: "large.png")
        let content = ArticleContent(title: "Banner", blocks: [
            first, first,
            .init(kind: .paragraph, text: String(repeating: "A readable sentence. ", count: 1000), links: []),
            block(fileName: "second.png", remote: "https://example.com/second.png",
                  bytes: try XCTUnwrap(encoded(as: .png)), onDiskAs: "second.png")
        ])
        let bytes = EpubBuilder().build(content: content, sourceURLString: "https://example.com",
                                        imagesDirectory: scratch, profile: .compact)
        let archive = try XCTUnwrap(ZipArchiveReader(data: bytes))
        XCTAssertEqual(archive.paths.filter { $0.hasPrefix("OEBPS/images/") }, ["OEBPS/images/banner.png"])
        let banner = try XCTUnwrap(archive.data(at: "OEBPS/images/banner.png"))
        XCTAssertLessThanOrEqual(banner.count, 8192)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(banner as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertLessThanOrEqual(image.width, 320)
        XCTAssertLessThanOrEqual(image.height, 160)
        XCTAssertEqual(image.colorSpace?.model, .monochrome)
        XCTAssertEqual(banner[24], 1, "PNG IHDR bit depth must be one; ImageIO may expand it when decoding")
        XCTAssertLessThan(bytes.count, 16 * 1024, "a normal article and banner fit comfortably over BLE")
        let chapter = try XCTUnwrap(archive.text(at: "OEBPS/chapter.xhtml"))
        XCTAssertEqual(chapter.components(separatedBy: "<img ").count - 1, 1)
        XCTAssertTrue(chapter.contains("A readable sentence."))
        XCTAssertTrue(try XCTUnwrap(archive.text(at: "OEBPS/content.opf")).contains("images/banner.png"))
    }

    func testCompactMissingOrCorruptBannerStillExportsAllText() throws {
        for name in ["absent.png", "corrupt.png"] {
            try Data("bad image".utf8).write(to: scratch.appendingPathComponent("corrupt.png"))
            let content = ArticleContent(title: "No banner", blocks: [
                .init(kind: .image, text: "Alternative", links: [], imageFileName: name),
                .init(kind: .paragraph, text: "Still readable", links: [])
            ])
            let bytes = EpubBuilder().build(content: content, sourceURLString: "https://example.com",
                                            imagesDirectory: scratch, profile: .compact)
            let archive = try XCTUnwrap(ZipArchiveReader(data: bytes))
            XCTAssertFalse(archive.paths.contains { $0.hasPrefix("OEBPS/images/") })
            let chapter = try XCTUnwrap(archive.text(at: "OEBPS/chapter.xhtml"))
            XCTAssertTrue(chapter.contains("Still readable"))
            XCTAssertTrue(chapter.contains("Alternative"))
        }
    }

    /// An unrecorded image cannot be found by deriving a path from its URL.
    func testDoesNotGuessImagePathWhenFileNameIsUnrecorded() {
        let remote = "https://example.com/unrecorded.png"
        let diskName = ArticleImageFiles.newFileName(fileExtension: "png")
        let archive = build([block(
            fileName: nil, remote: remote, bytes: encoded(as: .png)!, onDiskAs: diskName)])
        XCTAssertFalse(entryPaths(in: archive).contains("OEBPS/images/\(diskName)"),
                       "\(entryPaths(in: archive))")
    }

    /// EPUB is the ONE export format that can keep an animation, so the GIF
    /// bytes go in whole rather than being flattened to a frame.
    func testEmbedsAnimatedGIFWhole() {
        let gif = animatedGIF(frames: 4)
        let archive = build([block(
            fileName: "loop.gif", remote: "https://example.com/loop.gif",
            bytes: gif, onDiskAs: "loop.gif")])
        XCTAssertTrue(entryPaths(in: archive).contains("OEBPS/images/loop.gif"))
        XCTAssertTrue(text(in: archive).contains("media-type=\"image/gif\""))
        // The whole animation, not one frame: the stored bytes are the GIF's.
        XCTAssertTrue(archive.range(of: gif) != nil, "GIF was re-encoded, losing the animation")
    }

    /// WebP/HEIC/AVIF and the `img` unknown-type fallback are not EPUB core
    /// media types — Kindle's converter and most reading systems reject them.
    /// They must be transcoded to JPEG/PNG, not dropped.
    func testTranscodesNonCoreFormatsInsteadOfDroppingThem() throws {
        for (ext, type) in [("heic", UTType.heic), ("img", UTType.jpeg)] {
            let bytes = try XCTUnwrap(encoded(as: type))
            let archive = build([block(
                fileName: "shot.\(ext)", remote: "https://example.com/shot.\(ext)",
                bytes: bytes, onDiskAs: "shot.\(ext)")])
            let paths = entryPaths(in: archive).filter { $0.hasPrefix("OEBPS/images/") }
            XCTAssertEqual(paths.count, 1, "\(ext) produced \(paths)")
            let entry = try XCTUnwrap(paths.first)
            XCTAssertTrue(entry.hasSuffix(".jpg") || entry.hasSuffix(".png"), entry)
            // The chapter must point at the TRANSCODED name, not the original.
            XCTAssertTrue(
                text(in: archive).contains(
                    "<img src=\"images/\((entry as NSString).lastPathComponent)\""),
                entry)
            XCTAssertFalse(text(in: archive).contains("images/shot.\(ext)"))
        }
    }

    /// One image reused across blocks must produce ONE zip entry and ONE
    /// manifest item — duplicates make the EPUB invalid.
    func testRepeatedImageProducesOneEntry() {
        let png = encoded(as: .png)!
        let one = block(
            fileName: "logo.png", remote: "https://example.com/logo.png",
            bytes: png, onDiskAs: "logo.png")
        let archive = build([one, ArticleContent.Block(kind: .paragraph, text: "Body.", links: []), one])
        let paths = entryPaths(in: archive).filter { $0.hasPrefix("OEBPS/images/") }
        XCTAssertEqual(paths, ["OEBPS/images/logo.png"])
        let manifestItems = text(in: archive).components(separatedBy: "media-type=\"image/").count - 1
        XCTAssertEqual(manifestItems, 1)
        // Both blocks still render.
        XCTAssertEqual(
            text(in: archive).components(separatedBy: "<img src=\"images/logo.png\"").count - 1, 2)
    }

    /// A block whose file isn't on disk is skipped everywhere at once: no zip
    /// entry, no manifest item, and no dangling `<img>` in the chapter.
    func testMissingFileIsSkippedEverywhere() {
        let archive = build([ArticleContent.Block(
            kind: .image, text: "Gone", links: [],
            imageURLString: "https://example.com/gone.png", imageFileName: "gone.png")])
        XCTAssertTrue(entryPaths(in: archive).filter { $0.hasPrefix("OEBPS/images/") }.isEmpty)
        XCTAssertFalse(text(in: archive).contains("<img"))
    }
}

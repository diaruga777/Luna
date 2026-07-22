//
//  AnimatedArticleImageTests.swift
//  LunaTests
//

import ImageIO
import LunaModels
@testable import LunaReaderUI
import LunaStorage
import UniformTypeIdentifiers
import UIKit
import XCTest

@MainActor
final class AnimatedArticleImageTests: XCTestCase {
    func testGIFURLRequestsAnimationSafeRepresentation() {
        let gif = URL(string:
            "https://i0.wp.com/example.com/uploads/motion.gif?resize=800%2C80&ssl=1")!
        let jpeg = URL(string: "https://example.com/photo.jpg")!

        XCTAssertEqual(
            ArticleImageDownloader.acceptHeader(for: gif),
            "image/gif,image/apng,image/*,*/*;q=0.8")
        XCTAssertTrue(ArticleImageDownloader.acceptHeader(for: jpeg).contains("image/webp"))
    }

    func testResolveUnlinksLegacyFlattenedGIF() {
        let content = ArticleContent(title: "Animated lead", blocks: [
            .init(
                kind: .image, text: "", links: [],
                imageURLString: "https://example.com/motion.gif?size=large",
                imageFileName: "legacy-frame-zero.jpg"),
        ])

        let resolved = ArticleImageDownloader.resolveLocalImages(content, store: .shared)

        XCTAssertNil(
            resolved.blocks[0].imageFileName,
            "a prior frame-zero JPEG must be fetched again as an animation")
    }

    func testScrollReaderInstallsLiveViewForAnimatedLeadImage() throws {
        let fileName = "animated-lead-\(UUID().uuidString).gif"
        let fileURL = ReadingListStore.shared.articlesDirectory.appendingPathComponent(fileName)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try makeTwoFrameGIF().write(to: fileURL, options: .atomic)

        let content = ArticleContent(title: "Animated lead", blocks: [
            .init(
                kind: .image, text: "", links: [],
                imageURLString: "https://example.com/animated-lead.gif",
                imageFileName: fileName, imageWidth: 320, imageHeight: 180),
            .init(kind: .paragraph, text: "A short article body.", links: []),
        ])
        var item = ReadingListItem(urlString: "https://example.com/article")
        item.state = .ready
        let reader = ScrollReaderViewController(item: item, content: content)
        reader.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        reader.loadViewIfNeeded()
        reader.view.layoutIfNeeded()

        XCTAssertEqual(reader.animatedImageViewCountForTesting, 1)
    }

    private func makeTwoFrameGIF() throws -> Data {
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            output, UTType.gif.identifier as CFString, 2, nil))
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)
        for color in [UIColor.systemRed, UIColor.systemBlue] {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            }
            let frame = try XCTUnwrap(image.cgImage)
            CGImageDestinationAddImage(destination, frame, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]
            ] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }
}

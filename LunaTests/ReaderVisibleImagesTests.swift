import ImageIO
import LunaModels
import LunaStorage
import UIKit
import XCTest
@testable import Luna
@testable import LunaReaderUI

@MainActor
final class ReaderVisibleImagesTests: XCTestCase {
    private var files: [URL] = []
    private var savedIDs: [UUID] = []

    override func tearDown() {
        for id in savedIDs {
            if let item = SavesStore.shared.item(withID: id) { SavesStore.shared.delete(item) }
        }
        for file in files { try? FileManager.default.removeItem(at: file) }
        super.tearDown()
    }

    private func image(width: Int = 1200, height: Int = 800) throws -> String {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: CGFloat(width), height: CGFloat(height))
        let bitmap = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        let name = ArticleImageFiles.newFileName(fileExtension: "png")
        let url = SavesStore.shared.articlesDirectory.appendingPathComponent(name)
        files.append(url)
        try XCTUnwrap(bitmap.pngData()).write(to: url)
        return name
    }

    private func block(file: String?, width: Int = 1200, height: Int = 800,
                       url: String = "https://images.example.test/visible.png") -> ArticleContent.Block {
        .init(kind: .image, text: "", links: [], imageURLString: url,
              imageFileName: file, imageSize: .init(width: width, height: height))
    }

    private func text(_ value: String) -> ArticleContent.Block {
        .init(kind: .paragraph, text: value, links: [])
    }

    private func attachment(in text: NSAttributedString) throws -> (NSTextAttachment, NSRange) {
        var found: (NSTextAttachment, NSRange)?
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, stop in
            if let image = value as? NSTextAttachment { found = (image, range); stop.pointee = true }
        }
        return try XCTUnwrap(found)
    }

    private func textView(in view: UIView) -> UITextView? {
        if let text = view as? UITextView { return text }
        return view.subviews.lazy.compactMap { self.textView(in: $0) }.first
    }

    private func imageRect(in text: UITextView) throws -> CGRect {
        let (_, range) = try attachment(in: text.attributedText)
        text.layoutManager.ensureLayout(for: text.textContainer)
        let glyphs = text.layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        return text.layoutManager.boundingRect(forGlyphRange: glyphs, in: text.textContainer)
    }

    func testTallImageKeepsPlaceholderGeometryWhenPixelsArrive() throws {
        let name = try image(width: 600, height: 1800)
        let remote = ArticleTextRenderer.render(.init(title: "Tall", blocks: [block(file: nil, width: 600, height: 1800)]))
        let local = ArticleTextRenderer.render(.init(title: "Tall", blocks: [block(file: name, width: 600, height: 1800)]))
        let placeholder = try attachment(in: remote.text).0.bounds
        let loaded = try attachment(in: local.text).0.bounds
        XCTAssertEqual(placeholder.width, loaded.width, accuracy: 0.5)
        XCTAssertEqual(placeholder.height, loaded.height, accuracy: 0.5,
            "bitmap downsampling must not shrink the document's image box")
        let bitmap = try XCTUnwrap(try attachment(in: local.text).0.image?.cgImage)
        XCTAssertGreaterThanOrEqual(bitmap.width, 590,
            "a tall image must keep its source width instead of being reduced to a tiny bitmap")
    }

    func testFullRenderKeepsVisibleImageAndFollowingTextInPlace() async throws {
        let name = try image()
        let content = ArticleContent(title: "Visible", blocks:
            [block(file: name), text("Immediately after the picture.")]
            + (0..<12).map { _ in text(String(repeating: "word ", count: 160)) })
        let reader = ScrollReaderViewController(item: SavedItem(urlString: "https://example.test/story"),
            content: content, includesArticleTitle: false)
        reader.defersAutomaticFullContentLoad = true
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 300, height: 700)
        window.windowLevel = .alert + 1
        window.rootViewController = reader
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        reader.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 150_000_000)
        let text = try XCTUnwrap(textView(in: reader.view))
        let before = try imageRect(in: text)
        let following = (text.attributedText.string as NSString).range(of: "Immediately after the picture.")
        let followingGlyphs = text.layoutManager.glyphRange(forCharacterRange: following, actualCharacterRange: nil)
        let beforeText = text.layoutManager.boundingRect(forGlyphRange: followingGlyphs, in: text.textContainer)
        XCTAssertFalse(reader.didLoadFullContentForTesting)
        let beforeFrame = record(window, name: "visible-image-before-full-render")
        reader.prepareFullContent()
        await reader.fullContentTaskForTesting?.value
        // UITextView publishes its glyph tiles on the next display turn after
        // replacing attributedText. Capture the displayed frame, not that
        // intermediate layer transaction.
        try await Task.sleep(nanoseconds: 50_000_000)
        reader.view.layoutIfNeeded()
        let after = try imageRect(in: text)
        let afterText = text.layoutManager.boundingRect(forGlyphRange: followingGlyphs, in: text.textContainer)
        XCTAssertTrue(reader.didLoadFullContentForTesting)
        XCTAssertEqual(before.width, after.width, accuracy: 0.5)
        XCTAssertEqual(before.height, after.height, accuracy: 0.5)
        XCTAssertEqual(beforeText.minY, afterText.minY, accuracy: 0.5)
        let afterFrame = record(window, name: "visible-image-after-full-render")
        XCTAssertTrue(beforeFrame.pngData() == afterFrame.pngData(),
            "the displayed image and text must remain identical across the full render")
    }

    @discardableResult
    private func record(_ window: UIWindow, name: String) -> UIImage {
        let bitmap = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: bitmap)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return bitmap
    }

    func testWideViewportIncludesVisibleImageBeyondCharacterEstimateBeforeAnyWorker() throws {
        let name = try image()
        let content = ArticleContent(title: "Wide", blocks:
            [text(String(repeating: "word ", count: 150)), block(file: name)]
            + (0..<16).map { _ in text(String(repeating: "more ", count: 160)) })
        let reader = ScrollReaderViewController(item: SavedItem(urlString: "https://example.test/wide"),
            content: content, includesArticleTitle: false)
        reader.defersAutomaticFullContentLoad = true
        reader.view.frame = CGRect(x: 0, y: 0, width: 1000, height: 1300)
        reader.view.layoutIfNeeded()
        XCTAssertEqual(reader.loadedImageCountForTesting, 1)
        XCTAssertFalse(reader.didLoadFullContentForTesting, "offscreen text remains deferred")
        XCTAssertNil(reader.fullContentTaskForTesting)
        let text = try XCTUnwrap(textView(in: reader.view))
        XCTAssertLessThan(try imageRect(in: text).minY, text.bounds.height)
    }

    func testKnownSizeInitialImagesAreClaimedBeforeOffscreenImages() async throws {
        let name = try image()
        let source = SavesStore.shared.add(urlString: "https://example.test/source-\(UUID())")
        savedIDs.append(source.id)
        let belowURL = "https://images.example.test/below.png"
        _ = SavesStore.shared.saveContent(.init(title: "Source", blocks: [
            block(file: name), block(file: name, url: belowURL)
        ]), for: source)
        let target = SavesStore.shared.add(urlString: "https://example.test/target-\(UUID())")
        savedIDs.append(target.id)
        let content = ArticleContent(title: "Target", blocks: [
            block(file: nil), text(String(repeating: "word ", count: 800)),
            block(file: nil, url: belowURL)
        ])
        let prepared = await ArticleImageDownloader.downloadInitialLayoutImages(
            content, itemID: target.id, store: .shared, refererURL: URL(string: target.urlString)!)
        XCTAssertNotNil(prepared.blocks[0].imageFileName, "visible pixels are required even with known dimensions")
        XCTAssertNil(prepared.blocks[2].imageFileName, "the offscreen image can stay deferred")
    }

    func testReaderStartsVisibleImageLoadingWhileFullArticleIsDeferred() async throws {
        let name = try image()
        let source = SavesStore.shared.add(urlString: "https://example.test/cached-\(UUID())")
        savedIDs.append(source.id)
        _ = SavesStore.shared.saveContent(.init(title: "Cached", blocks: [block(file: name)]), for: source)
        let target = SavesStore.shared.add(urlString: "https://example.test/reader-\(UUID())")
        savedIDs.append(target.id)
        let content = ArticleContent(title: "Reader", blocks:
            [block(file: nil)] + (0..<12).map { _ in text(String(repeating: "word ", count: 160)) })
        let reader = ScrollReaderViewController(item: target, content: content, includesArticleTitle: false)
        reader.defersAutomaticFullContentLoad = true
        reader.view.frame = CGRect(x: 0, y: 0, width: 300, height: 700)
        reader.view.layoutIfNeeded()
        let text = try XCTUnwrap(textView(in: reader.view))
        let before = try imageRect(in: text)
        let deadline = Date().addingTimeInterval(3)
        while reader.loadedImageCountForTesting == 0 && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(reader.loadedImageCountForTesting, 1)
        XCTAssertFalse(reader.didLoadFullContentForTesting)
        let after = try imageRect(in: text)
        XCTAssertEqual(before.height, after.height, accuracy: 0.5)
    }

    func testUnknownSizeImageKeepsReservedBoxAndFollowingTextWhenPixelsArrive() async throws {
        let name = try image(width: 600, height: 1800)
        let source = SavesStore.shared.add(urlString: "https://example.test/portrait-\(UUID())")
        savedIDs.append(source.id)
        _ = SavesStore.shared.saveContent(.init(title: "Source", blocks: [block(file: name)]), for: source)
        let target = SavesStore.shared.add(urlString: "https://example.test/unknown-\(UUID())")
        savedIDs.append(target.id)
        var unknown = block(file: nil)
        unknown.imageSize = nil
        let reader = ScrollReaderViewController(item: target, content: .init(title: "Unknown", blocks:
            [unknown, text("Text below the picture.")]
            + (0..<12).map { _ in text(String(repeating: "word ", count: 160)) }),
            includesArticleTitle: false)
        reader.defersAutomaticFullContentLoad = true
        reader.view.frame = CGRect(x: 0, y: 0, width: 300, height: 700)
        reader.view.layoutIfNeeded()
        let text = try XCTUnwrap(textView(in: reader.view))
        let before = try imageRect(in: text)
        func followingY() -> CGFloat {
            let range = (text.attributedText.string as NSString).range(of: "Text below the picture.")
            let glyphs = text.layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            return text.layoutManager.boundingRect(forGlyphRange: glyphs, in: text.textContainer).minY
        }
        let beforeText = followingY()
        XCTAssertGreaterThan(before.height, 100, "unknown dimensions must never collapse the image")
        let deadline = Date().addingTimeInterval(3)
        while reader.loadedImageCountForTesting == 0 && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(reader.loadedImageCountForTesting, 1)
        XCTAssertEqual(try imageRect(in: text).height, before.height, accuracy: 0.5)
        XCTAssertEqual(followingY(), beforeText, accuracy: 0.5)
        // The portrait is fitted into the reserved landscape box. Its corners
        // remain transparent instead of stretching the photo to fill that box.
        let bitmap = try XCTUnwrap(try attachment(in: text.attributedText).0.image?.cgImage)
        let pixel = try XCTUnwrap(bitmap.dataProvider?.data)
        XCTAssertEqual(CFDataGetBytePtr(pixel)![3], 0)
    }

    func testReusedWideReaderFillsViewportBeforeFullContentPreparation() throws {
        let reader = ScrollReaderViewController(item: SavedItem(urlString: "https://example.test/old"),
            content: .init(title: "Old", blocks: [text("Old body.")]), includesArticleTitle: false)
        reader.defersAutomaticFullContentLoad = true
        reader.view.frame = CGRect(x: 0, y: 0, width: 1000, height: 1300)
        reader.view.layoutIfNeeded()
        let name = try image()
        let content = ArticleContent(title: "New", blocks:
            [text(String(repeating: "word ", count: 150)), block(file: name)]
            + (0..<16).map { _ in text(String(repeating: "more ", count: 160)) })
        reader.configureForReuse(item: SavedItem(urlString: "https://example.test/new"), content: content)
        reader.view.layoutIfNeeded()
        XCTAssertEqual(reader.loadedImageCountForTesting, 1)
        XCTAssertFalse(reader.didLoadFullContentForTesting)
        XCTAssertNil(reader.fullContentTaskForTesting)
    }

    func testEachAvailableImageIsPublishedBeforeTheDownloadBatchFinishes() async throws {
        let name = try image()
        let source = SavesStore.shared.add(urlString: "https://example.test/batch-source-\(UUID())")
        savedIDs.append(source.id)
        let secondURL = "https://images.example.test/second.png"
        let secondName = try image()
        _ = SavesStore.shared.saveContent(.init(title: "Source", blocks: [
            block(file: name), block(file: secondName, url: secondURL)
        ]), for: source)
        let target = SavesStore.shared.add(urlString: "https://example.test/batch-target-\(UUID())")
        savedIDs.append(target.id)
        let content = ArticleContent(title: "Target", blocks: [block(file: nil), block(file: nil, url: secondURL)])
        var snapshots: [ArticleContent] = []
        _ = await ArticleImageDownloader.downloadInitialLayoutImages(
            content, itemID: target.id, store: .shared, refererURL: URL(string: target.urlString)!,
            onImageReady: { snapshots.append($0) })
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertNotNil(snapshots.first?.blocks[0].imageFileName)
        XCTAssertNil(snapshots.first?.blocks[1].imageFileName,
            "the first image must be delivered before the second has resolved")
        XCTAssertNotNil(snapshots.last?.blocks[1].imageFileName)
    }

    func testCachedMastheadHasPixelsBeforeTheFirstLayout() throws {
        let name = try image()
        var item = SavedItem(urlString: "https://example.test/masthead")
        item.state = .ready
        item.thumbnailFileName = name
        let card = ReaderCardContentViewController(item: item, senderName: nil,
            knownContent: .init(title: "Masthead", blocks: [text("The first paragraph.")]))
        card.loadViewIfNeeded()
        func bannerCount(_ view: UIView) -> Int {
            let this = (view as? UIImageView)?.image.map { $0.size.width > 100 ? 1 : 0 } ?? 0
            return this + view.subviews.reduce(0) { $0 + bannerCount($1) }
        }
        XCTAssertGreaterThanOrEqual(bannerCount(card.view), 2,
            "both masthead copies must have their local bitmap without waiting for the run loop")
    }

}

import LunaDesignSystem
import LunaModels
import LunaReaderUI
import LunaStorage
import UIKit
import XCTest
@testable import Luna

@MainActor
final class SavedLibraryPresentationTests: XCTestCase {
    func testFilterDefaultsTypeUnionAndActualProgress() {
        var text = SavedItem(urlString: "https://example.com/article")
        var video = SavedItem(urlString: "https://example.com/movie")
        video.platform = .youtube
        XCTAssertTrue(SavedLibraryFilter.includes(text, filters: [], isVideo: false))
        XCTAssertTrue(SavedLibraryFilter.includes(video, filters: [.text, .video], isVideo: true))
        XCTAssertFalse(SavedLibraryFilter.includes(video, filters: [.text], isVideo: true))
        text.readState = .opened
        XCTAssertFalse(SavedLibraryFilter.includes(text, filters: [.inProgress], isVideo: false),
                       "merely passing through a carousel card is not reading progress")
        text.readingProgress = 0.25
        XCTAssertTrue(SavedLibraryFilter.includes(text, filters: [.inProgress, .text], isVideo: false))
        XCTAssertFalse(SavedLibraryFilter.includes(text, filters: [.inProgress, .video], isVideo: false))
        text.readState = .read
        XCTAssertFalse(SavedLibraryFilter.includes(text, filters: [.inProgress], isVideo: false))
    }

    func testScrubAccelerationIsSymmetricContinuousAndPreciseNearOrigin() {
        XCTAssertEqual(CarouselScrubberView.acceleratedDistance(0), 0)
        XCTAssertEqual(CarouselScrubberView.acceleratedDistance(10), 15.625)
        XCTAssertEqual(CarouselScrubberView.acceleratedDistance(-150), -CarouselScrubberView.acceleratedDistance(150))
        XCTAssertEqual(CarouselScrubberView.acceleratedDistance(200), 550)
        XCTAssertEqual(CarouselScrubberView.acceleratedDistance(201), 554)
        XCTAssertGreaterThan(CarouselScrubberView.acceleratedDistance(150), 150 * 2)
    }

    func testBannerMovesOnlyMatchingImageAndKeepsCanonicalArticle() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SavesStore(containerURL: directory)
        let data = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 40)).pngData { context in
            UIColor.systemIndigo.setFill(); context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        }
        let lead = "img-lead.jpg"
        try data.write(to: store.articlesDirectory.appendingPathComponent(lead))
        let item = store.add(urlString: "https://example.com/banner")
        let original = ArticleContent(title: "Banner article", blocks: [
            .init(kind: .image, text: "", links: [], imageFileName: lead),
            .init(kind: .caption, text: "Photo credit", links: []),
            .init(kind: .paragraph, text: "The body stays intact.", links: []),
            .init(kind: .image, text: "", links: [], imageURLString: "https://example.com/diagram.png"),
        ])
        let saved = store.saveContent(original, for: item)
        let cover = UIImage(data: data)!.jpegData(compressionQuality: 0.82)!
        XCTAssertNotEqual(cover, data, "banner and inline representations differ at ingest")
        store.setThumbnail(cover, for: saved.id)
        let fresh = try XCTUnwrap(store.item(withID: saved.id))
        let presented = ArticleBanner.prepare(content: original, item: fresh, store: store)
        XCTAssertNotNil(presented.imageURL)
        XCTAssertEqual(presented.content.blocks.map(\.kind), [.paragraph, .image])
        XCTAssertEqual(store.content(for: fresh), original, "exports must keep canonical content")
    }

    func testMissingBannerDoesNotRemoveInlineContent() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SavesStore(containerURL: directory)
        let item = store.add(urlString: "https://example.com/no-cover")
        let original = ArticleContent(title: "No cover", blocks: [
            .init(kind: .image, text: "", links: [], imageURLString: "https://example.com/photo.png"),
            .init(kind: .paragraph, text: "Body", links: []),
        ])
        let presented = ArticleBanner.prepare(content: original, item: item, store: store)
        XCTAssertNil(presented.imageURL)
        XCTAssertEqual(presented.content, original)
    }

    func testCardMastheadRemainsVisibleWhenScrollingCopyLeavesViewport() throws {
        var item = SavedItem(urlString: "https://example.com/masthead")
        item.title = "Visible masthead"
        item.state = .ready
        let content = ArticleContent(title: item.title!, blocks: [
            .init(kind: .paragraph, text: String(repeating: "A long article body. ", count: 200), links: []),
        ])
        let card = ReaderCardContentViewController(item: item, senderName: nil, knownContent: content)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = card
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        card.view.layoutIfNeeded()
        card.cardDidBecomeCentered()
        let scroll = try XCTUnwrap(card.rabbitHoleReader?.focusedContentScrollView)
        scroll.contentOffset.y = 0
        card.setCardChromeVisible(true, animated: false)
        let headers = descendants(card.view).filter {
            $0.accessibilityLabel == item.title && $0.accessibilityTraits.contains(.header)
        }
        XCTAssertTrue(headers.contains {
            $0.alpha > 0.01 && $0.convert($0.bounds, to: card.view).intersects(card.view.bounds)
        })
    }

    func testLibraryShowsMultipleTitleOnlyCardsWithNoPillsSelected() {
        let library = SavedLibraryViewController()
        library.entries = (0..<8).map { ordinal in
            var item = SavedItem(urlString: "https://example.com/\(ordinal)")
            item.title = "Readable article \(ordinal)"
            return SavedLibraryEntry(item: item, isVideo: false,
                                     loadBanner: { $0(nil) }, loadBadge: { $0(.symbol("globe")) })
        }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = library
        window.makeKeyAndVisible()
        library.loadViewIfNeeded()
        library.view.frame = window.bounds
        library.view.layoutIfNeeded()
        let collection = descendants(library.view).compactMap { $0 as? UICollectionView }.first!
        collection.layoutIfNeeded()
        XCTAssertEqual(collection.numberOfItems(inSection: 0), 8)
        XCTAssertGreaterThanOrEqual(collection.visibleCells.count, 4)
        let pills = descendants(library.view).compactMap { $0 as? UIButton }.filter {
            $0.accessibilityIdentifier?.hasPrefix("savedLibrary.filter.") == true
        }
        XCTAssertEqual(pills.count, 4)
        XCTAssertEqual(Set(pills.compactMap { $0.configuration?.title }), Set(["In progress", "Text", "Video", "Shopping"]))
        XCTAssertTrue(descendants(library.view).contains { ($0 as? UILabel)?.text == "Library" })
        XCTAssertTrue(pills.allSatisfy { !$0.isSelected })
        XCTAssertTrue(pills.allSatisfy { $0.convert($0.bounds, to: library.view).maxX <= library.view.bounds.maxX - 16 },
                      "all four pills must fit at normal iPhone text size")
        let videoPill = pills.first { $0.accessibilityIdentifier == "savedLibrary.filter.video" }!
        videoPill.sendActions(for: .touchUpInside)
        XCTAssertTrue(videoPill.isSelected)
        XCTAssertEqual(collection.numberOfItems(inSection: 0), 0)
        videoPill.sendActions(for: .touchUpInside)
        XCTAssertFalse(videoPill.isSelected)
        XCTAssertEqual(collection.numberOfItems(inSection: 0), 8)
        let labels = descendants(collection).compactMap { ($0 as? UILabel)?.text }
        XCTAssertFalse(labels.contains { $0.contains("example.com") })
    }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
}

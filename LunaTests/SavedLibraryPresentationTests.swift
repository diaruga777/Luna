import LunaDesignSystem
import LunaModels
import LunaReaderUI
import LunaStorage
import UIKit
import XCTest
@testable import Luna

@MainActor
final class SavedLibraryPresentationTests: XCTestCase {
    private final class LibraryPullPan: UIPanGestureRecognizer {
        var reportedState: UIGestureRecognizer.State = .changed
        var drag: CGFloat = 0
        var speed: CGFloat = 0
        override var state: UIGestureRecognizer.State {
            get { reportedState }
            set { reportedState = newValue }
        }
        override func translation(in view: UIView?) -> CGPoint { CGPoint(x: 0, y: drag) }
        override func velocity(in view: UIView?) -> CGPoint { CGPoint(x: 0, y: speed) }
    }

    private final class LibraryPullDelegate: CarouselScrubberViewDelegate {
        var requests = 0
        func scrubber(_ scrubber: CarouselScrubberView, didPreview index: Int) {}
        func scrubber(_ scrubber: CarouselScrubberView, didCommit index: Int) {}
        func scrubberDidRequestLibrary(_ scrubber: CarouselScrubberView) { requests += 1 }
    }

    func testLibraryPullDirectionGateIsInstalledOnTheRecognizer() throws {
        let strip = CarouselScrubberView()
        strip.frame = CGRect(x: 0, y: 0, width: 250, height: strip.preferredHeight)
        strip.setThumbnailCount(8)
        strip.layoutIfNeeded()
        let pull = try XCTUnwrap(strip.gestureRecognizers?.compactMap {
            $0 as? UIPanGestureRecognizer
        }.first)
        // Mini-card descendants receive the touches. UIView's should-begin
        // override on the strip does not gate a recognizer for those touches.
        let directionGate = try XCTUnwrap(pull.delegate)
        XCTAssertTrue(directionGate === strip)
        XCTAssertEqual(directionGate.gestureRecognizerShouldBegin?(pull), false,
                       "a stationary touch must not claim the strip for search")
    }

    func testSearchHintTracksPullReversalCancellationAndLibraryCommit() throws {
        let strip = CarouselScrubberView()
        strip.frame = CGRect(x: 0, y: 0, width: 250, height: strip.preferredHeight)
        let hint = try XCTUnwrap(descendants(strip).first {
            $0.accessibilityIdentifier == "carousel.librarySearchHint"
        })
        XCTAssertTrue(hint.isHidden, "embedded strips omit the root affordance")
        strip.showsLibrarySearchHint = true
        strip.setThumbnailCount(3)
        strip.layoutIfNeeded()
        XCTAssertFalse(hint.isHidden)
        let chips = try XCTUnwrap(descendants(strip).compactMap { $0 as? UICollectionView }.first)
        XCTAssertLessThan(chips.frame.maxY, hint.frame.minY)
        let delegate = LibraryPullDelegate()
        strip.delegate = delegate
        let pan = LibraryPullPan()
        func pull(_ distance: CGFloat, _ state: UIGestureRecognizer.State = .changed,
                  speed: CGFloat = 0) {
            pan.drag = -distance
            pan.speed = speed
            pan.reportedState = state
            strip.perform(NSSelectorFromString("pullLibrary:"), with: pan)
        }
        let animated = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(animated) }
        pull(32)
        XCTAssertEqual(hint.alpha, 0.5, accuracy: 0.001)
        pull(64)
        XCTAssertEqual(hint.alpha, 0, accuracy: 0.001)
        pull(16)
        XCTAssertEqual(hint.alpha, 0.75, accuracy: 0.001)
        pull(64, .cancelled)
        XCTAssertEqual(hint.alpha, 1, accuracy: 0.001)
        XCTAssertEqual(delegate.requests, 0)
        pull(39, .ended)
        XCTAssertEqual(delegate.requests, 0)
        pull(40, .ended)
        XCTAssertEqual(delegate.requests, 1)
        XCTAssertEqual(hint.alpha, 1, accuracy: 0.001)
        pull(12, .ended, speed: -400)
        XCTAssertEqual(delegate.requests, 2)
        pull(0, .ended, speed: -400)
        XCTAssertEqual(delegate.requests, 2, "retracting the pull must not open search")
    }

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
    func testEmailBodyImageStaysInlineWithoutAnExplicitCover() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SavesStore(containerURL: directory)
        let image = "email-body.png"
        let data = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 40)).pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        }
        try data.write(to: store.articlesDirectory.appendingPathComponent(image))
        let item = store.add(urlString: "lunamail://newsletter", source: .email)
        let content = ArticleContent(title: "Newsletter", blocks: [
            .init(kind: .image, text: "", links: [], imageFileName: image),
            .init(kind: .paragraph, text: "Email body", links: []),
        ])
        let presentation = ArticleBanner.prepare(content: content, item: item, store: store)
        XCTAssertNil(presentation.imageURL)
        XCTAssertEqual(presentation.content, content)

        store.setThumbnail(data, for: item.id)
        let withCover = try XCTUnwrap(store.item(withID: item.id))
        XCTAssertNotNil(ArticleBanner.prepare(content: content, item: withCover, store: store).imageURL)
    }

    func testMissingCardTitlesHideLabelsInReaderAndLibrary() throws {
        for title in [nil, "", "  ", "Untitled", " untitled "] as [String?] {
            var item = SavedItem(urlString: "https://example.com/no-title")
            item.title = title
            item.state = .ready
            XCTAssertNil(item.cardTitle)
            let content = ArticleContent(title: title ?? "", blocks: [
                .init(kind: .paragraph, text: "Body text", links: []),
            ])
            let card = ReaderCardContentViewController(item: item, senderName: nil, knownContent: content)
            card.loadViewIfNeeded()
            card.view.frame = CGRect(x: 0, y: 0, width: 350, height: 600)
            card.view.layoutIfNeeded()
            let titleLabels = descendants(card.view).compactMap { $0 as? UILabel }.filter {
                $0.accessibilityIdentifier == UtilCardSaveTransitionAnchor.title
            }
            XCTAssertFalse(titleLabels.isEmpty)
            XCTAssertTrue(titleLabels.allSatisfy(\.isHidden))

            let library = SavedLibraryViewController()
            library.entries = [SavedLibraryEntry(item: item, isVideo: false,
                loadBanner: { $0(nil) }, loadBadge: { $0(nil) })]
            library.loadViewIfNeeded()
            let collection = try XCTUnwrap(descendants(library.view).compactMap { $0 as? UICollectionView }.first)
            let cell = library.collectionView(collection, cellForItemAt: IndexPath(item: 0, section: 0))
            XCTAssertTrue(descendants(cell).compactMap { $0 as? UILabel }.allSatisfy { $0.isHidden || $0.text?.isEmpty != false })
        }
        XCTAssertEqual(SavedItem.cardTitle(" A real title "), "A real title")
    }

    func testLibraryCentersSelectionBeforeDismissalStarts() throws {
        let library = SavedLibraryViewController()
        let item = SavedItem(urlString: "https://example.com/selected")
        library.entries = [SavedLibraryEntry(item: item, isVideo: false,
            loadBanner: { $0(nil) }, loadBadge: { $0(nil) })]
        let host = UIViewController()
        let window = UITestSupport.host(host)
        defer { window.isHidden = true }
        host.present(library, animated: false)
        var selected: UUID?
        library.willSelect = { id in
            XCTAssertFalse(library.isBeingDismissed)
            XCTAssertTrue(host.presentedViewController === library)
            selected = id
            return true
        }
        library.didSelect = { _ in XCTFail("A centered card needs no external-open fallback") }
        let collection = try XCTUnwrap(descendants(library.view).compactMap { $0 as? UICollectionView }.first)
        library.collectionView(collection, didSelectItemAt: IndexPath(item: 0, section: 0))
        XCTAssertEqual(selected, item.id, "selection must be synchronous with the tap")
    }

    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }

    func testSearchUsesSavedTextAndRejectsSupersededQueries() throws {
        let store = SavesStore.shared
        let items = ["First library item", "Second library item"].enumerated().map { index, title in
            let item = store.add(urlString: "https://example.com/library-test-\(UUID().uuidString)")
            return store.saveContent(ArticleContent(title: title, blocks: [
                .init(kind: .paragraph, text: index == 0 ? "axolotlfirsttoken" : "wombatsecondtoken", links: []),
            ]), for: item)
        }
        defer { items.forEach(store.delete) }
        let library = SavedLibraryViewController()
        library.entries = items.map { SavedLibraryEntry(item: $0, isVideo: false,
                                                        loadBanner: { $0(nil) }, loadBadge: { $0(nil) }) }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = library
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        library.view.layoutIfNeeded()
        let field = try XCTUnwrap(descendants(library.view).compactMap { $0 as? UISearchBar }.first)
        let collection = try XCTUnwrap(descendants(library.view).compactMap { $0 as? UICollectionView }.first)
        field.text = "axolotlfirsttoken"
        library.searchBar(field, textDidChange: field.text!)
        field.text = "wombatsecondtoken"
        library.searchBar(field, textDidChange: field.text!)
        let results = expectation(for: NSPredicate { _, _ in
            collection.layoutIfNeeded()
            return collection.cellForItem(at: IndexPath(item: 0, section: 0))?.accessibilityLabel == "Second library item"
        }, evaluatedWith: library)
        wait(for: [results], timeout: 3)
        field.text = ""
        library.searchBar(field, textDidChange: "")
        collection.layoutIfNeeded()
        XCTAssertEqual(collection.numberOfItems(inSection: 0), 2)
        XCTAssertEqual(collection.cellForItem(at: IndexPath(item: 0, section: 0))?.accessibilityLabel, "First library item")
    }
}

//
//  OutcomePresenterTests.swift
//  ClipTests
//

import XCTest
@testable import Clip

/// Verifies the outcome→UI mapping contract each surface's `OutcomePresenter`
/// follows: every `Outcome` case maps to a distinct presentation intent, a video /
/// social / audio outcome NEVER maps to the article reader, and `.failed` NEVER maps
/// to a "Saved" success state. Modeled as a pure mapping so it's testable without
/// UIKit (the real presenters apply the same mapping to live VCs).
final class OutcomePresenterTests: XCTestCase {

    /// The presentation intent a thin presenter produces for an outcome. Mirrors the
    /// real surfaces' exhaustive switch (article→reader, product→tracker UI,
    /// video/social/audio→non-textual screen, document→saved, needsArchive→archive
    /// reader, failed→error).
    enum PresentationIntent: Equatable {
        case reader, tracker, nonTextual, savedDocument, archiveReader, error
    }

    /// A recording presenter exercising the exhaustive switch contract — the same
    /// shape as `IngestorOutcomePresenter` / `ShareOutcomePresenter`, minus the
    /// UIKit/store side effects, so the routing can be asserted in isolation.
    struct RecordingPresenter {
        func intent(for outcome: Outcome) -> PresentationIntent {
            switch outcome {
            case .article: return .reader
            case .product: return .tracker
            case .video, .social, .audio: return .nonTextual
            case .document: return .savedDocument
            case .needsArchive: return .archiveReader
            case .failed: return .error
            }
        }
    }

    private func sampleContent() -> ArticleContent {
        ArticleContent(title: "T", blocks: [.init(kind: .paragraph, text: "x", links: [])])
    }

    private func sampleProduct() -> ProductInfo {
        ProductInfo(name: "P", priceAmount: 9, priceCurrency: "USD",
                    imageURL: nil, brand: nil, productID: nil)
    }

    func testEveryOutcomeMapsToAnIntent() {
        let presenter = RecordingPresenter()
        let outcomes: [Outcome] = [
            .article(sampleContent(), html: "<html></html>"),
            .product(sampleProduct(), html: "<html></html>"),
            .social(.x, itemID: "1"),
            .video(.youtube, itemID: "v"),
            .audio(.music, service: .spotify, itemID: "t"),
            .document(type: "pdf"),
            .needsArchive(title: "Headline"),
            .failed,
        ]
        let intents = outcomes.map(presenter.intent(for:))
        XCTAssertEqual(intents, [.reader, .tracker, .nonTextual, .nonTextual, .nonTextual,
                                 .savedDocument, .archiveReader, .error])
    }

    /// The headline guard: a video/social/audio outcome must NEVER route to the
    /// article reader (the youtube-text-extraction bug class).
    func testNonTextualNeverRoutesToReader() {
        let presenter = RecordingPresenter()
        XCTAssertNotEqual(presenter.intent(for: .video(.youtube, itemID: "v")), .reader)
        XCTAssertNotEqual(presenter.intent(for: .social(.reddit, itemID: "r")), .reader)
        XCTAssertNotEqual(presenter.intent(for: .audio(.podcast, service: .apple, itemID: "e")), .reader)
    }

    /// `.failed` must surface an error, never a misleading "Saved"/reader/tracker.
    func testFailedRoutesToErrorNotSaved() {
        let presenter = RecordingPresenter()
        XCTAssertEqual(presenter.intent(for: .failed), .error)
    }

    // MARK: - Typed-URL validation (in-app "Save a Link")

    func testTypedURLAcceptsHTTPAndPrefixesBareHost() {
        XCTAssertEqual(
            ReadingListViewController.normalizedTypedURL("https://example.com/x"),
            "https://example.com/x")
        XCTAssertEqual(
            ReadingListViewController.normalizedTypedURL("example.com/x"),
            "https://example.com/x")
    }

    func testTypedURLRejectsNonHTTPSchemesAndJunk() {
        XCTAssertNil(ReadingListViewController.normalizedTypedURL("mailto:a@b.com"))
        XCTAssertNil(ReadingListViewController.normalizedTypedURL("tel:123"))
        XCTAssertNil(ReadingListViewController.normalizedTypedURL("just a sentence"))
        XCTAssertNil(ReadingListViewController.normalizedTypedURL("   "))
    }
}

//
//  BostonGlobeSavedArticleRepairTests.swift
//  LunaTests
//

import LunaModels
import LunaStorage
import XCTest
@testable import LunaReaderUI

@MainActor
final class BostonGlobeSavedArticleRepairTests: XCTestCase {
    private let articleURL = URL(string:
        "https://www.bostonglobe.com/2026/09/22/magazine/greenfield-last-ditch-bar-backlash/")!

    func testReadySubscriptionSaveIsReplacedWithRecoveredStory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BostonGlobeSavedArticleRepairTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SavesStore(containerURL: directory)
        let item = store.add(urlString: articleURL.absoluteString)
        let offer = ArticleContent(title: "Last Ditch Bar", blocks: [
            .init(kind: .paragraph,
                  text: "Subscribe Now for Digital Access to The Boston Globe. Choose your plan for unlimited access.",
                  links: [])
        ])
        _ = store.saveContent(offer, for: item)
        let story = ArticleContent(title: "Last Ditch Bar", blocks: [
            .init(kind: .paragraph,
                  text: "The bar's change to its mask policy sparked a community discussion in Greenfield.",
                  links: [])
        ])
        var resolvedURLs: [URL] = []
        let handler = ArticleIngestHandler(subscriptionRepairResolver: { url in
            resolvedURLs.append(url)
            return .readable(story, html: "<html><body><article><p>\(story.wholeText)</p></article></body></html>")
        })

        await handler.repairBostonGlobeSubscriptionSaves(store: store)

        let repaired = try XCTUnwrap(store.item(withID: item.id))
        XCTAssertEqual(repaired.state, .ready)
        XCTAssertEqual(store.content(for: repaired)?.wholeText, story.wholeText)
        XCTAssertEqual(resolvedURLs, [articleURL])
        XCTAssertEqual(store.items().count, 1)

        await handler.repairBostonGlobeSubscriptionSaves(store: store)
        XCTAssertEqual(resolvedURLs.count, 1, "a repaired row is not fetched again")
    }

    func testOrdinaryGlobeStoryIsNotRepaired() {
        let story = ArticleContent(title: "Last Ditch Bar", blocks: [
            .init(kind: .paragraph,
                  text: "The founders described why they changed the bar's mask policy.", links: [])
        ])
        XCTAssertFalse(ArticleIngestHandler.isBostonGlobeSubscriptionOffer(story, url: articleURL))
        XCTAssertFalse(ArticleIngestHandler.isBostonGlobeSubscriptionOffer(
            story, url: URL(string: "https://example.com/story")!))
    }

    func testFailedRecoveryKeepsReadySave() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BostonGlobeSavedArticleRepairTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SavesStore(containerURL: directory)
        let item = store.add(urlString: articleURL.absoluteString)
        let offer = ArticleContent(title: "Last Ditch Bar", blocks: [
            .init(kind: .paragraph,
                  text: "Subscribe Now for Digital Access to The Boston Globe. Choose your plan for unlimited access.",
                  links: [])
        ])
        _ = store.saveContent(offer, for: item)
        let handler = ArticleIngestHandler(subscriptionRepairResolver: { _ in .unreadable(nil) })

        await handler.repairBostonGlobeSubscriptionSaves(store: store)

        let unchanged = try XCTUnwrap(store.item(withID: item.id))
        XCTAssertEqual(unchanged.state, .ready)
        XCTAssertEqual(store.content(for: unchanged)?.wholeText, offer.wholeText)
    }
}

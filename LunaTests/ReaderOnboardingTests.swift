//
//  ReaderOnboardingTests.swift
//  LunaTests
//

import LunaModels
import LunaStorage
import XCTest
@testable import Luna

final class ReaderOnboardingTests: XCTestCase {
    func testCompletionIsOwnedByInjectedPerAppDefaults() {
        let suite = "ReaderOnboardingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = ReaderOnboardingStore(defaults: defaults)
        XCTAssertFalse(store.isCompleted)
        store.markCompleted()
        XCTAssertTrue(store.isCompleted)
    }

    func testBundledLunaArticleInstallsAsARealIdempotentOfflineSave() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReaderOnboardingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ReadingListStore(containerURL: directory)
        let first = ReaderBundledLunaArticle.install(in: store)
        let second = ReaderBundledLunaArticle.install(in: store)
        let content = try XCTUnwrap(store.content(for: first))

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.urlString, ReaderBundledLunaArticle.urlString)
        XCTAssertEqual(first.state, .ready)
        XCTAssertEqual(content.title, "Luna")
        XCTAssertEqual(content.author, "Wikipedia contributors")
        XCTAssertGreaterThan(content.blocks.count, 10)
        XCTAssertTrue(content.blocks.contains {
            $0.text.contains("Creative Commons Attribution-ShareAlike 4.0")
        })
    }

    func testLaunchTotalityKeepsTheEntireCoronaVisibleAcrossSupportedShapes() {
        let sizes = [
            CGSize(width: 320, height: 568),
            CGSize(width: 402, height: 874),
            CGSize(width: 440, height: 956),
            CGSize(width: 1_024, height: 1_366),
            CGSize(width: 1_366, height: 1_024),
        ]

        for size in sizes {
            let bounds = CGRect(origin: .zero, size: size)
            let body = ReaderLaunchGeometry.totalityCardFrame(in: bounds)
            let reach = body.width * ReaderLaunchGeometry.coronaReachRatio
            let entireCorona = body.insetBy(dx: -reach, dy: -reach)

            XCTAssertGreaterThanOrEqual(
                entireCorona.minX, bounds.minX + 4.9, "width \(size)")
            XCTAssertLessThanOrEqual(
                entireCorona.maxX, bounds.maxX - 4.9, "width \(size)")
            XCTAssertGreaterThanOrEqual(
                entireCorona.minY, bounds.minY + 4.9, "height \(size)")
            XCTAssertLessThanOrEqual(
                entireCorona.maxY, bounds.maxY - 4.9, "height \(size)")
            XCTAssertEqual(body.midX, bounds.midX, accuracy: 0.001)
            XCTAssertEqual(body.midY, bounds.midY, accuracy: 0.001)
        }
    }

    func testOfflineWikipediaPageIsBundledWithoutRemoteSubresources() throws {
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "LunaWikipedia", withExtension: "html"))
        let html = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(html.contains("<h1>Luna</h1>"))
        XCTAssertTrue(html.contains("Creative Commons"))
        XCTAssertFalse(html.contains("<script"))
        XCTAssertFalse(html.contains("src=\"http"))
        XCTAssertFalse(html.contains("href=\"http"))
    }
}

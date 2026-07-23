//
//  SurfaceSupportTests.swift
//  LunaTests
//

import LunaHTMLClassification
import LunaModels
import XCTest
@testable import LunaIngest

/// Covers `SurfaceSupport` — the pure per-app content gate every classified
/// outcome is checked against, replacing the old cross-app-purchase
/// `InteropGate`. Deliberately network/UIKit/UserDefaults-free: every input is
/// passed in.
final class SurfaceSupportTests: XCTestCase {

    // MARK: - Decision matrix

    func testNoOwnerIsAlwaysSupportedForEveryCurrentApp() {
        for current in LunaApp.allCases {
            XCTAssertEqual(SurfaceSupport.evaluate(owner: nil, current: current), .supported,
                           "current=\(current)")
        }
    }

    func testCentralLunaAppSupportsEveryOwner() {
        for owner in LunaApp.allCases {
            XCTAssertEqual(SurfaceSupport.evaluate(owner: owner, current: .luna), .supported,
                           "owner=\(owner)")
        }
    }

    func testOwnerMatchingCurrentIsSupported() {
        for app in LunaApp.allCases {
            XCTAssertEqual(SurfaceSupport.evaluate(owner: app, current: app), .supported,
                           "app=\(app)")
        }
    }

    /// Full matrix over every (owner, current) pair.
    func testFullMatrix() {
        for owner in LunaApp.allCases {
            for current in LunaApp.allCases {
                let decision = SurfaceSupport.evaluate(owner: owner, current: current)
                let expected: SurfaceSupport.Decision
                if current == .luna || owner == current {
                    expected = .supported
                } else {
                    expected = .unsupported(owner: owner)
                }
                XCTAssertEqual(decision, expected, "owner=\(owner) current=\(current)")
            }
        }
    }

    func testEveryCrossCombinationIsUnsupportedWithTheRightOwner() {
        for owner in LunaApp.allCases where owner != .luna {
            for current in LunaApp.allCases where current != .luna && current != owner {
                XCTAssertEqual(
                    SurfaceSupport.evaluate(owner: owner, current: current),
                    .unsupported(owner: owner),
                    "owner=\(owner) current=\(current)")
            }
        }
    }

    func testEvaluateForCurrentProcessMatchesRunningApp() {
        // The unit-test host is the central Luna app, so `.current` is `.luna`
        // and every owner is supported.
        XCTAssertEqual(LunaApp.current, .luna)
        for owner in LunaApp.allCases {
            XCTAssertEqual(SurfaceSupport.evaluateForCurrentProcess(owner: owner), .supported)
        }
        XCTAssertEqual(SurfaceSupport.evaluateForCurrentProcess(owner: nil), .supported)
    }

    // MARK: - Outcome.owningApp

    func testOwningAppMapping() {
        let content = ArticleContent(title: "T", blocks: [
            .init(kind: .paragraph, text: "Body.", links: []),
        ])
        let product = ProductInfo(name: "Widget", priceAmount: 1, priceCurrency: "USD",
                                  imageURL: nil, brand: nil, productID: nil)

        XCTAssertEqual(Outcome.article(content, html: "").owningApp, .reader)
        XCTAssertEqual(Outcome.needsArchive(title: "T").owningApp, .reader)
        XCTAssertEqual(Outcome.document(type: "pdf").owningApp, .reader)
        XCTAssertEqual(Outcome.social(.bluesky, itemID: "1").owningApp, .downloader)
        XCTAssertEqual(Outcome.video(.youtube, itemID: "1").owningApp, .downloader)
        XCTAssertEqual(Outcome.product(product, html: "").owningApp, .priceTracker)
        XCTAssertNil(Outcome.failed.owningApp, "a genuine failure belongs to nobody")
    }

    // MARK: - unsupportedMessage

    func testUnsupportedMessageNamesBothApps() {
        let message = SurfaceSupport.unsupportedMessage(owner: .downloader, current: .reader)
        XCTAssertTrue(message.contains("Luna Reader"), "must name the current app: \(message)")
        XCTAssertTrue(message.contains("Luna Downloader"), "must name the owning app: \(message)")
    }

    func testUnsupportedMessageDefaultsCurrentToRunningProcess() {
        // The unit-test host is `.luna`, so the default `current` param names it.
        let message = SurfaceSupport.unsupportedMessage(owner: .priceTracker)
        XCTAssertTrue(message.contains("Luna"))
        XCTAssertTrue(message.contains("Luna Price Tracker"))
    }
}

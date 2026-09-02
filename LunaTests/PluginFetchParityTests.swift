//
//  PluginFetchParityTests.swift
//  LunaTests
//

import LunaPaywallBypass
import LunaPluginKit
import LunaURLClassification
import XCTest

/// `PluginCrawlerIdentity` copies `CrawlerAgent`'s literals, because
/// `LunaPluginKit` is linked by the Safari appex and cannot carry the bypass
/// tier. This is the pin that keeps the copy from drifting: a change to one
/// table without the other fails here.
final class PluginFetchParityTests: XCTestCase {

    /// Named identity → the `CrawlerAgent` it copies.
    private static let pairs: [(PluginCrawlerIdentity, CrawlerAgent)] = [
        (.googlebot, .googlebotDesktop),
        (.googlebotMobile, .googlebotMobile),
        (.bingbot, .bingbot),
        (.facebookbot, .facebookbot),
    ]

    func testEveryCrawlerIdentitySendsTheSameUserAgentAsItsBypassTwin() {
        for (identity, agent) in Self.pairs {
            XCTAssertEqual(identity.userAgent, agent.userAgent, identity.rawValue)
        }
    }

    func testEveryCrawlerIdentitySendsTheSameForwardedForAsItsBypassTwin() {
        for (identity, agent) in Self.pairs {
            XCTAssertEqual(identity.xForwardedFor, agent.xForwardedFor, identity.rawValue)
        }
    }

    /// `safari` has no `CrawlerAgent` twin — it is the browser identity the
    /// fetch layer already sends by default, and this is where the two meet.
    func testTheSafariIdentityIsTheSameStringTheFetchLayerAlreadySends() {
        XCTAssertEqual(
            PluginCrawlerIdentity.safari.userAgent, WebFetchConstants.safariUserAgent)
    }

    func testEveryNamedIdentityIsReachableByItsManifestSpelling() {
        for identity in PluginCrawlerIdentity.allCases {
            XCTAssertEqual(PluginCrawlerIdentity.named(identity.rawValue), identity)
        }
        XCTAssertNil(PluginCrawlerIdentity.named("Googlebot"))
    }
}

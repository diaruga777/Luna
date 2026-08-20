//
//  YouTubeEmbeddedPlayerLiveTests.swift
//  LunaTests
//

import UIKit
import XCTest
@testable import LunaMediaDownload

/// Opt-in live proof for YouTube's client-identified WKWebView handshake. Kept
/// out of ordinary deterministic runs; invoke with RUN_LIVE_NETWORK_TESTS=1.
@MainActor
final class YouTubeEmbeddedPlayerLiveTests: XCTestCase {

    private final class Probe: YouTubeEmbeddedPlayerViewDelegate {
        enum Result { case ready, failed(Int?) }
        let terminal: XCTestExpectation
        var result: Result?

        init(test: XCTestCase) {
            terminal = test.expectation(description: "YouTube player ready or failed")
        }

        func youTubeEmbeddedPlayerDidBecomeReady(_ player: YouTubeEmbeddedPlayerView) {
            result = .ready
            terminal.fulfill()
        }

        func youTubeEmbeddedPlayer(
            _ player: YouTubeEmbeddedPlayerView, didFailWithCode code: Int?
        ) {
            result = .failed(code)
            terminal.fulfill()
        }
    }

    func testOfficialSamplePlayerAcceptsBundleIdentifiedEmbed() async throws {
        guard ProcessInfo.processInfo.environment["RUN_LIVE_NETWORK_TESTS"] == "1" else {
            throw XCTSkip("Set RUN_LIVE_NETWORK_TESTS=1 to exercise live YouTube")
        }
        let source = try XCTUnwrap(
            URL(string: "https://www.youtube.com/watch?v=M7lc1UVf-VE"))
        let player = try XCTUnwrap(YouTubeEmbeddedPlayerView(sourceURL: source))
        let probe = Probe(test: self)
        player.delegate = probe

        let host = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.addSubview(player)
        player.frame = CGRect(x: 0, y: 200, width: 390, height: 220)

        await fulfillment(of: [probe.terminal], timeout: 30)
        switch probe.result {
        case .ready:
            break
        case .failed(let code):
            XCTFail("identified YouTube player failed with code \(String(describing: code))")
        case nil:
            XCTFail("player produced no terminal event")
        }
        _ = window
    }
}

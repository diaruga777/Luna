//
//  RescueWebScriptWrappingTests.swift
//  LunaTests
//

import XCTest
@testable import LunaURLRescue

/// Pure tests of the JS wrapper + the applier's JSON-shell wrapping. The WebView
/// itself isn't unit-tested (same as WebViewPriceRenderer).
final class RescueWebScriptWrappingTests: XCTestCase {

    func testWrapProducesTryCatchIIFE() {
        let wrapped = RescueWebScriptRunner.wrap("return 'hi';")
        XCTAssertTrue(wrapped.contains("try"))
        XCTAssertTrue(wrapped.contains("catch"))
        XCTAssertTrue(wrapped.contains("return 'hi';"))
        // Always yields a string / empty-string, never throws out.
        XCTAssertTrue(wrapped.contains("typeof r"))
    }

    func testJSONResultWrappedAsJSONLDShell() {
        let shell = RescueDirectiveApplier.wrapJSONAsHTML("{\"@type\":\"Product\"}")
        XCTAssertTrue(shell.contains("application/ld+json"))
        XCTAssertTrue(shell.contains("{\"@type\":\"Product\"}"))
    }

    func testDirectAssetKindInference() {
        XCTAssertEqual(RescueDirectiveApplier.directAsset(from: URL(string: "https://x/y.mp4")!)?.kind, .video)
        XCTAssertEqual(RescueDirectiveApplier.directAsset(from: URL(string: "https://x/y.jpg")!)?.kind, .image)
        XCTAssertEqual(RescueDirectiveApplier.directAsset(from: URL(string: "https://x/y.mp3")!)?.kind, .audio)
        XCTAssertNil(RescueDirectiveApplier.directAsset(from: URL(string: "https://x/y.html")!))
    }

    func testOpenGraphContentExtraction() {
        let html = "<meta property=\"og:video\" content=\"https://cdn/v.mp4\">"
        XCTAssertEqual(RescueDirectiveApplier.openGraphContent(named: "og:video", in: html), "https://cdn/v.mp4")
    }
}

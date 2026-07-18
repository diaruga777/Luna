//
//  ProvideContextOnScreenURLTests.swift
//  LunaTests
//

import LunaIntents
import LunaInterop
import XCTest

final class ProvideContextOnScreenURLTests: XCTestCase {
    func testNilAndEmptyInputsDoNotProduceURL() {
        XCTAssertNil(ProvideContextOnScreenURL.collapse(nil, isSafari: false))
        XCTAssertNil(ProvideContextOnScreenURL.collapse([], isSafari: false))
        XCTAssertNil(ProvideContextOnScreenURL.collapse([""], isSafari: false))
    }

    func testLongestCompatiblePrefixWins() {
        XCTAssertEqual(
            ProvideContextOnScreenURL.collapse(
                [
                    "https://example.com/post",
                    "https://example.com/post/123",
                    " https://example.com/post/123 ",
                ],
                isSafari: false),
            "https://example.com/post/123")
    }

    func testShortcutTextInputDecodesNewlineSeparatedURLs() {
        XCTAssertEqual(
            ProvideContextOnScreenURL.collapseText(
                """
                https://example.com/post
                https://example.com/post/123

                """,
                isSafari: false),
            "https://example.com/post/123")
    }

    func testShortcutTextInputStillRejectsDivergentURLs() {
        XCTAssertNil(
            ProvideContextOnScreenURL.collapseText(
                "https://example.com/one\r\nhttps://example.com/two",
                isSafari: false))
    }

    func testContainedSubsetCollapsesIntoCompleteURL() {
        XCTAssertEqual(
            ProvideContextOnScreenURL.collapse(
                ["example.com/post/123", "https://example.com/post/123"],
                isSafari: false),
            "https://example.com/post/123")
    }

    func testSingleCompleteURLIsAccepted() {
        XCTAssertEqual(
            ProvideContextOnScreenURL.collapse(
                ["https://www.tiktok.com/@luna/video/123"], isSafari: false),
            "https://www.tiktok.com/@luna/video/123")
    }

    func testValuesNotContainedInOneResultAreRejected() {
        XCTAssertNil(
            ProvideContextOnScreenURL.collapse(
                ["https://example.com/one", "https://example.com/two"],
                isSafari: false))
    }

    func testInvalidOrIncompleteURLsAreRejected() {
        for value in [
            "example.com/post",
            "ftp://example.com/post",
            "https://",
            "https://example.com/post...",
            "https://example.com/post…",
            "https://example.com/post⋯",
            "https://example.com/post%E2%80%A6",
            "https://example.com/a path",
        ] {
            XCTAssertNil(
                ProvideContextOnScreenURL.collapse([value], isSafari: false),
                "expected rejection for \(value)")
        }
    }

    func testSafariNeverUsesOnScreenURLs() {
        XCTAssertNil(
            ProvideContextOnScreenURL.collapseText(
                "https://example.com/post", isSafari: true))
    }

    func testSuccessfulSaveOutcomeCompletesWithoutForegrounding() {
        XCTAssertEqual(
            ProvideContextOnScreenSave.success(
                from: .completed(savedURLString: "https://example.com/post")),
            .init(urlString: "https://example.com/post", requiresForeground: false))
    }

    func testFriendPromptSaveCompletesAndRequestsForeground() {
        XCTAssertEqual(
            ProvideContextOnScreenSave.success(
                from: .friendPromptRequested(savedURLString: "https://example.com/post")),
            .init(urlString: "https://example.com/post", requiresForeground: true))
    }

    func testUndeterminedAndBlockedSavesFallBack() {
        XCTAssertNil(
            ProvideContextOnScreenSave.success(
                from: .completed(savedURLString: nil)))
        XCTAssertNil(
            ProvideContextOnScreenSave.success(
                from: .blockedByInterop(owner: .reader, ownerInstalled: true)))
    }
}

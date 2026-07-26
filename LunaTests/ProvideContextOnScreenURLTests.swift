//
//  ProvideContextOnScreenURLTests.swift
//  LunaTests
//

import LunaIntents
import XCTest

final class ProvideContextOnScreenURLTests: XCTestCase {
    func testDisabledIgnoresOtherwiseValidURL() {
        XCTAssertNil(
            ProvideContextOnScreenURL.collapseText(
                "https://example.com/article",
                isSafari: false,
                isEnabled: false
            )
        )
    }

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

    func testShortcutTextInputExtractsURLsFromWrappedList() {
        XCTAssertEqual(
            ProvideContextOnScreenURL.collapseText(
                #"URLs: ["https://example.com/post", "https://example.com/post/123"]"#,
                isSafari: false),
            "https://example.com/post/123")
    }

    func testCompleteURLIsAcceptedForAnOtherwiseUnhandledNonSafariApp() {
        // ProvideContextIntent evaluates this candidate before it runs
        // current-app classification.
        let arbitraryAppIsSafari = AppNamePlatform.isSafari(forAppName: "Notes")
        XCTAssertEqual(
            ProvideContextOnScreenURL.collapseText(
                "On-screen URL: https://example.com/post/123",
                isSafari: arbitraryAppIsSafari),
            "https://example.com/post/123")
    }

    func testSignalInputCollapsesHTTPHostIntoHTTPSPageURL() {
        let signalIsSafari = AppNamePlatform.isSafari(forAppName: "Signal")
        XCTAssertEqual(
            ProvideContextOnScreenURL.collapseText(
                "https://www.tiktok.com/t/ZP8Gqx5p5/ http://www.tiktok.com",
                isSafari: signalIsSafari),
            "https://www.tiktok.com/t/ZP8Gqx5p5/")
    }

    func testShortcutTextInputExtractsCommaDelimitedURLs() {
        XCTAssertEqual(
            ProvideContextOnScreenURL.collapseText(
                "https://example.com/post,https://example.com/post/123",
                isSafari: false),
            "https://example.com/post/123")
    }

    func testShortcutTextInputTrimsPresentationPunctuation() {
        XCTAssertEqual(
            ProvideContextOnScreenURL.collapseText(
                "Detected (https://example.com/post).",
                isSafari: false),
            "https://example.com/post")
    }

    func testShortcutTextInputRequiresAnExtractedURL() {
        XCTAssertNil(
            ProvideContextOnScreenURL.collapseText(
                "Get On-Screen URLs returned one item", isSafari: false))
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

    func testSafariUsesCompleteOnScreenURL() {
        XCTAssertEqual(
            ProvideContextOnScreenURL.collapseText(
                "https://example.com/post", isSafari: true),
            "https://example.com/post")
    }

    // MARK: - Divergent values

    func testDivergentValidURLsAreReportedNotSwallowed() {
        XCTAssertEqual(
            ProvideContextOnScreenURL.resolveText(
                "https://example.com/one\r\nhttps://example.com/two", isSafari: false),
            .divergent(["https://example.com/one", "https://example.com/two"]))
    }

    func testDivergentValuesDedupeToOneCandidateAreNotAmbiguous() {
        // The same page in both schemes collapses; only genuinely different
        // pages count as ambiguity.
        XCTAssertEqual(
            ProvideContextOnScreenURL.resolve(
                ["https://example.com/one", "http://example.com/one"], isSafari: false),
            .single("https://example.com/one"))
    }

    func testDivergentValuesWithOnlyOneValidURLStayQuiet() {
        XCTAssertEqual(
            ProvideContextOnScreenURL.resolve(
                ["https://example.com/one", "https://example.com/two..."], isSafari: false),
            .none)
    }

    // MARK: - Plans (extraction + per-app pre-validation)

    private func plan(
        _ text: String?, handleable: Set<String>
    ) -> ProvideContextOnScreenURL.Plan {
        ProvideContextOnScreenURL.plan(text: text, isSafari: false) { urlString in
            handleable.contains(urlString)
                ? .handleable(urlString: urlString)
                : .foreignKind(owner: .downloader)
        }
    }

    func testHandleableSingleURLIsPlannedAsASave() {
        XCTAssertEqual(
            plan("https://example.com/post", handleable: ["https://example.com/post"]),
            .save("https://example.com/post"))
    }

    func testForeignKindURLFallsThroughSilently() {
        // Nothing this app could have saved: the screenshot/unhandled decision
        // continues, with no error dialog.
        XCTAssertEqual(plan("https://example.com/post", handleable: []), .skip)
    }

    func testDivergentURLsAreOnlyAnErrorWhenOneOfThemIsOurs() {
        let text = "https://example.com/one https://example.com/two"
        XCTAssertEqual(
            plan(text, handleable: ["https://example.com/two"]), .divergent)
        XCTAssertEqual(plan(text, handleable: []), .skip)
    }

    func testNoUsableURLIsSkipped() {
        XCTAssertEqual(plan("nothing here", handleable: []), .skip)
        XCTAssertEqual(plan(nil, handleable: []), .skip)
    }

    func testDisabledSettingSkipsEvenAHandleableURL() {
        XCTAssertEqual(
            ProvideContextOnScreenURL.plan(
                text: "https://example.com/post", isSafari: false, isEnabled: false,
                verdict: { .handleable(urlString: $0) }),
            .skip)
    }

    /// Safari's address bar shows the bare domain, so that is what on-screen URL
    /// extraction reads — `youtube.com`, not `m.youtube.com/shorts/<id>`. The
    /// extension's tracked URL is the exact page, so it has to win; saving the
    /// domain classifies as an unrecognized page and dies in the article path.
    func testSafariPrefersTheTrackedURLOverTheAddressBarDomain() {
        XCTAssertEqual(
            ProvideContextOnScreenURL.plan(
                text: "youtube.com", isSafari: true, safariHasFreshTrackedURL: true,
                verdict: { .handleable(urlString: $0) }),
            .skip)
    }

    /// With no tracked URL, the on-screen value is still the fallback — that is
    /// what it was added for, and it must keep working.
    func testSafariStillUsesOnScreenURLWithoutATrackedURL() {
        XCTAssertEqual(
            ProvideContextOnScreenURL.plan(
                text: "https://m.youtube.com/shorts/vPdLeu8Njok?ra=m",
                isSafari: true, safariHasFreshTrackedURL: false,
                verdict: { .handleable(urlString: $0) }),
            .save("https://m.youtube.com/shorts/vPdLeu8Njok?ra=m"))
    }

    func testSafariPlansCentralAppYouTubeURLAsSave() {
        XCTAssertEqual(
            ProvideContextOnScreenURL.plan(
                text: "https://www.youtube.com/watch?v=abc123", isSafari: true),
            .save("https://www.youtube.com/watch?v=abc123"))
    }
}

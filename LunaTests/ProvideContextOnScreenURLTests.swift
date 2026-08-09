//
//  ProvideContextOnScreenURLTests.swift
//  LunaTests
//

import LunaIntents
import XCTest

final class ProvideContextOnScreenURLTests: XCTestCase {
    /// `resolveText`, flattened to the single-URL case — `collapseText` was
    /// itself only this flattening with 0 production callers (`plan` reads
    /// `resolveText` directly), so it was deleted; kept here as the shape most
    /// of these tests want to assert against.
    private func collapseText(
        _ value: String?, isSafari: Bool, isEnabled: Bool = true
    ) -> String? {
        guard case let .single(urlString) = ProvideContextOnScreenURL.resolveText(
            value, isSafari: isSafari, isEnabled: isEnabled)
        else { return nil }
        return urlString
    }

    /// `resolve`, flattened the same way `collapse` used to.
    private func collapse(_ values: [String]?, isSafari: Bool) -> String? {
        guard case let .single(urlString) = ProvideContextOnScreenURL.resolve(
            values, isSafari: isSafari)
        else { return nil }
        return urlString
    }

    func testDisabledIgnoresOtherwiseValidURL() {
        XCTAssertNil(
            collapseText(
                "https://example.com/article",
                isSafari: false,
                isEnabled: false
            )
        )
    }

    func testNilAndEmptyInputsDoNotProduceURL() {
        XCTAssertNil(collapse(nil, isSafari: false))
        XCTAssertNil(collapse([], isSafari: false))
        XCTAssertNil(collapse([""], isSafari: false))
    }

    func testLongestCompatiblePrefixWins() {
        XCTAssertEqual(
            collapse(
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
            collapseText(
                """
                https://example.com/post
                https://example.com/post/123

                """,
                isSafari: false),
            "https://example.com/post/123")
    }

    func testShortcutTextInputStillRejectsDivergentURLs() {
        XCTAssertNil(
            collapseText(
                "https://example.com/one\r\nhttps://example.com/two",
                isSafari: false))
    }

    func testShortcutTextInputExtractsURLsFromWrappedList() {
        XCTAssertEqual(
            collapseText(
                #"URLs: ["https://example.com/post", "https://example.com/post/123"]"#,
                isSafari: false),
            "https://example.com/post/123")
    }

    func testCompleteURLIsAcceptedForAnOtherwiseUnhandledNonSafariApp() {
        // ProvideContextIntent evaluates this candidate before it runs
        // current-app classification.
        let arbitraryAppIsSafari = AppNamePlatform.isSafari(forAppName: "Notes")
        XCTAssertEqual(
            collapseText(
                "On-screen URL: https://example.com/post/123",
                isSafari: arbitraryAppIsSafari),
            "https://example.com/post/123")
    }

    func testSignalInputCollapsesHTTPHostIntoHTTPSPageURL() {
        let signalIsSafari = AppNamePlatform.isSafari(forAppName: "Signal")
        XCTAssertEqual(
            collapseText(
                "https://www.tiktok.com/t/ZP8Gqx5p5/ http://www.tiktok.com",
                isSafari: signalIsSafari),
            "https://www.tiktok.com/t/ZP8Gqx5p5/")
    }

    func testShortcutTextInputExtractsCommaDelimitedURLs() {
        XCTAssertEqual(
            collapseText(
                "https://example.com/post,https://example.com/post/123",
                isSafari: false),
            "https://example.com/post/123")
    }

    func testShortcutTextInputTrimsPresentationPunctuation() {
        XCTAssertEqual(
            collapseText(
                "Detected (https://example.com/post).",
                isSafari: false),
            "https://example.com/post")
    }

    func testShortcutTextInputRequiresAnExtractedURL() {
        XCTAssertNil(
            collapseText(
                "Get On-Screen URLs returned one item", isSafari: false))
    }

    func testContainedSubsetCollapsesIntoCompleteURL() {
        XCTAssertEqual(
            collapse(
                ["example.com/post/123", "https://example.com/post/123"],
                isSafari: false),
            "https://example.com/post/123")
    }

    func testSingleCompleteURLIsAccepted() {
        XCTAssertEqual(
            collapse(
                ["https://www.tiktok.com/@luna/video/123"], isSafari: false),
            "https://www.tiktok.com/@luna/video/123")
    }

    func testValuesNotContainedInOneResultAreRejected() {
        XCTAssertNil(
            collapse(
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
                collapse([value], isSafari: false),
                "expected rejection for \(value)")
        }
    }

    func testSafariUsesCompleteOnScreenURL() {
        XCTAssertEqual(
            collapseText(
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
                text: "https://youtube.com", isSafari: true,
                safariTrackedURLString: "https://m.youtube.com/shorts/vPdLeu8Njok?ra=m",
                verdict: { .handleable(urlString: $0) }),
            .skip)
    }

    /// The tracked URL's freshness window is days wide, so a tracked URL on a
    /// DIFFERENT site than what's on screen is stale history. Saving it stores a
    /// page the user left long ago — and, being a stale article rather than the
    /// video they're looking at, it never reaches the media download at all.
    func testSafariIgnoresATrackedURLFromADifferentSite() {
        XCTAssertEqual(
            ProvideContextOnScreenURL.plan(
                text: "https://youtube.com", isSafari: true,
                safariTrackedURLString: "https://www.nytimes.com/2026/07/20/some-article.html",
                verdict: { .handleable(urlString: $0) }),
            .save("https://youtube.com"))
    }

    /// With no tracked URL, the on-screen value is still the fallback — that is
    /// what it was added for, and it must keep working.
    func testSafariStillUsesOnScreenURLWithoutATrackedURL() {
        XCTAssertEqual(
            ProvideContextOnScreenURL.plan(
                text: "https://m.youtube.com/shorts/vPdLeu8Njok?ra=m",
                isSafari: true, safariTrackedURLString: nil,
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

//
//  BypassPlanTests.swift
//  ClipTests
//

import XCTest
@testable import Clip

/// Exercises the ONE typed `BypassPlan` factory both the resolver (silent leg) and the
/// archive reader (web leg) consume — proving the split is correct and the two paths
/// can't diverge, plus the `BypassURLs` mapper.
final class BypassPlanTests: XCTestCase {

    private func url(_ string: String) -> URL {
        guard let url = URL(string: string) else { fatalError("bad test URL: \(string)") }
        return url
    }

    // MARK: - Trailing-dot first silent, never a pre-stage (the NYT speed fix)

    func testNYTLeadsWithTrailingDotSilentAndOmitsItFromPreStages() {
        let plan = BypassPlan.make(for: url("https://www.nytimes.com/2026/06/20/story.html"), directHTML: nil)
        // Trailing-dot is the FIRST silent strategy.
        XCTAssertEqual(plan.silent.first, .trailingDotHost)
        // It already ran silently and doesn't benefit from a JS retry, so it is NOT a
        // WKWebView pre-stage (the ~9s redundant pre-stage the NYT slowness came from).
        XCTAssertFalse(plan.webPreStages.contains(.trailingDotHost))
        // The web leg is third-party reader pages only.
        XCTAssertTrue(plan.webPreStages.allSatisfy { if case .thirdPartyWeb = $0 { return true }; return false })
        // archive.today is permitted as the bounded last resort.
        XCTAssertTrue(plan.allowsArchiveToday)
    }

    // MARK: - The silent / web split is by construction

    func testSilentLegHasNoWebStrategiesAndViceVersa() {
        // WSJ: silent leg is all URLSession transforms; web leg is third-party pages.
        let plan = BypassPlan.make(for: url("https://www.wsj.com/articles/x"), directHTML: nil)
        // No silent case can be a WKWebView pre-stage — the SilentStrategy type forbids
        // .thirdPartyWeb / .archiveToday entirely, so this is free, but assert the legs
        // are non-overlapping in intent: every web pre-stage benefits from a JS retry
        // OR is a trailing-dot not tried silently.
        for stage in plan.webPreStages {
            let valid = stage.benefitsFromJSRetry
                || (stage == .trailingDotHost && !plan.silent.contains(.trailingDotHost))
            XCTAssertTrue(valid, "unexpected pre-stage \(stage)")
        }
        XCTAssertFalse(plan.silent.isEmpty)
        XCTAssertTrue(plan.allowsArchiveToday)
    }

    // MARK: - The two consumers see a CONSISTENT plan (no divergent re-derivation)

    /// The resolver and the archive reader both call `make(for:directHTML:)`. With the
    /// same inputs they MUST get the same plan — the regression guard for the former
    /// double-compute that could produce different orderings.
    func testPlanIsStableForSameInputs() {
        let target = url("https://www.nytimes.com/2026/06/20/story.html")
        let a = BypassPlan.make(for: target, directHTML: nil)
        let b = BypassPlan.make(for: target, directHTML: nil)
        XCTAssertEqual(a, b)
    }

    // MARK: - Not paywalled ⇒ empty plan

    func testNonPaywalledHostYieldsEmptyPlan() {
        // A plain readable page on an unknown host with HTML that shows no paywall
        // evidence: the gate blocks, so the plan is empty + archive disallowed.
        let html = "<html><head><title>Free</title></head><body><article>"
            + String(repeating: "<p>Free open reporting here for everyone to read. </p>", count: 20)
            + "</article></body></html>"
        let plan = BypassPlan.make(for: url("https://blog.example.com/post"), directHTML: html)
        XCTAssertTrue(plan.silent.isEmpty)
        XCTAssertTrue(plan.webPreStages.isEmpty)
        XCTAssertFalse(plan.allowsArchiveToday)
    }

    // MARK: - Bounded silent chain

    func testSilentChainHasABoundedDeadline() {
        XCTAssertGreaterThan(BypassPlan.silentChainDeadlineSeconds, 0)
        XCTAssertLessThanOrEqual(BypassPlan.silentChainDeadlineSeconds, 30)
    }

    // MARK: - BypassURLs mapper

    func testBypassURLsSilentRequestURLs() {
        let article = url("https://www.nytimes.com/2026/06/20/story.html")
        // Trailing-dot rewrites the host.
        XCTAssertEqual(BypassURLs.requestURL(for: .trailingDotHost, article: article)?.host,
                       "www.nytimes.com.")
        // Ladder proxy prefixes the article URL.
        XCTAssertEqual(BypassURLs.requestURL(for: .ladderProxy(.oneFt), article: article)?.absoluteString,
                       "https://1ft.io/" + article.absoluteString)
        // Header/session transforms fetch the canonical article URL itself.
        XCTAssertEqual(BypassURLs.requestURL(for: .userAgent(.googlebotDesktop), article: article), article)
        XCTAssertEqual(BypassURLs.requestURL(for: .freshSession, article: article), article)
        // Zero-network / discovered strategies have no request URL.
        XCTAssertNil(BypassURLs.requestURL(for: .jsonLDBody, article: article))
        XCTAssertNil(BypassURLs.requestURL(for: .amp, article: article))
    }

    func testBypassURLsWebLoadURLs() {
        let article = url("https://www.wsj.com/articles/x")
        XCTAssertEqual(BypassURLs.loadURL(for: .thirdPartyWeb(.smry), article: article)?.absoluteString,
                       "https://smry.ai/" + article.absoluteString)
        XCTAssertEqual(BypassURLs.loadURL(for: .trailingDotHost, article: article)?.host, "www.wsj.com.")
    }
}

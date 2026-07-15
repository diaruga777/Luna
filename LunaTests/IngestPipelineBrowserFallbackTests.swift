//
//  IngestPipelineBrowserFallbackTests.swift
//  LunaTests
//

import LunaIngest
import LunaPaywallBypass
import XCTest
@testable import Luna

final class IngestPipelineBrowserFallbackTests: XCTestCase {

    /// Reuters currently puts URLSession behind a DataDome 401 while the same page
    /// remains readable in a browser with Luna's site rule active. A title-less
    /// background failure must therefore park for the direct-unlock WKWebView leg,
    /// not become a terminal failed item before that browser leg can run.
    func testReutersBackgroundRejectionRoutesToBrowserRecovery() async {
        let url = URL(string:
            "https://www.reuters.com/world/meta-used-ai-target-workers-with-medical-conditions-layoffs-former-employees-2026-07-14/"
        )!
        let fetcher = MockArticleFetcher() // no stub: every URLSession attempt fails

        let outcome = await IngestPipeline.process(
            IngestInput(url: url, source: .paste),
            timeout: 1,
            fetcher: fetcher
        )

        XCTAssertEqual(
            outcome,
            .needsArchive(title:
                "Meta Used Ai Target Workers With Medical Conditions Layoffs Former Employees")
        )
        XCTAssertEqual(
            BypassPlan.make(for: url, directHTML: nil).webPreStages,
            [.directUnlock],
            "Reuters must still have the direct-unlock browser stage that this outcome opens"
        )
    }

    /// Keep the other side of the routing boundary explicit: an ordinary host with
    /// no rule and no readable response remains a real failure rather than sending
    /// every broken URL through the interactive archive UI.
    func testUnknownHostWithoutBrowserRuleStillFails() async {
        let url = URL(string: "https://example.com/unreachable-article")!

        let outcome = await IngestPipeline.process(
            IngestInput(url: url, source: .paste),
            timeout: 1,
            fetcher: MockArticleFetcher()
        )

        XCTAssertEqual(outcome, .failed)
    }
}

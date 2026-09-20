//
//  LLMHandoffPromptTests.swift
//  LunaTests
//

import XCTest
@testable import LunaModels

/// The hand-off prompts travel in a URL query, so their size IS a behavior:
/// a prompt over budget is a deep link the provider truncates or refuses.
/// Each test feeds the longest realistic input and checks the ceiling and the
/// contract lines a reply must follow (`claudedocs/plans/ai-flows.md` §7).
final class LLMHandoffPromptTests: XCTestCase {

    private let longURL = URL(string:
        "https://www.example-news-site.com/2026/09/20/a-fairly-long-article-slug-that-goes-on-and-on"
        + "?utm_source=newsletter&utm_medium=email&id=1234567890")!
    private let failure = "the server refused the app's request with HTTP 403 — a browser identity "
        + "or a different route may get through"

    // MARK: Recovery

    func testRecoveryPromptStaysUnderBudgetForEveryContentApp() {
        for app in [LunaApp.luna, .reader, .downloader, .priceTracker] {
            let prompt = LLMHandoffPrompts.recovery(url: longURL, app: app, failure: failure)
            XCTAssertLessThanOrEqual(prompt.count, LLMHandoffPrompts.maxCharacters, "\(app)")
        }
    }

    func testRecoveryPromptNamesTheAppsOwnExtensionAndTheHeader() {
        let prompt = LLMHandoffPrompts.recovery(url: longURL, app: .reader, failure: failure)
        XCTAssertTrue(prompt.contains("\"<title>.lunar\""))
        XCTAssertTrue(prompt.contains("/* luna-recovery"))
        XCTAssertTrue(prompt.contains("\"url\":\"\(longURL.absoluteString)\""))
        XCTAssertTrue(prompt.contains("What went wrong: \(failure)."))
    }

    func testSingleKindAppsAskForTheirKindOnlyAndTheCentralAppAsksForAChoice() {
        let reader = LLMHandoffPrompts.recovery(url: longURL, app: .reader, failure: nil)
        XCTAssertTrue(reader.contains("\"kind\" is \"article\""))
        XCTAssertFalse(reader.contains("\"kind\":\"product\""))
        XCTAssertFalse(reader.contains("What went wrong"), "no failure line without a reason")

        let video = LLMHandoffPrompts.recovery(url: longURL, app: .downloader, failure: nil)
        XCTAssertTrue(video.contains("\"kind\" is \"media\""))
        XCTAssertTrue(video.contains("\"<title>.lunad\""))

        let price = LLMHandoffPrompts.recovery(url: longURL, app: .priceTracker, failure: nil)
        XCTAssertTrue(price.contains("\"kind\" is \"product\""))
        XCTAssertTrue(price.contains("\"<title>.lunas\""))

        let central = LLMHandoffPrompts.recovery(url: longURL, app: .luna, failure: nil)
        XCTAssertTrue(central.contains("Decide \"kind\" from the page"))
        for kind in ["article", "product", "media"] {
            XCTAssertTrue(central.contains("\"kind\":\"\(kind)\""), kind)
        }
        XCTAssertTrue(central.contains("\"<title>.luna\""))
    }

    func testRecoveryPromptBoundsAnOverlongFailureSentence() {
        let long = String(repeating: "x", count: 2_000)
        let prompt = LLMHandoffPrompts.recovery(url: longURL, app: .reader, failure: long)
        XCTAssertLessThanOrEqual(prompt.count, LLMHandoffPrompts.maxCharacters)
        XCTAssertTrue(prompt.contains("…"), "a cut is marked, not silent")
    }

    // MARK: Plugin creation

    private var longDescription: String {
        String(repeating: "Save recipes from cooking.example.com with the ingredient list, the steps "
            + "and the hero photo. Example: https://cooking.example.com/recipes/12345-lemon-pasta. ",
            count: 12)
    }

    func testCreationPromptStaysUnderBudgetWithTheLongestDescription() {
        let prompt = LLMHandoffPrompts.pluginCreation(description: longDescription, host: "cooking.example.com")
        XCTAssertLessThanOrEqual(prompt.count, LLMHandoffPrompts.maxCharacters)
        XCTAssertTrue(prompt.contains("…"), "the description was cut, and the cut is marked")
    }

    func testCreationPromptCarriesTheContractAndTheReferenceLink() {
        let prompt = LLMHandoffPrompts.pluginCreation(description: "Save recipes", host: "www.cooking.example.com")
        XCTAssertTrue(prompt.contains(LLMHandoffPrompts.pluginAPIReferenceURL))
        XCTAssertTrue(prompt.contains("/* luna-plugin"))
        XCTAssertTrue(prompt.contains("\"<name>.luna\""))
        XCTAssertTrue(prompt.contains("luna.register"))
        XCTAssertTrue(prompt.contains("\"id\":\"user.cooking.example.com\""), "www is dropped from the id")
        XCTAssertTrue(prompt.contains("\"hosts\":[\"cooking.example.com\",\"*.cooking.example.com\"]"))
        XCTAssertTrue(prompt.contains("--- REQUEST ---\nSave recipes\n--- END REQUEST ---"))
    }

    func testCreationPromptWithoutAHostStillHasAValidSkeleton() {
        let prompt = LLMHandoffPrompts.pluginCreation(description: "Anything", host: nil)
        XCTAssertTrue(prompt.contains("\"id\":\"user.example.com\""))
    }

    // MARK: Plugin correction

    func testCorrectionPromptStaysUnderBudgetWithManyFindings() {
        let errors = (1...20).map {
            "ingest returned a Model of kind product but produces lists only article "
            + "(attempt \($0), classify claimed article, ingest fetched https://cooking.example.com/recipes/\($0))"
        }
        let prompt = LLMHandoffPrompts.pluginCorrection(
            description: longDescription, host: "cooking.example.com", errors: errors)
        XCTAssertLessThanOrEqual(prompt.count, LLMHandoffPrompts.maxCharacters)
        XCTAssertTrue(prompt.contains("--- PROBLEMS FOUND ---\n- ingest returned"))
        XCTAssertTrue(prompt.contains(LLMHandoffPrompts.pluginAPIReferenceURL))
        XCTAssertTrue(prompt.contains("/* luna-plugin"))
        XCTAssertFalse(prompt.contains("Requirements:"), "the compact contract leaves the bullets to the reference")
    }
}

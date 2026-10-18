//
//  LLMDeepLinkTests.swift
//  LunaTests
//

import LunaDesignSystem
import LunaStorage
import UIKit
import XCTest
@testable import Luna
@testable import LunaModels

final class LLMDeepLinkTests: XCTestCase {

    /// Every character that would otherwise end the query value, or start
    /// another URL component, has to survive the trip as data.
    func testDelimitersAndNewlinesRoundTripThroughTheQuery() throws {
        let prompt = "a&b+c=d?e#f/g\nsecond line"
        let url = try XCTUnwrap(LLMDeepLink.url(for: .chatGPT, prompt: prompt))
        let value = try XCTUnwrap(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "q" })?.value)
        XCTAssertEqual(value, prompt)
    }

    func testTheClaudeLinkCarriesThePromptInQ() throws {
        let prompt = "recover https://example.com/a?b=c"
        let url = try XCTUnwrap(
            LLMDeepLink.url(for: .claude, prompt: prompt, claudeTarget: .chat))
        let value = try XCTUnwrap(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "q" })?.value)
        XCTAssertEqual(value, prompt)
    }

    /// A prompt that would overflow a provider's URL is no link at all: a
    /// truncated one arrives as a truncated instruction.
    func testAPromptTooLongForTheURLYieldsNoLink() {
        let long = String(repeating: "x", count: LLMDeepLink.maxURLCharacters + 1)
        for provider in LLMProvider.allCases {
            XCTAssertNil(LLMDeepLink.url(for: provider, prompt: long), "\(provider)")
        }
    }

    /// A prompt at the prompt budget still fits, encoding and all — that is
    /// what the URL ceiling has headroom for.
    func testAPromptAtTheBudgetStillBuildsALink() {
        let prompt = String(repeating: "word ", count: LLMHandoffPrompts.maxCharacters / 5)
        for provider in LLMProvider.allCases {
            XCTAssertNotNil(LLMDeepLink.url(for: provider, prompt: prompt), "\(provider)")
        }
    }

    func testTheClaudeTargetPicksTheSurface() throws {
        let chat = try XCTUnwrap(LLMDeepLink.url(for: .claude, prompt: "x", claudeTarget: .chat))
        let code = try XCTUnwrap(LLMDeepLink.url(for: .claude, prompt: "x", claudeTarget: .code))
        XCTAssertEqual(chat.absoluteString, "https://claude.ai/new?q=x")
        XCTAssertEqual(code.absoluteString, "https://claude.ai/code/new?q=x")
    }

    func testChatGPTUsesTheWebQueryRouteInsteadOfTheUnsupportedAppPromptRoute() throws {
        let chatGPT = try XCTUnwrap(LLMDeepLink.url(for: .chatGPT, prompt: "x"))
        XCTAssertEqual(chatGPT.absoluteString, "https://chatgpt.com/?q=x")
        XCTAssertNil(LLMDeepLink.fallbackURL(for: .chatGPT, prompt: "x"))

        XCTAssertNil(LLMDeepLink.fallbackURL(for: .claude, prompt: "x", claudeTarget: .chat))
        XCTAssertEqual(
            LLMDeepLink.fallbackURL(for: .claude, prompt: "x", claudeTarget: .code)?.absoluteString,
            "claude://code/new?q=x")
    }

    /// The preference is what the card's long-press menu writes, and what a
    /// link built without an explicit target reads.
    func testTheRememberedClaudeTargetDrivesTheDefaultLink() throws {
        let original = LLMProviderPreferences.claudeTarget
        defer { LLMProviderPreferences.claudeTarget = original }

        LLMProviderPreferences.claudeTarget = .code
        XCTAssertEqual(
            LLMDeepLink.url(for: .claude, prompt: "x")?.absoluteString,
            "https://claude.ai/code/new?q=x")
        LLMProviderPreferences.claudeTarget = .chat
        XCTAssertEqual(
            LLMDeepLink.url(for: .claude, prompt: "x")?.absoluteString,
            "https://claude.ai/new?q=x")
    }
}

@MainActor
final class SaveRecoveryLaunchTests: XCTestCase {
    private final class Launcher: LLMLaunching {
        var urls: [URL] = []
        func openLLM(_ url: URL, fallback: URL?) { urls.append(url) }
    }

    func testBothProvidersReceiveTheWholeRecoveryPrompt() throws {
        let item = SavedItem(urlString: "https://example.com/story?a=b&c=d")
        defer {
            if let record = LLMHandoffStore.shared.record(forItemID: item.id) {
                LLMHandoffStore.shared.clear(id: record.id)
            }
        }
        for provider in LLMProvider.allCases {
            let launcher = Launcher()
            XCTAssertTrue(SaveRecoveryHandoff.begin(item: item, provider: provider,
                claudeTarget: .chat, failure: "Wrong content", launcher: launcher))
            let url = try XCTUnwrap(launcher.urls.first)
            XCTAssertEqual(url.scheme, "https")
            XCTAssertEqual(url.host, provider == .chatGPT ? "chatgpt.com" : "claude.ai")
            let prompt = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "q" })?.value)
            XCTAssertEqual(prompt, SaveRecoveryHandoff.prompt(for: item, failure: "Wrong content"))
            XCTAssertEqual(UIPasteboard.general.string, prompt)
        }
    }
    func testOversizedRecoveryLinkOpensComposerWithFullPromptCopied() throws {
        let item = SavedItem(urlString: "https://example.com/" + String(repeating: "😀", count: 500))
        let failure = String(repeating: "😀", count: 3_000)
        let prompt = try XCTUnwrap(SaveRecoveryHandoff.prompt(for: item, failure: failure))
        XCTAssertNil(LLMDeepLink.url(for: .claude, prompt: prompt, claudeTarget: .chat))
        defer {
            if let record = LLMHandoffStore.shared.record(forItemID: item.id) {
                LLMHandoffStore.shared.clear(id: record.id)
            }
        }
        let launcher = Launcher()
        XCTAssertTrue(SaveRecoveryHandoff.begin(item: item, provider: .claude,
            claudeTarget: .chat, failure: failure, launcher: launcher))
        XCTAssertEqual(launcher.urls.first?.absoluteString, "https://claude.ai/new?q=")
        XCTAssertEqual(UIPasteboard.general.string, prompt)
    }

}

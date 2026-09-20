//
//  PluginCreateScreenTests.swift
//  LunaTests
//
//  Where a plugin is asked for (`claudedocs/plans/ai-flows.md` §5.1): what a
//  failed save writes into the box, and what the tap hands the provider.
//

import LunaDesignSystem
import LunaModels
import LunaPluginUI
import LunaStorage
import UIKit
import XCTest

@MainActor
final class PluginCreateScreenTests: XCTestCase {

    func testAFailedSavePrefillsTheURLTheFailureAndTheMatchedPlugins() {
        let text = PluginCreateViewController.prefill(
            url: URL(string: "https://recipes.example.com/slow-roast")!,
            failure: "Nothing readable was found on the page",
            matchedPluginIDs: ["user.recipes", "user.any"])

        XCTAssertTrue(text.contains("https://recipes.example.com/slow-roast"))
        XCTAssertTrue(text.contains("Nothing readable was found on the page"))
        XCTAssertTrue(text.contains("user.recipes, user.any"))
    }

    func testAPrefillWithoutAFailureOrPluginsIsJustTheURL() {
        let text = PluginCreateViewController.prefill(
            url: URL(string: "https://example.com/page")!, failure: nil)

        XCTAssertEqual(text, "https://example.com/page")
    }

    func testTheHostComesFromTheFirstLinkInTheDescription() {
        XCTAssertEqual(
            PluginCreateViewController.host(
                inDescription: "save recipes from https://WWW.Recipes.example.com/a and elsewhere"),
            "www.recipes.example.com")
        XCTAssertNil(
            PluginCreateViewController.host(inDescription: "the recipe site I use every week"))
    }

    func testTappingAProviderHandsItThePromptCarryingTheRequestAndHost() {
        let launcher = RecordingCreateLauncher()
        let screen = PluginCreateViewController(
            prefill: "https://recipes.example.com/slow-roast — save the recipe",
            launcher: launcher)
        _ = UITestSupport.host(screen)

        screen.row(LLMHandoffRowView(), didChoose: .chatGPT)

        XCTAssertEqual(launcher.providers, [.chatGPT])
        let prompt = launcher.prompts.first ?? ""
        XCTAssertTrue(prompt.contains("save the recipe"), prompt)
        XCTAssertTrue(prompt.contains("recipes.example.com"), prompt)
        XCTAssertTrue(prompt.contains("luna-plugin"), prompt)
    }

    func testAnEmptyDescriptionAsksForOneRatherThanOpeningAProvider() {
        let launcher = RecordingCreateLauncher()
        let screen = PluginCreateViewController(launcher: launcher)
        _ = UITestSupport.host(screen)

        screen.row(LLMHandoffRowView(), didChoose: .claude)

        XCTAssertTrue(launcher.prompts.isEmpty)
    }
}

private final class RecordingCreateLauncher: LLMLaunching {
    private(set) var providers: [LLMProvider] = []
    private(set) var prompts: [String] = []

    func launch(_ provider: LLMProvider, prompt: String) {
        providers.append(provider)
        prompts.append(prompt)
    }
}

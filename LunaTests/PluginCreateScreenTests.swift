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

        XCTAssertEqual(launcher.opened.first?.scheme, "chatgpt")
        let prompt = launcher.opened.first.flatMap(LLMHandoffPromptReader.prompt(in:)) ?? ""
        XCTAssertTrue(prompt.contains("save the recipe"), prompt)
        XCTAssertTrue(prompt.contains("recipes.example.com"), prompt)
        XCTAssertTrue(prompt.contains("luna-plugin"), prompt)
    }

    func testTheRequestIsRememberedSoTheScreenShowsItAgain() {
        let store = temporaryHandoffStore()
        let first = PluginCreateViewController(
            prefill: "https://recipes.example.com/a — save the recipe",
            handoffStore: store, launcher: RecordingCreateLauncher())
        _ = UITestSupport.host(first)
        first.row(LLMHandoffRowView(), didChoose: .chatGPT)

        let record = store.pluginRecord()
        guard case .plugin(let description, let host)? = record?.kind else {
            return XCTFail("no plugin hand-off was recorded")
        }
        XCTAssertEqual(description, "https://recipes.example.com/a — save the recipe")
        XCTAssertEqual(host, "recipes.example.com")

        let second = PluginCreateViewController(
            handoffStore: store, launcher: RecordingCreateLauncher())
        _ = UITestSupport.host(second)
        XCTAssertTrue(
            textViews(in: second).contains(
                "https://recipes.example.com/a — save the recipe"))
    }

    func testAnEmptyDescriptionAsksForOneRatherThanOpeningAProvider() {
        let launcher = RecordingCreateLauncher()
        let screen = PluginCreateViewController(launcher: launcher)
        _ = UITestSupport.host(screen)

        screen.row(LLMHandoffRowView(), didChoose: .claude)

        XCTAssertTrue(launcher.opened.isEmpty)
    }

    private func temporaryHandoffStore() -> LLMHandoffStore {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return LLMHandoffStore(containerURL: root)
    }

    private func textViews(in screen: UIViewController) -> [String] {
        views(in: screen.view).compactMap { ($0 as? UITextView)?.text }
    }

    private func views(in root: UIView) -> [UIView] {
        root.subviews + root.subviews.flatMap { views(in: $0) }
    }
}

@MainActor
private final class RecordingCreateLauncher: LLMLaunching {
    private(set) var opened: [URL] = []

    func openLLM(_ url: URL, fallback: URL?) { opened.append(url) }
}

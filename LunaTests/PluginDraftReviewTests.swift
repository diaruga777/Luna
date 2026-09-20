//
//  PluginDraftReviewTests.swift
//  LunaTests
//
//  The nutrition label an arriving plugin draft is read on
//  (`claudedocs/plans/ai-flows.md` §5.2): what it shows, what Save writes, and
//  what Discard does not.
//

import LunaDesignSystem
import LunaModels
import LunaPluginKit
import LunaPluginUI
import LunaStorage
import UIKit
import XCTest

@MainActor
final class PluginDraftReviewTests: XCTestCase {

    // MARK: - What the screen shows

    func testTheLabelNamesTheHostsHooksAndEveryCapability() async {
        let screen = makeScreen(source: Self.passingDraft)
        _ = UITestSupport.host(screen)
        await settle(screen)

        let text = labels(in: screen).joined(separator: "\n")
        XCTAssertTrue(text.contains("recipes.example.com"), text)
        XCTAssertTrue(text.contains("classify"), text)
        XCTAssertTrue(text.contains("ingest"), text)
        XCTAssertTrue(text.contains(PluginCapabilityCopy.sentence(for: .fetch)), text)
        XCTAssertTrue(text.contains(PluginCapabilityCopy.sentence(for: .html)), text)
        XCTAssertTrue(text.contains(PluginCapabilityCopy.containmentDisclosure), text)
    }

    func testACapabilityTheTestCannotServeIsMarkedNotTested() async {
        let screen = makeScreen(source: Self.storageDraft)
        _ = UITestSupport.host(screen)
        await settle(screen)

        let storage = PluginCapabilityCopy.sentence(for: .storage)
        let line = labels(in: screen).first { $0.contains(storage) }
        XCTAssertNotNil(line)
        XCTAssertEqual(
            line, L10n.string("Plugins_review07CapabilityNotTested", "•  " + storage))
    }

    func testAPassingDraftSaysWhatItProduced() async {
        let screen = makeScreen(source: Self.passingDraft)
        _ = UITestSupport.host(screen)
        await settle(screen)

        XCTAssertTrue(
            labels(in: screen).contains(L10n.string("Plugins_review11Passed", "article")),
            labels(in: screen).joined(separator: "\n"))
    }

    func testAFailingDraftShowsTheErrorAndOffersSaveAnyway() async {
        let screen = makeScreen(source: Self.failingDraft)
        _ = UITestSupport.host(screen)
        await settle(screen)

        XCTAssertTrue(
            labels(in: screen).contains { $0.contains("ingest returned null") },
            labels(in: screen).joined(separator: "\n"))
        XCTAssertEqual(
            buttonTitles(in: screen).first, L10n.string("Plugins_review14SaveAnyway"))
    }

    // MARK: - Save and Discard

    func testSaveInstallsTheDraftAndTellsTheDelegate() async {
        let importer = RecordingImporter()
        let delegate = RecordingReviewDelegate()
        let screen = makeScreen(source: Self.passingDraft, importer: importer)
        screen.delegate = delegate
        _ = UITestSupport.host(screen)
        await settle(screen)

        tap(L10n.string("Plugins_review13Save"), in: screen)
        await pump(until: { !importer.installed.isEmpty })

        XCTAssertEqual(importer.installed.count, 1)
        XCTAssertEqual(importer.installed.first?.summary.id, "stage.recipe-saver")
        XCTAssertTrue(delegate.didInstall)
    }

    func testDiscardWritesNothing() async {
        let importer = RecordingImporter()
        let delegate = RecordingReviewDelegate()
        let screen = makeScreen(source: Self.passingDraft, importer: importer)
        screen.delegate = delegate
        _ = UITestSupport.host(screen)
        await settle(screen)

        tap(L10n.string("Plugins_review15Discard"), in: screen)

        XCTAssertTrue(importer.installed.isEmpty)
        XCTAssertTrue(delegate.didDiscard)
        XCTAssertFalse(delegate.didInstall)
    }

    // MARK: - Generate again

    func testGenerateAgainAsksForACorrectionCarryingTheFindings() async {
        let launcher = RecordingLauncher()
        let screen = makeScreen(source: Self.failingDraft, launcher: launcher)
        _ = UITestSupport.host(screen)
        await settle(screen)

        screen.row(LLMHandoffRowView(), didChoose: .claude)

        let prompt = try? XCTUnwrap(launcher.prompts.first)
        XCTAssertEqual(launcher.providers, [.claude])
        XCTAssertTrue(prompt?.contains("recipes.example.com") ?? false)
        XCTAssertTrue(prompt?.contains("ingest returned null") ?? false)
        XCTAssertTrue(prompt?.contains("PROBLEMS FOUND") ?? false)
    }

    // MARK: - Fixtures

    private func makeScreen(
        source: String,
        importer: PluginImporting = RecordingImporter(),
        launcher: any LLMLaunching = RecordingLauncher()
    ) -> PluginDraftReviewViewController {
        PluginDraftReviewViewController(
            sourceText: source,
            origin: PluginDraftReviewViewController.Origin(
                description: "https://recipes.example.com/slow-roast — save the recipe",
                host: "recipes.example.com",
                targetURL: URL(string: "https://recipes.example.com/slow-roast"),
                recordID: nil),
            importer: importer,
            launcher: launcher)
    }

    /// Validation runs a real disposable runtime, so the assertions wait for the
    /// result rather than a fixed pump.
    private func settle(_ screen: PluginDraftReviewViewController) async {
        await pump(until: {
            self.labels(in: screen)
                .allSatisfy { $0 != L10n.string("Plugins_review10Testing") }
        })
    }

    private func pump(until condition: @escaping () -> Bool) async {
        for _ in 0..<600 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func labels(in screen: UIViewController) -> [String] {
        views(in: screen.view).compactMap { ($0 as? UILabel)?.text }
    }

    private func buttonTitles(in screen: UIViewController) -> [String] {
        views(in: screen.view).compactMap { ($0 as? UIButton)?.configuration?.title }
    }

    private func tap(_ title: String, in screen: UIViewController) {
        let button = views(in: screen.view).compactMap { $0 as? UIButton }
            .first { $0.configuration?.title == title }
        button?.sendActions(for: .touchUpInside)
    }

    private func views(in root: UIView) -> [UIView] {
        root.subviews + root.subviews.flatMap { views(in: $0) }
    }

    private static func draft(capabilities: String, ingest: String) -> String {
        """
        /* luna-plugin
        {"id":"stage.recipe-saver","name":"Recipe Saver","version":"2.0.0","api":1,\
        "produces":["article"],"match":{"hosts":["recipes.example.com"]},\
        "capabilities":\(capabilities)}
        */
        luna.register({
          classify({ url }) { return { kind: "article" }; },
          async ingest() { return \(ingest); }
        });
        """
    }

    private static let passingDraft = draft(
        capabilities: #"["fetch","html"]"#,
        ingest: #"{ kind: "article", title: "Slow Roast", html: "<p>Season it.</p>" }"#)

    private static let storageDraft = draft(
        capabilities: #"["fetch","html","storage"]"#,
        ingest: #"{ kind: "article", title: "Slow Roast", html: "<p>Season it.</p>" }"#)

    private static let failingDraft = draft(
        capabilities: #"["fetch","html"]"#, ingest: "null")
}

/// Previews from the real parser, and remembers what it was asked to install.
private final class RecordingImporter: PluginImporting {
    private(set) var installed: [PluginImportPreview] = []

    func preview(sourceText: String) throws -> PluginImportPreview {
        let manifest = try PluginManifestParser.parse(source: sourceText).get()
        return PluginImportPreview(
            summary: manifest.summary(hooks: [], isBundled: false),
            description: manifest.description, capabilities: manifest.capabilities,
            runsInBackground: manifest.runsInBackground,
            addedCapabilities: manifest.capabilities, requiresConsent: true,
            replacesVersion: nil, sourceText: sourceText)
    }

    func install(_ preview: PluginImportPreview, origin: PluginImportOrigin) throws {
        installed.append(preview)
    }
}

private final class RecordingLauncher: LLMLaunching {
    private(set) var providers: [LLMProvider] = []
    private(set) var prompts: [String] = []

    func launch(_ provider: LLMProvider, prompt: String) {
        providers.append(provider)
        prompts.append(prompt)
    }
}

@MainActor
private final class RecordingReviewDelegate: PluginDraftReviewDelegate {
    private(set) var didInstall = false
    private(set) var didDiscard = false

    func pluginDraftReviewDidInstall(_ controller: PluginDraftReviewViewController) {
        didInstall = true
    }

    func pluginDraftReviewDidDiscard(_ controller: PluginDraftReviewViewController) {
        didDiscard = true
    }
}

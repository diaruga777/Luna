//
//  PluginUIBridgeTests.swift
//  LunaTests
//

import LunaPluginKit
import LunaPluginRuntime
import LunaPluginUI
import XCTest

/// `luna.ui` (`claudedocs/plugins.md` §5): app-only, and `shareSheet` resolves
/// a `FileHandle` through the scratch store rather than trusting a bare path.
@MainActor
final class PluginUIBridgeTests: XCTestCase {

    private var runner: PluginJSFixtureRunner!
    private var presenter: FakePresenter!
    private var previousScratch: PluginScratchStore?
    private var previousPresenter: (any PluginUIPresenting)?

    private static let pluginID = "app.luna.uitest"

    private struct Answer: Decodable { let value: PluginJSONValue }

    override func setUp() {
        super.setUp()
        previousPresenter = PluginUIComposition.presenter
    }

    override func tearDown() {
        PluginPlatformServices.scratch = previousScratch
        PluginUIComposition.install(previousPresenter)
        runner?.cleanUp()
        runner = nil
        presenter = nil
        super.tearDown()
    }

    private func install(
        processKind: PluginProcessKind, capabilities: String, jsBody: String,
        file: StaticString, line: UInt
    ) {
        runner = PluginJSFixtureRunner(processKind: processKind)
        previousScratch = PluginPlatformServices.scratch
        PluginPlatformServices.scratch = runner.scratch
        presenter = FakePresenter()
        if processKind == .app { PluginUIComposition.install(presenter) }
        runner.capabilities.register(
            PluginUIBridge(processKind: processKind, scheduler: runner.runtime))
        try? runner.load(
            """
            /* luna-plugin
            { "id": "\(Self.pluginID)", "name": "UI", "version": "1.0.0", "api": 1,
              "capabilities": \(capabilities) }
            */
            luna.register({ async onAction() { \(jsBody) } });
            """, file: file, line: line)
    }

    private func answer(
        _ jsBody: String, processKind: PluginProcessKind = .app,
        capabilities: String = "[\"ui\"]",
        file: StaticString = #filePath, line: UInt = #line
    ) async -> String? {
        install(
            processKind: processKind, capabilities: capabilities, jsBody: jsBody,
            file: file, line: line)
        guard let answer = await runner.invoke(
            .onAction, pluginID: Self.pluginID, as: Answer.self, file: file, line: line)
        else { return nil }
        return answer.value.jsonText
    }

    // MARK: - App only

    func testEveryUICallRejectsUnavailableHereOutsideTheApp() async {
        for processKind: PluginProcessKind in [.share, .action] {
            let json = await answer(
                """
                try {
                    await luna.ui.toast("hi");
                    return { value: "no error" };
                } catch (error) {
                    return { value: error.code };
                }
                """, processKind: processKind)
            XCTAssertEqual(json, "\"unavailable-here\"", "\(processKind) shows nothing")
        }
    }

    // MARK: - shareSheet item shapes

    func testShareSheetPassesThroughAUrlAndAText() async {
        _ = await answer("""
            await luna.ui.shareSheet([
                "a note", { url: "https://example.com/a" }]);
            return { value: "done" };
        """)
        XCTAssertEqual(presenter.shareSheetItems.count, 2)
        guard case .text(let text) = presenter.shareSheetItems[0] else {
            return XCTFail("expected a text item")
        }
        XCTAssertEqual(text, "a note")
        guard case .url(let url) = presenter.shareSheetItems[1] else {
            return XCTFail("expected a url item")
        }
        XCTAssertEqual(url.absoluteString, "https://example.com/a")
    }

    /// A `FileHandle` a plugin just wrote resolves to the real file through
    /// the scratch store — the documented shape, dropped before this test.
    ///
    /// The presenter reads the file's bytes itself, inside `shareSheet`,
    /// because the hook call is the file's own scratch-generation holder: the
    /// directory is reaped the moment the call returns, exactly as it would
    /// be once a real `UIActivityViewController` finishes reading it.
    func testShareSheetResolvesAFileHandleToTheFileItWrote() async {
        _ = await answer("""
            const handle = await luna.files.write("greeting.txt", "hello plugin");
            await luna.ui.shareSheet([handle]);
            return { value: "done" };
        """, capabilities: "[\"ui\", \"files\"]")
        guard case .fileURL = presenter.shareSheetItems.first else {
            return XCTFail("the FileHandle should have resolved to a file, got \(presenter.shareSheetItems)")
        }
        XCTAssertEqual(presenter.fileContentsRead, ["hello plugin"])
    }

    /// The deleted exploit: a bare `{path}` named any file on disk. It must
    /// now be dropped rather than shared.
    func testShareSheetDropsABarePathInsteadOfOpeningAnyFileOnDisk() async {
        _ = await answer("""
            await luna.ui.shareSheet([{ path: "/etc/passwd" }]);
            return { value: "done" };
        """)
        XCTAssertTrue(
            presenter.shareSheetItems.isEmpty,
            "a bare path is not a documented item shape and must not be shared")
    }

    // MARK: - Fake

    private final class FakePresenter: PluginUIPresenting {
        private(set) var shareSheetItems: [PluginShareItem] = []
        /// Every `.fileURL` item's contents, read while `shareSheet` still
        /// runs — the file is gone once the hook call that wrote it returns.
        private(set) var fileContentsRead: [String] = []

        func prompt(
            title: String, message: String?, placeholder: String?, keyboard: PluginPromptKeyboard,
            secure: Bool, defaultValue: String?
        ) async -> String? { nil }

        func confirm(
            title: String, message: String?, ok: String?, cancel: String?, destructive: Bool
        ) async -> Bool { false }

        func choose(title: String, options: [PluginUIChoiceOption]) async -> String? { nil }

        func toast(_ message: String) async {}

        func shareSheet(items: [PluginShareItem]) async {
            shareSheetItems = items
            for case .fileURL(let url) in items {
                fileContentsRead.append((try? String(contentsOf: url, encoding: .utf8)) ?? "<unreadable>")
            }
        }
    }
}

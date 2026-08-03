//
//  SafariPillLabelTests.swift
//  LunaTests
//

import WebKit
import XCTest

/// Guards the text of the in-page Safari pill ("Read in Luna" / "Download in
/// Luna" / "Track in Luna").
///
/// The pill is a `<div role="button">` sized entirely by its own text plus
/// padding, so an empty label doesn't degrade gracefully — it renders as a
/// ~44x30 indigo stub with nothing in it. That is exactly what shipped once the
/// labels moved to `browser.i18n.getMessage`: web-extension i18n reads ONLY
/// `_locales/<locale>/messages.json`, and Xcode's synchronized-group resource
/// copy FLATTENS nested resource folders, dropping `messages.json` at the bundle
/// root where the extension can't see it. Every key then resolved to "".
///
/// Two independent regressions are covered:
///  1. `content.js` must fall back to its inline English defaults whenever the
///     i18n lookup comes back empty (also the standalone-harness condition —
///     these WKWebView tests have no `browser` global at all).
///  2. The BUILT extension must still contain `_locales/en/messages.json`, so
///     the real localization path works rather than silently living on the
///     fallback.
@MainActor
final class SafariPillLabelTests: XCTestCase {

    /// `LunaTests/SafariPillLabelTests.swift` -> repo root.
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private static let contentScriptSource: String = {
        let url = repoRoot.appendingPathComponent("LunaSafari/Resources/content.js")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()

    /// The keys `content.js` renders (extensionName/Description are manifest-only).
    private static let renderedKeys = [
        "readInLuna", "downloadInLuna", "trackInLuna", "openingLuna", "unlockedWithLuna",
        "setupCompleteTitle", "returnToApp",
    ]

    override func setUp() {
        super.setUp()
        XCTAssertFalse(
            Self.contentScriptSource.isEmpty,
            "content.js not found on disk -- check the path relative to #filePath")
    }

    // MARK: - The fallback

    /// With no `browser` global — the flattened-`_locales` condition, and the one
    /// every standalone content.js harness runs in — every rendered string must
    /// still come back non-empty.
    func testEveryRenderedStringSurvivesAnEmptyI18nLookup() {
        for key in Self.renderedKeys {
            let label = evaluate("window.__lunaLocalizedMessage(\(jsString(key))) || ''")
            XCTAssertFalse(
                label.isEmpty,
                "localizedMessage(\"\(key)\") returned \"\" with no browser.i18n -- an empty "
                    + "pill label renders as a text-less stub")
        }
    }

    /// The inline defaults must agree with the shipped resource, so a wording
    /// change in one place can't leave the two surfaces disagreeing.
    func testInlineDefaultsMatchTheLocalizedResource() throws {
        let url = Self.repoRoot
            .appendingPathComponent("LunaSafari/Resources/_locales/en/messages.json")
        let data = try Data(contentsOf: url)
        let messages = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: [String: String]])

        for key in Self.renderedKeys {
            let resourceValue = try XCTUnwrap(
                messages[key]?["message"], "_locales/en/messages.json has no \"\(key)\"")
            let fallback = evaluate("window.__lunaMessageDefaults[\(jsString(key))] || ''")
            XCTAssertEqual(
                fallback, resourceValue,
                "content.js's MESSAGE_DEFAULTS[\"\(key)\"] has drifted from messages.json")
        }
    }

    /// Any NEW `localizedMessage("…")` call site must bring a default with it.
    func testEveryLocalizedMessageCallSiteHasADefault() throws {
        let pattern = #"localizedMessage\(\s*"([A-Za-z0-9_]+)"\s*\)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let source = Self.contentScriptSource
        let matches = regex.matches(
            in: source, range: NSRange(source.startIndex..., in: source))
        XCTAssertFalse(matches.isEmpty, "found no localizedMessage() call sites -- bad regex?")

        for match in matches {
            guard let range = Range(match.range(at: 1), in: source) else { continue }
            let key = String(source[range])
            let fallback = evaluate("window.__lunaMessageDefaults[\(jsString(key))] || ''")
            XCTAssertFalse(
                fallback.isEmpty,
                "localizedMessage(\"\(key)\") has no entry in content.js's MESSAGE_DEFAULTS")
        }
    }

    // MARK: - The built bundle

    /// The embedded extension must keep `_locales/en/messages.json` nested — the
    /// build phase re-creates the directory the resource copy flattens. A bundle
    /// with `messages.json` at its root is the shipped-broken state.
    func testEmbeddedExtensionKeepsTheLocalesDirectory() throws {
        let plugIns = try XCTUnwrap(
            Bundle.main.builtInPlugInsURL, "test host has no PlugIns directory")
        let appex = plugIns.appendingPathComponent("LunaSafari.appex")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: appex.path),
            "LunaSafari.appex is not embedded in this test host build")

        let nested = appex.appendingPathComponent("_locales/en/messages.json")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: nested.path),
            "LunaSafari.appex has no _locales/en/messages.json -- browser.i18n.getMessage() "
                + "will return \"\" for every key")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: appex.appendingPathComponent("messages.json").path),
            "LunaSafari.appex still carries the flattened root messages.json")

        let data = try Data(contentsOf: nested)
        let messages = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: [String: String]])
        for key in Self.renderedKeys {
            XCTAssertFalse(
                (messages[key]?["message"] ?? "").isEmpty,
                "the bundled messages.json has no text for \"\(key)\"")
        }
    }

    // MARK: - Harness

    /// Evaluates content.js in a bare `WKWebView` (no extension host, so no
    /// `browser` global) and returns `expression` as a String.
    private func evaluate(_ expression: String) -> String {
        let expectation = expectation(description: "expression evaluated")
        var outcome = ""

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let delegate = LoadDelegate {
            webView.evaluateJavaScript(Self.contentScriptSource) { _, error in
                if let error { XCTFail("content.js failed to evaluate: \(error)") }
                webView.evaluateJavaScript(expression) { result, error in
                    if let error { XCTFail("\(expression) failed to evaluate: \(error)") }
                    outcome = result as? String ?? ""
                    expectation.fulfill()
                }
            }
        }
        webView.navigationDelegate = delegate
        webView.loadHTMLString(
            "<html><body><p>fixture</p></body></html>", baseURL: URL(string: "https://example.com/"))

        wait(for: [expectation], timeout: 10)
        withExtendedLifetime(delegate) {}
        return outcome
    }

    /// A JS string literal — the keys are identifiers, but quoting them through
    /// JSON keeps the interpolation honest.
    private func jsString(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value])
        let array = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }

    private final class LoadDelegate: NSObject, WKNavigationDelegate {
        private let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onFinish() }
    }
}

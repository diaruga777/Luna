//
//  SafariPillLabelTests.swift
//  LunaTests
//

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

    private static var contentScriptSource: String { SafariJSTestHarness.contentScript }

    /// The keys `content.js` renders (extensionName/Description are manifest-only).
    private static let renderedKeys = [
        "readInLuna", "downloadInLuna", "trackInLuna", "openingLuna", "unlockedWithLuna",
        "setupCompleteTitle", "returnToApp", "wasPriceOnDate",
        "findingSellers", "priceAtSeller", "noBetterPrice", "sellerLookupFailed",
        "closeVideo", "lunaActions", "playVideo", "openInLuna", "hideLuna", "videoPlaybackFailed",
    ]

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

    /// No message may contain a `$`.
    ///
    /// `$NAME$` is web-extension i18n PLACEHOLDER syntax and `$1`…`$9` are its
    /// positional substitutions, so WebKit does not treat either as text: it
    /// resolves the name against the message entry's `placeholders` dictionary.
    /// An entry that declares none hands that lookup a NULL object, and
    /// `WebExtensionLocalization::localizedStringForKey` dereferences it —
    /// SIGSEGV in the Web Content process, which Safari reports to the user as
    /// "A problem repeatedly occurred" and which no amount of JS `try`/`catch`
    /// can contain. `"Return to $APP$"` shipped exactly this on 2026-08-04 and
    /// broke EVERY page on the device, because the crash landed just before the
    /// content script could record its one-shot flag.
    ///
    /// Luna substitutes its own tokens in `content.js` (`{app}`), so a `$` in
    /// this file buys nothing and risks the whole browser. A future message that
    /// genuinely needs a placeholder must declare a `placeholders` dictionary for
    /// it — and then relax this test deliberately, having checked that path works.
    func testNoLocalizedMessageCarriesPlaceholderSyntax() throws {
        let url = Self.repoRoot
            .appendingPathComponent("LunaSafari/Resources/_locales/en/messages.json")
        let data = try Data(contentsOf: url)
        let messages = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        for (key, entry) in messages {
            let entry = try XCTUnwrap(entry as? [String: Any], "\"\(key)\" is not an object")
            let message = try XCTUnwrap(entry["message"] as? String, "\"\(key)\" has no message")
            guard message.contains("$") else { continue }
            XCTAssertNotNil(
                entry["placeholders"],
                "messages.json's \"\(key)\" is \"\(message)\", which carries i18n placeholder "
                    + "syntax with no \"placeholders\" dictionary to resolve it. "
                    + "browser.i18n.getMessage(\"\(key)\") will SEGFAULT the Web Content "
                    + "process and every page in Safari will fail to load. Use a "
                    + "$-free token and substitute it in content.js.")
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

    private lazy var js = SafariJSTestHarness(self)
    private var didLoadContentScript = false

    /// Evaluates `expression` against content.js in the shared bare `WKWebView`
    /// (no extension host, so no `browser` global). The fixture page is loaded
    /// ONCE per test — every key in a sweep is answered from the same document.
    private func evaluate(_ expression: String) -> String {
        if !didLoadContentScript {
            js.load(
                html: "<html><body><p>fixture</p></body></html>",
                urlString: "https://example.com/",
                scripts: [SafariJSTestHarness.contentScript])
            didLoadContentScript = true
        }
        return js.string(expression) ?? ""
    }

    /// A JS string literal — the keys are identifiers, but quoting them through
    /// JSON keeps the interpolation honest.
    private func jsString(_ value: String) -> String { SafariJSTestHarness.jsString(value) }
}

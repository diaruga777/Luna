//
//  SafariPluginHandlerSourceTests.swift
//  LunaTests
//

import XCTest

/// `SafariWebExtensionHandler` and its plugin-message seam run in their own
/// appex targets; LunaTests hosts on the central APP and cannot `@testable
/// import` an extension, and no test in this suite fakes `NSExtensionContext`
/// (it has no public initializer). The existing Safari-handler suites
/// (`SafariVideoOverlayTests`, `SafariAnnoyanceSuppressionTests`,
/// `SharedProductMatchingParityTests`, …) pin their SOURCE instead — the
/// exempt "source-text pins against the unlinked LunaSafari/ hand-copies"
/// category. This suite does the same for the plugin message types
/// (`claudedocs/plans/plugin-platform.md` §13.1) and for the per-target-file
/// split that answers them (`SafariPluginMessages+Luna.swift` /
/// `SafariPluginMessages+None.swift`), the same mechanism
/// `KindWiring+Luna.swift`/`KindWiring+Reader.swift` use — CLAUDE.md is
/// explicit that `#if canImport` is never a reliable per-target gate here.
@MainActor
final class SafariPluginHandlerSourceTests: XCTestCase {

    private var handlerSource: String {
        SafariJSTestHarness.source("LunaSafari/SafariWebExtensionHandler.swift")
    }
    private var lunaVariantSource: String {
        SafariJSTestHarness.source("LunaSafari/SafariPluginMessages+Luna.swift")
    }
    private var noneVariantSource: String {
        SafariJSTestHarness.source("LunaSafari/SafariPluginMessages+None.swift")
    }

    private static let expectedMessageTypes = [
        "plugins.catalog", "plugins.source", "plugins.fetch",
        "plugins.storage.get", "plugins.storage.set", "plugins.storage.delete", "plugins.storage.keys",
        "plugins.collection.put", "plugins.collection.get", "plugins.collection.delete",
        "plugins.collection.find", "plugins.collection.count",
        "plugins.log", "plugins.settings.get", "plugins.browserDeferred", "plugins.queueModel",
        "plugins.recoveryHandoff",
    ]

    /// The shared handler dispatches every `plugins.*` string by prefix, to
    /// one per-target seam — it never names an individual message type
    /// itself, so the per-type list lives in the implementation instead.
    func testTheSharedHandlerDispatchesEveryPluginMessageByPrefixToTheSeam() {
        let text = handlerSource
        XCTAssertFalse(text.isEmpty, "SafariWebExtensionHandler.swift is missing from disk")
        XCTAssertTrue(text.contains(#"type.hasPrefix("plugins.")"#))
        XCTAssertTrue(text.contains("SafariPluginMessages.handler"))
        XCTAssertTrue(text.contains("protocol SafariPluginMessaging"))
    }

    func testEveryPluginMessageTypeFromThePlanIsHandledByTheLunaVariant() {
        let text = lunaVariantSource
        XCTAssertFalse(text.isEmpty, "SafariPluginMessages+Luna.swift is missing from disk")
        for type in Self.expectedMessageTypes {
            XCTAssertTrue(text.contains("\"\(type)\""), "missing a case for \(type)")
        }
    }

    /// Every capability-gated message checks the plugin actually declared that
    /// capability — `pluginDeclares` is the one gate every one of them shares,
    /// so the content script is never trusted to enforce its own grants.
    func testCapabilityGatedMessagesCheckPluginDeclares() {
        let text = lunaVariantSource
        for capability in ["storage", "fetch", "settings", "browser"] {
            XCTAssertTrue(
                text.contains("capability: .\(capability)"),
                "no message checks pluginDeclares(id:capability: .\(capability))")
        }
    }

    /// The appex shapes a `luna.fetch` request through the SAME type the
    /// JavaScriptCore bridge uses (`PluginFetchShapingParityTests` pins what
    /// that type answers). Building a `PluginFetchRequest` by hand here is what
    /// dropped `userAgent` and every structured body in Safari.
    func testTheFetchMessageShapesItsRequestThroughTheSharedShaper() {
        let text = lunaVariantSource
        XCTAssertTrue(text.contains("PluginFetchRequestShaping.request("))
        XCTAssertFalse(
            text.contains("PluginFetchRequest("),
            "the appex must not build a request of its own")
    }

    /// The message-size cap the content script relies on (§13.1: a plugin
    /// source over 1.5 MB is skipped in Safari and logged).
    func testTheSourceSizeCapMatchesThePlan() {
        XCTAssertTrue(lunaVariantSource.contains("1_500_000"))
    }

    /// No save exists yet in Safari (§8.2) — the browser-deferred reply must
    /// hand back a `save` route, never a `resolvedmedia`/`read` one meant for
    /// an existing item.
    func testBrowserDeferredAnswersASaveDeepLink() {
        XCTAssertTrue(lunaVariantSource.contains("LunaDeepLink.saveLink("))
        XCTAssertFalse(lunaVariantSource.contains("addingPercentEncoding"))
    }

    /// `capability-not-declared` is the grant answer and nothing else: a
    /// malformed message answers `bad-argument`, so an author debugging a
    /// typo'd key is not told their manifest lacks the capability. Every
    /// reader of the refusal is the tail of a `pluginDeclares` guard.
    func testAMalformedMessageAnswersBadArgumentRatherThanAPermissionDenial() {
        let text = lunaVariantSource
        XCTAssertTrue(text.contains(#"["error": "capability-not-declared"]"#))
        XCTAssertTrue(text.contains(#"["error": "bad-argument", "message": detail]"#))
        var searched = text.startIndex..<text.endIndex
        var uses = 0
        while let found = text.range(of: "Self.notDeclared", range: searched) {
            searched = found.upperBound..<text.endIndex
            let lookBack = text.index(
                found.lowerBound, offsetBy: -200, limitedBy: text.startIndex)
                ?? text.startIndex
            uses += 1
            XCTAssertTrue(
                text[lookBack..<found.lowerBound].contains("pluginDeclares(id: id, capability:"),
                "capability-not-declared is answered without a grant check")
        }
        XCTAssertGreaterThan(uses, 5, "the refusal payload is no longer shared")
    }

    /// A row the store refused for size answers a code, never `ok: false`
    /// — the content script rejects on a code, and a bare `ok: false` used to
    /// read as a completed write.
    func testAStorageRowOverTheCapAnswersTooLarge() {
        let text = lunaVariantSource
        XCTAssertTrue(text.contains(#""error": "too-large""#))
        XCTAssertTrue(text.contains("PluginKVStore.maxValueBytes"))
    }

    /// `luna.settings.get` answers the manifest field's own default, the same
    /// answer `PluginSettingsBridge.value` gives in the app — a plugin
    /// reading a setting nobody has touched must not have to write its call
    /// twice.
    func testASettingsReadAnswersTheManifestDefault() {
        XCTAssertTrue(lunaVariantSource.contains("field.defaultJSON"))
    }

    /// Logging needs no capability, but it does need a PLUGIN: the id names a
    /// category in the shared diagnostic log.
    func testTheLogMessageChecksThePluginIsEnabled() {
        let text = lunaVariantSource
        guard let range = text.range(of: "private func pluginLog(") else {
            return XCTFail("pluginLog is gone from the handler")
        }
        let body = text[range.lowerBound...].prefix(400)
        XCTAssertTrue(
            body.contains("enabledPlugin(id: id) != nil"),
            "plugins.log serves an id no enabled plugin owns")
    }

    /// One directory scan and one manifest parse per process, not per message:
    /// a classify makes twenty `plugins.*` calls inside an appex with an
    /// ~80 MB ceiling. `plugins.catalog` — the page's first message, and the
    /// one that builds the stamp the content script caches by — rescans.
    func testTheEnabledSetIsCachedForTheProcessAndRescannedByTheCatalog() {
        let text = lunaVariantSource
        XCTAssertTrue(text.contains("private var cachedEnabledPlugins: [InstalledPlugin]?"))
        XCTAssertTrue(text.contains("if !rescanning, let cachedEnabledPlugins { return cachedEnabledPlugins }"))
        guard let range = text.range(of: "private func pluginCatalogPayload(") else {
            return XCTFail("pluginCatalogPayload is gone from the handler")
        }
        XCTAssertTrue(
            text[range.lowerBound...].prefix(200).contains("enabledPlugins(rescanning: true)"),
            "the catalog message must rebuild the cached enabled set")
    }

    /// The whole point of the split: the shared file (built into all four
    /// Safari appexes) must never name the module only the central target
    /// links, and must never gate on `canImport` (CLAUDE.md: not a reliable
    /// per-target signal here) — only the per-target file split is.
    func testTheSharedHandlerNamesNeitherLunaPluginKitNorCanImport() {
        let text = handlerSource
        XCTAssertFalse(text.contains("LunaPluginKit"), "the shared handler must not name LunaPluginKit")
        XCTAssertFalse(text.contains("canImport"), "the shared handler must not gate on canImport")
    }

    /// `+Luna` is the one variant that actually imports the plugin platform;
    /// `+None` stays a plain `nil` with no such dependency.
    func testOnlyTheLunaVariantImportsThePluginPlatform() {
        XCTAssertTrue(lunaVariantSource.contains("import LunaPluginKit"))
        XCTAssertTrue(lunaVariantSource.contains("import LunaBundledPlugins"))
        XCTAssertFalse(noneVariantSource.contains("LunaPluginKit"))
        XCTAssertFalse(noneVariantSource.contains("LunaBundledPlugins"))
        XCTAssertFalse(handlerSource.contains("canImport"))
        XCTAssertFalse(lunaVariantSource.contains("canImport"))
        XCTAssertFalse(noneVariantSource.contains("canImport"))
    }

    /// Both variants declare the exact same public seam, so swapping one for
    /// the other (per target) is source-compatible.
    func testBothVariantsDeclareTheSameHandlerProperty() {
        XCTAssertTrue(lunaVariantSource.contains("static let handler: SafariPluginMessaging?"))
        XCTAssertTrue(noneVariantSource.contains("static let handler: SafariPluginMessaging?"))
        XCTAssertTrue(noneVariantSource.contains("= nil"))
    }

    func testRecoveryHandoffIsOnlyOpenedAfterAnExplicitPluginSaveAttempt() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("LunaSafari/Resources/content.js"),
            encoding: .utf8)
        let passiveWalk = try XCTUnwrap(source.range(of: "function runPluginWalkForPage()"))
        let ingestTarget = try XCTUnwrap(source.range(of: "function pluginSaveTargetFor"))
        let between = String(source[passiveWalk.lowerBound..<ingestTarget.lowerBound])

        XCTAssertFalse(between.contains("persistPluginRecoveryHandoff("))
        XCTAssertTrue(String(source[ingestTarget.lowerBound...]).contains(
            "persistPluginRecoveryHandoff(walk.matched, walk.outcomes)"))
    }
}

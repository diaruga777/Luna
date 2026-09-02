//
//  SafariPluginHandlerSourceTests.swift
//  LunaTests
//

import XCTest

/// `SafariWebExtensionHandler` runs in its own appex target; LunaTests hosts
/// on the central APP and cannot `@testable import` an extension, and no test
/// in this suite fakes `NSExtensionContext` (it has no public initializer).
/// The existing Safari-handler suites (`SafariVideoOverlayTests`,
/// `SafariAnnoyanceSuppressionTests`, `SharedProductMatchingParityTests`, …)
/// pin its SOURCE instead — the exempt "source-text pins against the unlinked
/// LunaSafari/ hand-copies" category. This suite does the same for the plugin
/// message types (`claudedocs/plans/plugin-platform.md` §13.1).
@MainActor
final class SafariPluginHandlerSourceTests: XCTestCase {

    private var source: String {
        SafariJSTestHarness.source("LunaSafari/SafariWebExtensionHandler.swift")
    }

    private static let expectedMessageTypes = [
        "plugins.catalog", "plugins.source", "plugins.fetch",
        "plugins.storage.get", "plugins.storage.set", "plugins.storage.delete", "plugins.storage.keys",
        "plugins.collection.put", "plugins.collection.get", "plugins.collection.delete",
        "plugins.collection.find", "plugins.collection.count",
        "plugins.log", "plugins.settings.get", "plugins.browserDeferred", "plugins.queueModel",
    ]

    func testEveryPluginMessageTypeFromThePlanIsHandled() {
        let text = source
        XCTAssertFalse(text.isEmpty, "SafariWebExtensionHandler.swift is missing from disk")
        for type in Self.expectedMessageTypes {
            XCTAssertTrue(text.contains("\"\(type)\""), "missing a case for \(type)")
        }
    }

    /// Every capability-gated message checks the plugin actually declared that
    /// capability — `pluginDeclares` is the one gate every one of them shares,
    /// so the content script is never trusted to enforce its own grants.
    func testCapabilityGatedMessagesCheckPluginDeclares() {
        let text = source
        for capability in ["storage", "fetch", "settings", "browser"] {
            XCTAssertTrue(
                text.contains("capability: .\(capability)"),
                "no message checks pluginDeclares(id:capability: .\(capability))")
        }
    }

    /// Every plugin.* payload builder answers nothing unless the running host
    /// is the central app — the single-kind hosts run no plugin platform.
    func testEveryPluginPayloadBuilderChecksTheCentralHostGate() {
        let text = source
        XCTAssertTrue(
            text.contains("private static var hostSupportsPlugins: Bool { isCentralLunaHost }"))
        let builders = [
            "pluginCatalogPayload", "pluginSourcePayload", "pluginFetch",
            "pluginStorageGet", "pluginStorageSet", "pluginStorageDelete", "pluginStorageKeys",
            "pluginCollectionPut", "pluginCollectionGet", "pluginCollectionDelete",
            "pluginCollectionFind", "pluginCollectionCount",
            "pluginLog", "pluginSettingsGet", "pluginBrowserDeferred", "pluginQueueModel",
        ]
        for name in builders {
            guard let range = text.range(of: "func \(name)(") else {
                XCTFail("missing \(name)")
                continue
            }
            // The gate check is the guard's own first clause, close to the
            // signature — a wide-but-bounded window avoids depending on exact
            // formatting while still failing if the check moves out of the
            // guard entirely.
            let windowEnd = text.index(range.lowerBound, offsetBy: 400, limitedBy: text.endIndex)
                ?? text.endIndex
            let body = text[range.lowerBound..<windowEnd]
            XCTAssertTrue(
                body.contains("hostSupportsPlugins"),
                "\(name) does not check hostSupportsPlugins near its signature")
        }
    }

    /// The message-size cap the content script relies on (§13.1: a plugin
    /// source over 1.5 MB is skipped in Safari and logged).
    func testTheSourceSizeCapMatchesThePlan() {
        XCTAssertTrue(source.contains("1_500_000"))
    }

    /// No save exists yet in Safari (§8.2) — the browser-deferred reply must
    /// hand back a `save` route, never a `resolvedmedia`/`read` one meant for
    /// an existing item.
    func testBrowserDeferredAnswersASaveDeepLink() {
        XCTAssertTrue(source.contains("://save?url="))
    }
}

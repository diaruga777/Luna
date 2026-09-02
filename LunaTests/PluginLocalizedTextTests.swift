//
//  PluginLocalizedTextTests.swift
//  LunaTests
//

import LunaPluginKit
import XCTest

/// `PluginLocalizedText.resolve`'s fallback order, pinned independent of the
/// manifest parser (`PluginManifestParserTests` exercises it end to end) and
/// mirrored by `LunaPluginHost.resolveLocalized`
/// (`SafariPluginHostTests.testResolveLocalizedMatchesTheSwiftRule`) and
/// `bridge.mjs`'s `resolveLocalized`.
final class PluginLocalizedTextTests: XCTestCase {

    private let table = ["en": "Hello", "de-AT": "Servus", "de": "Hallo"]

    func testAnExactTagWins() {
        XCTAssertEqual(PluginLocalizedText.resolve(table, preferring: ["de-AT"]), "Servus")
    }

    func testAnUnmatchedTagFallsBackToItsLanguagePrefix() {
        XCTAssertEqual(PluginLocalizedText.resolve(table, preferring: ["de-CH"]), "Hallo")
    }

    func testNoMatchAtAllFallsBackToEnglish() {
        XCTAssertEqual(PluginLocalizedText.resolve(table, preferring: ["fr", "es"]), "Hello")
    }

    func testTheFirstPreferredLanguageThatMatchesWins() {
        XCTAssertEqual(
            PluginLocalizedText.resolve(table, preferring: ["fr", "de-AT", "de"]), "Servus")
    }

    func testATableWithNoEnglishAndNoMatchAnswersAnEmptyString() {
        XCTAssertEqual(PluginLocalizedText.resolve(["de": "Hallo"], preferring: ["fr"]), "")
    }
}

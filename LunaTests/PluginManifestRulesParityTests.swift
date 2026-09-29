//
//  PluginManifestRulesParityTests.swift
//  LunaTests
//

import LunaModels
import LunaPluginKit
import XCTest

/// `PluginManifestRules.json` against `PluginManifestParser`'s own constants.
///
/// The file is the ONE manifest-rule table: the parser enforces these limits in
/// Swift and `tools/plugin-sim/run.mjs` reads the same file instead of the
/// hand-written validator it used to carry. A cross-artifact pin, which is the
/// exempt category — nothing here re-states a constant for its own sake; each
/// assertion is a claim that two artifacts still agree.
final class PluginManifestRulesParityTests: XCTestCase {

    /// The table as the BUILT bundle carries it. A file that never reached the
    /// resource bundle would leave the harness reading a rule the app has not
    /// got.
    private func bundledRules() throws -> PluginManifestRules {
        try XCTUnwrap(
            PluginManifestRules.bundled,
            "PluginManifestRules.json is missing from LunaPluginKit's resource bundle")
    }

    /// The same file as it sits in the repository — the copy `run.mjs` reads
    /// by path.
    private func repositoryRules() throws -> PluginManifestRules {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "LunaLibraries/Sources/LunaPluginKit/Resources/PluginManifestRules.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(PluginManifestRules.self, from: data)
    }

    func testTheHarnessReadsTheSameFileTheAppBundles() throws {
        XCTAssertEqual(try repositoryRules(), try bundledRules())
    }

    func testEveryLimitMatchesTheParser() throws {
        let rules = try bundledRules()
        XCTAssertEqual(rules.api.current, PluginAPIVersion.current)
        XCTAssertEqual(rules.source.maxKB, PluginManifestParser.maxSourceKB)
        XCTAssertEqual(rules.id.maxLength, PluginManifestParser.idMaxLength)
        XCTAssertEqual(rules.name.maxLength, PluginManifestParser.nameMaxLength)
        XCTAssertEqual(rules.description.maxLength, PluginManifestParser.descriptionMaxLength)
        XCTAssertEqual(rules.version.maxLength, PluginManifestParser.versionMaxLength)
        XCTAssertEqual(
            Set(rules.id.characters), PluginManifestParser.idCharacters)
        XCTAssertTrue(rules.id.forbidsLeadingDot)
        XCTAssertTrue(rules.id.forbidsTrailingDot)
        XCTAssertTrue(rules.id.forbidsDoubleDot)
    }

    func testEveryNameListMatchesItsSwiftEnum() throws {
        let rules = try bundledRules()
        XCTAssertEqual(
            Set(rules.kinds), Set(PluginModelKind.allCases.map(\.rawValue)))
        XCTAssertEqual(
            Set(rules.capabilities), Set(PluginCapabilityName.allCases.map(\.rawValue)))
        XCTAssertEqual(
            Set(rules.exportInputFormats),
            Set(PluginExportInputFormat.allCases.map(\.rawValue)))
    }

    /// The pattern the harness compiles has to accept and reject the same
    /// versions `PluginVersion.init` does; a regular expression is the only
    /// shape a JavaScript validator can carry, so it is checked against the
    /// real parser rather than read.
    func testTheVersionPatternAgreesWithTheVersionParser() throws {
        let pattern = try bundledRules().version.pattern
        let regex = try NSRegularExpression(pattern: pattern)
        for text in ["1.0.0", "0.0.1", "12.34.56", "1.2.3", "999999999.0.0"] {
            XCTAssertNotNil(PluginVersion(text), text)
            XCTAssertTrue(matches(regex, text), "\(text) should match the pattern")
        }
        for text in ["1.0", "1.0.0.0", "1.0.x", "v1.0.0", "1..0", "1.0.0-beta", ""] {
            XCTAssertNil(PluginVersion(text), text)
            XCTAssertFalse(matches(regex, text), "\(text) should not match the pattern")
        }
    }

    func testSettingsHooksAndExportAvailabilityMatchNativeEnums() throws {
        let rules = try bundledRules()
        XCTAssertEqual(Set(rules.settingTypes), Set(PluginSettingFieldType.allCases.map(\.rawValue)))
        XCTAssertEqual(Set(rules.hooks), Set(PluginHook.allCases.map(\.rawValue)))
        for kind in PluginModelKind.allCases {
            XCTAssertEqual(Set(rules.exportInputsByKind[kind.rawValue] ?? []),
                           Set(PluginExportInputAvailability.formats(for: kind).map(\.rawValue)))
        }
    }

    func testSharedAuthoringManifestCases() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Plugins/manifest-cases.json")
        let cases = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        for fixture in cases {
            let data = try JSONSerialization.data(withJSONObject: fixture["manifest"]!, options: [.fragmentsAllowed])
            let source = "/* luna-plugin\n" + String(decoding: data, as: UTF8.self) + "\n*/"
            let result = PluginManifestParser.parse(source: source)
            let valid: Bool
            switch result { case .success: valid = true; case .failure: valid = false }
            XCTAssertEqual(valid, fixture["valid"] as? Bool, "\(fixture["name"] ?? "fixture"): \(result)")
        }
    }

    private func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
            != nil
    }

    /// The harness must actually READ the file rather than keep its own copy
    /// of the table beside it.
    func testTheNodeHarnessReadsTheRulesFileRatherThanRepeatingIt() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("tools/plugin-sim/manifest.mjs")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains("PluginManifestRules.json"))
        XCTAssertFalse(
            source.contains("\"notifications\""),
            "manifest.mjs still spells the capability list out by hand")
    }
}

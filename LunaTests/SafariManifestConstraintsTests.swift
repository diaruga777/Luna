//
//  SafariManifestConstraintsTests.swift
//  LunaTests
//

import XCTest

/// `LunaSafari/Resources/manifest.json` constraints that App Store Connect
/// enforces at upload time (ITMS-90849) but that nothing in the build checks —
/// today these are doc-only. Reads the committed source file, not a built
/// bundle: none of these three ever differ between source and build product.
final class SafariManifestConstraintsTests: XCTestCase {

    private var repositoryRoot: URL {
        URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
    }

    private func manifest() throws -> [String: Any] {
        let url = repositoryRoot.appendingPathComponent("LunaSafari/Resources/manifest.json")
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }

    /// The manifest's `description` is a `__MSG_…__` reference; the actual
    /// English text ITMS-90849 measures lives in the locale's messages file.
    private func localizedDescription() throws -> String {
        let url = repositoryRoot.appendingPathComponent("LunaSafari/Resources/_locales/en/messages.json")
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        let messages = try XCTUnwrap(object as? [String: Any])
        let entry = try XCTUnwrap(messages["extensionDescription"] as? [String: Any])
        return try XCTUnwrap(entry["message"] as? String)
    }

    func testDescriptionIsAtMost112Characters() throws {
        let description = try localizedDescription()
        XCTAssertLessThanOrEqual(
            description.count, 112,
            "Safari extension description is \(description.count) chars — ITMS-90849 rejects an upload past 112")
    }

    func testBackgroundPageIsNotPersistent() throws {
        let manifest = try manifest()
        let background = try XCTUnwrap(manifest["background"] as? [String: Any])
        let persistent = try XCTUnwrap(background["persistent"] as? Bool)
        XCTAssertFalse(persistent, "Safari extension's background page must declare \"persistent\": false")
    }

    func testIconKeysAreAllNumericStrings() throws {
        let manifest = try manifest()
        let icons = try XCTUnwrap(manifest["icons"] as? [String: Any])
        XCTAssertFalse(icons.isEmpty, "manifest.json has no icons entries")
        for key in icons.keys {
            XCTAssertNotNil(
                Int(key), "manifest.json icons key \"\(key)\" is not a numeric string")
        }
    }
}

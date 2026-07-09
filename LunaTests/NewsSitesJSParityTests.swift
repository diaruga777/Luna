//
//  NewsSitesJSParityTests.swift
//  LunaTests
//

import Foundation
import LunaURLClassification
import XCTest

/// Guards the generated `LunaSafari/Resources/news_hosts.generated.js` artifact
/// against drift from the source-of-truth `NewsSites.hardPaywall` / `.free` host
/// lists (`LunaURLClassification`). The Safari extension's `content.js` treats a
/// known article/news host as an article without needing its DOM scorer to agree
/// -- see `content.js`'s `isKnownArticleHost` / `isKnownHardPaywallHost` -- so the
/// extension and the main app must share the exact same host data, not a
/// hand-copied approximation of it.
///
/// This test doubles as the generator: set `RECORD_NEWS_HOSTS=1` in the
/// environment (as `TEST_RUNNER_RECORD_NEWS_HOSTS=1` when driving via
/// `xcodebuild test`, so the value reaches the test runner rather than just the
/// build settings -- see `RECORD_SNAPSHOTS` in `SnapshotTesting.swift` for the
/// same convention) to (re)write the committed artifact from the current Swift
/// arrays. Without it, the test asserts the committed file matches byte-for-byte
/// and fails with a re-record hint on drift.
final class NewsSitesJSParityTests: XCTestCase {

    /// `LunaTests/NewsSitesJSParityTests.swift` -> repo root -> `LunaSafari/Resources/news_hosts.generated.js`.
    private static var artifactURL: URL {
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile.deletingLastPathComponent().deletingLastPathComponent()
        return repoRoot.appendingPathComponent("LunaSafari/Resources/news_hosts.generated.js")
    }

    /// One quoted host per line, indented, comma-terminated (including the last
    /// entry -- JS allows a trailing comma in an array literal, which keeps this
    /// generator simple and every line's diff independent of its neighbors).
    private static func jsArrayLines(_ hosts: [String], indent: String) -> String {
        hosts.map { indent + "\"" + $0 + "\"," }.joined(separator: "\n")
    }

    /// The expected file contents, built directly from the compiled `NewsSites`
    /// arrays (never by string-parsing the .swift source), in source order.
    private static func expectedContents() -> String {
        let lines = [
            "// GENERATED from NewsSites.swift (LunaURLClassification) by NewsSitesJSParityTests.",
            "// Do NOT edit by hand. Regenerate with: TEST_RUNNER_RECORD_NEWS_HOSTS=1 xcodebuild test -scheme Luna -destination \"platform=iOS Simulator,id=$SIM\" -configuration Debug -derivedDataPath \"$DD\" DIAGNOSE_MISSING_TARGET_DEPENDENCIES=NO",
            "self.__LUNA_NEWS_HOSTS = {",
            "  hardPaywall: [",
            jsArrayLines(NewsSites.hardPaywall, indent: "    "),
            "  ],",
            "  free: [",
            jsArrayLines(NewsSites.free, indent: "    "),
            "  ]",
            "};",
            "",
        ]
        return lines.joined(separator: "\n")
    }

    func testGeneratedArtifactMatchesNewsSites() {
        let expected = Self.expectedContents()

        if ProcessInfo.processInfo.environment["RECORD_NEWS_HOSTS"] == "1" {
            do {
                try expected.write(to: Self.artifactURL, atomically: true, encoding: .utf8)
                XCTContext.runActivity(named: "Recorded news_hosts.generated.js") { _ in }
            } catch {
                XCTFail("Failed to write news_hosts.generated.js: \(error)")
            }
            return
        }

        guard let actual = try? String(contentsOf: Self.artifactURL, encoding: .utf8) else {
            XCTFail("news_hosts.generated.js not found at \(Self.artifactURL.path) -- "
                    + "generate it with TEST_RUNNER_RECORD_NEWS_HOSTS=1")
            return
        }
        XCTAssertEqual(
            actual, expected,
            "news_hosts.generated.js is stale relative to NewsSites.swift -- regenerate with "
            + "TEST_RUNNER_RECORD_NEWS_HOSTS=1 xcodebuild test -scheme Luna ...")
    }
}

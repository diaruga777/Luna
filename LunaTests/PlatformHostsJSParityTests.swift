//
//  PlatformHostsJSParityTests.swift
//  LunaTests
//

import Foundation
import LunaURLClassification
import XCTest

/// Guards the generated `LunaSafari/Resources/platform_hosts.generated.js` artifact
/// against drift from the source-of-truth `PlatformRecognizer.rules` host lists
/// (`LunaURLClassification`). The Safari extension's `content.js` treats a
/// recognized platform host as a Downloader candidate -- see `content.js`'s
/// `recognizedPlatformPage` -- so the extension and the main app must share the
/// exact same host data, not a hand-copied approximation of it. Mirrors the
/// `NewsSitesJSParityTests` pattern exactly.
///
/// This test doubles as the generator: set `RECORD_PLATFORM_HOSTS=1` in the
/// environment (as `TEST_RUNNER_RECORD_PLATFORM_HOSTS=1` when driving via
/// `xcodebuild test`, so the value reaches the test runner rather than just the
/// build settings) to (re)write the committed artifact from the current Swift
/// tables. Without it, the test asserts the committed file matches byte-for-byte
/// and fails with a re-record hint on drift.
final class PlatformHostsJSParityTests: XCTestCase {

    /// `LunaTests/PlatformHostsJSParityTests.swift` -> repo root ->
    /// `LunaSafari/Resources/platform_hosts.generated.js`.
    private static var artifactURL: URL {
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile.deletingLastPathComponent().deletingLastPathComponent()
        return repoRoot.appendingPathComponent("LunaSafari/Resources/platform_hosts.generated.js")
    }

    /// One quoted host per line, indented, comma-terminated (including the last
    /// entry -- JS allows a trailing comma in an array literal, which keeps this
    /// generator simple and every line's diff independent of its neighbors).
    private static func jsArrayLines(_ hosts: [String], indent: String) -> String {
        hosts.map { indent + "\"" + $0 + "\"," }.joined(separator: "\n")
    }

    /// The expected file contents, built directly from `PlatformRecognizer.rules`
    /// (never by string-parsing the .swift source), in table order. Only the host
    /// lists are generated -- the path-shape predicates (Reddit's post gate,
    /// Bluesky's post-only requirement) stay hand-written in `content.js`, mirrored
    /// by eye and guarded by `PlatformHostsJSFixtureParityTests`' URL matrix.
    private static func expectedContents() -> String {
        let lines = [
            "// GENERATED from PlatformRecognizer.swift (LunaURLClassification) by PlatformHostsJSParityTests.",
            "// Do NOT edit by hand. Regenerate with: TEST_RUNNER_RECORD_PLATFORM_HOSTS=1 xcodebuild test -scheme Luna -destination \"platform=iOS Simulator,id=$SIM\" -configuration Debug -derivedDataPath \"$DD\" DIAGNOSE_MISSING_TARGET_DEPENDENCIES=NO",
            "self.__LUNA_PLATFORM_HOSTS = {",
            PlatformRecognizer.rules.map { rule in
                "  \(rule.platform.rawValue): [\n\(jsArrayLines(rule.hosts, indent: "    "))\n  ]"
            }.joined(separator: ",\n"),
            "};",
            "",
        ]
        return lines.joined(separator: "\n")
    }

    func testGeneratedArtifactMatchesPlatformRecognizer() {
        let expected = Self.expectedContents()

        if ProcessInfo.processInfo.environment["RECORD_PLATFORM_HOSTS"] == "1" {
            do {
                try expected.write(to: Self.artifactURL, atomically: true, encoding: .utf8)
                XCTContext.runActivity(named: "Recorded platform_hosts.generated.js") { _ in }
            } catch {
                XCTFail("Failed to write platform_hosts.generated.js: \(error)")
            }
            return
        }

        guard let actual = try? String(contentsOf: Self.artifactURL, encoding: .utf8) else {
            XCTFail("platform_hosts.generated.js not found at \(Self.artifactURL.path) -- "
                    + "generate it with TEST_RUNNER_RECORD_PLATFORM_HOSTS=1")
            return
        }
        XCTAssertEqual(
            actual, expected,
            "platform_hosts.generated.js is stale relative to PlatformRecognizer.swift -- regenerate with "
            + "TEST_RUNNER_RECORD_PLATFORM_HOSTS=1 xcodebuild test -scheme Luna ...")
    }
}

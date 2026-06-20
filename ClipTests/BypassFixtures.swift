//
//  BypassFixtures.swift
//  ClipTests
//

import Foundation
import XCTest

/// Loads a trimmed real-publisher HTML fixture from `ClipTests/Fixtures/`. Resolved
/// relative to this source file's path (the test bundle doesn't ship the .html files
/// as resources), so the fixtures live and version alongside the tests.
enum BypassFixtures {
    static func html(_ name: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        let fixturesDir = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
        let fileURL = fixturesDir.appendingPathComponent(name)
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
            XCTFail("missing fixture \(name) at \(fileURL.path)", file: file, line: line)
            return ""
        }
        return contents
    }
}

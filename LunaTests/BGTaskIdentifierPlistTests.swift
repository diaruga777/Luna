//
//  BGTaskIdentifierPlistTests.swift
//  LunaTests
//

import XCTest

/// Cross-artifact pin, in the shape of `LocalizableStringsTests`: a
/// `BGTaskScheduler` identifier used from Swift must also be claimed in
/// `BGTaskSchedulerPermittedIdentifiers`, or `register(forTaskWithIdentifier:)`
/// traps at launch (and, for a task never registered at all, scheduling it
/// silently no-ops). All four app targets share one `Luna/Info.plist`
/// (`INFOPLIST_FILE = Luna/Info.plist` for every app build setting), so there
/// is only one array to check, not one per app.
final class BGTaskIdentifierPlistTests: XCTestCase {

    private var repositoryRoot: URL {
        URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
    }

    /// The identifiers `BGTaskScheduler.register(forTaskWithIdentifier:)` is
    /// called with, read straight from source rather than re-declared here —
    /// re-declaring them would just be a second hand-copy to drift.
    private func swiftDeclaredTaskIdentifiers() throws -> [String] {
        var identifiers: [String] = []
        for (relativePath, pattern) in [
            ("Luna/AppDelegate.swift", "mailFetchTaskID = \""),
            ("Luna/AppDelegate.swift", "priceRefreshTaskID = \""),
            ("Luna/UtilCard/WeeklyProposalBackgroundCheck.swift", "taskID = \""),
        ] {
            let source = try String(
                contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
            guard let start = source.range(of: pattern) else {
                XCTFail("\(relativePath) no longer declares a task id matching `\(pattern)`")
                continue
            }
            let afterQuote = source[start.upperBound...]
            guard let end = afterQuote.range(of: "\"") else {
                XCTFail("\(relativePath): unterminated string literal after `\(pattern)`")
                continue
            }
            identifiers.append(String(afterQuote[..<end.lowerBound]))
        }
        return identifiers
    }

    private func plistPermittedIdentifiers() throws -> [String] {
        let url = repositoryRoot.appendingPathComponent("Luna/Info.plist")
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let dict = plist as? [String: Any],
              let identifiers = dict["BGTaskSchedulerPermittedIdentifiers"] as? [String]
        else {
            XCTFail("Luna/Info.plist has no BGTaskSchedulerPermittedIdentifiers array")
            return []
        }
        return identifiers
    }

    func testEverySwiftTaskIdentifierIsPermittedInInfoPlist() throws {
        let declared = try swiftDeclaredTaskIdentifiers()
        XCTAssertEqual(declared.count, 3, "expected three BGTask identifiers in Swift — parser drifted")
        let permitted = Set(try plistPermittedIdentifiers())
        for identifier in declared {
            XCTAssertTrue(
                permitted.contains(identifier),
                """
                "\(identifier)" is registered from Swift but is not in Luna/Info.plist's \
                BGTaskSchedulerPermittedIdentifiers — BGTaskScheduler traps at register(…) \
                for an unlisted identifier.
                """)
        }
    }
}

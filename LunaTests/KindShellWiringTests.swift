//
//  KindShellWiringTests.swift
//  LunaTests
//

import LunaModels
import LunaStorage
import XCTest
@testable import Luna

/// The app-shell half of a kind — the launch seams and the lifecycle work
/// `AppDelegate`/`SceneDelegate` ask for at fixed points — is defined once, in
/// that kind's `…ShellWiring` file, and every app that handles the kind runs the
/// same code.
///
/// Duplicating this per `KindWiring+<App>` variant is exactly how the central
/// app could skip the archive pass the Reader runs on the way to the
/// background: the same question, answered in two places, free to drift
/// apart. Two of these tests read SOURCE and one reads the project file,
/// because each app is a different process — no unit test can load four of
/// them.
final class KindShellWiringTests: XCTestCase {

    /// Each app root, and the kind legs its app handles. The per-app split is
    /// deliberate and must not collapse: a single-kind app calls exactly one leg.
    private static let expectedLegs: [String: Set<String>] = [
        "Luna/KindWiring+Luna.swift": ["Article", "Media", "Product"],
        "Luna/KindWiring+Reader.swift": ["Article"],
        "Luna/KindWiring+Downloader.swift": ["Media"],
        "Luna/KindWiring+PriceTracker.swift": ["Product"],
    ]

    private var repositoryRoot: URL {
        URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent()   // LunaTests
            .deletingLastPathComponent()   // repo root
            .resolvingSymlinksInPath()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: - One definition per kind, called by every app that has the kind

    func testEachAppRootCallsExactlyItsOwnKindShellLegs() throws {
        let all = ["Article", "Media", "Product"]
        for (path, expected) in Self.expectedLegs.sorted(by: { $0.key < $1.key }) {
            let source = try self.source(path)
            let called = Set(all.filter { source.contains("\($0)ShellWiring.") })
            XCTAssertEqual(
                called, expected,
                """
                \(path) calls shell legs \(called.sorted()) but its app handles \
                \(expected.sorted()). A missing leg means that app skips launch \
                seams or lifecycle work its kind owes; a foreign one would not \
                compile.
                """)
        }
    }

    /// Pre-SQL development installs are wiped manually. Launch maintenance may
    /// apply ordinary retention, but must never run a one-time library reset:
    /// that async reset can race a fresh download and replace current SQL rows
    /// with an empty table after the download has committed.
    func testMediaLaunchDoesNotRunTheRetiredSQLMigrationReset() throws {
        let mediaShell = try source("Luna/MediaShellWiring.swift")
        XCTAssertFalse(mediaShell.contains("resetLibraryForSQLOwnershipOnce"))
        XCTAssertTrue(mediaShell.contains("SavedMediaStore.shared.purgeExpired()"))
    }

    /// A kind's shell file stays excluded from the targets that do not link the
    /// kind — a membership exception, not a runtime check
    /// (`claudedocs/surface-support.md`). A dropped exception fails as a
    /// missing-symbol error, but only on a CLEAN build of that target, so pin
    /// the project file itself.
    func testKindShellWiringIsExcludedFromForeignTargets() throws {
        let exclusions = try membershipExceptionsByTarget()
        let expected: [(file: String, foreignTargets: [String])] = [
            ("ArticleShellWiring.swift", ["LunaDownloader", "LunaPriceTracker"]),
            ("MediaShellWiring.swift", ["LunaReader", "LunaPriceTracker"]),
            ("ProductShellWiring.swift", ["LunaReader", "LunaDownloader"]),
            // Spotlight indexing is one of the article leg's launch jobs: an app
            // that shows no article can neither index one nor open a hit.
            ("ArticleSpotlightIndexWiring.swift", ["LunaDownloader", "LunaPriceTracker"]),
        ]
        for (file, foreignTargets) in expected {
            for target in foreignTargets {
                let excluded = try XCTUnwrap(
                    exclusions[target], "no exception set at all for \(target)")
                XCTAssertTrue(
                    excluded.contains(file),
                    """
                    \(target) must exclude \(file) — it does not handle that kind, \
                    so the file has nothing to do there.
                    """)
            }
        }
    }

    /// Installing Spotlight indexing from `AppDelegate`, which every app
    /// compiles, would make the Downloader and Price Tracker index articles
    /// they cannot open. It belongs to the article leg and nowhere else.
    func testSpotlightIndexingIsInstalledOnlyFromTheArticleLeg() throws {
        var installers: [String] = []
        let base = repositoryRoot.appendingPathComponent("Luna")
        let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
        for case let url as URL in walker ?? .init() where url.pathExtension == "swift" {
            guard let source = try? String(contentsOf: url, encoding: .utf8),
                  source.contains("ArticleSpotlightIndexWiring.install()")
            else { continue }
            installers.append(
                url.resolvingSymlinksInPath().path
                    .replacingOccurrences(of: repositoryRoot.path + "/", with: ""))
        }
        XCTAssertEqual(
            installers, ["Luna/ArticleShellWiring.swift"],
            """
            The Spotlight index is installed from \(installers.sorted()). It must \
            be installed only by the article leg, which the two apps that handle \
            no article do not compile.
            """)
    }

    // MARK: - What the unified article leg does

    /// A finished read becomes an archive move on the way to the background,
    /// so the next launch starts settled — the invariant `KindDeckProvider`
    /// documents ("at launch/background"). Promoting pending completions at
    /// launch only would leave a read finished in one session sitting on the
    /// deck until the session after next.
    func testBackgroundingArchivesAFinishedRead() throws {
        let store = SavesStore.shared
        let item = SavedItem(
            seed: "shell-wiring-finished",
            urlString: "https://example.com/shell-wiring-finished",
            title: "Finished Read",
            dateAdded: Date(timeIntervalSince1970: 1_600_000_000),
            state: .ready,
            wordCount: 400)
        store.seedForTesting(
            items: [item],
            contents: [item.id: UITestFixtures.sampleArticleContent(title: "Finished Read")])
        let finishedAt = Date(timeIntervalSince1970: 1_700_000_000)
        store.markFinishedReading(item.id, at: finishedAt)
        XCTAssertEqual(
            store.item(withID: item.id)?.pendingArchiveAt, finishedAt,
            "a completion is pending, not archived, while the session continues")
        XCTAssertNil(store.item(withID: item.id)?.archivedAt)

        KindWiring.appDidEnterBackground()

        let settled = try XCTUnwrap(store.item(withID: item.id))
        XCTAssertEqual(settled.archivedAt, finishedAt)
        XCTAssertNil(settled.pendingArchiveAt)
    }

    override func tearDown() {
        SavesStore.shared.seedForTesting(items: [], contents: [:])
        super.tearDown()
    }

    /// Every `PBXFileSystemSynchronizedBuildFileExceptionSet`, keyed by the
    /// target it belongs to — the `target = … /* Name */` line inside the block
    /// rather than the block's own leading comment, which Xcode and the
    /// xcodeproj gem write differently.
    private func membershipExceptionsByTarget() throws -> [String: String] {
        let project = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Luna.xcodeproj/project.pbxproj"),
            encoding: .utf8)
        var result: [String: String] = [:]
        var remainder = Substring(project)
        while let isa = remainder.range(
            of: "isa = PBXFileSystemSynchronizedBuildFileExceptionSet;") {
            let block = remainder[isa.upperBound...]
            guard let blockEnd = block.range(of: "\n\t\t};") else { break }
            let body = block[..<blockEnd.lowerBound]
            if let targetLine = body.range(of: "target = "),
               let open = body.range(of: "/* ", range: targetLine.upperBound..<body.endIndex),
               let close = body.range(of: " */", range: open.upperBound..<body.endIndex) {
                result[String(body[open.upperBound..<close.lowerBound])] = String(body)
            }
            remainder = block[blockEnd.upperBound...]
        }
        return result
    }
}

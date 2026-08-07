//
//  StageRegistryTests.swift
//  LunaTests
//

import LunaAppConfig
import LunaModels
import LunaStorage
import UIKit
import XCTest
@testable import Luna

/// Guards staged mode (`claudedocs/staging.md`), on the same principle as
/// `KindCompositionRootTests`: the catalogs are per-target composition, so the
/// things that can silently break are (a) an id colliding or drifting from the
/// committed manifest, (b) a stage claiming an app that does not compile the
/// code it needs, and (c) a fixture that stopped resolving.
///
/// The suite hosts on the central Luna app, whose `KindWiring.install()`
/// registers every catalog at launch — so `StageRegistry` here is the complete
/// set, and a per-app view is a filter over it.
final class StageRegistryTests: XCTestCase {

    private var stages: [StageDescriptor] { StageRegistry.all }

    // MARK: - Identity

    func testEveryStageIDIsUniqueAndWellFormed() {
        var seen = Set<String>()
        for stage in stages {
            XCTAssertTrue(seen.insert(stage.id).inserted, "duplicate stage id \(stage.id)")
            XCTAssertFalse(stage.id.isEmpty)
            XCTAssertNil(
                stage.id.rangeOfCharacter(from: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-").inverted),
                """
                stage id "\(stage.id)" must be lowercase <area>.<screen>.<variant> \
                using only letters, digits, dots and hyphens — it is typed verbatim \
                into a shell by the screenshot harness and by any driving agent
                """)
            XCTAssertTrue(
                stage.id.contains("."), "stage id \(stage.id) needs an <area>. prefix")
        }
    }

    func testEveryStageDescribesItself() {
        for stage in stages {
            XCTAssertFalse(stage.screen.isEmpty, "\(stage.id) has no screen name")
            XCTAssertFalse(stage.variant.isEmpty, "\(stage.id) has no variant name")
            XCTAssertGreaterThan(
                stage.summary.count, 20,
                "\(stage.id) needs a summary a reviewer can read in the guide")
        }
    }

    // MARK: - The per-app split

    /// A stage may narrow its kind's app set (an email stage that only makes
    /// sense in the central app, say) but never widen it: the code a stage
    /// builds is compiled only into that kind's targets, so a wider claim is a
    /// promise the build cannot keep — the harness would launch an app that has
    /// never heard of the id.
    func testNoStageClaimsAnAppThatCannotCompileIt() {
        for stage in stages {
            XCTAssertFalse(stage.apps.isEmpty, "\(stage.id) applies to no app")
            let allowed = Set(stage.kind.apps)
            for app in stage.apps {
                XCTAssertTrue(
                    allowed.contains(app),
                    """
                    stage \(stage.id) (kind .\(stage.kind.rawValue)) claims \
                    \(app.storageIdentifier), which does not link that kind
                    """)
            }
        }
    }

    /// The kind → apps mapping, spelled out rather than derived, so a change to
    /// `LunaApp.handles*` has to be made deliberately in both places.
    func testKindAppSetsMatchTheDocumentedSplit() {
        XCTAssertEqual(StageDescriptor.Kind.shared.apps, LunaApp.allCases)
        XCTAssertEqual(StageDescriptor.Kind.article.apps, [.luna, .reader])
        XCTAssertEqual(StageDescriptor.Kind.email.apps, [.luna, .reader])
        XCTAssertEqual(StageDescriptor.Kind.media.apps, [.luna, .downloader])
        XCTAssertEqual(StageDescriptor.Kind.product.apps, [.luna, .priceTracker])
    }

    /// Every app has at least the shared stages, and only the central app has
    /// all of them.
    func testEveryAppHasStagesAndOnlyTheCentralAppHasThemAll() {
        for app in LunaApp.allCases {
            XCTAssertFalse(
                StageRegistry.all(for: app).isEmpty,
                "\(app.storageIdentifier) has no stages at all")
        }
        XCTAssertEqual(StageRegistry.all(for: .luna).count, stages.count)
        for app in LunaApp.allCases where app != .luna {
            XCTAssertLessThan(StageRegistry.all(for: app).count, stages.count)
        }
    }

    // MARK: - Composition roots

    /// Which catalogs each app's `KindWiring` installs — the same source-read
    /// check `KindCompositionRootTests` runs over the kind packs, for the same
    /// reason: no unit test can load four composition roots that each compile
    /// into a different binary.
    private static let expectedCatalogs: [String: Set<String>] = [
        "Luna/KindWiring+Luna.swift": ["Shared", "Article", "Email", "Media", "Product"],
        "Luna/KindWiring+Reader.swift": ["Shared", "Article", "Email"],
        "Luna/KindWiring+Downloader.swift": ["Shared", "Media"],
        "Luna/KindWiring+PriceTracker.swift": ["Shared", "Product"],
    ]

    private var repositoryRoot: URL {
        URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
    }

    func testEachAppRootInstallsExactlyItsOwnStageCatalogs() throws {
        let all = ["Shared", "Article", "Email", "Media", "Product"]
        for (path, expected) in Self.expectedCatalogs.sorted(by: { $0.key < $1.key }) {
            let source = try String(
                contentsOf: repositoryRoot.appendingPathComponent(path), encoding: .utf8)
            let installed = Set(all.filter { source.contains("\($0)StageCatalog.install()") })
            XCTAssertEqual(
                installed, expected,
                """
                \(path) installs stage catalogs \(installed.sorted()) but its app \
                handles \(expected.sorted()). A missing one means `-LunaStage` \
                cannot reach that app's own screens; a foreign one would not compile.
                """)
        }
    }

    /// The per-kind catalogs must stay excluded from the targets that do not
    /// link the kind — a membership exception, not a runtime check
    /// (`claudedocs/surface-support.md`). A dropped exception compiles as a
    /// missing-symbol error, but only on a CLEAN build of that target, so pin
    /// the project file itself.
    func testKindCatalogsAreExcludedFromForeignTargets() throws {
        let project = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Luna.xcodeproj/project.pbxproj"),
            encoding: .utf8)
        let expected: [(catalog: String, foreignTargets: [String])] = [
            ("Article", ["LunaDownloader", "LunaPriceTracker"]),
            ("Email", ["LunaDownloader", "LunaPriceTracker"]),
            ("Media", ["LunaReader", "LunaPriceTracker"]),
            ("Product", ["LunaReader", "LunaDownloader"]),
        ]
        for (catalog, foreignTargets) in expected {
            for target in foreignTargets {
                let marker = "Exceptions for \"Luna\" folder in \"\(target)\" target"
                guard let range = project.range(of: marker),
                      let end = project.range(
                        of: ");", range: range.upperBound..<project.endIndex)
                else {
                    return XCTFail("no exception set for \(target)")
                }
                XCTAssertTrue(
                    project[range.upperBound..<end.lowerBound]
                        .contains("Stage/StageCatalog+\(catalog).swift"),
                    "\(target) must exclude Stage/StageCatalog+\(catalog).swift")
            }
        }
    }

    // MARK: - The manifest

    /// The committed manifest is how an agent enumerates stages without a
    /// simulator, so it must match what `-LunaStageList` would print.
    ///
    /// Blank lines are dropped from both sides before comparing: the manifest
    /// is captured through `simctl launch --console-pty`, which occasionally
    /// interleaves an empty line of its own into the app's stdout. No line of
    /// real manifest is ever blank, so this costs the check nothing.
    func testCommittedManifestMatchesTheRegistry() throws {
        let url = repositoryRoot.appendingPathComponent("Luna/Stage/StageManifest.json")
        let committed = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(
            Self.significantLines(committed),
            Self.significantLines(StageRegistry.manifestJSON(for: .luna)),
            """
            Luna/Stage/StageManifest.json has drifted from the stage catalogs. \
            Regenerate it:
              xcrun simctl launch --console-pty <sim> com.hsanabria.luna \
                -LunaStageList | sed -n '/^{/,/^}/p' | grep -v '^[[:space:]]*$' \
                > Luna/Stage/StageManifest.json
            """)
    }

    private static func significantLines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func testManifestIsValidJSONAndCoversEveryStage() throws {
        let data = Data(StageRegistry.manifestJSON(for: .luna).utf8)
        let parsed = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let listed = try XCTUnwrap(parsed["stages"] as? [[String: Any]])
        XCTAssertEqual(listed.count, stages.count)
        XCTAssertEqual(listed.compactMap { $0["id"] as? String }, stages.map(\.id))
    }

    // MARK: - The fixtures

    /// Every stage's seed runs and every screen-building stage produces a
    /// screen. This is the check that catches a fixture whose store API moved
    /// under it — the failure staged mode would otherwise only show as a black
    /// screenshot hours later.
    ///
    /// Runs against a throwaway container, which is also a live check that the
    /// redirect works: if it did not, this test would wipe the device's real
    /// reading list.
    @MainActor
    func testEveryStageSeedsAndBuildsItsScreen() throws {
        StageContainer.activate(identifier: "registry-tests")
        defer {
            StageContainer.deactivateForTesting()
            UITestSeeder.sectioningNow = nil
        }
        XCTAssertTrue(StageContainer.isActive, "the staged container did not take")

        for stage in stages {
            stage.seed?()
            guard let make = stage.make else { continue }
            XCTAssertNotNil(make(), "stage \(stage.id) built no screen")
        }
    }

    /// A deck stage deliberately builds nothing — it seeds and lets the app
    /// construct its own root — and there must be some of both.
    func testBothStageShapesExist() {
        XCTAssertFalse(
            stages.filter { $0.make == nil }.isEmpty,
            "no deck stages: something collapsed them into hand-built screens")
        XCTAssertFalse(stages.filter { $0.make != nil }.isEmpty)
        for stage in stages where stage.make == nil {
            XCTAssertNotNil(
                stage.seed,
                "\(stage.id) builds no screen and seeds nothing, so it stages nothing")
        }
    }

    // MARK: - Inertness

    /// Staged mode must be invisible without its launch argument — this process
    /// has none, so nothing is active and the real container is in use.
    func testStagedModeIsInertWithoutItsLaunchArgument() {
        XCTAssertFalse(LunaStage.isActive)
        XCTAssertNil(LunaStage.requestedID)
        XCTAssertFalse(StageContainer.isActive)
        XCTAssertEqual(AppConfig.appGroupID, AppConfig.provisionedAppGroupID)
    }
}

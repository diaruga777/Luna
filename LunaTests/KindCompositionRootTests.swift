//
//  KindCompositionRootTests.swift
//  LunaTests
//

import XCTest
import LunaHTMLClassification
import LunaIngest
import LunaMediaDownload
import LunaModels
import LunaPriceUI
import LunaReaderUI
import LunaShareSurface
import LunaURLClassification

/// Guards the composition contract: **a kind's wiring is defined once, in that
/// kind's own module, and every surface installs it with one call.**
///
/// This exists because the alternative was tried and failed. Each surface root
/// used to hand-list its `IngestKindProcessors` / `ShareKindPresenters` entries,
/// so `IngestKindProcessors.socialText` (long-form X posts) landed in the two app
/// roots but not the share extension or the action extension: the same link read
/// fine inside the app and was rejected from the share sheet as Downloader-owned.
/// See `claudedocs/x-posts.md`.
///
/// These tests read composition-root SOURCE, because no unit test can load the
/// real roots — each registry is set in a principal class's initializer inside a
/// different process.
final class KindCompositionRootTests: XCTestCase {

    /// The kind packs. Each is the single definition of one kind's registrations.
    private static let packs = [
        "article": "ArticleKindComposition",
        "media": "MediaKindComposition",
        "product": "ProductKindComposition",
    ]

    /// Every composition root, and the kinds its app handles — the per-app split,
    /// which is deliberate and must NOT collapse: a single-content app installs
    /// only its own kind and drops the rest (`SurfaceSupport`).
    private static let expected: [String: Set<String>] = [
        "Luna/KindWiring+Luna.swift":            ["article", "media", "product"],
        "Luna/KindWiring+Reader.swift":          ["article"],
        "Luna/KindWiring+Downloader.swift":      ["media"],
        "Luna/KindWiring+PriceTracker.swift":    ["product"],
        "LunaShare/ShareEntry+Luna.swift":       ["article", "media", "product"],
        "LunaShare/ShareEntry+Reader.swift":     ["article"],
        "LunaShare/ShareEntry+Downloader.swift": ["media"],
        "LunaShare/ShareEntry+PriceTracker.swift": ["product"],
        "LunaAction/ActionEntry+Luna.swift":     ["article", "media", "product"],
        "LunaAction/ActionEntry+Reader.swift":   ["article"],
        "LunaAction/ActionEntry+Downloader.swift": ["media"],
        "LunaAction/ActionEntry+PriceTracker.swift": ["product"],
    ]

    /// Directories that hold composition roots. `LunaTests` is excluded: a test
    /// stubbing a processor is not a composition root.
    private static let rootDirectories = [
        "Luna", "LunaShare", "LunaAction",
    ]

    /// These tests compare a `#filePath`-derived prefix against paths a
    /// `FileManager` enumerator produces, and those two disagree the moment the
    /// checkout sits under a symlink: a worktree under `/tmp` (a symlink to
    /// `/private/tmp` on macOS) is compiled with a `/tmp` `#filePath` and walked
    /// as `/private/tmp`, so the prefix strip left `/privateLuna/KindWiring+Luna
    /// .swift` and every root read as unlisted.
    ///
    /// Both sides therefore go through `resolvingSymlinksInPath`, which is a
    /// NORMALIZER here rather than a resolver — note it strips `/private` from
    /// `/private/tmp` rather than adding it, so it is only correct when applied
    /// to both ends of the comparison. Applying it to one was the first
    /// (wrong) fix.
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

    // MARK: - The invariant

    /// THE rule that makes the original bug unrepresentable: no composition root
    /// touches the kind registries itself. Registration exists in exactly one
    /// place per kind, so a surface cannot be wired half-way — it either installs
    /// the pack or it doesn't.
    func testNoCompositionRootWritesTheKindRegistriesDirectly() throws {
        var offenders: [String] = []
        for (path, source) in try allRootSources() {
            for line in source.split(separator: "\n") {
                let text = line.trimmingCharacters(in: .whitespaces)
                guard !text.hasPrefix("//"), !text.hasPrefix("///") else { continue }
                if text.contains("IngestKindProcessors.") || text.contains("ShareKindPresenters.") {
                    offenders.append("\(path): \(text)")
                }
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            """
            A composition root registered a kind directly. Move it into that kind's \
            pack (\(Self.packs.values.sorted().joined(separator: " / "))) so every \
            surface picks it up — hand-listing per surface is how a kind ends up \
            registered in the app but not the share extension:
            \(offenders.joined(separator: "\n"))
            """)
    }

    /// Each root installs exactly the packs for the kinds its app handles —
    /// neither missing one (the reported bug) nor gaining a foreign kind (which
    /// would break the per-app content split).
    func testEachRootInstallsExactlyItsAppsKinds() throws {
        for (path, kinds) in Self.expected.sorted(by: { $0.key < $1.key }) {
            let source = try self.source(path)
            let installed = Set(Self.packs.filter { source.contains("\($0.value).install()") }.keys)
            XCTAssertEqual(
                installed, kinds,
                "\(path) installs \(installed.sorted()) but its app handles \(kinds.sorted())")
        }
    }

    /// Every expected root still exists, so renaming or deleting one fails here
    /// rather than silently escaping the checks above.
    func testEveryExpectedCompositionRootExists() {
        for path in Self.expected.keys.sorted() {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: repositoryRoot.appendingPathComponent(path).path),
                "composition root \(path) is missing — if it moved, update this test")
        }
    }

    /// A new root that installs a pack must be listed in `expected`, so an added
    /// surface can't quietly go unchecked.
    func testNoUnlistedRootInstallsAPack() throws {
        let listed = Set(Self.expected.keys)
        for (path, source) in try allRootSources()
        where Self.packs.values.contains(where: { source.contains("\($0).install()") }) {
            XCTAssertTrue(
                listed.contains(path),
                "\(path) installs a kind pack but isn't listed in this test's expectations")
        }
    }

    // MARK: - The plugin platform

    /// The plugin platform has one root call, and only the CENTRAL app's three
    /// roots make it (`claudedocs/plans/plugin-platform.md` §2.3). The three
    /// sibling apps are untouched by the pivot: no plugin stage, no plugin JS.
    private static let pluginRoots: Set<String> = [
        "Luna/KindWiring+Luna.swift",
        "LunaShare/ShareEntry+Luna.swift",
        "LunaAction/ActionEntry+Luna.swift",
    ]

    func testOnlyTheCentralRootsInstallThePluginPlatform() throws {
        var installers: Set<String> = []
        for (path, source) in try allRootSources() {
            for line in source.split(separator: "\n") {
                let text = line.trimmingCharacters(in: .whitespaces)
                guard !text.hasPrefix("//"), !text.hasPrefix("///") else { continue }
                if text.contains("PluginPlatformComposition.install(") { installers.insert(path) }
            }
        }
        XCTAssertEqual(
            installers, Self.pluginRoots,
            """
            The plugin platform is installed by exactly the central app's three \
            composition roots. A sibling app that installs it would run plugin JS \
            it was never meant to; a central root that skips it silently loses \
            every plugin on that surface.
            """)
    }

    /// Export, transport and the `luna.ui` app witnesses are the APP's own —
    /// `claudedocs/plugins.md` §2.3 says they "never run in the extensions".
    /// `PluginPlatformComposition.install()` builds the runtime every one of
    /// the three plugin roots needs, but only `Luna/KindWiring+Luna.swift`
    /// may follow it with these three calls: `ShareEntry+Luna` and
    /// `ActionEntry+Luna` install the runtime and stop there.
    func testOnlyTheAppRootInstallsExportTransportAndUIWitnesses() throws {
        let calls = [
            "PluginExportComposition.install(",
            "PluginTransportComposition.install(",
            "PluginUIComposition.installAppWitnesses(",
        ]
        for call in calls {
            var installers: Set<String> = []
            for (path, source) in try allRootSources() {
                for line in source.split(separator: "\n") {
                    let text = line.trimmingCharacters(in: .whitespaces)
                    guard !text.hasPrefix("//"), !text.hasPrefix("///") else { continue }
                    if text.contains(call) { installers.insert(path) }
                }
            }
            XCTAssertEqual(
                installers, ["Luna/KindWiring+Luna.swift"],
                """
                \(call) is the app's own composition — a share or action \
                extension that called it would run export, transport or \
                luna.ui work no extension is meant to:
                \(installers.sorted())
                """)
        }
    }

    /// A root installs the platform; it never ASSIGNS the registries the platform
    /// owns (reading a witness to hand it to a screen is fine). That is the same rule the kind packs hold,
    /// for the same reason: a hand-written half-installation is invisible.
    func testNoCompositionRootWritesThePluginRegistriesDirectly() throws {
        var offenders: [String] = []
        for (path, source) in try allRootSources() {
            for line in source.split(separator: "\n") {
                let text = line.trimmingCharacters(in: .whitespaces)
                guard !text.hasPrefix("//"), !text.hasPrefix("///") else { continue }
                if text.range(of: #"(PluginPlatformServices\.\w+|IngestPipeline\.pluginStage|PluginModelAdopters\.\w+|PluginTranscriptionSeams\.\w+)\s*=[^=]"#, options: .regularExpression) != nil {
                    offenders.append("\(path): \(text)")
                }
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            """
            A composition root wrote a plugin registry itself. The runtime fills \
            `PluginPlatformServices`, `PluginPlatformComposition.install()` fills \
            the stage and the transcription re-resolver, and each kind pack fills \
            its own adopter:
            \(offenders.joined(separator: "\n"))
            """)
    }

    // MARK: - The Luna file intake seam

    /// A `.luna` file can land on ANY surface, so every root installs both
    /// witnesses: the recovery half every app runs, and the plugin half only
    /// central Luna answers for real. A root that installs neither leaves an
    /// arriving file silently dropped on that one surface, which is the same
    /// split the kind packs exist to prevent.
    func testEveryCompositionRootInstallsALunaFileIntakeWitness() throws {
        for path in Self.expected.keys.sorted() {
            let source = try self.source(path)
            for seam in ["LunaFileIntake.recoveryHandler =", "LunaFileIntake.pluginHandler ="] {
                XCTAssertTrue(
                    source.contains(seam), "\(path) does not write `\(seam)`")
            }
        }
    }

    /// And nothing else writes either seam. One witness per process, installed
    /// by that process's root — a second write anywhere else is a surface
    /// quietly taking the seam away from the one that owns it.
    func testOnlyAListedCompositionRootWritesTheIntakeHandler() throws {
        let allowed = Set(Self.expected.keys)
        var offenders: [String] = []
        for (path, source) in try allRootSources() where !allowed.contains(path) {
            for line in source.split(separator: "\n") {
                let text = line.trimmingCharacters(in: .whitespaces)
                guard !text.hasPrefix("//"), !text.hasPrefix("///") else { continue }
                if text.contains("LunaFileIntake.recoveryHandler =")
                    || text.contains("LunaFileIntake.pluginHandler =") {
                    offenders.append("\(path): \(text)")
                }
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            """
            Something other than a composition root installed the Luna file \
            intake witness:
            \(offenders.joined(separator: "\n"))
            """)
    }

    // MARK: - The CARD half of a kind

    /// The card presenters, and the app roots allowed to install them. A card's
    /// kind behavior is defined once per kind (`CardKindPresenter.swift`) and
    /// installed by every app that shows that kind — the exact same contract the
    /// packs above hold for ingest, and for the exact same reason: the central
    /// app and each single-kind app were answering the same questions about the
    /// same save in two places and drifting apart.
    private static let presenters = [
        "article": "ArticleCardPresenter",
        "media": "MediaCardPresenter",
        "product": "ProductCardPresenter",
    ]

    /// Only the app shell draws cards, so only its four roots install presenters
    /// (an extension has no deck).
    private static let presenterRoots: [String: Set<String>] = [
        "Luna/KindWiring+Luna.swift": ["article", "media", "product"],
        "Luna/KindWiring+Reader.swift": ["article"],
        "Luna/KindWiring+Downloader.swift": ["media"],
        "Luna/KindWiring+PriceTracker.swift": ["product"],
    ]

    func testEachAppRootInstallsExactlyItsAppsCardPresenters() throws {
        for (path, kinds) in Self.presenterRoots.sorted(by: { $0.key < $1.key }) {
            let source = try self.source(path)
            let installed = Set(
                Self.presenters
                    .filter { source.contains("CardKindPresenters.\($0.key) = \($0.value)()") }
                    .keys)
            XCTAssertEqual(
                installed, kinds,
                """
                \(path) installs card presenters \(installed.sorted()) but its app \
                shows \(kinds.sorted()). A kind its app shows with no presenter \
                installed renders as a generic link card; a foreign one would break \
                the per-app content split.
                """)
        }
    }

    /// Nothing but an app root ASSIGNS the registry. Reading it
    /// (`CardKindPresenters.presenter(for:)`) is how the deck works and is fine;
    /// a second write is how a surface ends up with a different card for the
    /// same save.
    func testOnlyAppRootsWriteTheCardPresenterRegistry() throws {
        let allowed = Set(Self.presenterRoots.keys)
        var offenders: [String] = []
        for (path, source) in try allRootSources() where !allowed.contains(path) {
            for line in source.split(separator: "\n") {
                let text = line.trimmingCharacters(in: .whitespaces)
                guard !text.hasPrefix("//"), !text.hasPrefix("///") else { continue }
                for slot in Self.presenters.keys
                where text.contains("CardKindPresenters.\(slot) =") {
                    offenders.append("\(path): \(text)")
                }
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            """
            Something other than a KindWiring root installed a card presenter. \
            A kind's card behavior is installed in exactly one place per app:
            \(offenders.joined(separator: "\n"))
            """)
    }

    /// The deck itself never asks what KIND a save is. Resolution lives once, in
    /// `CardKindPresenters.presenter(for:)`; a deck that re-derives it is exactly
    /// how a kind gains a second, divergent code path.
    ///
    /// `SavesSectioning.isFailedSave` is deliberately allowed: a failed
    /// save carries NO kind, so its card is the deck's own and belongs to every
    /// app.
    func testTheDeckNeverBranchesOnKind() throws {
        let deckDirectory = repositoryRoot.appendingPathComponent("Luna/CardCarouselHost")
        let walker = FileManager.default.enumerator(at: deckDirectory, includingPropertiesForKeys: nil)
        var offenders: [String] = []
        for case let url as URL in walker ?? .init() where url.pathExtension == "swift" {
            // The registry file is where kind resolution is SUPPOSED to live.
            guard url.lastPathComponent != "CardKindPresenter.swift" else { continue }
            let source = try String(contentsOf: url, encoding: .utf8)
            for line in source.split(separator: "\n") {
                let text = line.trimmingCharacters(in: .whitespaces)
                guard !text.hasPrefix("//"), !text.hasPrefix("///") else { continue }
                for marker in ["isPriceTracker", "contentPlatform", "priceTracker"]
                where text.contains(marker) {
                    offenders.append("\(url.lastPathComponent): \(text)")
                }
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            """
            The deck branched on a save's kind. Move the behavior into that kind's \
            presenter and let `CardKindPresenters.presenter(for:)` resolve it:
            \(offenders.joined(separator: "\n"))
            """)
    }

    /// Every `.swift` file under the composition-root directories, keyed by its
    /// repo-relative path.
    private func allRootSources() throws -> [(String, String)] {
        var result: [(String, String)] = []
        for directory in Self.rootDirectories {
            let base = repositoryRoot.appendingPathComponent(directory)
            guard let walker = FileManager.default.enumerator(
                at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let relative = url.resolvingSymlinksInPath().path
                    .replacingOccurrences(of: repositoryRoot.path + "/", with: "")
                result.append((relative, source))
            }
        }
        return result
    }

    // MARK: - What a pack actually installs

    /// The source checks above prove every root installs the right PACKS; this
    /// proves a pack installs the right ENTRIES. Together they cover the whole
    /// path — otherwise an `install()` that quietly registered nothing would
    /// satisfy every other test here.
    @MainActor
    func testArticlePackRegistersBothProcessorsAndThePresenter() {
        let processors = (IngestKindProcessors.article, IngestKindProcessors.socialText)
        let presenter = ShareKindPresenters.article
        defer {
            (IngestKindProcessors.article, IngestKindProcessors.socialText) = processors
            ShareKindPresenters.article = presenter
        }
        IngestKindProcessors.article = nil
        IngestKindProcessors.socialText = nil
        ShareKindPresenters.article = nil

        ArticleKindComposition.install()

        XCTAssertNotNil(IngestKindProcessors.article, "article processor not installed")
        XCTAssertNotNil(
            IngestKindProcessors.socialText,
            "social-text processor not installed — long-form X posts would be dropped")
        XCTAssertNotNil(ShareKindPresenters.article, "extension article presenter not installed")
    }

    @MainActor
    func testProductPackRegistersItsProcessorAndPresenter() {
        let processor = IngestKindProcessors.product
        let presenter = ShareKindPresenters.product
        defer {
            IngestKindProcessors.product = processor
            ShareKindPresenters.product = presenter
        }
        IngestKindProcessors.product = nil
        ShareKindPresenters.product = nil

        ProductKindComposition.install()

        XCTAssertNotNil(IngestKindProcessors.product)
        XCTAssertNotNil(ShareKindPresenters.product)
    }

    /// Media registers a presenter only — it is classified from the URL alone, so
    /// there is no media slot in `IngestKindProcessors` to fill.
    @MainActor
    func testMediaPackRegistersItsPresenter() {
        let presenter = ShareKindPresenters.media
        defer { ShareKindPresenters.media = presenter }
        ShareKindPresenters.media = nil

        MediaKindComposition.install()

        XCTAssertNotNil(ShareKindPresenters.media)
    }

    // MARK: - The URL shape X's own share sheet produces

    /// X appends a tracking param (`?s=46`, `?t=…`) to every link shared from its
    /// app. That must not affect recognition — this is the exact shape a real
    /// share arrives in, and the one the reported failure used.
    func testTrackingParamsDoNotBreakPostRecognition() {
        let bare = "https://x.com/random_walker/status/2082163285588107752"
        for urlString in [
            bare,
            bare + "?s=46",
            bare + "?s=46&t=abc123",
            "https://twitter.com/random_walker/status/2082163285588107752?s=20",
            "https://mobile.twitter.com/random_walker/status/2082163285588107752",
        ] {
            let recognized = PlatformRecognizer.recognize(urlString)
            XCTAssertEqual(recognized?.platform, .x, "\(urlString)")
            XCTAssertEqual(recognized?.itemID, "2082163285588107752", "\(urlString)")
        }
    }

    /// Classification (the stage that hands the pipeline its `itemID`) survives the
    /// tracking param too, including after the unwrap's canonicalization.
    func testClassificationKeepsThePostIDAfterUnwrap() throws {
        let url = try XCTUnwrap(
            URL(string: "https://x.com/random_walker/status/2082163285588107752?s=46"))
        let canonical = URLUnwrapper.unwrapOffline(url).url
        guard case let .social(platform, itemID) = Classifier.classify(url: canonical) else {
            return XCTFail("expected .social for an X post, got \(Classifier.classify(url: canonical))")
        }
        XCTAssertEqual(platform, .x)
        XCTAssertEqual(itemID, "2082163285588107752")
    }
}

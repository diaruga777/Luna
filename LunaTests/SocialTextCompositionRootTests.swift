//
//  SocialTextCompositionRootTests.swift
//  LunaTests
//

import XCTest
import LunaHTMLClassification
import LunaIngest
import LunaModels
import LunaURLClassification

/// Guards the composition-root invariant that a long-form X post is readable on
/// EVERY article-handling surface, not just inside the app.
///
/// This exists because it was got wrong: `IngestKindProcessors.socialText` was
/// registered in the two `KindWiring+*` app roots but not in the share extension,
/// the action extension, or the App Clip — so sharing a long X post through the
/// share sheet classified `.social` and was dropped as Downloader-owned, while the
/// same link saved inside the app read fine. Each root is a separate per-target
/// file, so nothing but a check like this ties them together.
///
/// It reads the composition-root SOURCE rather than exercising the extensions,
/// which no unit test can load: the registries are set in each principal class's
/// initializer inside a different process.
final class SocialTextCompositionRootTests: XCTestCase {

    /// Directories holding per-target composition roots (thin app/extension shells).
    /// `LunaTests` is deliberately excluded: a test that stubs one processor is not
    /// a composition root.
    private static let rootDirectories = [
        "Luna", "LunaShare", "LunaAction", "LunaReaderClip", "LunaDownloaderClip",
    ]

    private var repositoryRoot: URL {
        URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent()   // LunaTests
            .deletingLastPathComponent()   // repo root
    }

    /// Every composition root that registers the article processor must also
    /// register the social-text processor: they are two halves of one kind, and a
    /// surface with only the first silently drops long-form X posts.
    func testEveryArticleHandlingRootAlsoRegistersSocialText() throws {
        let roots = try articleRegisteringFiles()
        XCTAssertFalse(roots.isEmpty, "found no composition roots — did the layout change?")

        let missing = roots.filter { url in
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { return false }
            return !source.contains("IngestKindProcessors.socialText")
        }
        XCTAssertTrue(
            missing.isEmpty,
            """
            These composition roots register IngestKindProcessors.article but NOT \
            .socialText, so a long-form X post shared through them is dropped as \
            Downloader-owned: \
            \(missing.map { $0.lastPathComponent }.sorted().joined(separator: ", "))
            """)
    }

    /// The surfaces that must be covered, named explicitly — so DELETING a
    /// registration (rather than adding an unguarded root) also fails.
    func testKnownArticleSurfacesAreAllCovered() throws {
        let covered = Set(try articleRegisteringFiles().map { $0.lastPathComponent })
        for expected in [
            "KindWiring+Luna.swift", "KindWiring+Reader.swift",
            "ShareEntry+Luna.swift", "ShareEntry+Reader.swift",
            "ActionEntry+Luna.swift", "ActionEntry+Reader.swift",
            "AppDelegate.swift",   // LunaReaderClip
        ] {
            XCTAssertTrue(
                covered.contains(expected),
                "\(expected) no longer registers the article processor — if that moved, "
                    + "update this test so the socialText invariant keeps covering it")
        }
    }

    /// Composition-root files that register the article-kind processor.
    private func articleRegisteringFiles() throws -> [URL] {
        var found: [URL] = []
        for directory in Self.rootDirectories {
            let base = repositoryRoot.appendingPathComponent(directory)
            guard let walker = FileManager.default.enumerator(
                at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                guard let source = try? String(contentsOf: url, encoding: .utf8),
                      source.contains("IngestKindProcessors.article =") else { continue }
                found.append(url)
            }
        }
        return found
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

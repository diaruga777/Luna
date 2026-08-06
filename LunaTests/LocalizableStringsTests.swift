//
//  LocalizableStringsTests.swift
//  LunaTests
//

import XCTest
@testable import LunaModels

/// Guards the one file every user-visible string is edited in.
///
/// These read the SHIPPED table out of the built LunaModels resource bundle
/// rather than the file in the working tree, which is the point: the bug that
/// prompted the single-file rewrite was a table that parsed perfectly on disk
/// and never reached the bundle at all, so every `L10n.string(…)` silently
/// returned its own key. A test that reads the source file would have passed
/// throughout.
///
/// The second thing they guard is a hand edit made on a phone. The file is
/// meant to be opened in a text editor away from Xcode, so a dropped `;`, a
/// stray quote or a `%@` deleted out of a format string all have to fail here
/// rather than at the point some screen tries to draw itself.
///
/// A key here is `"<base>_<suffix>"` — `Luna`, `Core`, `Reader`, `Downloader`
/// or `PriceTracker` (see `Localization.swift`) — never the English text.
/// `L10n.string("<base>")` tries `"<base>_<app's own suffix>"` first, then
/// `"<base>_Luna"`, so every base key referenced from code MUST have a
/// `_Luna` entry — that's the fallback with nowhere further to go.
final class LocalizableStringsTests: XCTestCase {
    static let suffixes = ["Luna", "Core", "Reader", "Downloader", "PriceTracker"]

    /// The compiled `Localizable.strings` from LunaModels' resource bundle,
    /// as it sits inside the test host app.
    private func shippedTable() throws -> (bundle: Bundle, entries: [String: String]) {
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "LunaLibraries_LunaModels", withExtension: "bundle"),
            "LunaModels' resource bundle is missing from the app. If this fails after a "
                + "Package.swift edit, check that `defaultLocalization` is still set — without "
                + "it the strings table is silently dropped from the bundle.")
        let bundle = try XCTUnwrap(Bundle(url: url))
        let strings = try XCTUnwrap(
            bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: "en.lproj")
                ?? bundle.url(forResource: "Localizable", withExtension: "strings"),
            "en.lproj/Localizable.strings is not in the shipped bundle")
        let parsed = NSDictionary(contentsOf: strings) as? [String: String]
        let entries = try XCTUnwrap(
            parsed,
            "Localizable.strings did not parse. This is what a bad hand edit looks like: "
                + "a missing trailing ';', an unescaped '\"', or a line that lost its '='.")
        return (bundle, entries)
    }

    /// Splits `"Foo_Reader"` into `("Foo", "Reader")`. `nil` if `key` doesn't
    /// end in one of the five recognized suffixes.
    private static func baseAndSuffix(_ key: String) -> (base: String, suffix: String)? {
        for suffix in suffixes {
            let tail = "_" + suffix
            if key.hasSuffix(tail), key.count > tail.count {
                return (String(key.dropLast(tail.count)), suffix)
            }
        }
        return nil
    }

    func testShippedTableParsesAndIsPopulated() throws {
        let (_, entries) = try shippedTable()
        // Deliberately a floor rather than an exact count: strings come and go
        // with features, and an exact number would fail for the wrong reason.
        // It is here to catch the table collapsing to empty or near-empty.
        XCTAssertGreaterThan(
            entries.count, 600,
            "only \(entries.count) strings survived parsing — the table is truncated")
    }

    /// Every key must resolve through the same bundle lookup `L10n.string` uses.
    func testEveryKeyResolvesThroughTheBundle() throws {
        let (bundle, entries) = try shippedTable()
        var unresolved: [String] = []
        for (key, value) in entries {
            let resolved = bundle.localizedString(forKey: key, value: nil, table: nil)
            if resolved != value { unresolved.append(key) }
        }
        XCTAssertTrue(
            unresolved.isEmpty,
            "\(unresolved.count) key(s) did not resolve to their value: "
                + unresolved.prefix(5).joined(separator: " | "))
    }

    /// Every entry's key must end in one of the five recognized suffixes —
    /// `L10n` only ever looks up `"<base>_<suffix>"`, so a key that doesn't
    /// end this way is unreachable dead weight (or a typo one keystroke away
    /// from being unreachable).
    func testEveryEntryKeyHasARecognizedSuffix() throws {
        let (_, entries) = try shippedTable()
        let unrecognized = entries.keys.filter { Self.baseAndSuffix($0) == nil }
        XCTAssertTrue(
            unrecognized.isEmpty,
            "\(unrecognized.count) key(s) don't end in _Luna/_Core/_Reader/_Downloader/"
                + "_PriceTracker: " + unrecognized.prefix(5).joined(separator: " | "))
    }

    /// Every base key needs a `_Luna` line — the universal fallback `L10n`
    /// reaches for when the running app has no override of its own. Without
    /// it, a per-app override with no `_Luna` sibling works fine for that one
    /// app and then shows a raw key the moment anyone else calls it.
    func testEveryBaseKeyHasALunaFallback() throws {
        let (_, entries) = try shippedTable()
        var basesNeedingLuna: Set<String> = []
        var basesWithLuna: Set<String> = []
        for key in entries.keys {
            guard let (base, suffix) = Self.baseAndSuffix(key) else { continue }
            if suffix == "Luna" {
                basesWithLuna.insert(base)
            } else {
                basesNeedingLuna.insert(base)
            }
        }
        let missing = basesNeedingLuna.subtracting(basesWithLuna)
        XCTAssertTrue(
            missing.isEmpty,
            "\(missing.count) base key(s) have an app override but no \"<base>_Luna\" "
                + "fallback: " + missing.prefix(5).joined(separator: " | "))
    }

    /// A value has to substitute exactly what its sibling suffix variants do.
    ///
    /// This is the edit most likely to get through review and crash in the
    /// field: a `_Reader` override that drops a `%@` its `_Luna` sibling has
    /// leaves an argument the call site still passes with nowhere to go, and
    /// one that adds a `%@` invents an argument that was never passed.
    func testFormatSpecifiersMatchAcrossSuffixVariants() throws {
        let (_, entries) = try shippedTable()
        var byBase: [String: [(suffix: String, value: String)]] = [:]
        for (key, value) in entries {
            guard let (base, suffix) = Self.baseAndSuffix(key) else { continue }
            byBase[base, default: []].append((suffix, value))
        }
        var mismatches: [String] = []
        for (base, variants) in byBase where variants.count > 1 {
            let specifierSets = variants.map { ($0.suffix, Self.specifiers(in: $0.value)) }
            let first = specifierSets[0].1
            if specifierSets.dropFirst().contains(where: { $0.1 != first }) {
                let detail = specifierSets.map { "\($0.0): \($0.1)" }.joined(separator: ", ")
                mismatches.append("\(base) — \(detail)")
            }
        }
        XCTAssertTrue(
            mismatches.isEmpty,
            "\(mismatches.count) base key(s) substitute differently between suffix variants:\n  "
                + mismatches.prefix(5).joined(separator: "\n  "))
    }

    /// Placeholders in the order they are substituted, positional or not.
    ///
    /// `%1$@ %2$lld` and `%@ %lld` describe the same substitution, so both
    /// reduce to `["@", "lld"]`; a literal `%%` substitutes nothing and is
    /// dropped. Comparing the reduced forms lets a value switch to positional
    /// markers — which is what a value must do the moment it reorders its
    /// arguments — without reading as a mismatch.
    static func specifiers(in text: String) -> [String] {
        // A literal percent substitutes nothing, so take those out first and
        // leave only real placeholders behind.
        let scrubbed = text.replacingOccurrences(of: "%%", with: "")
        let pattern = #"%(?:(\d+)\$)?[-+ 0#]*[0-9]*(?:\.[0-9]+)?(hh|h|ll|l|q|z|t|j|L)?([@dioufFeEgGxXscpaA])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        var positioned: [(index: Int, token: String)] = []
        var sequential: [String] = []

        for match in regex.matches(in: scrubbed, range: NSRange(scrubbed.startIndex..., in: scrubbed)) {
            func group(_ i: Int) -> String {
                guard let r = Range(match.range(at: i), in: scrubbed) else { return "" }
                return String(scrubbed[r])
            }
            // Keep the length modifier attached: %lld and %d are different
            // argument widths, and swapping one for the other misreads the
            // stack at the call site.
            let token = group(2) + group(3)
            if let index = Int(group(1)) {
                positioned.append((index, token))
            } else {
                sequential.append(token)
            }
        }

        return positioned.isEmpty
            ? sequential
            : positioned.sorted { $0.index < $1.index }.map(\.token)
    }

    /// The app's own bundle must carry the same table, because App Intents
    /// metadata resolves against the HOST bundle rather than LunaModels'.
    ///
    /// There is still only one file — the app targets copy it (see
    /// `scripts/add_strings_to_app_bundles.rb`). This asserts the copy is
    /// actually there and actually identical, since a target added later
    /// without that step would leave Shortcuts showing stale wording while
    /// everything inside the app updated correctly.
    func testAppBundleCarriesTheSameTable() throws {
        let (_, shipped) = try shippedTable()
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "Localizable", withExtension: "strings"),
            "the app bundle has no Localizable.strings — run "
                + "scripts/add_strings_to_app_bundles.rb")
        let appCopy = try XCTUnwrap(
            NSDictionary(contentsOf: url) as? [String: String],
            "the app bundle's Localizable.strings did not parse")
        XCTAssertEqual(
            appCopy, shipped,
            "the app bundle's copy has drifted from LunaModels' — they must be "
                + "the same file, not two files kept in step")
    }

    /// The App Intents metadata that has to be in the table to be editable.
    ///
    /// These are the literals Xcode bakes in at build time; they resolve
    /// against the table at runtime, which is the only reason their wording can
    /// be changed without a code edit. Unlike an `L10n` call, an intent literal
    /// has no runtime fallback — the Swift source carries the exact, already-
    /// suffixed key it needs, so this checks those concrete keys directly. If
    /// the sync script ever stops finding them, they silently become
    /// uneditable and nothing else notices.
    func testShortcutsMetadataIsInTheTable() throws {
        let (_, entries) = try shippedTable()
        for key in [
            "Intents_save_title_Luna",
            "Intents_provideContext_title_Luna",
            "Intents_readArticle_title_Luna",
            "Intents_provideContextOutcome_typeName_Luna",
            "Intents_provideContextResultEntity_typeName_Luna",
            "Intents_saveResultEntity_typeName_Luna",
            "Intents_articleEntity_typeName_Luna",
        ] {
            XCTAssertNotNil(entries[key], "intent string '\(key)' is missing")
        }
    }
}

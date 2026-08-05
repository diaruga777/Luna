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
final class LocalizableStringsTests: XCTestCase {

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

    /// A value has to substitute exactly what its key substitutes.
    ///
    /// This is the edit most likely to get through review and crash in the
    /// field: dropping a `%@` from a value leaves an argument with nowhere to
    /// go, and adding one invents an argument the call site never passed.
    func testFormatSpecifiersMatchBetweenKeyAndValue() throws {
        let (_, entries) = try shippedTable()
        var mismatches: [String] = []
        for (key, value) in entries {
            let inKey = Self.specifiers(in: key)
            let inValue = Self.specifiers(in: value)
            if inKey != inValue {
                mismatches.append("\(key)\n     key: \(inKey)  value: \(inValue)")
            }
        }
        XCTAssertTrue(
            mismatches.isEmpty,
            "\(mismatches.count) entry(ies) substitute differently from their key:\n  "
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
    /// be changed without a code edit. If the sync script ever stops finding
    /// them, they silently become uneditable and nothing else notices.
    func testShortcutsMetadataIsInTheTable() throws {
        let (_, entries) = try shippedTable()
        for key in ["Save", "Provide Context", "Read Article", "Capture Outcome",
                    "Context Result", "Save Result", "Article"] {
            XCTAssertNotNil(entries[key], "intent string '\(key)' is missing")
        }
    }
}

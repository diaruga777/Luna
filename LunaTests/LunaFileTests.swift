//
//  LunaFileTests.swift
//  LunaTests
//

import XCTest
import LunaModels

/// The one file format Luna reads back from a chat reply
/// (`claudedocs/luna-file.md`). Two readers share this parser — the plugin
/// importer and the recovery applier — so the header rules are asserted once,
/// here, and `PluginManifestParserTests` keeps the plugin vocabulary.
final class LunaFileTests: XCTestCase {

    // MARK: - The header comment

    private func recoveryFile(header: String, body: String) -> String {
        "/* luna-recovery\n\(header)\n*/\n\(body)\n"
    }

    private let articleContent = """
        { "kind": "article", "title": "A page", "html": "<p>hello</p>" }
        """

    func testMarkerMustMatchExactly() {
        for marker in ["luna-recovery-evil", "lunarecovery", "luna_recovery", "LUNA-RECOVERY"] {
            let text = "/* \(marker)\n{ \"api\": 1 }\n*/\n{}\n"
            XCTAssertNil(
                LunaFileIntake.classify(text: text),
                "\(marker) is not a Luna marker, so this is not a Luna file")
        }
    }

    func testBothMarkersAreRecognized() throws {
        let plugin = try XCTUnwrap(LunaFileIntake.classify(text: "/* luna-plugin\n{}\n*/\nluna.register({});"))
        guard case .success(.plugin) = plugin else {
            return XCTFail("expected a plugin draft, got \(plugin)")
        }
        let recovery = LunaFileIntake.classify(
            text: recoveryFile(
                header: #"{ "api": 1, "url": "https://example.com/p", "kind": "article" }"#,
                body: #"{ "content": \#(articleContent) }"#))
        guard case .success(.recovery) = try XCTUnwrap(recovery) else {
            return XCTFail("expected a recovery file, got \(String(describing: recovery))")
        }
    }

    func testTextWithNoHeaderIsNotALunaFile() {
        XCTAssertNil(LunaFileIntake.classify(text: "https://example.com/page"))
        XCTAssertNil(LunaFileIntake.classify(text: "// luna-recovery\n{}\n"))
    }

    /// Only the FIRST `*/` closes the header, so a body may hold one of its
    /// own — a plugin draft's JavaScript regularly does.
    func testACommentCloserInsideTheBodyDoesNotTruncateTheHeader() throws {
        let body = #"{ "content": { "kind": "article", "title": "A page", "html": "<p>/* not a closer */</p>" } }"#
        let outcome = try XCTUnwrap(
            LunaFileIntake.classify(
                text: recoveryFile(
                    header: #"{ "api": 1, "url": "https://example.com/p", "kind": "article" }"#,
                    body: body)))
        guard case .success(.recovery(let file)) = outcome else {
            return XCTFail("expected a recovery file, got \(outcome)")
        }
        guard case .article(let article) = file.content else {
            return XCTFail("expected an article Model")
        }
        XCTAssertEqual(article.html, "<p>/* not a closer */</p>")
    }

    /// An error names the line in the WHOLE file, not an offset into the
    /// header — that is the number the author is looking at. Leading blank
    /// lines are what a chat reply arrives with.
    func testAHeaderErrorNamesTheLineInTheWholeFile() throws {
        let text = "\n\n" + """
            /* luna-recovery
            {
              "api": 1,
              "url": "https://example.com/p"
            }
            */
            { "content": \(articleContent) }
            """
        let outcome = try XCTUnwrap(LunaFileIntake.classify(text: text))
        guard case .failure(.missingField(let field, let line)) = outcome else {
            return XCTFail("expected a missing `kind`, got \(outcome)")
        }
        XCTAssertEqual(field, "kind")
        // `/* luna-recovery` is line 3, so the header JSON starts on line 4.
        XCTAssertEqual(line, 4)
    }

    func testAFileOverTheSizeCapIsRefusedBeforeParsing() throws {
        let padding = String(repeating: " ", count: LunaFileLimits.maxSourceKB * 1024 + 1)
        let outcome = try XCTUnwrap(
            LunaFileIntake.classify(text: "/* luna-recovery\n{}\n*/\n" + padding))
        XCTAssertEqual(
            outcome, .failure(.fileTooLarge(limitKB: LunaFileLimits.maxSourceKB)))
    }

    // MARK: - Recovery validation

    private func recoveryOutcome(
        header: String, body: String
    ) throws -> Result<LunaFileKind, LunaFileError> {
        try XCTUnwrap(LunaFileIntake.classify(text: recoveryFile(header: header, body: body)))
    }

    func testTheHeaderKindMustMatchTheContentKind() throws {
        let outcome = try recoveryOutcome(
            header: #"{ "api": 1, "url": "https://example.com/p", "kind": "product" }"#,
            body: #"{ "content": \#(articleContent) }"#)
        XCTAssertEqual(outcome, .failure(.kindMismatch(header: .product, content: .article)))
    }

    func testContentIsRequired() throws {
        let outcome = try recoveryOutcome(
            header: #"{ "api": 1, "url": "https://example.com/p", "kind": "article" }"#,
            body: #"{ "recipe": { "url": "https://example.com/amp" } }"#)
        guard case .failure(.missingField(let field, _)) = outcome else {
            return XCTFail("expected the missing content field, got \(outcome)")
        }
        XCTAssertEqual(field, "content")
    }

    func testOnlyFormatOneIsRead() throws {
        let outcome = try recoveryOutcome(
            header: #"{ "api": 2, "url": "https://example.com/p", "kind": "article" }"#,
            body: #"{ "content": \#(articleContent) }"#)
        XCTAssertEqual(
            outcome, .failure(.unsupportedAPIVersion(declared: 2, supported: 1)))
    }

    func testTheHeaderURLMustBeAbsoluteHTTP() throws {
        for raw in ["/relative/page", "ftp://example.com/p", "not a url at all"] {
            let outcome = try recoveryOutcome(
                header: #"{ "api": 1, "url": "\#(raw)", "kind": "article" }"#,
                body: #"{ "content": \#(articleContent) }"#)
            guard case .failure(.invalidField(let field, _, _)) = outcome else {
                return XCTFail("expected \(raw) to be refused, got \(outcome)")
            }
            XCTAssertEqual(field, "url")
        }
    }

    // MARK: - The recipe

    /// A model that writes a header Luna does not replay loses the header, not
    /// the recovery: the content below it is still good.
    func testRecipeHeadersAreFilteredRatherThanRefused() throws {
        let body = """
            { "recipe": { "url": "https://example.com/amp",
                          "headers": { "User-Agent": "googlebot", "Cookie": "session=1",
                                       "referer": "https://example.com/" } },
              "content": \(articleContent) }
            """
        let outcome = try recoveryOutcome(
            header: #"{ "api": 1, "url": "https://example.com/p", "kind": "article" }"#,
            body: body)
        guard case .success(.recovery(let file)) = outcome,
              let recipe = file.recipe else {
            return XCTFail("expected a recipe, got \(outcome)")
        }
        XCTAssertEqual(recipe.headers, [
            "user-agent": "googlebot", "referer": "https://example.com/",
        ])
    }

    func testRecipeReturnsDefaultsToHTML() throws {
        let outcome = try recoveryOutcome(
            header: #"{ "api": 1, "url": "https://example.com/p", "kind": "article" }"#,
            body: #"{ "recipe": { "url": "https://example.com/amp" }, "content": \#(articleContent) }"#)
        guard case .success(.recovery(let file)) = outcome else {
            return XCTFail("expected a recovery file, got \(outcome)")
        }
        XCTAssertEqual(file.recipe?.returns, .html)
    }

    /// The script runs in an off-screen web view, so its size is capped where
    /// the file is read rather than where it runs.
    func testAnOversizedRecipeScriptIsRefused() throws {
        let script = String(
            repeating: "a", count: LunaRecoveryRecipe.maxJavaScriptBytes + 1)
        let outcome = try recoveryOutcome(
            header: #"{ "api": 1, "url": "https://example.com/p", "kind": "article" }"#,
            body: """
                { "recipe": { "url": "https://example.com/amp", "javascript": "\(script)" },
                  "content": \(articleContent) }
                """)
        guard case .failure(.invalidField(let field, _, _)) = outcome else {
            return XCTFail("expected the script to be refused, got \(outcome)")
        }
        XCTAssertEqual(field, "recipe.javascript")
    }

    // MARK: - The cheap text check

    /// The share sheet's text route runs this over every shared caption, so it
    /// must not answer yes to prose that merely mentions a marker.
    func testLooksLikeLunaFileAnswersTheFirstLineOnly() {
        XCTAssertTrue(LunaFileIntake.looksLikeLunaFile(text: "\n  /* luna-plugin\n{}\n*/\n"))
        XCTAssertTrue(LunaFileIntake.looksLikeLunaFile(text: "/* luna-recovery\n{}\n*/\n{}"))
        XCTAssertFalse(
            LunaFileIntake.looksLikeLunaFile(text: "Here is a luna-plugin for you:\n/* luna-plugin"))
        XCTAssertFalse(LunaFileIntake.looksLikeLunaFile(text: "/* a plain comment\nluna-plugin\n*/"))
        XCTAssertFalse(LunaFileIntake.looksLikeLunaFile(text: "https://example.com/page"))
    }

    // MARK: - Reading a file off disk

    func testReadingRefusesBytesThatAreNotUTF8() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).luna")
        try Data([0xFF, 0xFE, 0x00, 0x80]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(LunaFileReader.readText(at: url), .failure(.notText))
    }

    /// Only a copy the system made in this app's own inbox is deleted. A file
    /// the user opened in place belongs to them.
    func testOnlyAnInboxCopyIsDeleted() throws {
        let manager = FileManager.default
        let outside = manager.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).luna")
        try "/* luna-plugin\n{}\n*/".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? manager.removeItem(at: outside) }
        XCTAssertFalse(LunaFileReader.deleteInboxCopy(at: outside))
        XCTAssertTrue(manager.fileExists(atPath: outside.path))

        let inbox = try XCTUnwrap(manager.urls(for: .documentDirectory, in: .userDomainMask).first)
            .appendingPathComponent("Inbox")
        try manager.createDirectory(at: inbox, withIntermediateDirectories: true)
        let inside = inbox.appendingPathComponent("\(UUID().uuidString).luna")
        try "/* luna-plugin\n{}\n*/".write(to: inside, atomically: true, encoding: .utf8)
        XCTAssertTrue(LunaFileReader.deleteInboxCopy(at: inside))
        XCTAssertFalse(manager.fileExists(atPath: inside.path))
    }
}

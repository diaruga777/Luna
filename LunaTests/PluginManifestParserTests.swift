//
//  PluginManifestParserTests.swift
//  LunaTests
//

import LunaModels
import LunaPluginKit
import XCTest

/// The header parser is the import screen's whole vocabulary: what it refuses,
/// and whether the sentence it gives an author names the field and the line.
final class PluginManifestParserTests: XCTestCase {

    // MARK: - Building a source

    private func source(_ headerJSON: String, body: String = "luna.register({});") -> String {
        "/* luna-plugin\n\(headerJSON)\n*/\n\(body)\n"
    }

    private var minimalHeader: String {
        """
        {
          "id": "app.luna.test",
          "name": "Test",
          "version": "1.0.0",
          "api": 1
        }
        """
    }

    private func parse(_ source: String) -> Result<PluginManifest, PluginManifestError> {
        PluginManifestParser.parse(source: source)
    }

    private func failure(
        _ source: String, file: StaticString = #filePath, line: UInt = #line
    ) -> PluginManifestError? {
        switch parse(source) {
        case .success(let manifest):
            XCTFail("expected a refusal, got \(manifest.id)", file: file, line: line)
            return nil
        case .failure(let error):
            return error
        }
    }

    private func manifest(
        _ source: String, file: StaticString = #filePath, line: UInt = #line
    ) -> PluginManifest? {
        switch parse(source) {
        case .success(let manifest): return manifest
        case .failure(let error):
            XCTFail("expected a manifest, got \(error.message)", file: file, line: line)
            return nil
        }
    }

    // MARK: - The header comment

    func testAFileWithNoBlockCommentHasNoHeader() {
        XCTAssertEqual(failure("luna.register({});"), .noHeader)
    }

    func testABlockCommentThatDoesNotStartWithTheMarkerIsNotAHeader() {
        XCTAssertEqual(failure("/* just a comment\n{}\n*/\n"), .noHeader)
    }

    func testLeadingWhitespaceAndBlankLinesStillFindTheHeader() {
        let text = "\n\n   " + source(minimalHeader)
        XCTAssertEqual(manifest(text)?.id, "app.luna.test")
    }

    func testTheHeaderIsReadWithoutEvaluatingTheBody() {
        // A body that would throw on evaluation parses fine: nothing runs it.
        let text = source(minimalHeader, body: "throw new Error(\"boom\");")
        XCTAssertEqual(manifest(text)?.name, "Test")
    }

    func testUnparseableJSONNamesTheLineTheHeaderStartsOn() {
        guard case .headerNotJSON(let line, _)? = failure(source("{ \"id\": }")) else {
            return XCTFail("expected headerNotJSON")
        }
        XCTAssertEqual(line, 2)
    }

    func testASourceOverTheSizeCapIsRefused() {
        let padding = String(repeating: "/", count: PluginManifestParser.maxSourceKB * 1024 + 1)
        XCTAssertEqual(
            failure(source(minimalHeader, body: padding)),
            .sourceTooLarge(limitKB: PluginManifestParser.maxSourceKB))
    }

    // MARK: - Required fields

    func testEachRequiredFieldIsNamedWhenItIsAbsent() {
        let cases: [(String, String)] = [
            ("id", #"{ "name": "T", "version": "1.0.0", "api": 1 }"#),
            ("name", #"{ "id": "a.b", "version": "1.0.0", "api": 1 }"#),
            ("version", #"{ "id": "a.b", "name": "T", "api": 1 }"#),
            ("api", #"{ "id": "a.b", "name": "T", "version": "1.0.0" }"#),
        ]
        for (field, header) in cases {
            let error = failure(source(header))
            XCTAssertEqual(error?.field, field, "\(header)")
            XCTAssertTrue(
                error?.message.contains("\"\(field)\"") == true,
                "the message should quote the field: \(error?.message ?? "")")
        }
    }

    func testEveryFieldErrorCarriesTheLineTheFieldIsWrittenOn() {
        let header = """
        {
          "id": "app.luna.test",
          "name": "Test",
          "version": "not-a-version",
          "api": 1
        }
        """
        // Line 1 is `/* luna-plugin`, 2 is `{`, and `"version"` is the fourth
        // line of the object.
        XCTAssertEqual(failure(source(header))?.line, 5)
    }

    // MARK: - Field rules

    func testAnIdMayNotCarryASeparatorOrADotDot() {
        for bad in ["app/luna", "../escape", "App.Luna", ".leading"] {
            let header = #"{ "id": "\#(bad)", "name": "T", "version": "1.0.0", "api": 1 }"#
            XCTAssertEqual(failure(source(header))?.field, "id", bad)
        }
    }

    func testAVersionMustBeThreeNumbers() {
        for bad in ["1.0", "1.0.0.0", "1.0.x", "v1.0.0"] {
            let header = #"{ "id": "a.b", "name": "T", "version": "\#(bad)", "api": 1 }"#
            XCTAssertEqual(failure(source(header))?.field, "version", bad)
        }
    }

    func testAnApiHigherThanThisBuildRefusesTheImport() {
        let header = #"{ "id": "a.b", "name": "T", "version": "1.0.0", "api": 99 }"#
        XCTAssertEqual(
            failure(source(header)),
            .apiTooNew(declared: 99, supported: PluginAPIVersion.current))
    }

    func testAnUnknownCapabilityRefusesTheImportAndNamesIt() {
        let header = """
        { "id": "a.b", "name": "T", "version": "1.0.0", "api": 1,
          "capabilities": ["fetch", "telepathy"] }
        """
        guard case .unknownCapability(let name, _)? = failure(source(header)) else {
            return XCTFail("expected unknownCapability")
        }
        XCTAssertEqual(name, "telepathy")
    }

    func testCapabilitiesKeepTheirOrderAndDropDuplicates() {
        let header = """
        { "id": "a.b", "name": "T", "version": "1.0.0", "api": 1,
          "capabilities": ["storage", "fetch", "storage"] }
        """
        XCTAssertEqual(manifest(source(header))?.capabilities, [.storage, .fetch])
    }

    // MARK: - match

    func testAnIngestPluginNeedsMatchAndAtLeastOneHostOrAny() {
        let noMatch = """
        { "id": "a.b", "name": "T", "version": "1.0.0", "api": 1, "produces": ["media"] }
        """
        XCTAssertEqual(failure(source(noMatch))?.field, "match")

        let emptyHosts = """
        { "id": "a.b", "name": "T", "version": "1.0.0", "api": 1, "produces": ["media"],
          "match": { "hosts": [] } }
        """
        XCTAssertEqual(failure(source(emptyHosts))?.field, "match.hosts")
    }

    func testAnyHostNeedsNoHostList() {
        let header = """
        { "id": "a.b", "name": "T", "version": "1.0.0", "api": 1, "produces": ["media"],
          "match": { "any": true } }
        """
        let parsed = manifest(source(header))
        XCTAssertEqual(parsed?.matchesAnyHost, true)
        XCTAssertEqual(parsed?.hosts, [])
    }

    func testHostsAreLoweredAndDeduplicated() {
        let header = """
        { "id": "a.b", "name": "T", "version": "1.0.0", "api": 1, "produces": ["media"],
          "match": { "hosts": ["Example.COM", "*.Example.com", "example.com"] } }
        """
        XCTAssertEqual(manifest(source(header))?.hosts, ["example.com", "*.example.com"])
    }

    func testAnExportOnlyPluginNeedsNoMatch() {
        let header = """
        { "id": "a.b", "name": "T", "version": "1.0.0", "api": 1,
          "export": { "kinds": ["article"], "input": "epub", "title": "Send" } }
        """
        let parsed = manifest(source(header))
        XCTAssertEqual(parsed?.produces, [])
        XCTAssertEqual(parsed?.export?.title, "Send")
    }

    // MARK: - produces

    func testAnUnknownProducesKindIsRefused() {
        let header = """
        { "id": "a.b", "name": "T", "version": "1.0.0", "api": 1, "produces": ["podcast"],
          "match": { "hosts": ["a.com"] } }
        """
        XCTAssertEqual(failure(source(header))?.field, "produces")
    }

    func testAnIngestManifestRequiresClassifyAndIngest() {
        let header = """
        { "id": "a.b", "name": "T", "version": "1.0.0", "api": 1, "produces": ["media"],
          "match": { "hosts": ["a.com"] } }
        """
        XCTAssertEqual(manifest(source(header))?.requiredHooks, [.classify, .ingest])
    }

    // MARK: - export

    func testAnUnknownExportInputFormatIsRefused() {
        let header = """
        { "id": "a.b", "name": "T", "version": "1.0.0", "api": 1,
          "export": { "kinds": ["article"], "input": "papyrus", "title": "Send" } }
        """
        XCTAssertEqual(failure(source(header))?.field, "export.input")
    }

    func testTheEpubProfileAndDestinationFlagReachTheSummary() {
        let header = """
        { "id": "a.b", "name": "T", "version": "1.0.0", "api": 1,
          "export": { "kinds": ["article"], "input": "epub", "title": "Send to Xteink",
                      "destination": true, "requiresSettings": ["device"],
                      "inputOptions": { "epub": { "profile": "compact", "images": false } } } }
        """
        let export = manifest(source(header))?.export
        XCTAssertEqual(export?.epubProfile, "compact")
        XCTAssertEqual(export?.epubImages, false)
        XCTAssertEqual(export?.isDestination, true)
        XCTAssertEqual(export?.requiresSettings, ["device"])
        XCTAssertEqual(manifest(source(header))?.requiredHooks, [.export])
    }

    // MARK: - settings

    func testASettingsFieldParsesIntoTheSeamType() {
        let header = """
        { "id": "a.b", "name": "T", "version": "1.0.0", "api": 1,
          "settings": [
            { "key": "kindleAddress", "type": "email", "label": "Kindle address",
              "required": true, "help": "The @kindle.com address" },
            { "key": "quality", "type": "choice", "label": "Quality",
              "options": [{ "id": "hd", "label": "HD" }], "default": "hd" },
            { "key": "token", "type": "password", "label": "Token", "secret": true }
          ] }
        """
        let fields = manifest(source(header))?.settings ?? []
        XCTAssertEqual(fields.count, 3)
        XCTAssertEqual(fields[0].type, .email)
        XCTAssertEqual(fields[0].isRequired, true)
        XCTAssertEqual(fields[0].help, "The @kindle.com address")
        XCTAssertEqual(fields[1].options.map(\.id), ["hd"])
        XCTAssertEqual(fields[1].defaultJSON, "\"hd\"")
        XCTAssertEqual(fields[2].isSecret, true)
    }

    func testAReservedUnderscoreKeyIsRefused() {
        let header = """
        { "id": "a.b", "name": "T", "version": "1.0.0", "api": 1,
          "settings": [{ "key": "_status", "type": "info", "label": "Status" }] }
        """
        XCTAssertEqual(failure(source(header))?.field, "settings.key")
    }

    func testAChoiceFieldWithoutOptionsIsRefused() {
        let header = """
        { "id": "a.b", "name": "T", "version": "1.0.0", "api": 1,
          "settings": [{ "key": "quality", "type": "choice", "label": "Quality" }] }
        """
        XCTAssertEqual(failure(source(header))?.field, "settings.options")
    }

    // MARK: - bluetooth

    func testABluetoothDeclarationNeedsTheCapability() {
        let header = """
        { "id": "a.b", "name": "T", "version": "1.0.0", "api": 1,
          "bluetooth": { "services": ["FEED"], "pairing": "accessorySetupKit" } }
        """
        XCTAssertEqual(failure(source(header))?.field, "bluetooth")
    }

    func testABluetoothDeclarationRequiresTheOnBluetoothHook() {
        let header = """
        { "id": "a.b", "name": "T", "version": "1.0.0", "api": 1,
          "capabilities": ["bluetooth"],
          "bluetooth": { "services": ["FEED"], "pairing": "accessorySetupKit",
                         "standingConnect": true } }
        """
        let parsed = manifest(source(header))
        XCTAssertEqual(parsed?.requiredHooks, [.onBluetooth])
        XCTAssertEqual(parsed?.bluetooth?.standingConnect, true)
    }

    // MARK: - Host matching

    func testWildcardHostsMatchTheRootAndItsSubdomains() {
        let header = """
        { "id": "a.b", "name": "T", "version": "1.0.0", "api": 1, "produces": ["media"],
          "match": { "hosts": ["*.example.com", "other.test"] } }
        """
        guard let summary = manifest(source(header))?.summary(hooks: [], isBundled: false) else {
            return XCTFail("no manifest")
        }
        XCTAssertTrue(summary.matches(host: "example.com"))
        XCTAssertTrue(summary.matches(host: "www.example.com"))
        XCTAssertTrue(summary.matches(host: "other.test"))
        XCTAssertFalse(summary.matches(host: "notexample.com"))
        XCTAssertFalse(summary.matches(host: "example.com.evil.test"))
    }
}

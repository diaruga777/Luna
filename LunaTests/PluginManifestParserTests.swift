//
//  PluginManifestParserTests.swift
//  LunaTests
//

import Foundation
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

    private func parse(
        _ source: String, languages: [String] = Locale.preferredLanguages
    ) -> Result<PluginManifest, PluginManifestError> {
        PluginManifestParser.parse(source: source, languages: languages)
    }

    private func failure(
        _ source: String, languages: [String] = Locale.preferredLanguages,
        file: StaticString = #filePath, line: UInt = #line
    ) -> PluginManifestError? {
        switch parse(source, languages: languages) {
        case .success(let manifest):
            XCTFail("expected a refusal, got \(manifest.id)", file: file, line: line)
            return nil
        case .failure(let error):
            return error
        }
    }

    private func manifest(
        _ source: String, languages: [String] = Locale.preferredLanguages,
        file: StaticString = #filePath, line: UInt = #line
    ) -> PluginManifest? {
        switch parse(source, languages: languages) {
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

    func testMarkerMustBeExactRatherThanAPluginPrefix() {
        let text = "/* luna-plugin-evil\n\(minimalHeader)\n*/\nluna.register({});"
        XCTAssertEqual(failure(text), .noHeader)
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
                      "inputOptions": { "epub": { "profile": "compact", "images": false } } },
          "settings": [{ "key": "device", "type": "text", "label": "Device" }] }
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

    // MARK: - Localized copy

    func testALocalizedNameResolvesTheExactTagFirst() {
        let header = """
        { "id": "a.b", "name": { "en": "Test", "de-AT": "Test (AT)", "de": "Test (DE)" },
          "version": "1.0.0", "api": 1 }
        """
        XCTAssertEqual(manifest(source(header), languages: ["de-AT"])?.name, "Test (AT)")
    }

    func testALocalizedNameFallsBackToTheLanguagePrefix() {
        let header = """
        { "id": "a.b", "name": { "en": "Test", "de": "Test (DE)" },
          "version": "1.0.0", "api": 1 }
        """
        XCTAssertEqual(manifest(source(header), languages: ["de-CH"])?.name, "Test (DE)")
    }

    func testALocalizedNameFallsBackToEnglishWhenNothingMatches() {
        let header = """
        { "id": "a.b", "name": { "en": "Test", "de": "Test (DE)" },
          "version": "1.0.0", "api": 1 }
        """
        XCTAssertEqual(manifest(source(header), languages: ["fr"])?.name, "Test")
    }

    func testAPlainStringNameStillParses() {
        let header = #"{ "id": "a.b", "name": "Test", "version": "1.0.0", "api": 1 }"#
        XCTAssertEqual(manifest(source(header), languages: ["fr"])?.name, "Test")
    }

    func testALocalizedTableMissingEnglishIsRefused() {
        let header = """
        { "id": "a.b", "name": { "de": "Test (DE)" }, "version": "1.0.0", "api": 1 }
        """
        let error = failure(source(header))
        XCTAssertEqual(error?.field, "name")
        XCTAssertTrue(error?.message.contains("\"en\"") == true, error?.message ?? "")
    }

    func testEveryVariantOfALocalizedTableObeysTheFieldsCap() {
        let tooLong = String(repeating: "x", count: PluginManifestParser.nameMaxLength + 1)
        let header = """
        { "id": "a.b", "name": { "en": "Test", "de": "\(tooLong)" },
          "version": "1.0.0", "api": 1 }
        """
        XCTAssertEqual(failure(source(header))?.field, "name")
    }

    func testALocalizedExportTitleResolves() {
        let header = """
        { "id": "a.b", "name": "T", "version": "1.0.0", "api": 1,
          "export": { "kinds": ["article"], "input": "epub",
                      "title": { "en": "Send", "es": "Enviar" } } }
        """
        XCTAssertEqual(manifest(source(header), languages: ["es"])?.export?.title, "Enviar")
    }

    func testALocalizedSettingsLabelHelpAndOptionLabelResolve() {
        let header = """
        { "id": "a.b", "name": "T", "version": "1.0.0", "api": 1,
          "settings": [
            { "key": "quality", "type": "choice",
              "label": { "en": "Quality", "es": "Calidad" },
              "help": { "en": "Pick one", "es": "Elige una" },
              "options": [{ "id": "hd", "label": { "en": "HD", "es": "Alta" } }] }
          ] }
        """
        let field = manifest(source(header), languages: ["es"])?.settings.first
        XCTAssertEqual(field?.label, "Calidad")
        XCTAssertEqual(field?.help, "Elige una")
        XCTAssertEqual(field?.options.first?.label, "Alta")
    }

    // MARK: - R1#18 boolean validation

    func testASettingsRequiredFlagRejectsANonBoolean() {
        let header = """
        { "id": "a.b", "name": "T", "version": "1.0.0", "api": 1,
          "settings": [{ "key": "k", "type": "text", "label": "K", "required": 1 }] }
        """
        XCTAssertEqual(failure(source(header))?.field, "settings.required")
    }

    func testASettingsSecretFlagRejectsANonBoolean() {
        let header = """
        { "id": "a.b", "name": "T", "version": "1.0.0", "api": 1,
          "settings": [{ "key": "k", "type": "text", "label": "K", "secret": "yes" }] }
        """
        XCTAssertEqual(failure(source(header))?.field, "settings.secret")
    }

    func testAnUnencodableSettingsDefaultIsAnError() {
        // A JSON header cannot literally contain NaN, so this checks the
        // encode failure path with a value JSONSerialization already refuses
        // as a top-level fragment it cannot round-trip cleanly: a nested
        // dictionary with a non-string key is not expressible in JSON to
        // begin with, so the parser never sees one — instead this pins that a
        // valid default still round-trips, guarding the refactor from R1#18's
        // silent-drop bug regressing into a silent-empty one.
        let header = """
        { "id": "a.b", "name": "T", "version": "1.0.0", "api": 1,
          "settings": [{ "key": "k", "type": "toggle", "label": "K", "default": true }] }
        """
        XCTAssertEqual(manifest(source(header))?.settings.first?.defaultJSON, "true")
    }

    // MARK: - R1#19 settings key charset

    func testASettingsKeyRejectsNonASCIILetters() {
        let header = """
        { "id": "a.b", "name": "T", "version": "1.0.0", "api": 1,
          "settings": [{ "key": "clé", "type": "text", "label": "K" }] }
        """
        XCTAssertEqual(failure(source(header))?.field, "settings.key")
    }

    // MARK: - R1#20 host wildcard placement

    func testABareWildcardHostIsRefused() {
        let header = """
        { "id": "a.b", "name": "T", "version": "1.0.0", "api": 1, "produces": ["media"],
          "match": { "hosts": ["*"] } }
        """
        XCTAssertEqual(failure(source(header))?.field, "match.hosts")
    }

    func testAWildcardInTheMiddleOfAHostIsRefused() {
        let header = """
        { "id": "a.b", "name": "T", "version": "1.0.0", "api": 1, "produces": ["media"],
          "match": { "hosts": ["a.*.example.com"] } }
        """
        XCTAssertEqual(failure(source(header))?.field, "match.hosts")
    }

    // MARK: - R1#21 requiresSettings

    func testRequiresSettingsMustNameADeclaredKey() {
        let header = """
        { "id": "a.b", "name": "T", "version": "1.0.0", "api": 1,
          "export": { "kinds": ["article"], "input": "epub", "title": "Send",
                      "requiresSettings": ["missingKey"] },
          "settings": [{ "key": "otherKey", "type": "text", "label": "K" }] }
        """
        XCTAssertEqual(failure(source(header))?.field, "export.requiresSettings")
    }

    func testRequiresSettingsPassesWhenTheKeyIsDeclared() {
        let header = """
        { "id": "a.b", "name": "T", "version": "1.0.0", "api": 1,
          "export": { "kinds": ["article"], "input": "epub", "title": "Send",
                      "requiresSettings": ["deviceKey"] },
          "settings": [{ "key": "deviceKey", "type": "text", "label": "Device" }] }
        """
        XCTAssertEqual(manifest(source(header))?.export?.requiresSettings, ["deviceKey"])
    }
}

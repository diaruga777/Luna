//
//  LunaFileTypeTests.swift
//  LunaTests
//

import XCTest
import LunaAppConfig
import LunaModels
import UniformTypeIdentifiers

/// The Luna file types the BUILT app declares (`claudedocs/luna-file.md`).
///
/// This reads the test host's own `Info.plist` and the system type database,
/// because that is the only place the xcconfig → Info.plist → `actool` chain
/// can be observed: a Swift constant that agrees with a plist Xcode never
/// interpolated would prove nothing. The host is the central Luna app, so the
/// sibling apps' one differing key — the document type — is verified from the
/// built products directory instead (see the work package report).
final class LunaFileTypeTests: XCTestCase {

    private var info: [String: Any] {
        get throws { try XCTUnwrap(Bundle.main.infoDictionary) }
    }

    private var prefix: String { AppConfig.productBundlePrefix }

    // MARK: - The exported declarations

    private func exportedDeclaration(_ identifier: String) throws -> [String: Any] {
        let declarations = try XCTUnwrap(
            info["UTExportedTypeDeclarations"] as? [[String: Any]],
            "the app exports no type declarations")
        return try XCTUnwrap(
            declarations.first { $0["UTTypeIdentifier"] as? String == identifier },
            "no exported declaration for \(identifier)")
    }

    /// Every app exports all four, so each knows the family's types whether or
    /// not its siblings are installed.
    func testTheFourFamilyTypesAreExportedWithTheirExtensions() throws {
        let expected: [(app: LunaApp, fileExtension: String)] = [
            (.luna, "luna"), (.reader, "lunar"),
            (.downloader, "lunad"), (.priceTracker, "lunas"),
        ]
        for (app, fileExtension) in expected {
            let identifier = try XCTUnwrap(app.fileTypeIdentifier)
            let declaration = try exportedDeclaration(identifier)
            let tags = declaration["UTTypeTagSpecification"] as? [String: Any]
            XCTAssertEqual(
                tags?["public.filename-extension"] as? [String], [fileExtension],
                "\(identifier) does not claim .\(fileExtension)")
            XCTAssertFalse(
                (declaration["UTTypeDescription"] as? String ?? "").isEmpty,
                "\(identifier) has no description for the Files app to show")
        }
    }

    /// The three sibling types conform to the central one. That conformance is
    /// what lets the central app claim ONE document type and still open all
    /// four extensions.
    func testTheSiblingTypesConformToTheCentralType() throws {
        for app in [LunaApp.reader, .downloader, .priceTracker] {
            let identifier = try XCTUnwrap(app.fileTypeIdentifier)
            let declaration = try exportedDeclaration(identifier)
            XCTAssertEqual(
                declaration["UTTypeConformsTo"] as? [String], ["\(prefix).file"],
                "\(identifier) must conform to the central Luna file type")
        }
    }

    /// And the system agrees, which is the half a plist read cannot prove: a
    /// declaration the type database refused would still look right above.
    func testTheSystemResolvesTheConformance() throws {
        let central = try XCTUnwrap(UTType("\(prefix).file"), "the central type is not registered")
        for app in [LunaApp.reader, .downloader, .priceTracker] {
            let identifier = try XCTUnwrap(app.fileTypeIdentifier)
            let type = try XCTUnwrap(UTType(identifier), "\(identifier) is not registered")
            XCTAssertTrue(type.conforms(to: central), "\(identifier) does not conform to \(central)")
        }
        XCTAssertTrue(central.conforms(to: .plainText))
    }

    // MARK: - The document type

    /// `$(LUNA_DOC_UTI)` is set per app target, so this asserts the central
    /// app's value — and that the variable was interpolated at all rather than
    /// shipped as its own name.
    func testTheAppClaimsExactlyItsOwnDocumentType() throws {
        let types = try XCTUnwrap(
            info["CFBundleDocumentTypes"] as? [[String: Any]],
            "the app claims no document type")
        XCTAssertEqual(types.count, 1, "one document type covers the whole family")
        let entry = try XCTUnwrap(types.first)
        XCTAssertEqual(entry["LSItemContentTypes"] as? [String], ["\(prefix).file"])
        XCTAssertEqual(entry["LSHandlerRank"] as? String, "Owner")
    }

    /// Luna copies the file out of its inbox and deletes it, so it must not
    /// claim to edit the user's own copy in place.
    func testLunaDoesNotOpenDocumentsInPlace() throws {
        XCTAssertEqual(try info["LSSupportsOpeningDocumentsInPlace"] as? Bool, false)
    }

    // MARK: - The hand-off targets

    /// Without these the recovery row cannot tell whether the provider's app
    /// is installed, and would always fall back to the web form.
    func testTheLLMProviderSchemesAreQueryable() throws {
        let schemes = try XCTUnwrap(info["LSApplicationQueriesSchemes"] as? [String])
        XCTAssertTrue(schemes.contains("chatgpt"), "chatgpt is not queryable")
        XCTAssertTrue(schemes.contains("claude"), "claude is not queryable")
    }
}

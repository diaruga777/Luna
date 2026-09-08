//
//  WriterDeepLinkTests.swift
//  LunaWriterTests
//

import XCTest
@testable import LunaWriterLibraryUI
import LunaWriterModels

final class WriterDeepLinkTests: XCTestCase {

    func testDocumentURLParsesTheUUID() throws {
        let id = DocumentID()
        let url = try XCTUnwrap(URL(string: "lunawriter://document/\(id.storageValue)"))
        XCTAssertEqual(WriterDeepLink(url: url), .document(id))
    }

    func testNewSheetURLParses() throws {
        let url = try XCTUnwrap(URL(string: "lunawriter://new"))
        XCTAssertEqual(WriterDeepLink(url: url), .newSheet)
    }

    func testAForeignSchemeIsRejected() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/document/whatever"))
        XCTAssertNil(WriterDeepLink(url: url))
    }

    func testAMalformedUUIDIsRejected() throws {
        let url = try XCTUnwrap(URL(string: "lunawriter://document/not-a-uuid"))
        XCTAssertNil(WriterDeepLink(url: url))
    }

    func testAnUnrecognizedHostIsRejected() throws {
        let url = try XCTUnwrap(URL(string: "lunawriter://somethingElse"))
        XCTAssertNil(WriterDeepLink(url: url))
    }
}

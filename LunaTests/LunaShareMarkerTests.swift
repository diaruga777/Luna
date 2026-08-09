//
//  LunaShareMarkerTests.swift
//  LunaTests
//
//  Ported from LunaLibraries/Tests/LunaMailAccountTests (retired — that SwiftPM
//  test target never ran under the app-hosted `LunaTests` bundle).
//

import XCTest
@testable import LunaMailAccount

final class LunaShareMarkerTests: XCTestCase {

    func testHeaderRoundTrip() {
        let marker = LunaShareMarker(
            url: "https://example.com/a", title: "A Title", kind: "article", sender: "Alice")
        let value = marker.headerValue()
        XCTAssertFalse(value.isEmpty)
        let parsed = LunaShareMarker.from(headerValue: value)
        XCTAssertEqual(parsed, marker)
    }

    func testHeaderRoundTripWithUnicodeAndNoSender() {
        let marker = LunaShareMarker(
            url: "https://example.com/π", title: "Café — Résumé", kind: "video")
        let parsed = LunaShareMarker.from(headerValue: marker.headerValue())
        XCTAssertEqual(parsed, marker)
    }

    func testHiddenBodyRoundTrip() {
        let marker = LunaShareMarker(
            url: "https://example.com/b", title: "B", kind: "product", sender: "Bob")
        let body = "<html><body><p>Hi</p>\(marker.hiddenHTMLBlock())</body></html>"
        XCTAssertEqual(LunaShareMarker.from(htmlBody: body), marker)
    }

    func testRejectsGarbage() {
        XCTAssertNil(LunaShareMarker.from(headerValue: "not base64 !!!"))
        XCTAssertNil(LunaShareMarker.from(htmlBody: "<p>no marker here</p>"))
    }

    func testProviderUsernameDerivation() {
        let icloud = MailProvider.provider(for: .icloud)
        XCTAssertEqual(icloud.imapUsername(for: "jane@icloud.com"), "jane")
        XCTAssertEqual(icloud.smtpUsername(for: "jane@icloud.com"), "jane@icloud.com")
        let gmail = MailProvider.provider(for: .gmail)
        XCTAssertEqual(gmail.imapUsername(for: "jane@gmail.com"), "jane@gmail.com")
    }
}

//
//  IncomingMailImporterTests.swift
//  LunaTests
//

import XCTest
import LunaMailAccount
import LunaSocial
@testable import LunaReadingList

final class IncomingMailImporterTests: XCTestCase {

    func testIsLunaShareSubjectTrueForPrefix() {
        XCTAssertTrue(IncomingMailImporter.isLunaShareSubject(
            "\(FilterGuide.subjectPrefix)A Great Article"))
    }

    func testIsLunaShareSubjectFalseForOldReadablePrefix() {
        XCTAssertFalse(IncomingMailImporter.isLunaShareSubject("From Luna: A Great Article"))
    }

    func testIsLunaShareSubjectFalseForOrdinaryNewsletter() {
        XCTAssertFalse(IncomingMailImporter.isLunaShareSubject("Money Stuff: The Stock Market"))
    }

    func testIsLunaShareSubjectDecodesEncodedWordsFirst() {
        // "=?UTF-8?B?dmlhIEx14oCMbmE6IEhlbGxv?=" -> "via Lu\u{200C}na: Hello"
        XCTAssertTrue(IncomingMailImporter.isLunaShareSubject("=?UTF-8?B?dmlhIEx14oCMbmE6IEhlbGxv?="))
    }

    func testTitleStrippingLunaPrefixRemovesPrefixAndTrims() {
        XCTAssertEqual(
            IncomingMailImporter.titleStrippingLunaPrefix(
                "\(FilterGuide.subjectPrefix)A Great Article"),
            "A Great Article")
    }

    func testTitleStrippingLunaPrefixLeavesNonLunaSubjectUnchanged() {
        XCTAssertEqual(
            IncomingMailImporter.titleStrippingLunaPrefix("Money Stuff: The Stock Market"),
            "Money Stuff: The Stock Market")
    }

    func testTitleStrippingLunaPrefixHandlesURLFallbackTitle() {
        // EmailContentRenderer.subject falls back to the URL when the share
        // has no title — the stripped title should just be the bare URL.
        XCTAssertEqual(
            IncomingMailImporter.titleStrippingLunaPrefix(
                "\(FilterGuide.subjectPrefix)https://example.com/article"),
            "https://example.com/article")
    }

    func testSameAddressIsCaseAndWhitespaceInsensitive() {
        XCTAssertTrue(IncomingMailImporter.sameAddress(
            " Sender@Example.com ", "sender@example.com"))
        XCTAssertFalse(IncomingMailImporter.sameAddress(
            "sender@example.com", "other@example.com"))
        XCTAssertFalse(IncomingMailImporter.sameAddress("sender@example.com", nil))
    }
}

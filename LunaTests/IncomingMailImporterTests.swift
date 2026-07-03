//
//  IncomingMailImporterTests.swift
//  LunaTests
//

import XCTest
@testable import LunaReadingList

final class IncomingMailImporterTests: XCTestCase {

    func testIsLunaShareSubjectTrueForPrefix() {
        XCTAssertTrue(IncomingMailImporter.isLunaShareSubject("From Luna: A Great Article"))
    }

    func testIsLunaShareSubjectFalseForOrdinaryNewsletter() {
        XCTAssertFalse(IncomingMailImporter.isLunaShareSubject("Money Stuff: The Stock Market"))
    }

    func testIsLunaShareSubjectDecodesEncodedWordsFirst() {
        // "=?UTF-8?B?RnJvbSBMdW5hOiBIZWxsbw==?=" → "From Luna: Hello"
        XCTAssertTrue(IncomingMailImporter.isLunaShareSubject("=?UTF-8?B?RnJvbSBMdW5hOiBIZWxsbw==?="))
    }

    func testTitleStrippingLunaPrefixRemovesPrefixAndTrims() {
        XCTAssertEqual(
            IncomingMailImporter.titleStrippingLunaPrefix("From Luna: A Great Article"),
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
            IncomingMailImporter.titleStrippingLunaPrefix("From Luna: https://example.com/article"),
            "https://example.com/article")
    }
}

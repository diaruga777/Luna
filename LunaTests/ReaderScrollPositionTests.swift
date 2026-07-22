//
//  ReaderScrollPositionTests.swift
//  LunaTests
//


import LunaModels
import XCTest

final class ReaderScrollPositionTests: XCTestCase {
    func testOffsetsThroughTitleHeaderNormalizeToTop() {
        XCTAssertEqual(
            ReaderScrollPosition.normalizedForPersistence(-72, titleHeaderHeight: 96), 0)
        XCTAssertEqual(
            ReaderScrollPosition.normalizedForPersistence(0, titleHeaderHeight: 96), 0)
        XCTAssertEqual(
            ReaderScrollPosition.normalizedForPersistence(95.9, titleHeaderHeight: 96), 0)
        XCTAssertEqual(
            ReaderScrollPosition.normalizedForPersistence(96, titleHeaderHeight: 96), 0)
    }

    func testOffsetPastTitleHeaderIsPreservedExactly() {
        XCTAssertEqual(
            ReaderScrollPosition.normalizedForPersistence(96.1, titleHeaderHeight: 96), 96.1)
    }
}

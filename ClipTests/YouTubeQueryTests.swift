//
//  YouTubeQueryTests.swift
//  ClipTests
//

import ClipYouTubeAPI
import XCTest
@testable import Clip

final class YouTubeQueryTests: XCTestCase {

    func testSplitsOnFirstColon() {
        let parsed = YouTubeQuery.parse("Veritasium:The Science of Everything")
        XCTAssertEqual(parsed?.channel, "Veritasium")
        XCTAssertEqual(parsed?.title, "The Science of Everything")
    }

    func testTitleMayContainColons() {
        let parsed = YouTubeQuery.parse("Lex Fridman:Elon Musk: Tesla and SpaceX")
        XCTAssertEqual(parsed?.channel, "Lex Fridman")
        XCTAssertEqual(parsed?.title, "Elon Musk: Tesla and SpaceX")
    }

    func testDropsAtPrefixFromChannel() {
        let parsed = YouTubeQuery.parse("@mkbhd:iPhone review")
        XCTAssertEqual(parsed?.channel, "mkbhd")
        XCTAssertEqual(parsed?.title, "iPhone review")
    }

    func testDropsEllipsisCharacterAndDots() {
        let parsed = YouTubeQuery.parse("Kurzgesagt:What if we…:the end of")
        XCTAssertEqual(parsed?.channel, "Kurzgesagt")
        XCTAssertEqual(parsed?.title, "What if we :the end of")

        let dots = YouTubeQuery.parse("Channel:Title that trails off...")
        XCTAssertEqual(dots?.title, "Title that trails off")
    }

    func testRejectsMissingColonOrEmptyParts() {
        XCTAssertNil(YouTubeQuery.parse("no colon here"))
        XCTAssertNil(YouTubeQuery.parse(":only title"))
        XCTAssertNil(YouTubeQuery.parse("only channel:"))
        XCTAssertNil(YouTubeQuery.parse("@:…"))
    }
}

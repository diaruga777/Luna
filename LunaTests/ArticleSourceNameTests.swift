//
//  ArticleSourceNameTests.swift
//  LunaTests
//

import LunaIntents
import XCTest

final class ArticleSourceNameTests: XCTestCase {

    /// Both halves of the source-name derivation, as tables: the host a saved URL
    /// reduces to, and the spoken name that host reduces to.
    func testHostAndHumanReadableDerivations() {
        // urlString → host (nil = no host worth showing)
        let hosts: [(String, String?)] = [
            ("https://www.theatlantic.com/article", "theatlantic.com"),
            ("https://TheAtlantic.COM/x", "theatlantic.com"),
            ("lunadoc://abc-123", nil),
            ("", nil),
        ]
        for (input, expected) in hosts {
            XCTAssertEqual(
                ArticleSourceName.host(fromURLString: input), expected,
                "host(fromURLString: \(input))")
        }

        // host → human-readable name
        let names: [(String, String)] = [
            ("theatlantic.com", "the atlantic"),
            ("thehill.com", "the hill"),
            ("theverge.com", "the verge"),
            ("new-york-times.com", "new york times"),
            ("bbc.co.uk", "bbc"),
            ("www.theatlantic.com", "the atlantic"),
            ("nytimes.com", "nytimes"),
        ]
        for (input, expected) in names {
            XCTAssertEqual(
                ArticleSourceName.humanReadable(host: input), expected,
                "humanReadable(host: \(input))")
        }
    }
}

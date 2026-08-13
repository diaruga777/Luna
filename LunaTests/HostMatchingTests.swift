//
//  HostMatchingTests.swift
//  LunaTests
//

import LunaURLClassification
import XCTest

final class HostMatchingTests: XCTestCase {

    func testNormalizedHostStripsALeadingWwwPrefix() {
        XCTAssertEqual(HostMatching.normalizedHost("www.example.com"), "example.com")
    }

    func testNormalizedHostLowercasesTheHost() {
        XCTAssertEqual(HostMatching.normalizedHost("WWW.Example.COM"), "example.com")
    }

    /// A `www` that isn't the leading subdomain is part of the host, not a
    /// prefix to strip — "shopwww.com" must stay "shopwww.com", never lose
    /// its middle "www." the way a bare `replacingOccurrences` would.
    func testNormalizedHostLeavesAMidStringWwwAlone() {
        XCTAssertEqual(HostMatching.normalizedHost("shopwww.com"), "shopwww.com")
    }

    func testNormalizedHostLeavesAHostWithNoWwwAlone() {
        XCTAssertEqual(HostMatching.normalizedHost("example.com"), "example.com")
    }
}

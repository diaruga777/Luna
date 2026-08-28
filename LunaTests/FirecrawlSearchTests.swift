//
//  FirecrawlSearchTests.swift
//  LunaTests
//

import LunaFetch
import LunaModels
import XCTest

/// Firecrawl answers JSON, so the whole of what can go wrong is a body shape or
/// a status: a successful search, a search that found nothing, a 200 carrying
/// `"success": false`, a body that is not JSON at all, and the 429 every keyless
/// cap uses. The mapping is pure, so all of it is asserted without a server.
final class FirecrawlSearchTests: XCTestCase {

    private func json(_ raw: String) -> Data {
        Data(raw.utf8)
    }

    // MARK: - The body shape Firecrawl serves

    func testWebResultsAreParsedInResponseOrderWithTitleAndDescription() throws {
        let entries = try XCTUnwrap(FirecrawlSearch.entries(inJSON: json("""
        {"success": true, "data": {"web": [
          {"url": "https://www.binglee.com.au/products/hrfd634bw", "title": "Hisense 634L",
           "description": "PureFlat French Door", "position": 1},
          {"url": "https://www.thegoodguys.com.au/hisense-634l", "title": "Hisense 634L Fridge",
           "position": 2}
        ]}, "creditsUsed": 2}
        """)))
        XCTAssertEqual(entries.map(\.url.host), ["www.binglee.com.au", "www.thegoodguys.com.au"])
        XCTAssertEqual(entries.first?.title, "Hisense 634L")
        XCTAssertEqual(entries.first?.description, "PureFlat French Door")
        XCTAssertNil(entries.last?.description, "an absent description must not become empty text")
    }

    func testRepeatedURLsCollapseAndUnusableOnesAreDropped() throws {
        let entries = try XCTUnwrap(FirecrawlSearch.entries(inJSON: json("""
        {"success": true, "data": {"web": [
          {"url": "https://a.example.com/p", "title": "A"},
          {"url": "https://a.example.com/p", "title": "A again"},
          {"title": "no url at all"},
          {"url": "not a url", "title": "B"},
          {"url": "https://b.example.com/p", "title": "B"}
        ]}}
        """)))
        XCTAssertEqual(
            entries.map(\.url.absoluteString),
            ["https://a.example.com/p", "https://b.example.com/p"])
    }

    /// A search that found nothing is an ANSWER, and must not read as a failure:
    /// the chain resets the cooldown on it and stops paying for a retry.
    func testSuccessfulSearchWithNoWebResultsParsesToAnEmptyList() {
        XCTAssertEqual(
            FirecrawlSearch.entries(inJSON: json(#"{"success": true, "data": {}}"#))?.count, 0)
        XCTAssertEqual(
            FirecrawlSearch.entries(inJSON: json(#"{"success": true, "data": {"web": []}}"#))?
                .count, 0)
    }

    // MARK: - The bodies that are not answers

    func testFailureReportedInTheBodyIsNotAnEmptySearch() {
        XCTAssertNil(FirecrawlSearch.entries(
            inJSON: json(#"{"success": false, "error": "Rate limit exceeded"}"#)))
    }

    func testMalformedAndUnexpectedBodiesAnswerNil() {
        XCTAssertNil(FirecrawlSearch.entries(inJSON: json("{not json at all")))
        XCTAssertNil(FirecrawlSearch.entries(inJSON: json("[]")))
        XCTAssertNil(FirecrawlSearch.entries(inJSON: json(#"{"success": true}"#)))
        XCTAssertNil(FirecrawlSearch.entries(inJSON: Data()))
    }

    // MARK: - Status → outcome

    func testTwoHundredWithResultsIsAServedSearch() {
        let outcome = FirecrawlSearch.outcome(
            statusCode: 200, retryAfterHeader: nil,
            body: json(#"{"success": true, "data": {"web": [{"url": "https://a.example.com/p"}]}}"#))
        guard case let .results(entries) = outcome else { return XCTFail("got \(outcome)") }
        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(entries.first?.title)
    }

    func testTwoHundredCarryingAFailureBodyIsUnavailableRatherThanEmpty() {
        XCTAssertEqual(
            FirecrawlSearch.outcome(
                statusCode: 200, retryAfterHeader: nil,
                body: json(#"{"success": false, "error": "Rate limit exceeded"}"#)),
            .unavailable)
    }

    /// 402 (out of credits), 408 and 5xx differ in whether a RETRY would help,
    /// and none of them tells us anything about the IP's budget — so all of them
    /// are the same "fall back to DuckDuckGo this run".
    func testNonRateLimitFailureStatusesAreAllUnavailable() {
        for status in [400, 402, 403, 408, 500, 502, 503] {
            XCTAssertEqual(
                FirecrawlSearch.outcome(statusCode: status, retryAfterHeader: nil, body: Data()),
                .unavailable, "status \(status)")
        }
    }

    func testRateLimitStatusIsRateLimitedRegardlessOfBody() {
        XCTAssertEqual(
            FirecrawlSearch.outcome(
                statusCode: 429, retryAfterHeader: nil,
                body: json(#"{"success": false, "error": "Rate limit exceeded"}"#)),
            .rateLimited(retryAfter: nil))
    }

    func testRetryAfterInSecondsIsCarriedIntoTheOutcome() {
        XCTAssertEqual(
            FirecrawlSearch.outcome(statusCode: 429, retryAfterHeader: " 45 ", body: nil),
            .rateLimited(retryAfter: 45))
    }

    func testRetryAfterAsAnHTTPDateBecomesTheSecondsUntilThen() throws {
        let now = Date(timeIntervalSince1970: 1_756_000_000)
        let outcome = FirecrawlSearch.outcome(
            statusCode: 429, retryAfterHeader: "Sun, 24 Aug 2025 01:52:00 GMT", body: nil, now: now)
        guard case let .rateLimited(retryAfter) = outcome else { return XCTFail("got \(outcome)") }
        XCTAssertEqual(try XCTUnwrap(retryAfter), 320, accuracy: 1)
    }

    /// An unusable header must leave the cooldown free to escalate on its own
    /// rather than being pinned to a bogus wait.
    func testUnusableRetryAfterValuesAnswerNoWait() {
        for header in ["", "   ", "soon", "0", "-30", "Mon, 26 Aug 1990 00:00:00 GMT"] {
            XCTAssertEqual(
                FirecrawlSearch.outcome(statusCode: 429, retryAfterHeader: header, body: nil),
                .rateLimited(retryAfter: nil), "header \(header.debugDescription)")
        }
    }

    // MARK: - The request

    func testRequestBodyAsksForOneWebPageOfResultsUnderAServerDeadline() throws {
        let body = try XCTUnwrap(
            FirecrawlSearch.requestBody(forQuery: "  hisense 634L  ", location: "Australia"))
        let payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(payload["query"] as? String, "hisense 634L")
        XCTAssertEqual(payload["limit"] as? Int, FirecrawlSearch.resultLimit)
        XCTAssertEqual(payload["location"] as? String, "Australia")
        XCTAssertEqual(payload["sources"] as? [String], ["web"])
        XCTAssertEqual(
            payload["timeout"] as? Int, FirecrawlSearch.serverTimeoutMilliseconds,
            "the server deadline must stay under the transport one")
        XCTAssertLessThan(
            TimeInterval(FirecrawlSearch.serverTimeoutMilliseconds) / 1000,
            FirecrawlSearch.requestTimeout)
    }

    func testNoLocationIsOmittedRatherThanSentEmpty() throws {
        let body = try XCTUnwrap(FirecrawlSearch.requestBody(forQuery: "widget", location: nil))
        let payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(payload["location"])
    }

    func testAnEmptyQueryIsNotSentAtAll() async {
        XCTAssertNil(FirecrawlSearch.requestBody(forQuery: "   ", location: nil))
        LiveNetworkPolicy.resetRecordedRefusals()
        let outcome = await FirecrawlSearch.results(forQuery: "  ")
        XCTAssertEqual(outcome, .unavailable)
        XCTAssertTrue(
            LiveNetworkPolicy.recordedRefusals.isEmpty,
            "an empty query must be refused before the policy is even consulted")
        LiveNetworkPolicy.resetRecordedRefusals()
    }
}

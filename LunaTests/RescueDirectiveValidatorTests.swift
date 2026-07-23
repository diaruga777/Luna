//
//  RescueDirectiveValidatorTests.swift
//  LunaTests
//

import XCTest
import LunaModels
@testable import LunaURLRescue

final class RescueDirectiveValidatorTests: XCTestCase {
    private let validator = RescueDirectiveValidator()

    private func request(_ urlString: String = "https://www.example.com/story",
                         hint: RescueRequest.ContentHint = .article) -> RescueRequest {
        RescueRequest(url: URL(string: urlString)!, source: .manual, failureKind: .articleFailed, hint: hint)
    }

    private func validate(_ plan: RescuePlanResponse, request req: RescueRequest? = nil,
                          digest: String = "", supportsArticle: Bool = false)
        -> Result<RescueDirectiveValidator.PlanResolution, RescueDirectiveValidator.Rejection> {
        validator.validate(plan: plan, request: req ?? request(), digest: digest, supportsArticlePayload: supportsArticle)
    }

    // MARK: - Reroute host policy

    func testRerouteSameDomainAccepted() {
        let plan = RescuePlanResponse(kind: "reroute", rerouteURLString: "https://amp.example.com/story")
        guard case .success(.directive(.reroute(let r))) = validate(plan, request: request(hint: .article)) else {
            return XCTFail("expected reroute")
        }
        XCTAssertEqual(r.url.host, "amp.example.com")
    }

    func testRerouteCrossDomainRejected() {
        let plan = RescuePlanResponse(kind: "reroute", rerouteURLString: "https://evil.attacker.com/story")
        guard case .failure(.rerouteHostNotAllowed) = validate(plan) else { return XCTFail("expected reject") }
    }

    func testRerouteAllowlistedMirrorAccepted() {
        let plan = RescuePlanResponse(kind: "reroute", rerouteURLString: "https://web.archive.org/web/2/https://x")
        guard case .success(.directive(.reroute)) = validate(plan) else { return XCTFail("expected accept") }
    }

    func testRerouteCoUkRegistrableDomain() {
        let req = request("https://www.bbc.co.uk/news/story", hint: .article)
        let plan = RescuePlanResponse(kind: "reroute", rerouteURLString: "https://amp.bbc.co.uk/news/story")
        guard case .success(.directive(.reroute)) = validate(plan, request: req) else {
            return XCTFail("co.uk subdomain should match")
        }
    }

    func testRerouteHttpRejected() {
        let plan = RescuePlanResponse(kind: "reroute", rerouteURLString: "http://www.example.com/other")
        guard case .failure(.badRerouteURL) = validate(plan) else { return XCTFail("http must reject") }
    }

    func testRerouteEqualToOriginalRejected() {
        let plan = RescuePlanResponse(kind: "reroute", rerouteURLString: "https://www.example.com/story")
        guard case .failure(.rerouteEqualsOriginal) = validate(plan) else { return XCTFail("no-op reroute") }
    }

    // MARK: - Headers

    func testHeaderTokenMapAndDrops() {
        let plan = RescuePlanResponse(
            kind: "reroute", rerouteURLString: "https://m.example.com/story",
            userAgentToken: "googlebot", refererString: "https://www.google.com/",
            acceptLanguage: "en-US,en;q=0.9", xForwardedFor: "66.249.66.1")
        guard case .success(.directive(.reroute(let r))) = validate(plan) else { return XCTFail() }
        XCTAssertTrue(r.headers.userAgent?.contains("Googlebot") == true)
        XCTAssertEqual(r.headers.referer?.absoluteString, "https://www.google.com/")
        XCTAssertEqual(r.headers.acceptLanguage, "en-US,en;q=0.9")
        XCTAssertEqual(r.headers.xForwardedFor, "66.249.66.1")
    }

    func testHeaderUnknownUATokenDropped() {
        let plan = RescuePlanResponse(kind: "reroute", rerouteURLString: "https://m.example.com/s",
                                      userAgentToken: "curl/8.0")
        guard case .success(.directive(.reroute(let r))) = validate(plan) else { return XCTFail() }
        XCTAssertNil(r.headers.userAgent)
    }

    func testHeaderInvalidIPv4Dropped() {
        let plan = RescuePlanResponse(kind: "reroute", rerouteURLString: "https://m.example.com/s",
                                      xForwardedFor: "999.1.1.1")
        guard case .success(.directive(.reroute(let r))) = validate(plan) else { return XCTFail() }
        XCTAssertNil(r.headers.xForwardedFor)
    }

    func testIPv4Validation() {
        XCTAssertTrue(RescueDirectiveValidator.isIPv4("192.168.0.1"))
        XCTAssertFalse(RescueDirectiveValidator.isIPv4("192.168.0"))
        XCTAssertFalse(RescueDirectiveValidator.isIPv4("192.168.0.256"))
        XCTAssertFalse(RescueDirectiveValidator.isIPv4("192.168.00.1"))
    }

    // MARK: - WebJS

    func testWebJSSizeCap() {
        let big = String(repeating: "a", count: RescueDirectiveValidator.maxJavaScriptBytes + 1)
        let plan = RescuePlanResponse(kind: "webjs", javascript: big, scriptResultKind: "html")
        guard case .failure(.badJavaScript) = validate(plan) else { return XCTFail("oversize JS must reject") }
    }

    func testWebJSUsesRerouteURLWhenSameDomain() {
        let plan = RescuePlanResponse(kind: "webjs", rerouteURLString: "https://embed.example.com/e",
                                      javascript: "return document.body.innerHTML;", scriptResultKind: "html")
        guard case .success(.directive(.webJS(let s))) = validate(plan) else { return XCTFail() }
        XCTAssertEqual(s.pageURL.host, "embed.example.com")
        XCTAssertEqual(s.resultKind, .html)
    }

    // MARK: - Product

    func testProductVerbatimPriceAccepted() {
        let plan = RescuePlanResponse(kind: "product", productName: "Widget",
                                      productPriceAmount: "129.99", productCurrency: "usd")
        let result = validate(plan, request: request(hint: .product), digest: "price is 129.99 today")
        guard case .success(.directive(.productPayload(let info))) = result else { return XCTFail("expected product") }
        XCTAssertEqual(info.priceCurrency, "USD")
        XCTAssertEqual(info.priceAmount, Decimal(string: "129.99"))
    }

    func testProductPriceNotInDigestRejected() {
        let plan = RescuePlanResponse(kind: "product", productName: "Widget",
                                      productPriceAmount: "42.00", productCurrency: "USD")
        let result = validate(plan, request: request(hint: .product), digest: "nothing priced here")
        guard case .failure(.priceNotEvidenced) = result else { return XCTFail("hallucinated price must reject") }
    }

    func testProductCommaDecimalVariantAccepted() {
        let plan = RescuePlanResponse(kind: "product", productName: "Widget",
                                      productPriceAmount: "19.95", productCurrency: "EUR")
        let result = validate(plan, request: request(hint: .product), digest: "Preis: 19,95 €")
        guard case .success(.directive(.productPayload)) = result else { return XCTFail("comma variant") }
    }

    func testProductBadCurrencyRejected() {
        let plan = RescuePlanResponse(kind: "product", productName: "Widget",
                                      productPriceAmount: "10.00", productCurrency: "dollars")
        let result = validate(plan, request: request(hint: .product), digest: "10.00")
        guard case .failure(.badCurrency) = result else { return XCTFail() }
    }

    // MARK: - Media URL

    func testMediaURLByExtensionAccepted() {
        let plan = RescuePlanResponse(kind: "media_url", mediaURLString: "https://cdn.somewhere.net/v/clip.mp4")
        let result = validate(plan, request: request(hint: .media), digest: "")
        guard case .success(.directive(.mediaURL(let u))) = result else { return XCTFail() }
        XCTAssertEqual(u.pathExtension, "mp4")
    }

    func testMediaURLNoExtensionNeedsEvidence() {
        let unproven = RescuePlanResponse(kind: "media_url", mediaURLString: "https://cdn.net/stream/abc")
        guard case .failure(.badMediaURL) = validate(unproven, request: request(hint: .media), digest: "") else {
            return XCTFail("unevidenced non-extension URL must reject")
        }
        let proven = RescuePlanResponse(kind: "media_url", mediaURLString: "https://cdn.net/stream/abc")
        guard case .success(.directive(.mediaURL)) = validate(proven, request: request(hint: .media),
                                                               digest: "src: https://cdn.net/stream/abc") else {
            return XCTFail("verbatim-evidenced URL should pass")
        }
    }

    // MARK: - Kind legality

    func testOnDeviceArticleKindRejectedButSalvagedToReroute() {
        let plan = RescuePlanResponse(kind: "article", rerouteURLString: "https://amp.example.com/story")
        // supportsArticle=false → salvage to the reroute it also carries.
        guard case .success(.directive(.reroute)) = validate(plan, request: request(hint: .article), supportsArticle: false) else {
            return XCTFail("should salvage to reroute")
        }
    }

    func testOnDeviceArticleKindNoSalvageRejected() {
        let plan = RescuePlanResponse(kind: "article")
        guard case .failure(.articleNotAllowedOnDevice) = validate(plan, request: request(hint: .article), supportsArticle: false) else {
            return XCTFail("no salvage fields → reject")
        }
    }

    func testArticleKindOnPCCNeedsPayload() {
        let plan = RescuePlanResponse(kind: "article")
        guard case .success(.needsArticlePayload) = validate(plan, request: request(hint: .article), supportsArticle: true) else {
            return XCTFail("PCC article should request payload")
        }
    }

    func testGiveUpRejected() {
        guard case .failure(.giveUp) = validate(RescuePlanResponse(kind: "give_up")) else { return XCTFail() }
    }

    // MARK: - Article payload validation

    func testArticlePayloadEvidencedAccepted() {
        // Three blocks, each ≥200 chars (clears the 600-char minimum) and each
        // beginning with a distinct 40+ char phrase that appears in the digest.
        let filler = String(repeating: "and the story continued at length ", count: 6)
        let p1 = "The quick brown fox jumped over the lazy dog in the meadow " + filler
        let p2 = "A second paragraph about the harvest festival in autumn " + filler
        let p3 = "A third paragraph describing the long winter that followed " + filler
        let digest = [p1, p2, p3].joined(separator: " ")
        let response = RescueArticleResponse(title: "T", blocks: [
            .init(kind: "paragraph", text: p1),
            .init(kind: "paragraph", text: p2),
            .init(kind: "paragraph", text: p3),
        ])
        guard case .success(.articlePayload(let content)) = validator.validateArticlePayload(response, digest: digest) else {
            return XCTFail("evidenced article should pass")
        }
        XCTAssertEqual(content.blocks.count, 3)
    }

    func testArticlePayloadHallucinatedRejected() {
        // Long enough to clear the length gate, but nothing appears in the digest.
        let filler = String(repeating: "with fabricated details continuing on ", count: 6)
        let response = RescueArticleResponse(title: "T", blocks: [
            .init(kind: "paragraph", text: "Totally fabricated sentence never in the source " + filler),
            .init(kind: "paragraph", text: "Another invented paragraph with no grounding here " + filler),
            .init(kind: "paragraph", text: "A third made-up block clearing the count but not evidence " + filler),
        ])
        guard case .failure(.articleNotEvidenced) = validator.validateArticlePayload(
            response, digest: "completely unrelated digest text about weather and traffic and nothing else at all") else {
            return XCTFail("hallucinated article must reject")
        }
    }

    func testArticlePayloadTooShortRejected() {
        let response = RescueArticleResponse(title: "T", blocks: [.init(kind: "paragraph", text: "short")])
        guard case .failure(.articleTooShort) = validator.validateArticlePayload(response, digest: "short") else {
            return XCTFail()
        }
    }
}

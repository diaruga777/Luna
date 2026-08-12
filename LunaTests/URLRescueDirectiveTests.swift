//
//  URLRescueDirectiveTests.swift
//  LunaTests
//

import XCTest
import LunaModels
@testable import LunaURLRescue

final class URLRescueDirectiveTests: XCTestCase {
    private let validator = RescueDirectiveValidator()

    private func request(_ urlString: String = "https://www.example.com/story",
                         hint: RescueHint? = .article) -> RescueRequest {
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

    // MARK: - The widened action space

    func testOpenInBrowserIsATerminalDirective() {
        guard case .success(.directive(.openInBrowser)) = validate(RescuePlanResponse(kind: "open_in_browser"))
        else { return XCTFail("open_in_browser must validate as its own directive") }
    }

    func testSearchCarriesTheQueryThrough() {
        let plan = RescuePlanResponse(kind: "search", searchQuery: "  the missing article  ")
        guard case .success(.needsSearch(let query)) = validate(plan) else {
            return XCTFail("expected a search resolution")
        }
        XCTAssertEqual(query, "the missing article")
    }

    func testAnEmptySearchQueryIsRejected() {
        guard case .failure(.emptySearchQuery) = validate(RescuePlanResponse(kind: "search")) else {
            return XCTFail("a search with no query is nothing to run")
        }
    }

    /// The inspect round is a free fetch, so its URL is held to exactly the
    /// reroute host policy — a free fetch of any host the model names would be an
    /// exfiltration channel.
    func testInspectURLObeysTheRerouteHostPolicy() {
        guard case .success(.needsInspection(let url)) = validate(
            RescuePlanResponse(kind: "inspect_url", rerouteURLString: "https://amp.example.com/index"))
        else { return XCTFail("same-domain inspect should be allowed") }
        XCTAssertEqual(url.host, "amp.example.com")

        guard case .failure(.badInspectURL) = validate(
            RescuePlanResponse(kind: "inspect_url", rerouteURLString: "https://attacker.test/collect"))
        else { return XCTFail("off-domain inspect must be rejected") }
    }

    /// The round cap is the validator's to enforce on the engine's behalf: on a
    /// follow-up round the intermediate kinds are simply not available, so a
    /// loop is structurally impossible rather than prompt-discouraged.
    func testIntermediateKindsAreRefusedOnAFollowUpRound() {
        let search = validator.validate(
            plan: RescuePlanResponse(kind: "search", searchQuery: "again"),
            request: request(), digest: "", supportsArticlePayload: false,
            allowsIntermediate: false)
        guard case .failure(.searchNotAvailable) = search else { return XCTFail("nested search") }

        let inspect = validator.validate(
            plan: RescuePlanResponse(kind: "inspect_url", rerouteURLString: "https://amp.example.com/x"),
            request: request(), digest: "", supportsArticlePayload: false,
            allowsIntermediate: false)
        guard case .failure(.inspectNotAvailable) = inspect else { return XCTFail("nested inspect") }
    }

    /// The search leg's ONLY relaxation: a URL the engine put in front of the
    /// model. Everything else about the host policy stands.
    func testCandidateListRelaxesTheHostRuleForItsOwnURLsOnly() {
        let offDomain = "https://syndicated.test/story"
        let plan = RescuePlanResponse(kind: "reroute", rerouteURLString: offDomain)

        guard case .failure(.rerouteHostNotAllowed) = validate(plan) else {
            return XCTFail("off-domain reroute is refused without a candidate list")
        }
        guard case .success(.directive(.reroute(let reroute))) = validator.validate(
            plan: plan, request: request(), digest: "", supportsArticlePayload: false,
            candidates: [offDomain], allowsIntermediate: false)
        else { return XCTFail("a listed candidate must be accepted") }
        XCTAssertEqual(reroute.url.absoluteString, offDomain)

        guard case .failure(.rerouteHostNotAllowed) = validator.validate(
            plan: RescuePlanResponse(kind: "reroute", rerouteURLString: "https://attacker.test/x"),
            request: request(), digest: "", supportsArticlePayload: false,
            candidates: [offDomain], allowsIntermediate: false)
        else { return XCTFail("a candidate list must not whitelist the whole web") }
    }

    /// Widening the action space must not relax any EVIDENCE rule: a product
    /// price still has to appear verbatim in the digest, candidate list or not.
    func testTheCandidateListDoesNotRelaxPayloadEvidence() {
        let plan = RescuePlanResponse(
            kind: "product", productName: "Widget",
            productPriceAmount: "129.99", productCurrency: "USD")
        guard case .failure(.priceNotEvidenced) = validator.validate(
            plan: plan, request: request(hint: .product), digest: "no price here",
            supportsArticlePayload: false, candidates: ["https://syndicated.test/story"])
        else { return XCTFail("an unevidenced price stays rejected") }
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

    // MARK: - Auto (model-chosen) content type

    /// a nil hint is what the failed-save card sends: the model decides the content
    /// type, so a product payload must be ACCEPTED rather than downgraded, even
    /// though the failing pass was the article branch.
    func testAutoHintAcceptsAProductPayload() {
        let plan = RescuePlanResponse(
            kind: "product", productName: "Widget",
            productPriceAmount: "129.99", productCurrency: "USD")
        guard case .success(.directive(.productPayload(let info))) = validate(
            plan, request: request(hint: nil), digest: "price 129.99 USD") else {
            return XCTFail("auto must let the model choose product")
        }
        XCTAssertEqual(info.name, "Widget")
    }

    func testAutoHintAcceptsAMediaPayload() {
        let plan = RescuePlanResponse(kind: "media_url", mediaURLString: "https://cdn.example.com/v.mp4")
        guard case .success(.directive(.mediaURL(let url))) = validate(
            plan, request: request(hint: nil)) else {
            return XCTFail("auto must let the model choose media")
        }
        XCTAssertEqual(url.lastPathComponent, "v.mp4")
    }

    func testAutoHintAcceptsAnArticlePayloadOnPCC() {
        let plan = RescuePlanResponse(kind: "article")
        guard case .success(.needsArticlePayload) = validate(
            plan, request: request(hint: nil), supportsArticle: true) else {
            return XCTFail("auto must let the model choose article")
        }
    }

    /// A CONCRETE hint still constrains the answer — the price editor's "Ask Apple
    /// Intelligence" shouldn't come back with a video.
    func testAConcreteHintStillRejectsAForeignPayload() {
        let plan = RescuePlanResponse(kind: "media_url", mediaURLString: "https://cdn.example.com/v.mp4")
        guard case .failure(.illegalKind) = validate(plan, request: request(hint: .product)) else {
            return XCTFail("a product-hinted rescue must not accept media")
        }
    }

    /// a nil hint widens which payloads are legal; it does not weaken any evidence
    /// rule. A price the digest never mentions is still a fabrication.
    func testAutoHintDoesNotRelaxTheEvidenceRules() {
        let plan = RescuePlanResponse(
            kind: "product", productName: "Widget",
            productPriceAmount: "8888.00", productCurrency: "USD")
        guard case .failure(.priceNotEvidenced) = validate(
            plan, request: request(hint: nil), digest: "nothing numeric here") else {
            return XCTFail("auto must still require a verbatim price")
        }
    }

    // MARK: - Prompt auto classification (model-chosen content type)

    /// Under a nil hint every payload option is on the table AND the model is told
    /// the classification is its job — without that, the options read as a menu
    /// and it picks whatever the digest mentions first.
    func testAutoInstructionsOfferEveryOptionAndAskForClassification() {
        let instructions = RescuePrompts.planInstructions(hint: nil, allowsArticlePayload: true)
        XCTAssertTrue(instructions.contains("FIRST decide what kind of content"))
        XCTAssertTrue(instructions.contains("\"article\""))
        XCTAssertTrue(instructions.contains("\"product\""))
        XCTAssertTrue(instructions.contains("\"media_url\""))
    }

    /// On-device can't reproduce a whole article, so the article option stays
    /// gated by tier even under a nil hint.
    func testAutoInstructionsStillGateArticleByTier() {
        let onDevice = RescuePrompts.planInstructions(hint: nil, allowsArticlePayload: false)
        XCTAssertFalse(onDevice.contains("you will be asked for the full text next"))
        XCTAssertTrue(onDevice.contains("\"product\""), "the other options remain")
    }

    /// A concrete hint keeps the old single-option form.
    func testAConcreteHintOffersOnlyItsOwnOption() {
        let product = RescuePrompts.planInstructions(hint: .product, allowsArticlePayload: true)
        XCTAssertTrue(product.contains("\"product\""))
        XCTAssertFalse(product.contains("\"media_url\""))
        XCTAssertFalse(product.contains("FIRST decide what kind of content"))
    }

    /// The prompt must not name a content type under a nil hint — that would undo
    /// the classification the instructions just asked for. What it names instead
    /// is the failure that already happened.
    func testAutoPromptStatesTheFailureRatherThanAHint() {
        let prompt = RescuePrompts.planPrompt(
            url: URL(string: "https://example.com/x")!, hint: nil,
            failureKind: .articleFailed, failureReason: nil,
            digest: "digest", evidence: nil)
        XCTAssertFalse(prompt.contains("Content hint:"))
        XCTAssertTrue(prompt.contains("What already failed:"))
        XCTAssertTrue(prompt.contains("no usable text"))
    }

    func testConcretePromptStillCarriesTheHint() {
        let prompt = RescuePrompts.planPrompt(
            url: URL(string: "https://example.com/x")!, hint: .media,
            failureKind: .mediaNoAssets, failureReason: nil,
            digest: "digest", evidence: nil)
        XCTAssertTrue(prompt.contains("Content hint: media"))
    }

    /// No hint at all means a nil hint, not "guess from the failure kind" — this is
    /// the default every automatic path and the card now take. It is a plain nil
    /// rather than a sentinel case — the engine used to carry its own `ContentHint`
    /// mirror of `RescueHint` whose `.auto` was a second spelling of nil.
    func testAnAbsentHintStaysNilAndAllowsEveryPayload() {
        let request = RescueRequest(
            url: URL(string: "https://example.com/x")!, source: .manual,
            failureKind: .productNoPrice)
        XCTAssertNil(request.hint)
        for kind in RescueHint.allCases {
            XCTAssertTrue(request.allows(kind), "no hint must allow \(kind)")
        }
    }

    /// A concrete hint allows only its own payload.
    func testAConcreteHintAllowsOnlyItsOwnPayload() {
        let product = RescueRequest(
            url: URL(string: "https://example.com/x")!, source: .manual,
            failureKind: .productNoPrice, hint: .product)
        XCTAssertTrue(product.allows(.product))
        XCTAssertFalse(product.allows(.article))
        XCTAssertFalse(product.allows(.media))
    }

    /// Learned rules are keyed per (host, hint), so a model-classified rescue must
    /// not replay a rule learned under a pinned kind.
    func testHintKeyDistinguishesNoHintFromAPinnedKind() {
        let base = URL(string: "https://example.com/x")!
        let auto = RescueRequest(url: base, source: .manual, failureKind: .articleFailed)
        let pinned = RescueRequest(url: base, source: .manual, failureKind: .articleFailed, hint: .article)
        XCTAssertEqual(auto.hintKey, "auto")
        XCTAssertEqual(pinned.hintKey, "article")
    }
}

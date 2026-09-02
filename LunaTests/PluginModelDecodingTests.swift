import LunaModels
import XCTest

/// What a plugin returns crosses an untrusted boundary, so these assert what the
/// decoder ACCEPTS and, for each cap, what it refuses and with which error.
///
/// Relative URLs are deliberately not resolved here — `PluginIngestStage`
/// resolves them against the save's URL — so a relative asset URL is accepted
/// as written.
final class PluginModelDecodingTests: XCTestCase {

    private func decode(_ json: String) throws -> PluginModel {
        try JSONDecoder().decode(PluginModel.self, from: Data(json.utf8))
    }

    private func error(_ json: String, file: StaticString = #filePath, line: UInt = #line)
        -> PluginModelValidationError? {
        do {
            _ = try decode(json)
            XCTFail("expected the decode to fail", file: file, line: line)
            return nil
        } catch let error as PluginModelValidationError {
            return error
        } catch {
            XCTFail("expected a validation error, got \(error)", file: file, line: line)
            return nil
        }
    }

    // MARK: - Accepted

    func testMediaModelDecodesAssetsHeadersAndExpiry() throws {
        let model = try decode("""
            {"kind":"media","title":"Clip","author":"someone","platform":"instagram",
             "itemId":"ABC123","thumbnailURL":"https://cdn.example/t.jpg","expiresAt":1700000000,
             "assets":[{"url":"https://cdn.example/v.mp4","type":"video","quality":"1080p",
                        "estimatedBytes":4096,"headers":{"Referer":"https://example.com"},
                        "audioURL":"https://cdn.example/a.m4a","timeRange":{"start":2,"end":9}}]}
            """)
        guard case .media(let media) = model else { return XCTFail("expected a media Model") }
        XCTAssertEqual(media.itemID, "ABC123")
        XCTAssertEqual(media.expiresAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(media.assets.count, 1)
        let asset = try XCTUnwrap(media.assets.first)
        XCTAssertEqual(asset.type, .video)
        XCTAssertEqual(asset.headers["Referer"], "https://example.com")
        XCTAssertEqual(asset.audioURL?.absoluteString, "https://cdn.example/a.m4a")
        XCTAssertEqual(asset.timeRange?.end, 9)
        XCTAssertEqual(asset.estimatedBytes, 4096)
    }

    /// The stage resolves a relative asset URL later, so the decoder must not
    /// refuse one for having no scheme.
    func testRelativeAssetURLIsKeptForTheStageToResolve() throws {
        let model = try decode("""
            {"kind":"media","assets":[{"url":"/media/clip.mp4","type":"video"}]}
            """)
        guard case .media(let media) = model else { return XCTFail("expected a media Model") }
        XCTAssertEqual(media.assets.first?.url.absoluteString, "/media/clip.mp4")
        XCTAssertNil(media.assets.first?.url.scheme)
    }

    func testArticleModelDecodesBodyAndDocument() throws {
        let model = try decode("""
            {"kind":"article","title":"A piece","html":"<p>body</p>","excerpt":"short",
             "baseURL":"https://example.com/a","language":"en","publishedAt":"2026-09-02T00:00:00Z",
             "document":{"url":"https://example.com/a.pdf","type":"pdf",
                         "headers":{"user-agent":"Luna"}}}
            """)
        guard case .article(let article) = model else { return XCTFail("expected an article Model") }
        XCTAssertEqual(article.title, "A piece")
        XCTAssertEqual(article.html, "<p>body</p>")
        XCTAssertEqual(article.document?.type, .pdf)
        XCTAssertEqual(article.document?.headers["user-agent"], "Luna")
    }

    func testProductModelKeepsTheExactDecimalAndItsSellers() throws {
        let model = try decode("""
            {"kind":"product","name":"Kettle","price":{"amount":"129.95","currency":"AUD"},
             "brand":"Acme","productId":"K-1","identifiers":{"gtin":"9312345678907","sku":"S1"},
             "sellers":[{"url":"https://shop.example/k","name":"Shop",
                         "price":{"amount":"119.00","currency":"AUD"}}]}
            """)
        guard case .product(let product) = model else { return XCTFail("expected a product Model") }
        XCTAssertEqual(product.price.amount, Decimal(string: "129.95"))
        XCTAssertEqual(product.identifiers?.gtin, "9312345678907")
        XCTAssertEqual(product.sellers.count, 1)
        XCTAssertEqual(product.sellers.first?.price?.amount, Decimal(string: "119.00"))
    }

    // MARK: - Refused

    func testUnknownKindIsRefusedByName() {
        XCTAssertEqual(
            error(#"{"kind":"recipe"}"#), .unknownKind("recipe"))
    }

    func testAbsentKindIsAMissingField() {
        XCTAssertEqual(error("{}"), .missingField("kind"))
    }

    func testMissingRequiredFieldNamesTheField() {
        XCTAssertEqual(
            error(#"{"kind":"article","title":"t"}"#), .missingField("html"))
        XCTAssertEqual(
            error(#"{"kind":"product","name":"n"}"#), .missingField("price"))
        XCTAssertEqual(
            error(#"{"kind":"media","assets":[{"type":"video"}]}"#),
            .missingField("assets[].url"))
    }

    func testNonHTTPURLSchemeIsRefused() {
        XCTAssertEqual(
            error("""
                {"kind":"media","assets":[{"url":"file:///etc/passwd","type":"video"}]}
                """),
            .invalidURL(field: "assets[].url", value: "file:///etc/passwd"))
    }

    func testStringOverItsCapIsRefusedWithTheLimit() {
        let long = String(repeating: "a", count: PluginModelCaps.title + 1)
        XCTAssertEqual(
            error(#"{"kind":"article","title":"\#(long)","html":"<p>x</p>"}"#),
            .stringTooLong(field: "title", limit: PluginModelCaps.title))
    }

    func testAssetCountMustBeOneToFifty() {
        XCTAssertEqual(
            error(#"{"kind":"media","assets":[]}"#), .assetCountOutOfRange(0))

        let one = #"{"url":"https://cdn.example/v.mp4","type":"video"}"#
        let fiftyOne = Array(repeating: one, count: 51).joined(separator: ",")
        XCTAssertEqual(
            error(#"{"kind":"media","assets":[\#(fiftyOne)]}"#),
            .assetCountOutOfRange(51))
    }

    func testMoreThanTwentySellersIsRefused() {
        let seller = #"{"url":"https://shop.example/k"}"#
        let sellers = Array(repeating: seller, count: 21).joined(separator: ",")
        XCTAssertEqual(
            error("""
                {"kind":"product","name":"Kettle","price":{"amount":"1.00","currency":"AUD"},
                 "sellers":[\(sellers)]}
                """),
            .tooManySellers(21))
    }

    func testHTMLOverFourMegabytesIsRefused() {
        let oversized = String(repeating: "x", count: PluginModelCaps.html + 1)
        XCTAssertEqual(
            error(#"{"kind":"article","title":"t","html":"\#(oversized)"}"#),
            .htmlTooLarge(PluginModelCaps.html + 1))
    }

    func testHeaderOutsideTheAllowlistIsRefused() {
        XCTAssertEqual(
            error("""
                {"kind":"media","assets":[{"url":"https://cdn.example/v.mp4","type":"video",
                 "headers":{"Authorization":"Bearer x"}}]}
                """),
            .disallowedHeader("Authorization"))
    }

    func testHeaderValueOverItsCapIsRefused() {
        let long = String(repeating: "c", count: PluginModelCaps.headerValue + 1)
        XCTAssertEqual(
            error("""
                {"kind":"media","assets":[{"url":"https://cdn.example/v.mp4","type":"video",
                 "headers":{"cookie":"\(long)"}}]}
                """),
            .headerValueTooLong("cookie"))
    }

    func testANegativeEstimatedByteCountIsRefused() {
        XCTAssertEqual(
            error("""
                {"kind":"media","assets":[{"url":"https://cdn.example/v.mp4","type":"video",
                 "estimatedBytes":-1}]}
                """),
            .negativeByteCount(field: "assets[].estimatedBytes"))
    }

    /// The allowlist is compared case-insensitively, so a plugin's own casing
    /// never decides whether a header is allowed.
    func testAllowlistedHeaderPassesInAnyCasing() throws {
        let model = try decode("""
            {"kind":"media","assets":[{"url":"https://cdn.example/v.mp4","type":"video",
             "headers":{"ACCEPT-LANGUAGE":"en-AU","cookie":"a=b"}}]}
            """)
        guard case .media(let media) = model else { return XCTFail("expected a media Model") }
        XCTAssertEqual(media.assets.first?.headers["ACCEPT-LANGUAGE"], "en-AU")
    }

    func testPriceAmountMustParseAsADecimal() {
        XCTAssertEqual(
            error("""
                {"kind":"product","name":"Kettle","price":{"amount":"lots","currency":"AUD"}}
                """),
            .invalidPrice("lots"))
    }

    /// A float amount would already have lost digits by the time Swift saw it,
    /// so the contract is a string and anything else is a decode failure rather
    /// than a silently rounded price.
    func testFloatPriceAmountIsNotAccepted() {
        XCTAssertThrowsError(try decode("""
            {"kind":"product","name":"Kettle","price":{"amount":129.95,"currency":"AUD"}}
            """))
    }

    // MARK: - MediaAsset

    /// `requestHeaders` is additive: an asset persisted before it existed must
    /// still decode, since `ResolvedMediaStores` keeps this JSON in the App
    /// Group across builds.
    func testMediaAssetWithoutRequestHeadersDecodesToNone() throws {
        let asset = try JSONDecoder().decode(MediaAsset.self, from: Data("""
            {"url":"https://cdn.example/v.mp4","kind":"video"}
            """.utf8))
        XCTAssertEqual(asset.requestHeaders, [:])
    }

    func testMediaAssetRoundTripsItsRequestHeaders() throws {
        let asset = MediaAsset(
            url: URL(string: "https://cdn.example/v.mp4")!, kind: .video,
            requestHeaders: ["Referer": "https://example.com"])
        let decoded = try JSONDecoder().decode(
            MediaAsset.self, from: JSONEncoder().encode(asset))
        XCTAssertEqual(decoded.requestHeaders, ["Referer": "https://example.com"])
        XCTAssertEqual(decoded, asset)
    }
}

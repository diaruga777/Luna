//
//  SellerFanOutRealWorldTests.swift
//  LunaTests
//

import LunaModels
import LunaPriceCompare
import LunaPriceMetadata
import XCTest

/// The fan-out was unit-green and returned ZERO results against the live web.
/// Every test here is pinned to a captured page from the run that proved it, so
/// the fixes cannot regress into "passes the tests, finds nothing".
///
/// Fixtures are trimmed real captures (`LunaTests/Fixtures/Products/`) — the
/// link regions and the detail/buy-box regions, nothing else. `LiveNetworkPolicy`
/// refuses live traffic under XCTest by design, so a fixture is the only honest
/// way to test this.
final class RealWorldSearchLinkExtractionTests: XCTestCase {

    private func links(_ fixture: String, base: String, limit: Int = 3, gtin: String? = nil)
        -> [URL] {
        LeanProductPageParser.productLinks(
            inSearchHTML: BypassFixtures.html("Products/\(fixture)"),
            baseURL: URL(string: base)!, limit: limit,
            preferring: GTINForms.variants(of: gtin))
    }

    /// eBay writes its search hrefs UNQUOTED (`href=https://…`), so an
    /// attribute regex expecting quotes found 0 of 99 product URLs.
    func testEbayUnquotedHrefsAreFound() {
        let found = links("ebay-search.html", base: "https://www.ebay.com/sch/i.html?_nkw=x")
        XCTAssertEqual(found.count, 3)
        for url in found {
            XCTAssertEqual(url.host, "www.ebay.com")
            XCTAssertTrue(url.path.hasPrefix("/itm/"), url.absoluteString)
        }
    }

    /// The same page seeds "Shop on eBay" promo cards at `/itm/123456`, which
    /// the shared `/itm/[0-9]{4,}` pattern accepts and which would otherwise
    /// consume every link slot the candidate has.
    func testEbayPromoPlaceholderListingsAreRefused() {
        let found = links(
            "ebay-search.html", base: "https://www.ebay.com/sch/i.html?_nkw=x", limit: 10)
        XCTAssertFalse(found.isEmpty)
        XCTAssertFalse(
            found.contains { $0.path == "/itm/123456" },
            "the placeholder promo card is not a product")
        for url in found {
            XCTAssertGreaterThanOrEqual(
                url.lastPathComponent.count, 9, "a real eBay listing id is 12 digits")
        }
    }

    /// Barnes & Noble keeps every product under `/w/`, which no shared pattern
    /// matches. A generic extractor would find only a Nook e-reader SAMPLE on
    /// a different subdomain.
    func testBarnesAndNobleProductLinksAreFoundAndTheNookSampleIsNot() {
        let found = links(
            "barnesandnoble-search.html", base: "https://www.barnesandnoble.com/s/x",
            gtin: "9780735211292")
        XCTAssertFalse(found.isEmpty)
        for url in found {
            XCTAssertEqual(url.host, "www.barnesandnoble.com")
            XCTAssertTrue(url.path.hasPrefix("/w/"), url.absoluteString)
        }
        XCTAssertFalse(found.contains { $0.absoluteString.contains("nook.") })
        XCTAssertFalse(found.contains { $0.absoluteString.contains("/sample") })
    }

    /// When the searched identifier is IN a link, that link is the retailer
    /// telling us which of its fifty results is the right one.
    func testALinkCarryingTheSearchedIdentifierRanksFirst() throws {
        let found = try XCTUnwrap(links(
            "barnesandnoble-search.html", base: "https://www.barnesandnoble.com/s/x",
            gtin: "9780735211292").first)
        XCTAssertTrue(found.absoluteString.contains("9780735211292"), found.absoluteString)
    }

    /// Target's search page is a JS shell — 123KB of bundle, zero product
    /// links. Finding none is the CORRECT answer, and what the client-rendered
    /// flag and the render fallback both exist for.
    func testTargetSearchShellYieldsNothing() {
        XCTAssertTrue(links(
            "target-search-shell.html", base: "https://www.target.com/s?searchTerm=x").isEmpty)
    }

    /// A whole-document scan picks up bundle and API URLs by the hundred; they
    /// match `/products/[^/]+` as happily as a real product does.
    func testAssetAndAPIURLsAreNotProducts() {
        let html = """
        <a href="https://gdx-api.costco.com/catalog/product/product-api/v1/products/summary">a</a>
        <a href="https://www.costco.com/_next/static/css/e9e5.css">b</a>
        <a href="https://www.costco.com/consumer-web/products/bundle.js">c</a>
        <a href="https://www.costco.com/p/widget/10024438">real</a>
        """
        let found = LeanProductPageParser.productLinks(
            inSearchHTML: html, baseURL: URL(string: "https://www.costco.com/CatalogSearch?k=x")!,
            limit: 5)
        XCTAssertEqual(found.map(\.path), ["/p/widget/10024438"])
    }

    /// Measured live on officeworks.com.au: a search for an unrelated fridge
    /// still seeded its own print-services nav links, which match the
    /// retailer's own (necessarily loose) `/p/[^/]+` accept pattern just as
    /// well as a real product does — `/print-copy/p/flyers-pcdhflcp` is a
    /// category page, not a product.
    func testOfficeworksPrintCopyNavLinksAreRefusedDespiteMatchingTheAcceptPattern() {
        let html = """
        <a href="/print-copy/p/flyers-pcdhflcp?cm_sp=all:menu-mobile:print-copy">Flyers</a>
        <a href="/shop/officeworks/p/hisense-634l-fridge-hrfd634bw">Fridge</a>
        """
        let found = LeanProductPageParser.productLinks(
            inSearchHTML: html, baseURL: URL(string: "https://www.officeworks.com.au/search?q=x")!,
            limit: 5)
        XCTAssertEqual(found.map(\.path), ["/shop/officeworks/p/hisense-634l-fridge-hrfd634bw"])
    }

    /// Product URLs live in embedded JSON at least as often as in `<a href>`,
    /// where they are written with escaped slashes.
    func testJSONEscapedURLsInScriptPayloadsAreFound() {
        let html = #"""
        <script>window.__DATA__ = {"items":[{"canonicalUrl":"https:\/\/shop.example\/products\/widget-blue"}]}</script>
        """#
        let found = LeanProductPageParser.productLinks(
            inSearchHTML: html, baseURL: URL(string: "https://shop.example/search?q=x")!, limit: 3)
        XCTAssertEqual(found.map(\.absoluteString), ["https://shop.example/products/widget-blue"])
    }

    /// A retailer's own help, cart and store-locator pages outnumber its
    /// products on a search page.
    func testRetailerFurnitureIsRefused() {
        let html = """
        <a href="/help/returns">help</a>
        <a href="/cart">cart</a>
        <a href="/store-locator/products/nearby">stores</a>
        <a href="https://careers.shop.example/products/join">careers</a>
        <a href="/products/widget-blue">product</a>
        """
        let found = LeanProductPageParser.productLinks(
            inSearchHTML: html, baseURL: URL(string: "https://shop.example/search?q=x")!, limit: 9)
        XCTAssertEqual(found.map(\.path), ["/products/widget-blue"])
    }

    /// One Amazon product appears under a dozen slugs and a `/ref=` crumb
    /// apiece; without collapsing, three link slots are three copies of one
    /// product.
    func testAmazonLinksCollapseToTheirASIN() {
        let html = """
        <a href="/Atomic-Habits-James-Clear/dp/0735211299/ref=sr_1_1?qid=123&sr=8-1">a</a>
        <a href="/gp/product/0735211299/ref=ox_sc">b</a>
        <a href="/Atomic-Habits-Audiobook/dp/B07RFSSYBH/ref=sr_1_2">c</a>
        """
        let found = LeanProductPageParser.productLinks(
            inSearchHTML: html, baseURL: URL(string: "https://www.amazon.com/s?k=x")!, limit: 5)
        XCTAssertEqual(found.map(\.absoluteString), [
            "https://www.amazon.com/dp/0735211299",
            "https://www.amazon.com/dp/B07RFSSYBH",
        ])
    }
}

// MARK: - Amazon

/// Amazon publishes no JSON-LD, no price meta and no microdata, so every
/// structured reader called its pages empty. As a SOURCE that meant a fan-out
/// with no identifiers to verify anyone against; as a CANDIDATE it meant
/// `price == nil` on the lean path. Both directions are pinned here.
final class AmazonProductDetailsTests: XCTestCase {

    private func fixture(_ name: String) -> String {
        BypassFixtures.html("Products/\(name)")
    }

    func testBookPageYieldsISBN13AsGTIN() {
        let found = AmazonProductDetails.identifiers(
            inHTML: fixture("amazon-pdp-book.html"),
            url: URL(string: "https://www.amazon.com/dp/0735211299")!)
        XCTAssertEqual(found.gtin, "9780735211292")
    }

    func testElectronicsPageYieldsBarcodeModelNumberAndBrand() {
        let found = AmazonProductDetails.identifiers(
            inHTML: fixture("amazon-pdp-electronics.html"),
            url: URL(string: "https://www.amazon.com/dp/B09XS7JWHH")!)
        XCTAssertEqual(GTINForms.digits(found.gtin), "04548736132627")
        XCTAssertEqual(found.mpn, "XM5BK")
        XCTAssertEqual(found.brand, "Sony")
        XCTAssertEqual(found.sku, "B09XS7JWHH")
    }

    func testOrdinaryASINIsPreservedAsRetailerScopedSKU() {
        let found = AmazonProductDetails.identifiers(
            inHTML: "<html><body>No details module</body></html>",
            url: URL(string: "https://www.amazon.com.au/example/dp/B0CWRSYTTK/ref=abc")!)
        XCTAssertEqual(found.sku, "B0CWRSYTTK")
        XCTAssertNil(found.gtin)
        XCTAssertNil(found.mpn)
    }

    func testPrimaryImageAndVisibleTitleComeFromAmazonImageBlock() throws {
        let html = """
        <span id="productTitle">  Sony WH-1000XM5 Headphones  </span>
        <img id="main-image" src="data:image/gif;base64,x"
             data-a-hires="https://m.media-amazon.com/images/I/61O3iMlnJIL.jpg">
        """
        XCTAssertEqual(
            AmazonProductDetails.title(inHTML: html), "Sony WH-1000XM5 Headphones")
        XCTAssertEqual(
            try XCTUnwrap(AmazonProductDetails.imageURL(inHTML: html)).absoluteString,
            "https://m.media-amazon.com/images/I/61O3iMlnJIL.jpg")
    }

    func testLargestDynamicPrimaryImageWinsOverPlaceholderSource() throws {
        let html = """
        <img id="landingImage" src="data:image/gif;base64,x"
          data-a-dynamic-image="{&quot;https://m.media-amazon.com/small.jpg&quot;:[96,96],&quot;https://m.media-amazon.com/large.jpg&quot;:[1200,1200]}">
        """
        XCTAssertEqual(
            try XCTUnwrap(AmazonProductDetails.imageURL(inHTML: html)).absoluteString,
            "https://m.media-amazon.com/large.jpg")
    }

    /// The product-overview grid tags its row `class="po-brand"`, so a naive
    /// label scan reads the brand of every such page as the string "Brand".
    func testLabelsInsideMarkupAreNotContent() {
        XCTAssertNotEqual(
            AmazonProductDetails.identifiers(
                inHTML: fixture("amazon-pdp-electronics.html"),
                url: URL(string: "https://www.amazon.com/dp/B09XS7JWHH")!).brand,
            "Brand")
    }

    /// The warranty paragraph contains the word "Manufacturer" long before the
    /// details table does. Narrowing to the detail containers is what removes it.
    func testWarrantyProseIsNotABrand() {
        let html = """
        <div>Manufacturer’s warranty can be requested from customer service.
        <a href="/gp/help">Click here</a> to make a request.</div>
        <table id="prodDetTable"><tr><th>Manufacturer</th><td>Bosch</td></tr></table>
        """
        XCTAssertEqual(
            AmazonProductDetails.identifiers(inHTML: html, url: nil).brand, "Bosch")
    }

    func testBuyBoxPriceIsReadFromTheOffscreenSpan() throws {
        let price = try XCTUnwrap(AmazonProductDetails.price(
            inHTML: fixture("amazon-pdp-book.html"), currencyHint: "USD"))
        XCTAssertGreaterThan(price.amount, 0)
        XCTAssertEqual(price.currency.count, 3)
    }

    func testLocalizedAmazonBuyBoxPriceUsesTheDecimalSeparator() throws {
        let html = """
        <div id="corePriceDisplay_desktop_feature_div">
          <span class="a-price"><span class="a-offscreen">1.299,00 €</span></span>
        </div>
        """
        let price = try XCTUnwrap(
            AmazonProductDetails.price(inHTML: html, currencyHint: "EUR"))
        XCTAssertEqual(price.amount, Decimal(1299))
        XCTAssertEqual(price.currency, "EUR")
    }

    /// The current desktop layout serves an EMPTY `a-offscreen` and splits the
    /// number across `a-price-whole` / `a-price-fraction`.
    func testSplitBuyBoxPriceIsRecomposed() throws {
        let html = """
        <span class="apex-pricetopay-value"><span class="a-offscreen"> </span>
        <span aria-hidden="true"><span class="a-price-symbol">$</span>
        <span class="a-price-whole">350<span class="a-price-decimal">.</span></span>
        <span class="a-price-fraction">97</span></span></span>
        """
        let price = try XCTUnwrap(AmazonProductDetails.price(inHTML: html, currencyHint: "USD"))
        XCTAssertEqual(price.amount, Decimal(string: "350.97"))
        XCTAssertEqual(price.currency, "USD")
    }

    /// The whole point of the fixtures: the LEAN parser (the one the Safari
    /// appex runs) prices an Amazon page and identifies it.
    func testLeanParserPricesAndIdentifiesAnAmazonPage() throws {
        let parsed = try XCTUnwrap(LeanProductPageParser.parse(
            html: fixture("amazon-pdp-electronics.html"),
            url: URL(string: "https://www.amazon.com/dp/B09XS7JWHH")!,
            currencyHint: "USD"))
        XCTAssertTrue(parsed.hasUsablePrice)
        XCTAssertEqual(parsed.identifiers.brand, "Sony")
        XCTAssertEqual(parsed.identifiers.sku, "B09XS7JWHH")
        XCTAssertNotNil(parsed.identifiers.normalizedGTIN)
    }

    func testAmazonHostRecognition() {
        XCTAssertTrue(AmazonProductDetails.isAmazonHost("www.amazon.com"))
        XCTAssertTrue(AmazonProductDetails.isAmazonHost("www.amazon.co.uk"))
        XCTAssertTrue(AmazonProductDetails.isAmazonHost("amazon.com.au"))
        XCTAssertFalse(AmazonProductDetails.isAmazonHost("amazon.scam.example"))
        XCTAssertFalse(AmazonProductDetails.isAmazonHost(nil))
    }
}

/// A GTIN is one number written four ways. Comparing the strings directly means
/// the same book fails to match itself.
final class GTINFormsTests: XCTestCase {

    func testISBN13AndISBN10AreTheSameBook() {
        XCTAssertEqual(GTINForms.isbn10(fromISBN13: "9780735211292"), "0735211299")
        XCTAssertEqual(GTINForms.isbn13(fromISBN10: "0735211299"), "9780735211292")
        XCTAssertTrue(GTINForms.sameProduct("0735211299", as: "9780735211292"))
    }

    func testHyphenatedAndPaddedFormsNormalize() {
        XCTAssertEqual(GTINForms.digits("978-0-7352-1129-2"), "9780735211292")
        XCTAssertTrue(GTINForms.variants(of: "9780735211292").contains("09780735211292"))
    }

    func testUPCAndEANFormsAreBothProduced() {
        let variants = GTINForms.variants(of: "0673419340540")
        XCTAssertTrue(variants.contains("0673419340540"))
        XCTAssertTrue(variants.contains("673419340540"), "the printed UPC-A")
        XCTAssertTrue(variants.contains("00673419340540"), "the GTIN-14")
    }

    /// The ASIN/ISBN inference is only safe because an ordinary ASIN fails the
    /// ISBN-10 checksum.
    func testAnOrdinaryASINIsNotAnISBN() {
        XCTAssertFalse(GTINForms.isValidISBN10("B09XS7JWHH"))
        XCTAssertNil(GTINForms.isbn13(fromISBN10: "B09XS7JWHH"))
        XCTAssertTrue(GTINForms.isValidISBN10("0735211299"))
    }

    func testVariantsAreOrderedLongestFirstAndDeduplicated() {
        let variants = GTINForms.variants(of: "9780735211292")
        XCTAssertEqual(variants, variants.sorted { $0.count > $1.count })
        XCTAssertEqual(Set(variants).count, variants.count)
    }

    func testTooShortIsNotAnIdentifier() {
        XCTAssertTrue(GTINForms.variants(of: "12345").isEmpty)
        XCTAssertTrue(GTINForms.variants(of: nil).isEmpty)
    }
}

/// A page title is not a product name, and both the search query and the
/// name-similarity check were being handed the retailer's chrome.
final class ProductTitleHygieneTests: XCTestCase {

    func testStorefrontPrefixIsRemoved() {
        XCTAssertEqual(
            ProductTitleHygiene.cleaned("Amazon.com: Atomic Habits: An Easy Way"),
            "Atomic Habits: An Easy Way")
        XCTAssertEqual(
            ProductTitleHygiene.cleaned("Amazon.com.au: Sony Headphones"), "Sony Headphones")
    }

    func testStorefrontSuffixIsRemoved() {
        XCTAssertEqual(
            ProductTitleHygiene.cleaned("Beats Solo Buds - Walmart.com"), "Beats Solo Buds")
        XCTAssertEqual(ProductTitleHygiene.cleaned("LEGO Technic 42115 | Target"), "LEGO Technic 42115")
    }

    func testFormatParentheticalsAreRemovedButEditionsAreNot() {
        XCTAssertEqual(ProductTitleHygiene.cleaned("Atomic Habits (Paperback)"), "Atomic Habits")
        XCTAssertEqual(
            ProductTitleHygiene.cleaned("Atomic Habits (Anniversary Edition)"),
            "Atomic Habits (Anniversary Edition)",
            "an edition distinguishes products and must survive")
    }

    /// A title that is ONLY chrome keeps its original text rather than becoming
    /// an empty product name.
    func testNothingSurvivingLeavesTheOriginal() {
        XCTAssertEqual(ProductTitleHygiene.cleaned("Amazon.com"), "Amazon.com")
    }

    func testOrdinaryTitlesAreLeftAlone() {
        XCTAssertEqual(
            ProductTitleHygiene.cleaned("Sony WH-1000XM5 Wireless Headphones, Black"),
            "Sony WH-1000XM5 Wireless Headphones, Black")
        XCTAssertEqual(ProductTitleHygiene.cleaned("Widget | Shop"), "Widget | Shop")
    }

    /// Amazon AU's `<title>` puts its own domain in a COLON-separated segment
    /// AFTER the product name, with a category segment on the OTHER side of
    /// it — neither a prefix nor a dash/pipe suffix, so this was passing
    /// through uncleaned: a live save's retailer query was measured as the
    /// full raw string, `coles-au q=Russell Hobbs … Chrome: Toasters:
    /// Amazon.com.au`, which returns nothing on every retailer's search.
    func testAmazonColonChromeWithCategoryBeforeTheDomainIsRemoved() {
        XCTAssertEqual(
            ProductTitleHygiene.cleaned(
                "Russell Hobbs RHT82BRU Carlton 2 Slice Toaster, Wide Slots, 7 Browning "
                    + "Controls, Defrost, Cancel & Reheat Functions, Chrome: Toasters: Amazon.com.au"),
            "Russell Hobbs RHT82BRU Carlton 2 Slice Toaster, Wide Slots, 7 Browning "
                + "Controls, Defrost, Cancel & Reheat Functions, Chrome")
    }

    /// The other real shape: the domain segment BEFORE the category segment.
    func testAmazonColonChromeWithCategoryAfterTheDomainIsRemoved() {
        XCTAssertEqual(
            ProductTitleHygiene.cleaned(
                "Panasonic spare blade men's shaver 6-blade ES9600 : Amazon.com.au: "
                    + "Health, Household & Personal Care"),
            "Panasonic spare blade men's shaver 6-blade ES9600")
    }

    /// A category segment that happens to share a word with the
    /// `looksLikeStorefront` word list (`Books`) must NOT be mistaken for the
    /// storefront itself when there is no ACTUAL domain segment alongside it
    /// — the colon-tail stripper only fires on a domain-shaped fragment
    /// (`amazon.com.au`), never a bare category word, so an ordinary colon in
    /// a title survives exactly as it always did.
    func testAnOrdinaryColonWithNoStorefrontDomainSegmentSurvives() {
        XCTAssertEqual(
            ProductTitleHygiene.cleaned(
                "Amazon.com: Atomic Habits: An Easy & Proven Way to Build Good Habits "
                    + "& Break Bad Ones | Clear, James: Books"),
            "Atomic Habits: An Easy & Proven Way to Build Good Habits "
                + "& Break Bad Ones | Clear, James: Books")
    }

    /// A title that is ONLY colon chrome (no real segment before the
    /// storefront) keeps whatever text remains rather than losing the whole
    /// title — the same conservatism the other strippers hold.
    func testColonChromeAloneIsNotTurnedIntoNothing() {
        XCTAssertEqual(ProductTitleHygiene.cleaned("Toasters: Amazon.com.au"), "Toasters")
    }
}

// MARK: - The evidence tier

/// Most real PDPs expose no structured identifier at all, so demanding one
/// refused pages that had been found by searching the retailer for the exact
/// GTIN and that printed those digits.
final class GTINInPageMatchingTests: XCTestCase {

    private let source = ProductIdentifiers(gtin: "9780735211292")
    private let title = "Atomic Habits: An Easy & Proven Way to Build Good Habits"

    private func verify(
        candidate: ProductIdentifiers = ProductIdentifiers(),
        candidateName: String? = nil, html: String? = nil, url: String? = nil,
        reachedByGTINSearch: Bool = true, allowsNameOnly: Bool = false
    ) -> SellerMatchConfidence? {
        ComparisonMatching.verify(
            source: source, sourceName: title,
            candidate: candidate, candidateName: candidateName ?? title,
            evidence: CandidatePageEvidence(
                reachedByGTINSearch: reachedByGTINSearch, html: html,
                url: url.flatMap { URL(string: $0) }),
            allowsNameOnlyMatch: allowsNameOnly)
    }

    func testGTINSearchPlusDigitsInMarkupPlusNameIsAccepted() {
        XCTAssertEqual(verify(html: "<p>ISBN: 9780735211292</p>"), .gtinInPage)
    }

    /// A bookshop asked for an ISBN-13 routinely prints the ISBN-10 — and
    /// Amazon's book ASINs ARE the ISBN-10, which is why the URL counts.
    func testTheISBN10FormAndTheURLBothCount() {
        XCTAssertEqual(verify(html: "<p>ISBN-10: 0735211299</p>"), .gtinInPage)
        XCTAssertEqual(verify(url: "https://www.amazon.com/dp/0735211299"), .gtinInPage)
    }

    func testHyphenatedPrintingsStillMatch() {
        XCTAssertEqual(verify(html: "<td>978-0-7352-1129-2</td>"), .gtinInPage)
    }

    /// Search provenance is not a precondition: the NAME already has to
    /// agree before this tier is even consulted (the caller's own nesting),
    /// and that plus containment is what makes it evidence rather than a
    /// "related items" rail — a web-search hit, or a retailer's own search
    /// buried under a NAME query, lands on this exact page just as often as
    /// a GTIN query does (the measured case: a JB Hi-Fi-style GTIN source
    /// verifying a Costco-style page found by DDG, whose title matches and
    /// whose markup prints the barcode, with nothing about how it was found).
    func testContainmentWithoutAGTINSearchIsNowAcceptedWhenTheNameAgrees() {
        XCTAssertEqual(verify(html: "9780735211292", reachedByGTINSearch: false), .gtinInPage)
    }

    func testContainmentWithoutTheNameAgreeingIsStillNotEvidence() {
        XCTAssertNil(verify(
            candidateName: "Garden Hose Reel 50ft", html: "9780735211292", reachedByGTINSearch: false))
    }

    func testNoContainmentIsNotEvidenceRegardlessOfHowThePageWasReached() {
        XCTAssertNil(verify(html: "<p>a completely different book</p>"))
        XCTAssertNil(verify(html: "<p>a completely different book</p>", reachedByGTINSearch: false))
    }

    func testTheNameMustStillMatch() {
        XCTAssertNil(verify(
            candidateName: "Garden Hose Reel 50ft", html: "9780735211292"))
    }

    /// The wrong-variant trap this tier could have introduced: the audiobook
    /// matches by name and does NOT carry the paperback's ISBN.
    func testTheAudiobookEditionIsStillRefused() {
        XCTAssertNil(verify(
            candidateName: "Atomic Habits: An Easy & Proven Way to Build Good Habits (Audiobook)",
            html: "<p>ASIN B07RFSSYBH · ISBN-13 9781713554851</p>",
            url: "https://www.amazon.com/dp/B07RFSSYBH"))
    }

    /// A candidate that DECLARES a different GTIN is a refusal at tier 1 and
    /// never reaches the evidence tier.
    func testADeclaredConflictingGTINStillWins() {
        XCTAssertNil(verify(
            candidate: ProductIdentifiers(gtin: "9781713554851"), html: "9780735211292"))
    }

    func testTheTierSitsBetweenNameAndMPN() {
        XCTAssertTrue(SellerMatchConfidence.gtinInPage > .name)
        XCTAssertTrue(SellerMatchConfidence.gtinInPage < .mpn)
        XCTAssertTrue(SellerMatchConfidence.mpn < .gtin)
    }

    /// The constrained (Safari) profile refuses name-only matches but must
    /// accept this one — it is identifier evidence, not a guess.
    func testTheConstrainedProfileAcceptsItAndStillRefusesNameOnly() {
        XCTAssertEqual(verify(html: "9780735211292", allowsNameOnly: false), .gtinInPage)
        XCTAssertNil(
            ComparisonMatching.verify(
                source: ProductIdentifiers(brand: "Sony"), sourceName: title,
                candidate: ProductIdentifiers(brand: "Sony"), candidateName: title,
                allowsNameOnlyMatch: false),
            "name-only is still refused where it always was")
    }

    /// The fan-out only spends a second fetch when the markup is the one thing
    /// left to decide.
    func testPageEvidenceIsOnlyRequiredWhenItWouldDecide() {
        XCTAssertTrue(ComparisonMatching.requiresPageEvidence(
            source: source, sourceName: title,
            candidate: ProductIdentifiers(), candidateName: title))
        XCTAssertFalse(ComparisonMatching.requiresPageEvidence(
            source: source, sourceName: title,
            candidate: ProductIdentifiers(gtin: "9780735211292"), candidateName: title),
            "already decided by the declared identifier")
        XCTAssertFalse(ComparisonMatching.requiresPageEvidence(
            source: source, sourceName: title,
            candidate: ProductIdentifiers(), candidateName: "Cordless Drill"),
            "the name already refused it")
    }
}

// MARK: - The MPN containment tier

/// The symmetric hole the GTIN evidence tier had: an MPN-only source (a
/// degraded extraction — brand + model number, no barcode, the measured Bing
/// Lee shape) could never verify a candidate whose page carries no structured
/// identifier at all, even though the model number is usually right there in
/// the candidate's own title.
final class MPNContainmentMatchingTests: XCTestCase {

    private let source = ProductIdentifiers(mpn: "HRFD634BW", brand: "Hisense")
    private let sourceName = "Hisense 634L PureFlat French Door Fridge Dark Steel HRFD634BW"
    private let candidateName = "Hisense HRFD634BW 634L PureFlat French Door Fridge (Dark Stainless Steel)"

    private func verify(
        candidate: ProductIdentifiers = ProductIdentifiers(),
        html: String? = nil, url: String? = nil, allowsNameOnly: Bool = false
    ) -> SellerMatchConfidence? {
        ComparisonMatching.verify(
            source: source, sourceName: sourceName,
            candidate: candidate, candidateName: candidateName,
            evidence: CandidatePageEvidence(html: html, url: url.flatMap { URL(string: $0) }),
            allowsNameOnlyMatch: allowsNameOnly)
    }

    func testMPNTokenInURLPlusMatchingNameIsAccepted() {
        XCTAssertEqual(
            verify(url: "https://www.jbhifi.com.au/products/hisense-hrfd634bw-634l-fridge"), .mpn)
    }

    func testMPNTokenInPageMarkupIsAccepted() {
        XCTAssertEqual(verify(html: "<p>Model: HRFD634BW</p>"), .mpn)
    }

    /// Case and separators must not defeat the containment check — a page can
    /// print `hrfd-634bw` where the source recorded `HRFD634BW`.
    func testMPNTokenIsCaseAndSeparatorInsensitive() {
        XCTAssertEqual(verify(html: "<p>model no. hrfd-634bw</p>"), .mpn)
    }

    func testNoMPNTokenAnywhereIsNotEvidence() {
        XCTAssertNil(verify(html: "<p>completely unrelated copy</p>"))
    }

    /// The name must still agree — containment on a page for a different
    /// product (an accessory bundle, say) is not the fridge.
    func testTheNameMustStillAgreeForMPNContainment() {
        XCTAssertNil(ComparisonMatching.verify(
            source: source, sourceName: sourceName,
            candidate: ProductIdentifiers(), candidateName: "Garden Hose Reel 50ft",
            evidence: CandidatePageEvidence(html: "HRFD634BW"),
            allowsNameOnlyMatch: false))
    }

    /// A candidate that structurally declares its OWN (different) MPN is not
    /// overridden by incidental containment — that page has already told us
    /// what it is.
    func testACandidateDeclaringItsOwnMPNIsNotOverriddenByContainment() {
        XCTAssertNil(verify(
            candidate: ProductIdentifiers(mpn: "SOME-OTHER-MODEL"),
            html: "mentions HRFD634BW in passing"))
    }

    func testAvailableInTheConstrainedProfileTooAsIdentifierEvidence() {
        XCTAssertEqual(verify(html: "<p>Model: HRFD634BW</p>", allowsNameOnly: false), .mpn)
    }
}

// MARK: - The relaxed name + model-code tier

/// A candidate with NO structured identifiers at all — the common case for a
/// plain retail listing — would otherwise reach only the ordinary name-only
/// tier, which the source having a GTIN/MPN blocks outright. The measured
/// case: a Costco AU page, $1599.99, 0.90 name similarity, no JSON-LD —
/// refused without this tier. The model code (`HRFD634BW`) printed in
/// Costco's own URL/PDP is the discriminator that makes trusting a bare name
/// match safe.
/// The model-code check reads the URL/markup ONLY, never the candidate name
/// itself — the name has already been compared (at this tier's own HIGHER
/// bar) to reach here, so a token that is only found by re-scanning that
/// same name is not independent evidence.
final class RelaxedNameWithModelCodeMatchingTests: XCTestCase {

    private let source = ProductIdentifiers(gtin: "9337640009775", brand: "Hisense")
    private let sourceName = "Hisense HRFD634BW 634L PureFlat French Door Fridge (Dark Stainless Steel)"

    private func verify(
        candidateName: String, candidate: ProductIdentifiers = ProductIdentifiers(),
        html: String? = nil, url: String? = nil, allowsNameOnly: Bool = true
    ) -> SellerMatchConfidence? {
        ComparisonMatching.verify(
            source: source, sourceName: sourceName,
            candidate: candidate, candidateName: candidateName,
            evidence: CandidatePageEvidence(html: html, url: url.flatMap { URL(string: $0) }),
            allowsNameOnlyMatch: allowsNameOnly)
    }

    /// The Costco case itself: high name similarity, the model code in the
    /// candidate's own URL, no structured identifier on the candidate at all.
    func testHighNameSimilarityPlusModelCodeInURLIsAccepted() {
        XCTAssertEqual(
            verify(
                candidateName: "Hisense 634L PureFlat French Door Fridge Dark Steel",
                url: "https://www.costco.com.au/Hisense-634L-PureFlat-French-Door-Fridge-Dark-Steel-HRFD634BW/p/177525"),
            .nameWithModelCode)
    }

    /// The model code repeated in the candidate's OWN name is not, by
    /// itself, independent evidence — the name was already compared to reach
    /// this tier, so a token found only by re-scanning it again would just
    /// be re-confirming a comparison already made. Still refused here even
    /// though the name similarity is high, because no URL/markup evidence
    /// was offered.
    func testModelCodeOnlyInTheCandidateNameIsNotIndependentEvidence() {
        XCTAssertNil(
            verify(candidateName: "Hisense 634L PureFlat French Door Fridge Dark Steel HRFD634BW"))
    }

    /// The model code may be on the PAGE rather than in the title the parser
    /// extracted.
    func testModelCodeInMarkupAloneAlsoCounts() {
        XCTAssertEqual(
            verify(
                candidateName: "Hisense 634L PureFlat French Door Fridge Dark Steel",
                html: "<p>Model HRFD634BW</p>"),
            .nameWithModelCode)
    }

    /// Below the relaxed 0.75 bar, this tier refuses even with the model code
    /// present — the ordinary 0.6 name-only tier is a DIFFERENT tier (and is
    /// blocked here anyway because the source has a GTIN).
    func testBelowTheRelaxedThresholdIsRefusedEvenWithTheModelCode() {
        XCTAssertNil(verify(candidateName: "Fridge HRFD634BW on sale this week only, limited stock"))
    }

    /// When the source's name/MPN carries NO model-code-like token, the
    /// higher name-similarity bar alone is enough — there is no discriminator
    /// to demand.
    func testNoModelCodeToDemandFallsBackToTheHigherBarAlone() {
        let plainSource = ProductIdentifiers(gtin: "9337640009775", brand: "Acme")
        XCTAssertEqual(
            ComparisonMatching.verify(
                source: plainSource, sourceName: "Acme Wireless Mechanical Keyboard",
                candidate: ProductIdentifiers(), candidateName: "Acme Wireless Mechanical Keyboard Pro",
                allowsNameOnlyMatch: true),
            .nameWithModelCode)
    }

    /// A candidate that declares ANY structured identifier (even one that
    /// doesn't match) is not eligible for this tier — it has already told us
    /// something structural about itself.
    func testACandidateWithAnyStructuredIdentifierIsIneligible() {
        XCTAssertNil(verify(
            candidateName: "Hisense 634L PureFlat French Door Fridge Dark Steel HRFD634BW",
            candidate: ProductIdentifiers(sku: "177525")))
    }

    /// The constrained (Safari) profile refuses this tier along with the
    /// ordinary name-only one — it is still a NAME match at heart, just a
    /// more careful one.
    func testTheConstrainedProfileRefusesThisTierToo() {
        XCTAssertNil(verify(
            candidateName: "Hisense 634L PureFlat French Door Fridge Dark Steel HRFD634BW",
            allowsNameOnly: false))
    }

    /// A source with NO cross-host identifier at all never needs this tier —
    /// the ordinary name-only tier already covers it, and fires FIRST.
    func testASourceWithNoIdentifierUsesTheOrdinaryNameTierNotThisOne() {
        XCTAssertEqual(
            ComparisonMatching.verify(
                source: ProductIdentifiers(brand: "Hisense"), sourceName: sourceName,
                candidate: ProductIdentifiers(), candidateName: sourceName,
                allowsNameOnlyMatch: true),
            .name)
    }

    func testConfidenceOrderingPlacesItAboveNameAndBelowGTINInPage() {
        XCTAssertTrue(SellerMatchConfidence.nameWithModelCode > .name)
        XCTAssertTrue(SellerMatchConfidence.nameWithModelCode < .gtinInPage)
    }
}

// MARK: - The Amazon small-interstitial bot wall

/// Amazon's search intermittently serves a tiny (measured ~2KB) Akamai Bot
/// Manager challenge as an ordinary 200 rather than a blocked status — the
/// generic challenge needles (`captcha`, `unusual traffic`, …) never appear
/// on it, so it passed straight through as a "successful" empty search.
final class AmazonInterstitialBotWallTests: XCTestCase {

    private func fixture() -> String {
        BypassFixtures.html("Products/amazon-au-bm-verify-interstitial.html")
    }

    func testTheMeasuredInterstitialIsRecognized() {
        let html = fixture()
        XCTAssertLessThan(html.count, 8_000)
        XCTAssertTrue(BotWallDetection.isBotWall(statusCode: 200, html: html))
    }

    /// The existing large-page safeguard must stay green: this is a SIZE-
    /// gated check, not a blanket needle match.
    func testTheSameNeedlesDoNotCondemnALargePage() {
        let padded = fixture() + String(repeating: "<div>product details</div>", count: 400)
        XCTAssertGreaterThan(padded.count, 8_000)
        XCTAssertFalse(BotWallDetection.isBotWall(statusCode: 200, html: padded))
    }
}

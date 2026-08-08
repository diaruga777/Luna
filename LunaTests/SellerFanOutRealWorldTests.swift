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
    /// matches. The only link the old extractor found on this page was a Nook
    /// e-reader SAMPLE on a different subdomain.
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

    /// Both halves are required. Containment alone, on a page reached by a NAME
    /// search, could be a "related items" rail.
    func testContainmentWithoutAGTINSearchIsNotEvidence() {
        XCTAssertNil(verify(html: "9780735211292", reachedByGTINSearch: false))
    }

    func testAGTINSearchWithoutContainmentIsNotEvidence() {
        XCTAssertNil(verify(html: "<p>a completely different book</p>"))
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

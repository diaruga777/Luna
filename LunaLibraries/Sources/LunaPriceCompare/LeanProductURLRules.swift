//
//  LeanProductURLRules.swift
//  LunaPriceCompare
//

import Foundation

/// The retail URL SHAPES this module recognizes, and the questions it asks of a
/// link found in a search-results page: does this look like one product, does it
/// look like another listing grid, and is it one of the pages a retailer keeps on
/// its own domain that is definitely not a product?
///
/// The first two tables are a deliberate hand-copy of `ProductPageRules` +
/// `ProductPageDetector.urlLooksLikeProduct` / `.urlIsMultiProductListing`
/// (LunaHTMLClassification). That module depends on SwiftSoup, and this module
/// depends on Models + URLClassification + PriceMetadata and nothing heavier, so
/// it cannot reach the originals — the fan-out has to stay affordable inside a
/// Safari appex. `LeanProductURLParityTests` pins the tables and the two
/// predicates to the originals, so the copy cannot drift silently.
///
/// The RETAILER table below is this module's own and has no counterpart upstream:
/// the shared rules answer "could this URL be a product page anywhere on the
/// web", which is the right question when classifying a link the user tapped, and
/// the wrong one when picking three links out of a thousand on a retailer's own
/// search page. Barnes & Noble puts every product under `/w/`, which no shared
/// pattern knows, and eBay's search page carries `/itm/123456` promo cards that
/// the shared `/itm/[0-9]{4,}` happily accepts. Both were real, measured
/// failures — B&N yielded one link (a Nook e-reader SAMPLE) out of 79 products,
/// eBay yielded none out of 99.
public enum LeanProductURLRules {

    /// Regex syntax stays inside the subset both `NSRegularExpression` and
    /// JavaScript's `RegExp` support, matching the original.
    public static let productPathPatterns = [
        "_p[0-9]{4,}",
        "/dp/[A-Z0-9]{6,}",
        "/gp/product/",
        "/p/[0-9]{4,}",
        "/products/[^/]+",
        "/itm/[0-9]{4,}",
    ]

    public static let listingFirstPathSegments = [
        "s", "search", "sch", "b", "browse", "bestsellers",
        "deals", "stores", "category", "categories", "collections",
    ]

    public static let listingTwoSegmentPaths = [
        "gp/search", "gp/bestsellers", "gp/browse",
    ]

    public static let searchQueryParameterNames = [
        "k", "field-keywords", "q", "query", "keyword", "keywords", "searchterm",
    ]

    /// Whether the URL path matches a common retail product-page shape.
    public static func looksLikeProduct(_ url: URL?) -> Bool {
        guard let path = url?.path, !path.isEmpty else { return false }
        for pattern in productPathPatterns
        where path.range(of: pattern, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    /// URL shapes that list MANY products at equal primacy. A recognized
    /// single-product URL wins outright, exactly as in the original.
    public static func isMultiProductListing(_ url: URL?) -> Bool {
        guard let url else { return false }
        if looksLikeProduct(url) { return false }

        let segments = url.path.split(separator: "/").map { $0.lowercased() }
        if let first = segments.first, listingFirstPathSegments.contains(first) { return true }
        let firstTwo = segments.prefix(2).joined(separator: "/")
        if listingTwoSegmentPaths.contains(firstTwo) { return true }
        let searchParamNames = Set(searchQueryParameterNames)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return query.contains { searchParamNames.contains($0.name.lowercased()) }
    }

    // MARK: - Per-retailer product paths

    /// One retailer's own answer to "which of my URLs are product pages?".
    ///
    /// `reject` is consulted FIRST and is a veto, because the false positives
    /// worth naming are all shapes a shared pattern would otherwise accept.
    /// A URL matching neither list falls through to the shared tiers, so an
    /// entry can only ever ADD reach — a pattern guessed wrong costs nothing,
    /// which is why the table covers retailers nobody has measured.
    struct RetailerURLRule: Equatable, Sendable {
        let accept: [String]
        let reject: [String]

        init(accept: [String], reject: [String] = []) {
            self.accept = accept
            self.reject = reject
        }
    }

    /// Registrable domain → its product-path shapes. Anchored at the start of
    /// the path (`^`) unless the shape genuinely floats.
    static let retailerRules: [String: RetailerURLRule] = {
        var rules: [String: RetailerURLRule] = [:]

        // Amazon, every storefront: an ASIN is exactly ten characters, and the
        // whole of `/gp/*` that is not `/gp/product/` is account furniture.
        let amazon = RetailerURLRule(
            accept: ["^/([^/]+/)?dp/[A-Z0-9]{10}", "^/gp/product/[A-Z0-9]{10}"],
            reject: ["^/gp/(help|cart|css|customer-media|bestsellers|browse)",
                     "^/ap/", "^/hz/", "^/b/", "^/stores/", "^/gcx/"])
        for domain in ["amazon.com", "amazon.co.uk", "amazon.ca", "amazon.com.au",
                       "amazon.in", "amazon.sg", "amazon.de", "amazon.fr"] {
            rules[domain] = amazon
        }

        // eBay's search page seeds a handful of "Shop on eBay" promo cards whose
        // hrefs are literally `/itm/123456`. A real listing id is 12 digits, and
        // without the veto the promos take every link slot the candidate has.
        let ebay = RetailerURLRule(
            accept: ["^/itm/[0-9]{9,}", "^/p/[0-9]{6,}"],
            reject: ["^/itm/[0-9]{1,8}([/?]|$)", "^/b/", "^/sch/", "^/deals"])
        for domain in ["ebay.com", "ebay.co.uk", "ebay.ca", "ebay.com.au", "ebay.ie"] {
            rules[domain] = ebay
        }

        // US
        rules["walmart.com"] = RetailerURLRule(accept: ["^/ip/([^/]+/)?[0-9]+"])
        rules["target.com"] = RetailerURLRule(accept: ["^/p/[^?]*/-/A-[0-9]+", "^/p/A-[0-9]+"])
        rules["barnesandnoble.com"] = RetailerURLRule(
            accept: ["^/w/[^/]+/[0-9]{6,}", "^/w/[^/]+"],
            // `nook.barnesandnoble.com/products/…/sample` is a Nook e-reader
            // excerpt, not the book — and it is the ONE link the old shared
            // `/products/[^/]+` pattern found on a B&N search page.
            reject: ["/sample", "^/products/", "^/b/", "^/s/"])
        rules["bestbuy.com"] = RetailerURLRule(accept: ["^/site/([^/]+/)?[0-9]+\\.p"])
        rules["homedepot.com"] = RetailerURLRule(accept: ["^/p/([^/]+/)?[0-9]{6,}"])
        rules["lowes.com"] = RetailerURLRule(accept: ["^/pd/[^/]+/[0-9]+"])
        rules["costco.com"] = RetailerURLRule(accept: ["\\.product\\.[0-9]+\\.html", "^/p/[^/]+/[0-9]+"])
        rules["samsclub.com"] = RetailerURLRule(accept: ["^/p/[^/]+/[0-9]+", "^/ip/[^/]+/[0-9]+"])
        rules["newegg.com"] = RetailerURLRule(accept: ["^/p/[A-Za-z0-9]{6,}", "/Product/Product\\.aspx"])
        rules["bhphotovideo.com"] = RetailerURLRule(accept: ["^/c/product/[0-9]+"])
        rules["microcenter.com"] = RetailerURLRule(accept: ["^/product/[0-9]+"])
        rules["gamestop.com"] = RetailerURLRule(accept: ["^/[^/]+/[^/]+/[0-9]+\\.html", "^/products/[^/]+"])
        rules["chewy.com"] = RetailerURLRule(accept: ["/dp/[0-9]+"])
        rules["petco.com"] = RetailerURLRule(accept: ["/product/[^/]+"])
        rules["petsmart.com"] = RetailerURLRule(accept: ["^/product/[0-9]+", "-[0-9]{6,}\\.html"])
        rules["staples.com"] = RetailerURLRule(accept: ["/product_[0-9A-Za-z]+"])
        rules["officedepot.com"] = RetailerURLRule(accept: ["^/a/products/[0-9]+"])
        rules["wayfair.com"] = RetailerURLRule(accept: ["/pdp/[^/]+", "-[A-Z0-9]{8}\\.html"])
        rules["macys.com"] = RetailerURLRule(accept: ["^/shop/product/[^/]+"])
        rules["kohls.com"] = RetailerURLRule(accept: ["^/product/prd-[0-9]+"])
        rules["nordstrom.com"] = RetailerURLRule(accept: ["^/s/[^/]+/[0-9]+"])
        rules["jcpenney.com"] = RetailerURLRule(accept: ["^/p/[^/]+/[a-z0-9]+"])
        rules["zappos.com"] = RetailerURLRule(accept: ["^/p/[^/]+/product/[0-9]+"])
        rules["rei.com"] = RetailerURLRule(accept: ["^/product/[0-9]+"])
        rules["dickssportinggoods.com"] = RetailerURLRule(accept: ["^/p/[^/]+"])
        rules["academy.com"] = RetailerURLRule(accept: ["^/p/[^/]+"])
        rules["basspro.com"] = RetailerURLRule(accept: ["^/shop/en/[^/]+", "^/p/[0-9]+"])
        rules["tractorsupply.com"] = RetailerURLRule(accept: ["^/tsc/product/[^/]+"])
        rules["acehardware.com"] = RetailerURLRule(accept: ["^/departments/.+/[0-9]{4,}", "^/p/[0-9]+"])
        rules["menards.com"] = RetailerURLRule(accept: ["^/main/p-[0-9]+"])
        rules["michaels.com"] = RetailerURLRule(accept: ["^/product/[^/]+", "/[A-Z][0-9]{6,}\\.html"])
        rules["joann.com"] = RetailerURLRule(accept: ["^/p/[^/]+", "/[0-9]{6,}[A-Za-z]?\\.html"])
        rules["hobbylobby.com"] = RetailerURLRule(accept: ["/p/[0-9]+"])
        rules["guitarcenter.com"] = RetailerURLRule(accept: ["\\.gc$", "\\.gc\\?"])
        rules["ulta.com"] = RetailerURLRule(accept: ["^/p/[^/]+", "^/product/[^/]+"])
        rules["sephora.com"] = RetailerURLRule(accept: ["^/product/[^/]+"])
        rules["sallybeauty.com"] = RetailerURLRule(accept: ["/SBS-[0-9]+", "^/p/[^/]+"])
        rules["cvs.com"] = RetailerURLRule(accept: ["prodid-[0-9]+", "^/shop/[^/]+-prodid"])
        rules["walgreens.com"] = RetailerURLRule(accept: ["^/store/c/[^/]+/ID=[0-9]+"])
        rules["autozone.com"] = RetailerURLRule(accept: ["/p/[^/]+/[0-9]+", "^/products/[^/]+"])
        rules["oreillyauto.com"] = RetailerURLRule(accept: ["^/detail/[^/]+"])
        rules["overstock.com"] = RetailerURLRule(accept: ["/product\\.html", "^/products/[0-9]+"])
        rules["qvc.com"] = RetailerURLRule(accept: ["\\.product\\.[A-Z0-9]+\\.html", "^/qic/[^/]+"])
        rules["williams-sonoma.com"] = RetailerURLRule(accept: ["^/products/[^/]+"])
        rules["etsy.com"] = RetailerURLRule(accept: ["^/listing/[0-9]+"])
        rules["bookshop.org"] = RetailerURLRule(accept: ["^/p/books/[^/]+"])
        rules["abebooks.com"] = RetailerURLRule(
            accept: ["/[0-9]{8,}/bd$", "/[0-9]{8,}/bd"], reject: ["^/checkout/", "/sf$"])
        rules["thriftbooks.com"] = RetailerURLRule(accept: ["^/w/[^/]+"], reject: ["^/browse/", "^/a/"])
        rules["booksamillion.com"] = RetailerURLRule(accept: ["/p/[^/]+/[0-9]+", "^/product/[0-9]+"])
        rules["footlocker.com"] = RetailerURLRule(accept: ["^/product/[^/]+/[0-9]+"])
        rules["bathandbodyworks.com"] = RetailerURLRule(accept: ["^/p/[^/]+"])
        rules["ikea.com"] = RetailerURLRule(accept: ["/p/[^/]+-[0-9]{6,}", "/p/[^/]+"])

        // GB / IE
        rules["argos.co.uk"] = RetailerURLRule(accept: ["^/product/[0-9]+"])
        rules["argos.ie"] = rules["argos.co.uk"]
        rules["johnlewis.com"] = RetailerURLRule(accept: ["/p[0-9]{6,}"])
        rules["currys.co.uk"] = RetailerURLRule(accept: ["^/products/[^/]+"])
        rules["currys.ie"] = rules["currys.co.uk"]
        rules["very.co.uk"] = RetailerURLRule(accept: ["/[0-9]+\\.prd"])
        rules["next.co.uk"] = RetailerURLRule(accept: ["^/style/[^/]+", "^/g[0-9]+"])
        rules["marksandspencer.com"] = RetailerURLRule(accept: ["/p/[a-z0-9]+"])
        rules["tesco.com"] = RetailerURLRule(accept: ["/products/[0-9]+"])
        rules["tesco.ie"] = rules["tesco.com"]
        rules["sainsburys.co.uk"] = RetailerURLRule(accept: ["/product/[^/]+"])
        rules["asda.com"] = RetailerURLRule(accept: ["/product/[^/]*[0-9]+"])
        rules["morrisons.com"] = RetailerURLRule(accept: ["/products/[^/]+"])
        rules["waitrose.com"] = RetailerURLRule(accept: ["/products/[^/]+"])
        rules["ocado.com"] = RetailerURLRule(accept: ["/products/[^/]+-[0-9]+"])
        rules["boots.com"] = RetailerURLRule(accept: ["-[0-9]{8}", "^/product/[^/]+"])
        rules["boots.ie"] = rules["boots.com"]
        rules["superdrug.com"] = RetailerURLRule(accept: ["/p/[0-9]+"])
        rules["lookfantastic.com"] = RetailerURLRule(accept: ["/[0-9]{6,}\\.html"])
        rules["waterstones.com"] = RetailerURLRule(accept: ["^/book/[^/]+"])
        rules["whsmith.co.uk"] = RetailerURLRule(accept: ["^/products/[^/]+"])
        rules["screwfix.com"] = RetailerURLRule(accept: ["^/p/[0-9A-Za-z]+"])
        rules["toolstation.com"] = RetailerURLRule(accept: ["/p[0-9]+"])
        rules["wickes.co.uk"] = RetailerURLRule(accept: ["^/product/[^/]+"])
        rules["diy.com"] = RetailerURLRule(accept: ["^/products/[^/]+"])
        rules["homebase.co.uk"] = RetailerURLRule(accept: ["/[0-9]{6,}$", "^/product/[^/]+"])
        rules["dunelm.com"] = RetailerURLRule(accept: ["^/product/[^/]+"])
        rules["therange.co.uk"] = RetailerURLRule(accept: ["/[0-9]{5,}$", "^/p/[0-9]+"])
        rules["game.co.uk"] = RetailerURLRule(accept: ["^/[^/]+/[0-9]{5,}", "^/product/[^/]+"])
        rules["smythstoys.com"] = RetailerURLRule(accept: ["/p/[0-9]+"])
        rules["ao.com"] = RetailerURLRule(accept: ["^/product/[^/]+"])
        rules["halfords.com"] = RetailerURLRule(accept: ["/[0-9]{6,}$", "^/p/[0-9]+"])
        rules["decathlon.co.uk"] = RetailerURLRule(accept: ["^/p/[^/]+"])
        rules["sportsdirect.com"] = RetailerURLRule(accept: ["-[0-9]{6,}$", "/[0-9]{6,}$"])
        rules["jdsports.co.uk"] = RetailerURLRule(accept: ["^/product/[^/]+/[0-9]+"])
        rules["selfridges.com"] = RetailerURLRule(accept: ["^/[A-Z]{2}/[a-z]{2}/cat/[^/]+"])
        rules["houseoffraser.co.uk"] = RetailerURLRule(accept: ["-[0-9]{6,}$", "/[0-9]{6,}$"])
        rules["matalan.co.uk"] = RetailerURLRule(accept: ["/p/[0-9]+"])
        rules["boohoo.com"] = RetailerURLRule(accept: ["/[a-z0-9]+\\.html"])
        rules["asos.com"] = RetailerURLRule(accept: ["/prd/[0-9]+"])
        rules["petsathome.com"] = RetailerURLRule(accept: ["^/product/[^/]+", "^/shop/en/pets/[^/]+"])
        rules["tkmaxx.com"] = RetailerURLRule(accept: ["/p/[0-9]+"])
        rules["easons.com"] = RetailerURLRule(accept: ["^/[^/]+-[0-9]{10,13}"])
        rules["arnotts.com"] = RetailerURLRule(accept: ["/p/[0-9]+", "^/product/[^/]+"])
        rules["brownthomas.com"] = RetailerURLRule(accept: ["/p/[0-9]+", "^/product/[^/]+"])
        rules["harveynorman.ie"] = RetailerURLRule(accept: ["^/[^/]+\\.html"])
        rules["did.ie"] = RetailerURLRule(accept: ["^/products/[^/]+"])
        rules["woodies.ie"] = RetailerURLRule(accept: ["/p/[0-9]+", "^/products/[^/]+"])
        rules["elverys.ie"] = RetailerURLRule(accept: ["/p/[0-9]+"])
        rules["lifestylesports.com"] = RetailerURLRule(accept: ["/p/[0-9]+"])
        rules["littlewoodsireland.ie"] = RetailerURLRule(accept: ["/[0-9]+\\.prd"])
        rules["dunnesstores.com"] = RetailerURLRule(accept: ["/product/[^/]+"])

        // AU / NZ
        rules["bigw.com.au"] = RetailerURLRule(accept: ["/p/[0-9]+"])
        rules["kmart.com.au"] = RetailerURLRule(accept: ["^/product/[^/]+"])
        rules["kmart.co.nz"] = rules["kmart.com.au"]
        rules["target.com.au"] = RetailerURLRule(accept: ["^/p/[^/]+/[0-9]+"])
        rules["bunnings.com.au"] = RetailerURLRule(accept: ["_p[0-9]+"])
        rules["bunnings.co.nz"] = rules["bunnings.com.au"]
        rules["jbhifi.com.au"] = RetailerURLRule(accept: ["^/products/[^/]+"])
        rules["jbhifi.co.nz"] = rules["jbhifi.com.au"]
        rules["harveynorman.com.au"] = RetailerURLRule(accept: ["^/[^/]+\\.html"])
        rules["harveynorman.co.nz"] = rules["harveynorman.com.au"]
        // Live search results seed nav/menu links under the store's OTHER
        // sections that also happen to match the bare "/p/" accept pattern —
        // `/print-copy/p/flyers-pcdhflcp` (a print-services category page,
        // not a product) measured on a real search for an unrelated fridge.
        // A real officeworks product lives at `/shop/officeworks/p/<slug>`,
        // never under `/print-copy/`.
        rules["officeworks.com.au"] = RetailerURLRule(accept: ["/p/[^/]+"], reject: ["^/print-copy/"])
        rules["booktopia.com.au"] = RetailerURLRule(accept: ["/book/[0-9]{10,13}", "/[0-9]{10,13}\\.html"])
        rules["dymocks.com.au"] = RetailerURLRule(accept: ["^/book/[^/]+"])
        rules["coles.com.au"] = RetailerURLRule(accept: ["/product/[^/]+"])
        rules["woolworths.com.au"] = RetailerURLRule(accept: ["/productdetails/[0-9]+", "/product/[0-9]+"])
        rules["woolworths.co.nz"] = rules["woolworths.com.au"]
        rules["chemistwarehouse.com.au"] = RetailerURLRule(accept: ["^/buy/[0-9]+"])
        rules["catch.com.au"] = RetailerURLRule(accept: ["^/product/[^/]+"])
        rules["kogan.com"] = RetailerURLRule(accept: ["/buy/[^/]+"])
        rules["myer.com.au"] = RetailerURLRule(accept: ["/p/[^/]+"])
        rules["davidjones.com"] = RetailerURLRule(accept: ["/product/[^/]+", "/[0-9]{6,}$"])
        rules["rebelsport.com.au"] = RetailerURLRule(accept: ["/p/[^/]+"])
        rules["rebelsport.co.nz"] = rules["rebelsport.com.au"]
        rules["supercheapauto.com.au"] = RetailerURLRule(accept: ["/p/[^/]+"])
        rules["repco.com.au"] = RetailerURLRule(accept: ["/p/[^/]+"])
        rules["anacondastores.com"] = RetailerURLRule(accept: ["/p/[^/]+"])
        rules["bcf.com.au"] = RetailerURLRule(accept: ["/p/[^/]+"])
        rules["trademe.co.nz"] = RetailerURLRule(accept: ["/listing/[0-9]+"])
        rules["thewarehouse.co.nz"] = RetailerURLRule(accept: ["^/p/[^/]+"])
        rules["pbtech.co.nz"] = RetailerURLRule(accept: ["^/product/[A-Z0-9]+"])
        rules["mitre10.co.nz"] = RetailerURLRule(accept: ["/p/[0-9]+"])
        rules["noelleeming.co.nz"] = RetailerURLRule(accept: ["^/p/[^/]+"])
        rules["whitcoulls.co.nz"] = RetailerURLRule(accept: ["^/p/[^/]+"])
        rules["paperplus.co.nz"] = RetailerURLRule(accept: ["^/products/[^/]+"])
        rules["ebgames.com.au"] = RetailerURLRule(accept: ["^/product/[^/]+"])
        rules["ebgames.co.nz"] = rules["ebgames.com.au"]

        // CA
        rules["indigo.ca"] = RetailerURLRule(accept: ["/[0-9]{10,13}\\.html", "^/en-ca/[^/]+/[^/]+"])
        rules["canadiantire.ca"] = RetailerURLRule(accept: ["/pdp/[^/]+"])
        rules["thebay.com"] = RetailerURLRule(accept: ["^/product/[^/]+"])
        rules["staples.ca"] = RetailerURLRule(accept: ["^/products/[^/]+"])
        rules["sportchek.ca"] = RetailerURLRule(accept: ["^/product/[^/]+"])
        rules["londondrugs.com"] = RetailerURLRule(accept: ["/p/L[0-9]+", "/p/[0-9]+"])
        rules["shoppersdrugmart.ca"] = RetailerURLRule(accept: ["/p/[0-9]+"])
        rules["rona.ca"] = RetailerURLRule(accept: ["/product/[^/]+"])
        rules["marks.com"] = RetailerURLRule(accept: ["/product/[^/]+"])
        rules["mec.ca"] = RetailerURLRule(accept: ["/product/[0-9]+"])
        rules["simons.ca"] = RetailerURLRule(accept: ["/[0-9]{6,}$"])
        rules["leons.ca"] = RetailerURLRule(accept: ["^/products/[^/]+"])
        rules["thebrick.com"] = RetailerURLRule(accept: ["^/products/[^/]+"])
        rules["gianttiger.com"] = RetailerURLRule(accept: ["^/products/[^/]+"])
        rules["michaels.ca"] = rules["michaels.com"]
        rules["bestbuy.ca"] = RetailerURLRule(accept: ["/product/[^/]+/[0-9]+"])
        rules["homedepot.ca"] = RetailerURLRule(accept: ["/product/[^/]+/[0-9]+"])
        rules["walmart.ca"] = RetailerURLRule(accept: ["^/[a-z]{2}/ip/[^/]+", "^/ip/[^/]+"])
        rules["costco.ca"] = RetailerURLRule(accept: ["\\.product\\.[0-9]+\\.html", "^/p/[^/]+/[0-9]+"])
        rules["newegg.ca"] = rules["newegg.com"]
        rules["petsmart.ca"] = rules["petsmart.com"]

        // IN / SG / ZA
        rules["flipkart.com"] = RetailerURLRule(accept: ["/p/itm[a-z0-9]+"])
        rules["myntra.com"] = RetailerURLRule(accept: ["/[0-9]+/buy"])
        rules["croma.com"] = RetailerURLRule(accept: ["/p/[0-9]+"])
        rules["reliancedigital.in"] = RetailerURLRule(accept: ["/p/[0-9]+", "/product/[^/]+"])
        rules["tatacliq.com"] = RetailerURLRule(accept: ["/p-[a-z0-9]+"])
        rules["nykaa.com"] = RetailerURLRule(accept: ["/p/[0-9]+"])
        rules["bigbasket.com"] = RetailerURLRule(accept: ["/pd/[0-9]+"])
        rules["lazada.sg"] = RetailerURLRule(accept: ["-i[0-9]+", "^/products/[^/]+"])
        rules["shopee.sg"] = RetailerURLRule(accept: ["-i\\.[0-9]+\\.[0-9]+", "^/product/[0-9]+/[0-9]+"])
        rules["fairprice.com.sg"] = RetailerURLRule(accept: ["^/product/[^/]+"])
        rules["challenger.sg"] = RetailerURLRule(accept: ["^/products/[^/]+"])
        rules["watsons.com.sg"] = RetailerURLRule(accept: ["/p/[0-9]+"])
        rules["guardian.sg"] = RetailerURLRule(accept: ["/p/[0-9]+", "^/products/[^/]+"])
        rules["courts.com.sg"] = RetailerURLRule(accept: ["^/[^/]+\\.html"])
        rules["takealot.com"] = RetailerURLRule(accept: ["/PLID[0-9]+"])
        rules["makro.co.za"] = RetailerURLRule(accept: ["/p/[A-Z0-9]+", "^/products/[^/]+"])
        rules["clicks.co.za"] = RetailerURLRule(accept: ["/p/[0-9]+"])
        rules["dischem.co.za"] = RetailerURLRule(accept: ["/[0-9]{6,}$", "^/product/[^/]+"])
        rules["game.co.za"] = RetailerURLRule(accept: ["/p/[0-9]+"])
        rules["incredible.co.za"] = RetailerURLRule(accept: ["^/products/[^/]+"])
        rules["woolworths.co.za"] = RetailerURLRule(accept: ["^/prod/[^/]+"])

        return rules
    }()

    /// The rule for `host`'s retailer family, if the table knows it.
    static func retailerRule(forHost host: String) -> RetailerURLRule? {
        retailerRules[registrableDomain(host)]
    }

    /// Registrable domain — the same two-or-three-label rule
    /// `ProductIdentityMatching.registrableDomain` applies, reimplemented here
    /// only so this table can be consulted without a LunaModels import at the
    /// call sites that already have a host string.
    static func registrableDomain(_ host: String) -> String {
        let lower = host.lowercased()
        let parts = lower.split(separator: ".").map(String.init)
        guard parts.count > 2 else { return lower }
        let secondLevel = ["co", "com", "org", "net", "gov", "edu", "ac"]
        if parts.count >= 3, secondLevel.contains(parts[parts.count - 2]) {
            return parts.suffix(3).joined(separator: ".")
        }
        return parts.suffix(2).joined(separator: ".")
    }

    // MARK: - Non-product pages on a retailer's own domain

    /// Subdomain labels that belong to the retailer but never to a product:
    /// `nook.barnesandnoble.com` sells e-reader samples, `help.*` sells nothing.
    /// A search page links to a dozen of these before it links to a product.
    public static let excludedSubdomainLabels: Set<String> = [
        "nook", "help", "support", "care", "careers", "jobs", "investor", "investors",
        "corporate", "press", "news", "blog", "community", "forum", "forums",
        "affiliate", "affiliates", "developer", "developers", "api", "ads",
        "advertising", "advertise", "sellercentral", "seller", "sell", "partners",
        "business", "b2b", "giftcards", "gift", "images", "img", "static", "cdn",
        "assets", "media", "photos", "video", "search", "account", "accounts",
        "signin", "login", "secure", "checkout", "cart", "pay", "payments",
        "stores", "locations", "maps", "jobs2", "about", "legal", "policy",
    ]

    /// Path SEGMENTS that mark a non-product page. Segment-exact rather than
    /// substring, so `/cart` is excluded and `/cartridges` is not.
    public static let excludedPathSegments: Set<String> = [
        "sample", "samples", "excerpt", "preview", "review", "reviews",
        "customer-reviews", "help", "faq", "cart", "checkout", "basket",
        "wishlist", "wishlists", "registry", "account", "accounts", "signin",
        "sign-in", "login", "logout", "register", "customer-service",
        "customerservice", "terms", "privacy", "policies", "legal", "careers",
        "sitemap", "blog", "support", "returns", "shipping", "delivery",
        "track-order", "orders", "gift-cards", "giftcards", "gift-card",
        "store-locator", "storelocator", "stores", "locations", "about",
        "contact", "press", "affiliate", "affiliates", "advertise", "sell",
        "seller", "sellercentral", "compare", "recently-viewed",
    ]

    /// Substrings that mark a non-product page and do not sit on a segment
    /// boundary (`/gp/help/customer/…`, a bundler's `/_next/static/…`).
    ///
    /// The API and asset needles are what keep a WHOLE-DOCUMENT scan honest: a
    /// Next.js search page is three megabytes of bundle URLs and GraphQL
    /// endpoints, and `gdx-api.costco.com/…/products/summary` matches the shared
    /// `/products/[^/]+` pattern perfectly.
    public static let excludedPathNeedles = [
        "/gp/help", "/ap/signin", "/gp/cart", "/gp/css", "/customer-reviews/",
        "/product-reviews/", "/store-locator", "/giftcard",
        "/_next/", "/api/", "/graphql", "/static/", "/assets/", "/_nuxt/",
    ]

    /// File extensions that are an asset, never a page.
    public static let excludedPathExtensions: Set<String> = [
        "css", "js", "mjs", "cjs", "json", "xml", "txt", "map",
        "png", "jpg", "jpeg", "gif", "webp", "svg", "ico", "avif", "bmp",
        "woff", "woff2", "ttf", "otf", "eot", "mp4", "webm", "mp3", "pdf", "zip",
    ]

    /// Subdomain labels that are machine endpoints rather than storefronts. A
    /// prefix/suffix test rather than a set, because every retailer names them
    /// differently (`gdx-api`, `ecom-api`, `api-prod`, `img1`, `cdn2`).
    static let machineSubdomainFragments = ["api", "cdn", "static", "assets", "img", "media"]

    /// Whether a URL on the retailer's own domain is one of the pages that is
    /// definitely not a product.
    public static func isExcludedNonProductURL(_ url: URL) -> Bool {
        if let host = url.host?.lowercased() {
            let labels = host.split(separator: ".").map(String.init)
            // Every label except the registrable domain's own is a subdomain.
            let registrableLabelCount = registrableDomain(host)
                .split(separator: ".").count
            for label in labels.dropLast(registrableLabelCount) {
                if excludedSubdomainLabels.contains(label) { return true }
                if machineSubdomainFragments.contains(where: { label.contains($0) }) { return true }
            }
        }
        let path = url.path.lowercased()
        if excludedPathExtensions.contains((path as NSString).pathExtension) { return true }
        for needle in excludedPathNeedles where path.contains(needle) { return true }
        for segment in path.split(separator: "/").map(String.init)
        where excludedPathSegments.contains(segment) {
            return true
        }
        return false
    }

    /// Domains a retailer legitimately serves product links from that are NOT
    /// its own registrable domain — Amazon's short forms, mostly.
    public static let affiliatedDomains: [String: Set<String>] = [
        "amazon.com": ["amzn.to", "a.co", "amzn.com"],
        "amazon.co.uk": ["amzn.to", "amzn.eu"],
        "amazon.ca": ["amzn.to", "a.co"],
        "amazon.com.au": ["amzn.to", "amzn.asia"],
        "amazon.in": ["amzn.to", "amzn.asia"],
        "amazon.sg": ["amzn.to", "amzn.asia"],
    ]

    /// Whether a link found on `searchDomain`'s search page is allowed to point
    /// at `linkDomain`.
    public static func domainIsInScope(_ linkDomain: String, forSearchDomain searchDomain: String)
        -> Bool {
        linkDomain == searchDomain
            || affiliatedDomains[searchDomain]?.contains(linkDomain) == true
    }
}

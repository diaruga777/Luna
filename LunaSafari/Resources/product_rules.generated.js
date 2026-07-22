// GENERATED from ProductPageRules.swift (LunaHTMLClassification) by ProductPageRulesJSParityTests.
// Do NOT edit by hand. Regenerate with: TEST_RUNNER_RECORD_PRODUCT_RULES=1 xcodebuild test -scheme Luna -destination "platform=iOS Simulator,id=$SIM" -configuration Debug -derivedDataPath "$DD" DIAGNOSE_MISSING_TARGET_DEPENDENCIES=NO
self.__LUNA_PRODUCT_RULES = {
  minimumHeuristicScore: 2,
  productOpenGraphTypes: [
    "product",
    "product.item",
  ],
  productPriceMetaNames: [
    "product:price:amount",
    "og:price:amount",
    "product:price",
  ],
  productPathPatterns: [
    "_p[0-9]{4,}",
    "/dp/[A-Z0-9]{6,}",
    "/gp/product/",
    "/p/[0-9]{4,}",
    "/products/[^/]+",
    "/itm/[0-9]{4,}",
  ],
  listingFirstPathSegments: [
    "s",
    "search",
    "sch",
    "b",
    "browse",
    "bestsellers",
    "deals",
    "stores",
    "category",
    "categories",
    "collections",
  ],
  listingTwoSegmentPaths: [
    "gp/search",
    "gp/bestsellers",
    "gp/browse",
  ],
  searchQueryParameterNames: [
    "k",
    "field-keywords",
    "q",
    "query",
    "keyword",
    "keywords",
    "searchterm",
  ],
  addToCartPhrases: [
    "add to cart",
    "add to bag",
  ],
  addToCartMarkupNeedles: [
    "addtocart",
  ],
  ratingMarkupNeedles: [
    "aggregaterating",
    "ratingvalue",
    "out of 5",
    "star rating",
  ],
};

//
//  ProductPageRulesJSParityTests.swift
//  LunaTests
//

import Foundation
import LunaHTMLClassification
import XCTest

/// Guards Safari's generated product-page rule data against the compiled Swift
/// source of truth. Behavior parity is exercised separately by
/// `ProductPageJSFixtureParityTests`.
final class ProductPageRulesJSParityTests: XCTestCase {
    private static var artifactURL: URL {
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile.deletingLastPathComponent().deletingLastPathComponent()
        return repoRoot.appendingPathComponent("LunaSafari/Resources/product_rules.generated.js")
    }

    private static func jsArray(_ name: String, _ values: [String]) -> String {
        let entries = values.map { "    \"\($0)\"," }.joined(separator: "\n")
        return "  \(name): [\n\(entries)\n  ],"
    }

    private static func expectedContents() -> String {
        [
            "// GENERATED from ProductPageRules.swift (LunaHTMLClassification) by ProductPageRulesJSParityTests.",
            "// Do NOT edit by hand. Regenerate with: TEST_RUNNER_RECORD_PRODUCT_RULES=1 xcodebuild test -scheme Luna -destination \"platform=iOS Simulator,id=$SIM\" -configuration Debug -derivedDataPath \"$DD\" DIAGNOSE_MISSING_TARGET_DEPENDENCIES=NO",
            "self.__LUNA_PRODUCT_RULES = {",
            "  minimumHeuristicScore: \(ProductPageRules.minimumHeuristicScore),",
            jsArray("productOpenGraphTypes", ProductPageRules.productOpenGraphTypes),
            jsArray("productPriceMetaNames", ProductPageRules.productPriceMetaNames),
            jsArray("productPathPatterns", ProductPageRules.productPathPatterns),
            jsArray("listingFirstPathSegments", ProductPageRules.listingFirstPathSegments),
            jsArray("listingTwoSegmentPaths", ProductPageRules.listingTwoSegmentPaths),
            jsArray("searchQueryParameterNames", ProductPageRules.searchQueryParameterNames),
            jsArray("addToCartPhrases", ProductPageRules.addToCartPhrases),
            jsArray("addToCartMarkupNeedles", ProductPageRules.addToCartMarkupNeedles),
            jsArray("ratingMarkupNeedles", ProductPageRules.ratingMarkupNeedles),
            "};",
            "",
        ].joined(separator: "\n")
    }

    func testGeneratedArtifactMatchesProductPageRules() {
        let expected = Self.expectedContents()
        if ProcessInfo.processInfo.environment["RECORD_PRODUCT_RULES"] == "1" {
            do {
                try expected.write(to: Self.artifactURL, atomically: true, encoding: .utf8)
                XCTContext.runActivity(named: "Recorded product_rules.generated.js") { _ in }
            } catch {
                XCTFail("Failed to write product_rules.generated.js: \(error)")
            }
            return
        }

        guard let actual = try? String(contentsOf: Self.artifactURL, encoding: .utf8) else {
            XCTFail("product_rules.generated.js not found -- generate it with "
                    + "TEST_RUNNER_RECORD_PRODUCT_RULES=1")
            return
        }
        XCTAssertEqual(
            actual, expected,
            "product_rules.generated.js is stale relative to ProductPageRules.swift -- regenerate with "
            + "TEST_RUNNER_RECORD_PRODUCT_RULES=1 xcodebuild test -scheme Luna ...")
    }
}

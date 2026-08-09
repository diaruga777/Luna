//
//  ProductIdentifiersTests.swift
//  LunaTests
//

import LunaModels
import XCTest

/// The keyed identifier value type + the shared normalization primitives it is
/// built on. Parity with the older `ProductMatcher`/`SnapshotMatcher` copies is
/// pinned separately by `ComparisonMatchingParityTests`.
final class ProductIdentifiersTests: XCTestCase {

    func testEmptyAndWhitespaceFieldsCollapseToNil() {
        let identifiers = ProductIdentifiers(gtin: "  ", mpn: "", sku: nil, brand: " Sony ")
        XCTAssertNil(identifiers.gtin)
        XCTAssertNil(identifiers.mpn)
        XCTAssertNil(identifiers.sku)
        XCTAssertEqual(identifiers.brand, "Sony")
        XCTAssertFalse(identifiers.isEmpty)
        XCTAssertTrue(ProductIdentifiers().isEmpty)
    }

    func testNormalizedGTINZeroPadsToFourteenDigits() {
        XCTAssertEqual(ProductIdentifiers(gtin: "0123456789012").normalizedGTIN, "00123456789012")
        XCTAssertEqual(ProductIdentifiers(gtin: "123456789012").normalizedGTIN, "00123456789012")
        // Different declared widths of the SAME number compare equal.
        XCTAssertEqual(
            ProductIdentifiers(gtin: "12345670").normalizedGTIN,
            ProductIdentifiers(gtin: "0000012345670").normalizedGTIN)
        // Punctuation is stripped before padding.
        XCTAssertEqual(ProductIdentifiers(gtin: "1-234-567-89012").normalizedGTIN, "00123456789012")
        // A non-numeric id (ISBN-10 with a check letter) compares as-is.
        XCTAssertEqual(ProductIdentifiers(gtin: "080442957X").normalizedGTIN, "080442957X")
    }

    func testMergingFillsOnlyEmptyFields() {
        let strong = ProductIdentifiers(gtin: "111", brand: "Sony")
        let weak = ProductIdentifiers(gtin: "999", mpn: "WH-1000XM5", sku: "SKU9", brand: "Other")
        let merged = strong.merging(weak)
        XCTAssertEqual(merged.gtin, "111")
        XCTAssertEqual(merged.brand, "Sony")
        XCTAssertEqual(merged.mpn, "WH-1000XM5")
        XCTAssertEqual(merged.sku, "SKU9")
    }

    func testHasCrossHostIdentifier() {
        XCTAssertTrue(ProductIdentifiers(gtin: "123").hasCrossHostIdentifier)
        XCTAssertTrue(ProductIdentifiers(mpn: "XM5").hasCrossHostIdentifier)
        // An SKU is retailer-scoped — it is not cross-host evidence.
        XCTAssertFalse(ProductIdentifiers(sku: "A1", brand: "Sony").hasCrossHostIdentifier)
    }

    func testBrandCompatibilityTreatsUnknownAsCompatible() {
        XCTAssertTrue(ProductIdentityMatching.brandsCompatible("Sony", "sony"))
        XCTAssertTrue(ProductIdentityMatching.brandsCompatible(nil, "Sony"))
        XCTAssertTrue(ProductIdentityMatching.brandsCompatible("Sony", "  "))
        XCTAssertFalse(ProductIdentityMatching.brandsCompatible("Sony", "Bose"))
    }

    func testRegistrableDomainHandlesCompoundSuffixes() {
        XCTAssertEqual(ProductIdentityMatching.registrableDomain("www.amazon.com"), "amazon.com")
        XCTAssertEqual(ProductIdentityMatching.registrableDomain("www.johnlewis.co.uk"), "johnlewis.co.uk")
        XCTAssertTrue(ProductIdentityMatching.hostFamilyMatches("smile.amazon.com", "amazon.com"))
        XCTAssertFalse(ProductIdentityMatching.hostFamilyMatches("amazon.com", "amazon.co.uk"))
    }
}

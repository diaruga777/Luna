//
//  InteropPurchaseControllerTests.swift
//  LunaTests
//

import XCTest
@testable import LunaInterop

/// `InteropPurchaseController` itself talks to live StoreKit with no local
/// test seam (no StoreKit Testing configuration is wired into this scheme),
/// so this covers its two pure, StoreKit-free seams: product-id derivation
/// and the verified-transaction-relevance decision every unlock recording
/// path (`Transaction.updates`, `Transaction.currentEntitlements`) funnels
/// through before calling the injected `onVerifiedTransaction` closure.
final class InteropPurchaseControllerTests: XCTestCase {

    func testProductIDDerivation() {
        XCTAssertEqual(
            InteropProductID.derive(forBundleIdentifier: "com.acme.luna.reader"),
            "com.acme.luna.reader.interop")
        XCTAssertEqual(
            InteropProductID.derive(forBundleIdentifier: "com.acme.luna.downloader"),
            "com.acme.luna.downloader.interop")
    }

    func testTransactionRelevanceRequiresVerification() {
        XCTAssertFalse(InteropTransactionRelevance.shouldRecordUnlock(
            transactionProductID: "com.acme.luna.reader.interop", verified: false,
            ownProductID: "com.acme.luna.reader.interop"))
    }

    func testTransactionRelevanceRequiresMatchingProductID() {
        XCTAssertFalse(InteropTransactionRelevance.shouldRecordUnlock(
            transactionProductID: "com.acme.luna.downloader.interop", verified: true,
            ownProductID: "com.acme.luna.reader.interop"))
    }

    func testTransactionRelevanceTrueForVerifiedOwnProduct() {
        XCTAssertTrue(InteropTransactionRelevance.shouldRecordUnlock(
            transactionProductID: "com.acme.luna.reader.interop", verified: true,
            ownProductID: "com.acme.luna.reader.interop"))
    }

    @MainActor
    func testControllerIsUnlockedReflectsInjectedEntitlement() {
        let suiteName = "InteropPurchaseControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let entitlement = InteropEntitlement(defaults: defaults)
        let controller = InteropPurchaseController(
            productID: "com.acme.luna.reader.interop", entitlement: entitlement)
        XCTAssertFalse(controller.isUnlocked)
        entitlement.recordUnlocked()
        XCTAssertTrue(controller.isUnlocked)
    }
}

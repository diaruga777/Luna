import XCTest
@testable import LunaPremium

@MainActor
final class PremiumAccessTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    override func setUp() {
        super.setUp()
        suite = "test.premium.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }
    func testFreeUnlockIsOnlyInMemoryAndDoesNotCrossAppsOrRelaunch() {
        let firstApp = PremiumAccessState(defaults: defaults)
        XCTAssertFalse(firstApp.hasAccess)
        firstApp.continueForFree()
        XCTAssertTrue(firstApp.hasAccess)
        XCTAssertFalse(firstApp.isPaid)
        XCTAssertFalse(PremiumAccessState(defaults: defaults).hasAccess)
        XCTAssertNil(defaults.persistentDomain(forName: suite)?["luna.premium.verifiedPurchase"])
    }
    func testVerifiedPurchaseCrossesAppsAndRelaunchAndRevocationRemovesIt() {
        let firstApp = PremiumAccessState(defaults: defaults)
        let secondApp = PremiumAccessState(defaults: UserDefaults(suiteName: suite)!)
        firstApp.recordVerifiedPurchase(transactionID: 123)
        XCTAssertTrue(secondApp.isPaid)
        XCTAssertTrue(secondApp.hasAccess)
        XCTAssertTrue(PremiumAccessState(defaults: defaults).isPaid)
        firstApp.recordVerifiedPurchase(transactionID: nil)
        XCTAssertFalse(secondApp.hasAccess)
    }
    func testFreeSessionStillWorksAfterPaidEntitlementIsRevoked() {
        let state = PremiumAccessState(defaults: defaults)
        state.continueForFree()
        state.recordVerifiedPurchase(transactionID: 456)
        state.recordVerifiedPurchase(transactionID: nil)
        XCTAssertTrue(state.hasAccess)
        XCTAssertFalse(state.isPaid)
    }
    func testDiscountKeepsCanonicalEntitlementForOlderCompanionApps() {
        let state = PremiumAccessState(defaults: defaults)
        state.recordVerifiedPurchase(transactionID: 789, productID: PremiumAccess.happyHourProductID)
        let record = defaults.dictionary(forKey: "luna.premium.verifiedPurchase")
        XCTAssertEqual(record?["productID"] as? String, PremiumAccess.productID)
        XCTAssertEqual(record?["purchasedProductID"] as? String, PremiumAccess.happyHourProductID)
        XCTAssertTrue(PremiumAccessState(defaults: defaults).isPaid)
    }
}

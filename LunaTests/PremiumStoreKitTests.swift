import StoreKit
import StoreKitTest
import XCTest
@testable import LunaPremium

@MainActor
final class PremiumStoreKitTests: XCTestCase {
    private var session: SKTestSession!
    private var access: PremiumAccess!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        session = try SKTestSession(contentsOf: root.appendingPathComponent("Config/LunaPremium.storekit"))
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        suite = "test.premium.storekit.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        access = PremiumAccess(state: PremiumAccessState(defaults: defaults))
    }
    override func tearDownWithError() throws {
        access = nil
        session.clearTransactions()
        session = nil
        defaults.removePersistentDomain(forName: suite)
        try super.tearDownWithError()
    }
    func testVerifiedPurchaseLoadsLocalizedPriceAndUnlocksDurably() async throws {
        await access.prepare()
        XCTAssertEqual(access.product?.price, Decimal(2))
        XCTAssertFalse(access.product?.displayPrice.isEmpty ?? true)
        let purchased = try await access.purchase()
        XCTAssertTrue(purchased)
        XCTAssertTrue(access.state.isPaid)
        XCTAssertTrue(PremiumAccessState(defaults: defaults).isPaid)
    }
    func testRefundClearsSharedAccess() async throws {
        let purchased = try await access.purchase()
        XCTAssertTrue(purchased)
        let transaction = try XCTUnwrap(session.allTransactions().first)
        try session.refundTransaction(identifier: transaction.identifier)
        let deadline = Date().addingTimeInterval(3)
        while access.state.hasAccess && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(access.state.hasAccess)
    }
    func testCancelledPurchaseNeverGrantsAccess() async throws {
        try await session.setSimulatedError(.generic(.userCancelled), forAPI: .purchase)
        do {
            let purchased = try await access.purchase()
            XCTAssertFalse(purchased)
        } catch {
            // StoreKit test may surface cancellation as StoreKitError instead.
            guard case .userCancelled = error as? StoreKitError else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertFalse(access.state.hasAccess)
    }
    func testExplicitRestoreFindsEarlierPurchase() async throws {
        _ = try await session.buyProduct(identifier: PremiumAccess.productID)
        let restored = try await access.restore()
        XCTAssertTrue(restored)
        XCTAssertTrue(access.state.isPaid)
    }
    func testExistingStoreKitEntitlementRestoresOnLaunch() async throws {
        _ = try await session.buyProduct(identifier: PremiumAccess.productID)
        XCTAssertFalse(access.state.hasAccess)
        await access.prepare()
        XCTAssertTrue(access.state.isPaid)
    }
}

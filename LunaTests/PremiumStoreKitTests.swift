import StoreKit
import LunaPluginUI
import LunaModels
import UIKit
import StoreKitTest
import XCTest
@testable import LunaPremium

@MainActor
final class PremiumStoreKitTests: XCTestCase {
    private var session: SKTestSession!
    private var access: PremiumAccess!
    private var defaults: UserDefaults!
    private var suite: String!
    private var now = Date()

    private func localDate(day: Int, hour: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        session = try SKTestSession(contentsOf: root.appendingPathComponent("Config/LunaPremium.storekit"))
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        suite = "test.premium.storekit.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        now = localDate(day: 26, hour: 12) // Monday; deterministic outside the promotion.
        access = PremiumAccess(state: PremiumAccessState(defaults: defaults), now: { [unowned self] in self.now })
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
    func testHappyHourBuysDiscountSKUAndSharesDurableAccess() async throws {
        now = localDate(day: 24, hour: 14)
        await access.prepare()
        XCTAssertEqual(access.purchaseProduct?.id, PremiumAccess.happyHourProductID)
        XCTAssertEqual(access.purchaseProduct?.price, Decimal(string: "1.49"))
        let purchased = try await access.purchase(expectedProductID: PremiumAccess.happyHourProductID)
        XCTAssertTrue(purchased)
        XCTAssertEqual(session.allTransactions().last?.productIdentifier, PremiumAccess.happyHourProductID)
        XCTAssertTrue(PremiumAccessState(defaults: defaults).isPaid)
    }

    func testExpiredDiscountNeverFallsBackToFullPrice() async throws {
        now = localDate(day: 24, hour: 14)
        await access.prepare()
        let displayedID = try XCTUnwrap(access.purchaseProduct?.id)
        now = localDate(day: 24, hour: 15)
        do {
            _ = try await access.purchase(expectedProductID: displayedID)
            XCTFail("An expired offer must require a new tap on the updated price")
        } catch PremiumAccess.PurchaseError.offerChanged { }
        XCTAssertTrue(session.allTransactions().isEmpty)
        XCTAssertFalse(access.state.hasAccess)
    }

    func testFullPriceTapAtStartOfHappyHourRequiresNewConsent() async throws {
        await access.prepare()
        now = localDate(day: 24, hour: 14)
        do {
            _ = try await access.purchase(expectedProductID: PremiumAccess.productID)
            XCTFail("A different SKU requires updated consent")
        } catch PremiumAccess.PurchaseError.offerChanged { }
        XCTAssertTrue(session.allTransactions().isEmpty)
    }

    func testDiscountRestoresOutsideHappyHour() async throws {
        _ = try await session.buyProduct(identifier: PremiumAccess.happyHourProductID)
        let restored = try await access.restore()
        XCTAssertTrue(restored)
        XCTAssertTrue(access.state.isPaid)
    }

    func testRefundOfOneSKUDoesNotRevokeOtherSKU() async throws {
        _ = try await session.buyProduct(identifier: PremiumAccess.productID)
        _ = try await session.buyProduct(identifier: PremiumAccess.happyHourProductID)
        await access.prepare()
        let regular = try XCTUnwrap(session.allTransactions().first { $0.productIdentifier == PremiumAccess.productID })
        try session.refundTransaction(identifier: regular.identifier)
        await access.refreshEntitlement()
        XCTAssertTrue(access.state.isPaid)
        let discount = try XCTUnwrap(session.allTransactions().first { $0.productIdentifier == PremiumAccess.happyHourProductID })
        try session.refundTransaction(identifier: discount.identifier)
        let deadline = Date().addingTimeInterval(3)
        while access.state.isPaid && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(access.state.isPaid)
    }

    func testExistingOwnerCannotBuySecondSKU() async throws {
        _ = try await session.buyProduct(identifier: PremiumAccess.productID)
        now = localDate(day: 24, hour: 14)
        do {
            _ = try await access.purchase()
            XCTFail("Already purchased")
        } catch PremiumAccess.PurchaseError.alreadyOwned { }
        XCTAssertEqual(session.allTransactions().count, 1)
    }
    func testHappyHourScreenShowsSalePriceAndKeepsFreeChoice() async throws {
        now = localDate(day: 24, hour: 14)
        access.state.continueForFree() // Reminder taps can still offer a paid unlock this launch.
        await access.prepare()
        let controller = PremiumUnlockViewController(access: access) { _ in }
        let window = UITestSupport.host(UINavigationController(rootViewController: controller), size: UIScreen.main.bounds.size)
        defer { window.isHidden = true }
        let sale = try XCTUnwrap(access.purchaseProduct)
        let deadline = Date().addingTimeInterval(3)
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        while !descendants(controller.view).contains(where: {
            ($0 as? UIButton)?.title(for: .normal) == L10n.string("Premium_unlockPrice", sale.displayPrice)
        }) && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let buttons = descendants(controller.view).compactMap { $0 as? UIButton }
        XCTAssertTrue(buttons.contains { $0.title(for: .normal) == L10n.string("Premium_unlockPrice", sale.displayPrice) })
        XCTAssertTrue(buttons.contains { $0.title(for: .normal) == L10n.string("Premium_unlockWithoutPaying") })
        XCTAssertTrue(buttons.contains { $0.title(for: .normal) == L10n.string("Premium_remindMe") })
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { context in
            window.layer.render(in: context.cgContext)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Premium happy hour"
        attachment.lifetime = .keepAlways
        add(attachment)
        try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/luna-premium-happy-hour.png"))
    }
}

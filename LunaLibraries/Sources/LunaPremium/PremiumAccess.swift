import Foundation
import LunaAppConfig
import LunaModels
import StoreKit

/// Paid access crosses Luna processes through the App Group. The free override
/// belongs to this object only: it is never written to defaults or the keychain.
@MainActor
public final class PremiumAccessState {
    private let defaults: UserDefaults
    private let paidKey = "luna.premium.verifiedPurchase"
    public private(set) var freeForThisLaunch = false

    public init(defaults: UserDefaults) { self.defaults = defaults }
    public var isPaid: Bool {
        guard let id = defaults.dictionary(forKey: paidKey)?["productID"] as? String else { return false }
        return PremiumAccess.productIDs.contains(id)
    }
    public var hasAccess: Bool { isPaid || freeForThisLaunch }
    public func continueForFree() { freeForThisLaunch = true }

    // Only StoreKit's verified transaction path writes durable access.
    func recordVerifiedPurchase(transactionID: UInt64?, productID: String = PremiumAccess.productID) {
        if let transactionID {
            guard PremiumAccess.productIDs.contains(productID) else { return }
            // Preserve the canonical entitlement ID read by older companion apps.
            defaults.set(["productID": PremiumAccess.productID, "purchasedProductID": productID,
                          "transactionID": String(transactionID)], forKey: paidKey)
        } else { defaults.removeObject(forKey: paidKey) }
    }
}

/// The central Luna app owns the purchase. Other Luna apps read the same paid
/// entitlement; they never remove it because their own receipt lacks this IAP.
@MainActor
public final class PremiumAccess {
    public static let productID = AppConfig.productBundlePrefix + ".premium"
    public static let happyHourProductID = productID + ".happyhour"
    public static let productIDs: Set<String> = [productID, happyHourProductID]
    public static let shared = PremiumAccess()
    public let state: PremiumAccessState
    public private(set) var product: Product?
    public private(set) var happyHourProduct: Product?
    private let now: () -> Date

    public var isHappyHour: Bool { PremiumHappyHour.isActive(at: now()) }
    public var hasHappyHourPrice: Bool {
        guard let product, let happyHourProduct else { return false }
        return PremiumHappyHour.isEligiblePrice(
            regular: product.price, discounted: happyHourProduct.price,
            regularCurrency: product.priceFormatStyle.currencyCode,
            discountedCurrency: happyHourProduct.priceFormatStyle.currencyCode)
    }
    public var purchaseProduct: Product? {
        isHappyHour ? (hasHappyHourPrice ? happyHourProduct : nil) : product
    }
    private var listener: Task<Void, Never>?
    private var initialRefresh: Task<Void, Never>?
    private var foregroundObserver: NSObjectProtocol?
    private var ownsPurchase: Bool { Bundle.main.bundleIdentifier == AppConfig.productBundlePrefix }

    private convenience init() {
        self.init(state: PremiumAccessState(defaults: UserDefaults(suiteName: AppConfig.appGroupID) ?? .standard))
    }

    init(state: PremiumAccessState, now: @escaping () -> Date = Date.init) {
        self.state = state
        self.now = now
    }

    deinit {
        listener?.cancel()
        initialRefresh?.cancel()
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
    }

    public func start() {
        guard listener == nil, ownsPurchase else { return }
        listener = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self, case .verified(let transaction) = result,
                      Self.productIDs.contains(transaction.productID) else { continue }
                // Reconcile both SKUs: refunding one must not revoke the other.
                await self.refreshEntitlement()
                await transaction.finish()
            }
        }
        initialRefresh = Task { [weak self] in
            guard let self else { return }
            await self.refreshEntitlement()
        }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("UIApplicationDidBecomeActiveNotification"), object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in await self?.refreshEntitlement() } }
    }

    public func prepare() async {
        start()
        await initialRefresh?.value
        if product == nil || happyHourProduct == nil { await reloadProducts() }
    }

    public func reloadProducts() async {
        guard ownsPurchase else { return }
        let products = (try? await Product.products(for: Array(Self.productIDs))) ?? []
        product = products.first { $0.id == Self.productID }
        happyHourProduct = products.first { $0.id == Self.happyHourProductID }
    }

    func refreshEntitlement() async {
        guard ownsPurchase else { return }
        var entitlement: Transaction?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  Self.productIDs.contains(transaction.productID),
                  transaction.revocationDate == nil, !transaction.isUpgraded else { continue }
            entitlement = transaction
        }
        state.recordVerifiedPurchase(transactionID: entitlement?.id, productID: entitlement?.productID ?? Self.productID)
        if state.isPaid { PremiumHappyHourReminders.shared.cancel() }
    }

    public enum PurchaseError: LocalizedError {
        case unavailable, unverified, pending, offerChanged, alreadyOwned
        public var errorDescription: String? {
            switch self {
            case .unavailable: return L10n.string("Premium_purchaseUnavailable")
            case .unverified: return L10n.string("Premium_unverified")
            case .pending: return L10n.string("Premium_pending")
            case .offerChanged: return L10n.string("Premium_offerChanged")
            case .alreadyOwned: return L10n.string("Premium_alreadyOwned")
            }
        }
    }

    /// False means the user cancelled Apple's sheet; it never grants access.
    public func purchase(expectedProductID: String? = nil) async throws -> Bool {
        await prepare()
        guard ownsPurchase else { throw PurchaseError.unavailable }
        await refreshEntitlement()
        guard !state.isPaid else { throw PurchaseError.alreadyOwned }
        // Recheck after every suspension, immediately before opening Apple's sheet.
        guard let product = purchaseProduct else { throw PurchaseError.unavailable }
        guard expectedProductID == nil || expectedProductID == product.id else { throw PurchaseError.offerChanged }
        switch try await product.purchase() {
        case .success(let result):
            guard case .verified(let transaction) = result, transaction.revocationDate == nil,
                  transaction.productID == product.id else { throw PurchaseError.unverified }
            state.recordVerifiedPurchase(transactionID: transaction.id, productID: transaction.productID)
            PremiumHappyHourReminders.shared.cancel()
            await transaction.finish()
            return true
        case .pending: throw PurchaseError.pending
        case .userCancelled: return false
        @unknown default: return false
        }
    }

    public func restore() async throws -> Bool {
        guard ownsPurchase else { return state.isPaid }
        try await AppStore.sync()
        await refreshEntitlement()
        return state.isPaid
    }
}

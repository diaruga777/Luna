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
    public var isPaid: Bool { defaults.dictionary(forKey: paidKey)?["productID"] as? String == PremiumAccess.productID }
    public var hasAccess: Bool { isPaid || freeForThisLaunch }
    public func continueForFree() { freeForThisLaunch = true }

    // Only StoreKit's verified transaction path writes durable access.
    func recordVerifiedPurchase(transactionID: UInt64?) {
        if let transactionID {
            defaults.set(["productID": PremiumAccess.productID, "transactionID": String(transactionID)], forKey: paidKey)
        } else { defaults.removeObject(forKey: paidKey) }
    }
}

/// The central Luna app owns the purchase. Other Luna apps read the same paid
/// entitlement; they never remove it because their own receipt lacks this IAP.
@MainActor
public final class PremiumAccess {
    public static let productID = AppConfig.productBundlePrefix + ".premium"
    public static let shared = PremiumAccess()
    public let state: PremiumAccessState
    public private(set) var product: Product?
    private var listener: Task<Void, Never>?
    private var initialRefresh: Task<Void, Never>?
    private var foregroundObserver: NSObjectProtocol?
    private var ownsPurchase: Bool { Bundle.main.bundleIdentifier == AppConfig.productBundlePrefix }

    private convenience init() {
        self.init(state: PremiumAccessState(defaults: UserDefaults(suiteName: AppConfig.appGroupID) ?? .standard))
    }

    init(state: PremiumAccessState) { self.state = state }

    deinit {
        listener?.cancel()
        initialRefresh?.cancel()
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
    }

    public func start() {
        guard listener == nil, ownsPurchase else { return }
        listener = Task { [weak self] in
            for await result in Transaction.updates {
                guard case .verified(let transaction) = result,
                      transaction.productID == Self.productID else { continue }
                if transaction.revocationDate != nil {
                    self?.state.recordVerifiedPurchase(transactionID: nil)
                } else {
                    self?.state.recordVerifiedPurchase(transactionID: transaction.id)
                }
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
        if product == nil { product = try? await Product.products(for: [Self.productID]).first }
    }

    func refreshEntitlement() async {
        guard ownsPurchase else { return }
        var transactionID: UInt64?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.productID == Self.productID,
                  transaction.revocationDate == nil, !transaction.isUpgraded else { continue }
            transactionID = transaction.id
        }
        state.recordVerifiedPurchase(transactionID: transactionID)
    }

    public enum PurchaseError: LocalizedError {
        case unavailable, unverified, pending
        public var errorDescription: String? {
            switch self {
            case .unavailable: return L10n.string("Premium_purchaseUnavailable")
            case .unverified: return L10n.string("Premium_unverified")
            case .pending: return L10n.string("Premium_pending")
            }
        }
    }

    /// False means the user cancelled Apple's sheet; it never grants access.
    public func purchase() async throws -> Bool {
        await prepare()
        guard ownsPurchase, let product else { throw PurchaseError.unavailable }
        switch try await product.purchase() {
        case .success(let result):
            guard case .verified(let transaction) = result, transaction.revocationDate == nil,
                  transaction.productID == Self.productID else { throw PurchaseError.unverified }
            state.recordVerifiedPurchase(transactionID: transaction.id)
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

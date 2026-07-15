//
//  InteropPurchaseController.swift
//  LunaInterop
//

import StoreKit
import Foundation

/// Whether a StoreKit transaction result should record an interop unlock: it
/// must be App-Store-verified AND for THIS app's own product id (never a
/// sibling app's — those live in a different App Store Connect app record and
/// can never appear here anyway, but the id check keeps the decision explicit
/// and unit-testable without any real StoreKit call).
enum InteropTransactionRelevance {
    static func shouldRecordUnlock(transactionProductID: String, verified: Bool, ownProductID: String) -> Bool {
        verified && transactionProductID == ownProductID
    }
}

/// Drives the StoreKit 2 side of the cross-app interop purchase: loading this
/// app's own `$1.99` non-consumable, buying it, restoring it, and listening
/// for transactions — every verified transaction for THIS app's product id
/// writes the shared App-Group `InteropEntitlement` flag every Luna app trusts.
///
/// Kept thin on purpose: the only logic worth unit-testing without a live
/// StoreKit environment is product-id derivation (`InteropProductID`) and the
/// verified-transaction-relevance decision (`InteropTransactionRelevance`,
/// exercised indirectly via the injectable `onVerifiedTransaction` closure in
/// `recordIfRelevant`). `loadProduct`/`purchase`/`restore` are real StoreKit
/// calls with no local test seam — they're exercised manually against the
/// StoreKit Testing configuration in Xcode, not unit-tested.
@MainActor
public final class InteropPurchaseController {
    public enum PurchaseOutcome: Equatable {
        case unlocked
        case userCancelled
        case pending
    }

    public enum PurchaseError: Error, Equatable {
        case productUnavailable
        case verificationFailed
        case unknown
    }

    public let productID: String
    private let entitlement: InteropEntitlement
    /// Injected so tests can observe unlock recording without real StoreKit.
    /// Production default writes the real App-Group flag.
    private let onVerifiedTransaction: () -> Void
    private var transactionListenerTask: Task<Void, Never>?

    public private(set) var product: Product?

    /// The running app's own controller (its own product id, the shared
    /// App-Group entitlement). Installed once at launch (`AppDelegate`):
    /// `listenForTransactions()` + an initial `checkCurrentEntitlements()`
    /// sweep. The Settings screen and the paywall reuse this instance so a
    /// purchase made from either immediately reflects in the other.
    public static let shared = InteropPurchaseController()

    public init(
        productID: String = InteropProductID.current ?? "",
        entitlement: InteropEntitlement = .shared,
        onVerifiedTransaction: (() -> Void)? = nil
    ) {
        self.productID = productID
        self.entitlement = entitlement
        self.onVerifiedTransaction = onVerifiedTransaction ?? { entitlement.recordUnlocked() }
    }

    deinit {
        transactionListenerTask?.cancel()
    }

    /// Whether this device already unlocked interop (via this app OR any
    /// sibling Luna app — the App-Group flag is shared).
    public var isUnlocked: Bool { entitlement.isUnlocked }

    /// Loads this app's own product (price + display metadata for the paywall).
    /// A no-op leaving `product` nil if `productID` is empty or the App Store
    /// can't resolve it (offline, not yet configured in ASC, etc.) — the
    /// paywall shows an unavailable state rather than crashing.
    @discardableResult
    public func loadProduct() async -> Product? {
        guard !productID.isEmpty else { return nil }
        product = try? await Product.products(for: [productID]).first
        return product
    }

    /// Buys this app's own product. On success records the unlock (via the
    /// injected closure) before returning.
    public func purchase() async throws -> PurchaseOutcome {
        let resolvedProduct: Product
        if let product { resolvedProduct = product } else if let loaded = await loadProduct() {
            resolvedProduct = loaded
        } else {
            throw PurchaseError.productUnavailable
        }

        let result = try await resolvedProduct.purchase()
        switch result {
        case let .success(verification):
            try recordIfVerified(verification)
            return .unlocked
        case .userCancelled:
            return .userCancelled
        case .pending:
            return .pending
        @unknown default:
            return .pending
        }
    }

    /// `AppStore.sync()` (re-signs in with the App Store account and refreshes
    /// entitlements) then scans `Transaction.currentEntitlements` for a
    /// verified transaction of THIS app's product. ONLY ever finds one if the
    /// purchase was originally made in THIS app — a different Luna app's
    /// product id lives in a different App Store Connect app record — which is
    /// exactly the restore caveat the paywall UI must explain.
    @discardableResult
    public func restore() async throws -> Bool {
        try await AppStore.sync()
        return await checkCurrentEntitlements()
    }

    /// Scans current entitlements for a verified transaction of this app's own
    /// product id, recording an unlock for each one found. Used both at launch
    /// (in case a prior purchase's `Transaction.updates` event was missed while
    /// not running) and after `restore()`.
    @discardableResult
    public func checkCurrentEntitlements() async -> Bool {
        var found = false
        for await result in Transaction.currentEntitlements {
            if recordIfRelevant(result) { found = true }
        }
        return found
    }

    /// Starts (or restarts) the long-lived listener for new transactions
    /// (renewal-free for a non-consumable, but StoreKit still delivers Ask to
    /// Buy / family-sharing approvals and cross-device purchases this way).
    /// Call once at launch (`AppDelegate`); safe to call again (cancels any
    /// prior listener first).
    public func listenForTransactions() {
        transactionListenerTask?.cancel()
        transactionListenerTask = Task { [weak self] in
            guard let self else { return }
            for await result in Transaction.updates {
                await self.handleTransactionUpdate(result)
            }
        }
    }

    private func handleTransactionUpdate(_ result: VerificationResult<Transaction>) async {
        _ = recordIfRelevant(result)
        if case .verified(let transaction) = result {
            await transaction.finish()
        }
    }

    @discardableResult
    private func recordIfRelevant(_ result: VerificationResult<Transaction>) -> Bool {
        let verified: Bool
        let transactionProductID: String
        switch result {
        case .verified(let transaction):
            verified = true
            transactionProductID = transaction.productID
        case .unverified(let transaction, _):
            verified = false
            transactionProductID = transaction.productID
        }
        guard InteropTransactionRelevance.shouldRecordUnlock(
            transactionProductID: transactionProductID, verified: verified, ownProductID: productID
        ) else { return false }
        onVerifiedTransaction()
        return true
    }

    private func recordIfVerified(_ verification: VerificationResult<Transaction>) throws {
        guard case .verified(let transaction) = verification else { throw PurchaseError.verificationFailed }
        Task { await transaction.finish() }
        onVerifiedTransaction()
    }
}

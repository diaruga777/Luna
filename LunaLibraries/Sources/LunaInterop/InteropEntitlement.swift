//
//  InteropEntitlement.swift
//  LunaInterop
//

import Foundation

/// The shared "cross-app interop unlocked" state. Two independent unlock
/// routes:
///
/// - **Purchased**: a single App Group boolean any of the three Luna apps can
///   set (after a verified StoreKit purchase in ANY of them) and every app
///   trusts. There is no per-app entitlement — one non-consumable bought in
///   one Luna app unlocks cross-app saving in all three, because they all read
///   the same App Group flag.
/// - **Build-granted**: debug builds and TestFlight installs get every paid
///   feature for free (`InteropBuildGrant`), so development and beta testing
///   never hit the paywall. The reason is inspectable (`status`) so UI can say
///   "Unlocked (TestFlight)" instead of implying a purchase.
///
/// Injectable `UserDefaults` AND build-grant seam, so tests never touch the
/// real App Group suite and can exercise the LOCKED paths even under a DEBUG
/// test build (where the production grant would otherwise make every gate test
/// trivially pass).
public struct InteropEntitlement {
    /// Why (or whether) interop is unlocked on this device.
    public enum UnlockStatus: Equatable, Sendable {
        /// A verified StoreKit purchase was recorded (in any Luna app).
        case purchased
        /// A `#if DEBUG` build — everything paid is free.
        case debugBuild
        /// A TestFlight/sandbox install — everything paid is free.
        case testFlight
        /// No purchase, no build grant: the gate applies.
        case locked
    }

    /// `group.<namespace>` App Group key. Never renamed casually — it's read by
    /// every Luna app/extension process via `InteropAppGroupDefaults`.
    public static let unlockedKey = "interop.unlocked"

    public let defaults: UserDefaults
    /// The build-level free unlock, nil when this build isn't granted one.
    /// Production default: `InteropBuildGrant.detect`.
    private let buildGrant: () -> UnlockStatus?

    public init(
        defaults: UserDefaults = InteropAppGroupDefaults.current,
        buildGrant: @escaping () -> UnlockStatus? = InteropBuildGrant.detect
    ) {
        self.defaults = defaults
        self.buildGrant = buildGrant
    }

    /// The default instance, reading/writing the real App Group suite with the
    /// real build-grant detection. Production call sites use this; tests
    /// construct their own `InteropEntitlement` with a scratch
    /// `UserDefaults(suiteName:)` and an injected grant.
    public static let shared = InteropEntitlement()

    /// The full unlock state, with its reason. A recorded purchase wins over a
    /// build grant (it's the stronger, device-portable claim); the grant covers
    /// everyone else on debug/TestFlight builds.
    public var status: UnlockStatus {
        if defaults.bool(forKey: Self.unlockedKey) { return .purchased }
        if let grant = buildGrant() { return grant }
        return .locked
    }

    /// Whether cross-app interop is unlocked, for any reason.
    public var isUnlocked: Bool {
        status != .locked
    }

    /// Records a verified purchase (StoreKit transaction, in this app or a
    /// restore) as unlocking cross-app interop for every Luna app sharing this
    /// App Group. Idempotent — safe to call for every verified transaction,
    /// including ones already recorded.
    public func recordUnlocked() {
        defaults.set(true, forKey: Self.unlockedKey)
    }
}

/// Detects a build-level free unlock. Deliberately SYNCHRONOUS and cheap so
/// `isUnlocked` stays usable from the short-lived extension processes:
/// `AppTransaction`/StoreKit would be async, but the receipt URL's filename is
/// a plain property — a TestFlight/sandbox install stores its receipt as
/// `sandboxReceipt` (an App Store install's is `receipt`).
public enum InteropBuildGrant {
    /// The grant for THIS build/process, nil for a real App Store install.
    public static func detect() -> InteropEntitlement.UnlockStatus? {
        #if DEBUG
        return .debugBuild
        #else
        if receiptURL(for: Bundle.main)?.lastPathComponent == "sandboxReceipt" {
            return .testFlight
        }
        return nil
        #endif
    }

    /// Returns the receipt for an app OR for the containing app when called in
    /// an `.appex`. StoreKit receipts belong to the application bundle; asking
    /// only `Bundle.main` inside an extension can therefore return nil and make
    /// a TestFlight app free while its own share/action extension stays locked.
    /// The injectable URL variant keeps the ancestor walk unit-testable without
    /// relying on the test runner's bundle layout.
    static func receiptURL(for bundle: Bundle) -> URL? {
        if let receipt = bundle.appStoreReceiptURL { return receipt }
        return containingAppBundleURL(for: bundle.bundleURL)
            .flatMap(Bundle.init(url:))?
            .appStoreReceiptURL
    }

    static func containingAppBundleURL(for bundleURL: URL) -> URL? {
        var candidate = bundleURL.standardizedFileURL
        while candidate.path != "/" {
            if candidate.pathExtension.lowercased() == "app" { return candidate }
            candidate.deleteLastPathComponent()
        }
        return nil
    }
}

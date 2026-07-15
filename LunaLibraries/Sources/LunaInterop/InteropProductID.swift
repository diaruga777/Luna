//
//  InteropProductID.swift
//  LunaInterop
//

import Foundation

/// Each Luna app sells its OWN non-consumable interop unlock — there is no
/// shared product id — so a purchase's App Store receipt only ever exists
/// inside the app it was bought in. That's what makes "restore only works in
/// the app you bought it in" true, and it's also why the shared App-Group
/// `InteropEntitlement` flag (not StoreKit) is what the OTHER two apps trust.
public enum InteropProductID {
    /// The running app's own product id, or nil if `Bundle.main.bundleIdentifier`
    /// is unexpectedly unset (never happens for a real app/extension bundle).
    public static var current: String? {
        Bundle.main.bundleIdentifier.map(derive(forBundleIdentifier:))
    }

    /// Pure derivation, testable without `Bundle.main`.
    public static func derive(forBundleIdentifier bundleIdentifier: String) -> String {
        "\(bundleIdentifier).interop"
    }
}

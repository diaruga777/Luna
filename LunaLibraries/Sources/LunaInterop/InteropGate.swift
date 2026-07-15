//
//  InteropGate.swift
//  LunaInterop
//

import LunaModels
import Foundation

/// THE single decision every cross-app write is checked against. Pure — no
/// UserDefaults/StoreKit/UIKit reads of its own — so the whole matrix is
/// unit-testable without touching the App Group or a device. Callers resolve
/// `owner`/`isUnlocked`/`isInstalled` (from `InteropSurface`, `InteropEntitlement`,
/// `InteropInstallationMarkers`) and pass the resolved values in.
public enum InteropGate {

    /// What a save may do, given who owns its outcome, who's running, and the
    /// unlock/install state.
    public enum Decision: Equatable {
        /// Same-surface save, or an outcome with no owner (`.failed`) — never
        /// gated, byte-identical to today.
        case allowed
        /// Cross-surface, paid: the write proceeds exactly as today, but the
        /// owning app isn't installed — show an informational "go install X"
        /// prompt (the item is still saved; the shared store surfaces it once
        /// the owning app is installed).
        case allowedNeedsInstall(owner: InteropSurface)
        /// Cross-surface, unpaid: the write must be BLOCKED — nothing may remain
        /// in the store. `ownerInstalled` tells the caller whether the prompt
        /// needs an install step in addition to the paywall step.
        case blocked(owner: InteropSurface, ownerInstalled: Bool)
    }

    /// The pure decision function. `owner` is the surface `InteropSurface(owning:)`
    /// resolves for the save's outcome — nil for an outcome with no owner
    /// (`.failed`). `isInstalled` is a closure (not a stored value) purely so
    /// tests can assert it's never even called for the trivial `.allowed` paths.
    public static func evaluate(
        owner: InteropSurface?,
        current: InteropSurface,
        isUnlocked: Bool,
        isInstalled: (InteropSurface) -> Bool
    ) -> Decision {
        guard let owner, owner != current else { return .allowed }
        guard isUnlocked else {
            return .blocked(owner: owner, ownerInstalled: isInstalled(owner))
        }
        return isInstalled(owner) ? .allowed : .allowedNeedsInstall(owner: owner)
    }

    /// Whether a save from `source` is subject to interop gating at all.
    /// `.email` and `.friendShare` are background/universal ingestion — saves
    /// arriving that way keep writing cross-surface regardless of payment, no
    /// matter what `evaluate` would otherwise say. Exhaustive (no `default`) so
    /// a newly added `CaptureSource` forces an explicit exemption decision here.
    public static func isGated(source: CaptureSource) -> Bool {
        switch source {
        case .email, .friendShare: return false
        case .shareSheet, .paste, .manual, .appIntent: return true
        }
    }
}

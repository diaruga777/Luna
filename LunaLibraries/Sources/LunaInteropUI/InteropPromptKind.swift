//
//  InteropPromptKind.swift
//  LunaInteropUI
//

import LunaInterop
import Foundation

/// What the interop prompt shows — the two `InteropGate.Decision` cases that
/// actually need UI (`.allowed` never presents anything).
public enum InteropPromptKind: Equatable {
    /// Paid (or same-surface) but the owning app isn't installed on this
    /// device. The save already went through — this is purely informational.
    case needsInstall(owner: InteropSurface)
    /// Unpaid cross-surface write — blocked, nothing was saved.
    /// `ownerInstalled` controls whether an install step shows alongside the
    /// pay step.
    case blocked(owner: InteropSurface, ownerInstalled: Bool)

    public var owner: InteropSurface {
        switch self {
        case .needsInstall(let owner): return owner
        case .blocked(let owner, _): return owner
        }
    }
}

public extension InteropGate.Decision {
    /// `nil` for `.allowed` — nothing to show.
    var promptKind: InteropPromptKind? {
        switch self {
        case .allowed: return nil
        case .allowedNeedsInstall(let owner): return .needsInstall(owner: owner)
        case .blocked(let owner, let ownerInstalled): return .blocked(owner: owner, ownerInstalled: ownerInstalled)
        }
    }
}

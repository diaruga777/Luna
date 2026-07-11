//
//  DotMatrixTransitionExempt.swift
//  LunaTransitions
//
//  A small opt-out seam for view controllers that manage their own push/pop
//  transition — e.g. one using iOS 18's `preferredTransition = .zoom(...)` — and
//  must not have it overridden by the Dot Matrix pixel-wipe.
//

import UIKit

/// Conform a pushed/popped view controller to this to make `DotMatrixNavigationDelegate`
/// step aside for ITS transition: `animationController(for:)` returns nil (falling back
/// to the system transition, which honors the VC's own `preferredTransition`) whenever
/// either endpoint of a push/pop conforms, and the delegate's edge-pan interactive-pop
/// gesture declines to begin while the exempt VC is on top — so the system's own
/// interactive dismissal (e.g. the zoom transition's) can run unobstructed.
public protocol DotMatrixTransitionExempt {}

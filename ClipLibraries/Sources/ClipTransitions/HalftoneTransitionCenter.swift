//
//  HalftoneTransitionCenter.swift
//  ClipTransitions
//
//  Owns the GPU overlay views for the global halftone "pixel wipe". A single overlay
//  is prewarmed and parked per window so the costly Metal pipeline compile happens
//  once, off the tap critical path; transitions borrow it, animate, and return it.
//  `isEnabled` is the single gate every transition surface checks — the user toggle
//  AND Metal availability — so a disabled/unsupported state falls straight through to
//  the original UIKit animation.
//

import ClipContentRendering
import ClipDesignSystem
import UIKit

public final class HalftoneTransitionCenter {
    public static let shared = HalftoneTransitionCenter()
    private init() {}

    /// Parked, reusable overlays keyed weakly by window (auto-released on window
    /// teardown). At most one parked overlay per window; extra concurrent transitions
    /// allocate a transient overlay (cheap — the GPU context is shared).
    private let parked = NSMapTable<UIWindow, RabbitHoleTransitionView>.weakToStrongObjects()

    /// True when the pixel-wipe toggle is on AND Metal is available. The only check
    /// transition surfaces need; false ⇒ use the stock UIKit animation.
    public var isEnabled: Bool {
        ReaderSettings.pixelWipeTransitionsEnabled && RabbitHoleTransitionView.isSupported
    }

    /// Build and park an overlay now so the first transition doesn't pay the Metal
    /// setup cost. Safe to call repeatedly; a no-op when Metal is unavailable.
    public func prewarm(in window: UIWindow) {
        guard RabbitHoleTransitionView.isSupported, parked.object(forKey: window) == nil,
              let view = RabbitHoleTransitionView.make() else { return }
        view.isHidden = true
        parked.setObject(view, forKey: window)
    }

    /// Borrow an overlay for a transition (reusing the window's parked one if free),
    /// or nil when Metal is unavailable. The caller owns parenting until it returns it.
    func borrowOverlay(for window: UIWindow?) -> RabbitHoleTransitionView? {
        guard RabbitHoleTransitionView.isSupported else { return nil }
        if let window, let parkedView = parked.object(forKey: window) {
            parked.removeObject(forKey: window)
            return parkedView
        }
        return RabbitHoleTransitionView.make()
    }

    /// Return an overlay after a transition: drop its textures, detach it, and re-park
    /// it for reuse (one per window; transient extras are simply released).
    func returnOverlay(_ view: RabbitHoleTransitionView, for window: UIWindow?) {
        view.clearTextures()
        view.isHidden = true
        view.removeFromSuperview()
        if let window, parked.object(forKey: window) == nil {
            parked.setObject(view, forKey: window)
        }
    }
}

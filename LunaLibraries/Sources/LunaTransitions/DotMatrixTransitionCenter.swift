//
//  DotMatrixTransitionCenter.swift
//  LunaTransitions
//
//  Owns the GPU overlay views for the global Dot Matrix "pixel wipe". A single overlay
//  is prewarmed and parked per window so the costly Metal pipeline compile happens
//  once, off the tap critical path; transitions borrow it, animate, and return it.
//  `isEnabled` is the single gate every transition surface checks — the user's
//  animated-transitions preference, the system Reduce Motion setting, and Metal
//  availability — so a disabled/unsupported state falls straight through to the
//  original UIKit animation.
//

import LunaContentRendering
import LunaDesignSystem
import UIKit

public final class DotMatrixTransitionCenter {
    public static let shared = DotMatrixTransitionCenter()
    private init() {}

    /// Parked, reusable overlays keyed weakly by window (auto-released on window
    /// teardown). At most one parked overlay per window; extra concurrent transitions
    /// allocate a transient overlay (cheap — the GPU context is shared).
    private let parked = NSMapTable<UIWindow, RabbitHoleTransitionView>.weakToStrongObjects()

    /// True when the user's animated-transitions preference is on, Reduce Motion is off,
    /// AND Metal is available. The only check transition surfaces need; false ⇒ use the
    /// stock UIKit animation.
    public var isEnabled: Bool {
        AppearanceSettings.animatedTransitionsEnabled
            && !UIAccessibility.isReduceMotionEnabled
            && RabbitHoleTransitionView.isSupported
    }

    /// Build and park an overlay now so the first transition doesn't pay the Metal
    /// setup, texture-upload, CAMetalLayer drawable, or first command-buffer cost.
    /// Safe to call repeatedly; a no-op when Metal is unavailable.
    public func prewarm(in window: UIWindow) {
        guard RabbitHoleTransitionView.isSupported, parked.object(forKey: window) == nil,
              let view = RabbitHoleTransitionView.make() else { return }
        warmFirstFrame(of: view, in: window)
        view.isHidden = true
        view.alpha = 1
        view.frame = .zero
        view.clearTextures()
        view.removeFromSuperview()
        parked.setObject(view, forKey: window)
    }

    /// Render one tiny real frame through the same path used by transitions. Merely
    /// constructing the overlay compiles the pipeline, but the first visible wipe was
    /// still paying for layer attachment, texture creation, drawable allocation, and
    /// the first command buffer. Doing that work after launch makes the first user
    /// transition as smooth as the second.
    private func warmFirstFrame(of view: RabbitHoleTransitionView, in window: UIWindow) {
        guard let image = Self.warmupImage else { return }
        view.style = DotMatrixTransitionStyleProvider.style(for: window.traitCollection)
        view.direction = .random
        view.dissolvesOut = false
        view.frame = CGRect(x: 0, y: 0, width: 2, height: 2)
        view.alpha = 0.001
        view.isHidden = false
        window.addSubview(view)
        view.configure(before: image, after: image)
        window.layoutIfNeeded()
        view.setProgress(0.5)
    }

    private static let warmupImage: UIImage? = {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = min(UIScreen.main.scale, 2)
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2), format: format)
            .image { context in
                UIColor.black.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
            }
    }()

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
        view.dissolvesOut = false
        view.layer.cornerRadius = 0
        view.layer.masksToBounds = false
        view.clearTextures()
        view.isHidden = true
        view.removeFromSuperview()
        if let window, parked.object(forKey: window) == nil {
            parked.setObject(view, forKey: window)
        }
    }
}

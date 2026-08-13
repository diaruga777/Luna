//
//  ExtensionNavigationController.swift
//  LunaShareSurface
//

import UIKit

/// Told when a qualifying downward swipe asks the extension's sheet to go away.
/// The host answers on the same completion path every Done/Close affordance uses;
/// the navigation container only recognizes the gesture.
@MainActor
public protocol ExtensionSwipeDismissDelegate: AnyObject {
    func extensionNavigationControllerDidSwipeToDismiss(
        _ navigationController: ExtensionNavigationController)
}

/// The navigation container the extension surfaces put their screens in, and
/// the one place that decides how much of the sheet the header bar owns.
///
/// Automatic content-inset adjustment cannot handle this on its own. This
/// container is a child view controller living in someone else's window (the
/// extension host's), and a modern navigation bar draws over the content it
/// titles rather than standing above it. As a result, the screen underneath
/// can receive a safe area that its own bar still covers: a reader can open
/// with its title tucked under the bar, and a scroll indicator can begin its
/// track behind it.
///
/// To fix this, the controller measures the bar after every layout and adds
/// whatever it still overlaps to the visible screen's safe area. The
/// correction is zero when the runtime already accounted for the bar, and
/// zero while the bar is hidden (the extension reader's loading, saved, and
/// failure states hide it). So it only ever moves content out from under a
/// bar that is actually there.
public final class ExtensionNavigationController: UINavigationController,
    UIGestureRecognizerDelegate {

    /// The action extension's sheet-wide exit gesture needs both a real drag and
    /// a deliberate flick, so ordinary vertical scrolling does not close the
    /// extension by accident.
    public static let swipeDismissDistance: CGFloat = 96
    public static let swipeDismissVelocity: CGFloat = 900
    private static let swipeDismissVerticalBias: CGFloat = 1.15

    /// Enabled only by the app surfaces whose extensions support sheet-wide
    /// swipe dismissal. Keeping the recognizer off otherwise also leaves the
    /// reader extensions completely untouched.
    public var allowsSwipeDownToDismiss = false

    /// Told when the visible action-extension screen receives a qualifying
    /// downward swipe. Weak: the host owns this container, and the container
    /// does not own extension completion.
    public weak var swipeDismissDelegate: (any ExtensionSwipeDismissDelegate)?

    private lazy var swipeDownGesture: UIPanGestureRecognizer = {
        let gesture = UIPanGestureRecognizer(
            target: self, action: #selector(handleSwipeDown(_:)))
        gesture.delegate = self
        // Let scroll views and web views continue their own interaction while
        // this sheet-wide recognizer observes the same touch.
        gesture.cancelsTouchesInView = false
        return gesture
    }()
    private var peakDownwardVelocity: CGFloat = 0
    private var peakLateralVelocity: CGFloat = 0
    private var didRequestSwipeDismiss = false

    public override func viewDidLoad() {
        super.viewDidLoad()
        if allowsSwipeDownToDismiss {
            view.addGestureRecognizer(swipeDownGesture)
        }
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyHeaderInsetToVisibleScreen()
    }

    /// How much safe area a screen still needs before the bar stops covering it:
    /// how far down the bar reaches, less what UIKit already granted. Never
    /// negative — this only pushes content out from under the bar, and never
    /// crops a screen that was already clear of it.
    public static func additionalTopInset(
        barBottom: CGFloat, grantedSafeAreaTop: CGFloat
    ) -> CGFloat {
        max(0, barBottom - grantedSafeAreaTop)
    }

    private func applyHeaderInsetToVisibleScreen() {
        guard let screen = topViewController, screen.isViewLoaded else { return }
        // `safeAreaInsets` already includes any correction from a previous pass,
        // so take it back out to see what UIKit itself granted.
        let granted = screen.view.safeAreaInsets.top - screen.additionalSafeAreaInsets.top
        let needed = Self.additionalTopInset(
            barBottom: barBottom(in: screen.view), grantedSafeAreaTop: granted)
        guard abs(screen.additionalSafeAreaInsets.top - needed) > 0.5 else { return }
        screen.additionalSafeAreaInsets.top = needed
    }

    /// Pure threshold policy kept public so the extension's "anywhere" exit
    /// remains directly testable without synthesizing UIKit touch events.
    public static func shouldDismissOnSwipe(
        translationY: CGFloat,
        peakDownwardVelocity: CGFloat,
        peakLateralVelocity: CGFloat
    ) -> Bool {
        translationY >= swipeDismissDistance
            && peakDownwardVelocity >= swipeDismissVelocity
            && peakDownwardVelocity >= peakLateralVelocity * swipeDismissVerticalBias
    }

    /// Scroll views own their pan gestures. A touch that begins anywhere in a
    /// scroll view (including one of its descendants, such as a web view's
    /// internal content) must never be promoted to sheet dismissal.
    public static func isInsideScrollView(_ view: UIView?) -> Bool {
        var candidate = view
        while let current = candidate {
            if current is UIScrollView { return true }
            candidate = current.superview
        }
        return false
    }

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        guard gestureRecognizer === swipeDownGesture else { return true }
        return !Self.isInsideScrollView(touch.view)
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === swipeDownGesture else { return true }
        let pan = gestureRecognizer as! UIPanGestureRecognizer
        let velocity = pan.velocity(in: view)
        let translation = pan.translation(in: view)
        let x = velocity == .zero ? translation.x : velocity.x
        let y = velocity == .zero ? translation.y : velocity.y
        // Direction is decided as soon as the pan starts. The larger distance
        // and velocity thresholds are checked at the end of the gesture.
        return y > 0 && y >= abs(x) * Self.swipeDismissVerticalBias
    }

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer === swipeDownGesture || otherGestureRecognizer === swipeDownGesture
    }

    @objc private func handleSwipeDown(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            peakDownwardVelocity = 0
            peakLateralVelocity = 0
            didRequestSwipeDismiss = false
        case .changed, .ended:
            let velocity = gesture.velocity(in: view)
            peakDownwardVelocity = max(peakDownwardVelocity, velocity.y)
            peakLateralVelocity = max(peakLateralVelocity, abs(velocity.x))
            guard gesture.state == .ended, !didRequestSwipeDismiss else { return }
            guard Self.shouldDismissOnSwipe(
                translationY: gesture.translation(in: view).y,
                peakDownwardVelocity: peakDownwardVelocity,
                peakLateralVelocity: peakLateralVelocity
            ) else { return }
            didRequestSwipeDismiss = true
            swipeDismissDelegate?
                .extensionNavigationControllerDidSwipeToDismiss(self)
        case .cancelled, .failed:
            didRequestSwipeDismiss = false
        default:
            break
        }
    }

    /// The bar's bottom edge in `view`'s coordinate space, or zero when there is
    /// no bar on screen to clear.
    private func barBottom(in view: UIView) -> CGFloat {
        guard !isNavigationBarHidden, !navigationBar.isHidden,
              let container = navigationBar.superview
        else { return 0 }
        return container.convert(navigationBar.frame, to: view).maxY
    }
}

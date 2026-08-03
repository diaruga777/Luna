//
//  ExtensionNavigationController.swift
//  LunaShareSurface
//

import UIKit

/// The navigation container the extension surfaces put their screens in — and the
/// one place that decides how much of the sheet the header bar owns.
///
/// It cannot be left to the automatic content-inset adjustment. This container is
/// a CHILD view controller living in someone else's window (the extension host's),
/// and a modern navigation bar draws OVER the content it titles rather than
/// standing above it. Between those two, the screen underneath can be handed a
/// safe area that its own bar still covers, and everything measured from that safe
/// area then starts too high: a reader opens with its title tucked up under the
/// bar, and a scroll indicator begins its track behind it.
///
/// So the bar is MEASURED after every layout and whatever it still overlaps is
/// added to the visible screen's safe area. The correction is zero on a runtime
/// that already accounted for the bar, and zero while the bar is hidden (the
/// extension reader's own loading / saved / failure states hide it), so it can
/// only ever move content out from under a bar that is really there.
public final class ExtensionNavigationController: UINavigationController {

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

    /// The bar's bottom edge in `view`'s coordinate space, or zero when there is
    /// no bar on screen to clear.
    private func barBottom(in view: UIView) -> CGFloat {
        guard !isNavigationBarHidden, !navigationBar.isHidden,
              let container = navigationBar.superview
        else { return 0 }
        return container.convert(navigationBar.frame, to: view).maxY
    }
}

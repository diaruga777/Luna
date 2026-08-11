//
//  OnboardingPriceComparisonLesson.swift
//  Luna
//

import LunaDesignSystem
import LunaModels
import UIKit

/// The beats of the price tracker's Safari lesson. Every delay is scaled by
/// `OnboardingAnimationClock`, so `-slowOnboardingAnimations` walks through the
/// whole sequence.
enum OnboardingPriceComparisonTiming {
    /// The product page registers as a product page before anything is drawn
    /// over it — the extension's own lookup starts on `DOMContentLoaded`, so a
    /// pill that appeared with the page would read as part of the site.
    static let pageHoldDuration: TimeInterval = 0.9
    static let pillRevealDuration: TimeInterval = 0.28
    /// Once the black spotlight has zoomed in on the lookup, leave its
    /// searching state visible for a deliberate beat before replacing it with
    /// the comparable seller result.
    static let resultRevealDelay: TimeInterval = 1.0
    /// The comparison result reads on its own before the instructions popup
    /// arrives above it.
    static let instructionsDelay: TimeInterval = 0.5
    static let spotlightFadeDuration: TimeInterval = 0.3
    static let spotlightCollapseDuration: TimeInterval = 0.85
    static let cardRevealDuration: TimeInterval = 0.5
}

/// A native replica of the alternative-seller pill the Safari extension injects
/// (`content.js`, `sellerPillStyle`): fixed to the bottom-trailing corner of the
/// page, capsule, near-black at 85%, 13pt medium white.
///
/// It is drawn in UIKit rather than injected into the mock page's HTML for the
/// same reason the browser chrome around it is: the lesson animates the pill —
/// it grows from its waiting state into its answer, and a spotlight closes on
/// its exact frame — and a `<div>` inside a `WKWebView` is not something the
/// rest of the demonstration can measure or move.
final class OnboardingSellerPillView: UIView {
    /// The extension's own geometry, point for pixel.
    static let horizontalPadding: CGFloat = 14
    static let verticalPadding: CGFloat = 8
    static let dotDiameter: CGFloat = 6
    static let dotToTextGap: CGFloat = 8
    /// The page inset the extension uses (`right: 16px`).
    static let trailingInset: CGFloat = 16
    private static let font = UIFont.systemFont(ofSize: 13, weight: .medium)
    private static let pulseKey = "onboarding.sellerPill.dot"

    private let label = UILabel()
    private let dot = UIView()
    private(set) var isLooking = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityIdentifier =
            OnboardingStrings.Accessibility.safariPricePill.value()
        isAccessibilityElement = true
        backgroundColor = UIColor(
            red: 20 / 255, green: 20 / 255, blue: 26 / 255, alpha: 0.85)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 7
        layer.shadowOffset = CGSize(width: 0, height: 4)

        dot.backgroundColor = .white
        dot.layer.cornerRadius = Self.dotDiameter / 2
        dot.alpha = 0.6
        addSubview(dot)

        label.font = Self.font
        label.textColor = .white
        label.numberOfLines = 1
        label.text = OnboardingStrings.Safari.pricePillLooking.value()
        accessibilityLabel = label.text
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        var x = Self.horizontalPadding
        if isLooking {
            dot.frame = CGRect(
                x: x,
                y: ((bounds.height - Self.dotDiameter) / 2).rounded(),
                width: Self.dotDiameter,
                height: Self.dotDiameter)
            x += Self.dotDiameter + Self.dotToTextGap
        }
        label.frame = CGRect(
            x: x,
            y: 0,
            width: max(bounds.width - x - Self.horizontalPadding, 0),
            height: bounds.height)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let text = label.intrinsicContentSize
        let leading = isLooking ? Self.dotDiameter + Self.dotToTextGap : 0
        return CGSize(
            width: ceil(text.width) + leading + Self.horizontalPadding * 2,
            height: ceil(text.height) + Self.verticalPadding * 2)
    }

    /// The waiting dot. Web Animations in the extension, Core Animation here;
    /// the same 1.2s breath either way.
    func startLookingIndication() {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.3
        pulse.toValue = 1
        pulse.duration = 0.6
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dot.layer.add(pulse, forKey: Self.pulseKey)
    }

    /// Puts the pill back in its waiting state, so a second entry into the
    /// lesson looks for the price again rather than opening on the answer.
    func prepareToLookAgain() {
        guard !isLooking else { return }
        isLooking = true
        dot.isHidden = false
        dot.layer.removeAnimation(forKey: Self.pulseKey)
        label.text = OnboardingStrings.Safari.pricePillLooking.value()
        accessibilityLabel = label.text
        setNeedsLayout()
    }

    /// The answer takes the waiting pill's place rather than arriving beside it
    /// — the extension fills the same element in place, so the page's corner
    /// never jumps.
    func showFoundPrice(_ text: String) {
        guard isLooking else { return }
        isLooking = false
        dot.layer.removeAnimation(forKey: Self.pulseKey)
        UIView.transition(
            with: label,
            duration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.22,
            options: [.transitionCrossDissolve, .beginFromCurrentState]
        ) {
            self.label.text = text
            self.dot.isHidden = true
        }
        accessibilityLabel = text
    }
}

/// The 70%-black overlay with one circular hole in it, centred on whatever the
/// lesson is pointing at. The hole opens at the screen's full height — so the
/// first frame is barely a scrim at all, just darkness in the corners — and
/// closes to a small ring of air around the target.
///
/// The hole is an even-odd mask (bounds rect + circle) rather than four dimming
/// bands: only a mask can put a truly round edge on the light, and animating
/// one path into another of the same structure is what makes the close a single
/// continuous movement.
final class OnboardingSpotlightScrimView: UIView {
    static let dimAlpha: CGFloat = 0.7
    /// The air left around the target once the circle has closed.
    static let focusPadding: CGFloat = 12
    private static let collapseKey = "onboarding.spotlight.collapse"

    private let hole = CAShapeLayer()
    private var isCollapsed = false

    /// What the hole is centred on, in this view's own coordinates.
    var focusRect: CGRect = .zero {
        didSet {
            guard focusRect != oldValue else { return }
            setNeedsLayout()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityIdentifier =
            OnboardingStrings.Accessibility.safariPriceSpotlight.value()
        backgroundColor = UIColor.black.withAlphaComponent(Self.dimAlpha)
        hole.fillRule = .evenOdd
        layer.mask = hole
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// A circle as tall as the screen: the state the lesson opens on.
    var openRadius: CGFloat { bounds.height / 2 }

    /// The target's own circumscribed circle plus a little air.
    var collapsedRadius: CGFloat {
        hypot(focusRect.width, focusRect.height) / 2 + Self.focusPadding
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // A mask layer has no view to inherit UIKit's animation actions from,
        // so an assignment here would otherwise run Core Animation's own
        // implicit quarter-second fade against the explicit close below.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hole.frame = bounds
        hole.path = path(radius: isCollapsed ? collapsedRadius : openRadius)
        CATransaction.commit()
    }

    func collapse(completion: @escaping () -> Void) {
        layoutIfNeeded()
        let from = hole.path
        isCollapsed = true
        let to = path(radius: collapsedRadius)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hole.path = to
        CATransaction.commit()

        guard !UIAccessibility.isReduceMotionEnabled else {
            completion()
            return
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        let close = CABasicAnimation(keyPath: "path")
        close.fromValue = from
        close.toValue = to
        close.duration = OnboardingPriceComparisonTiming.spotlightCollapseDuration
        close.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        hole.add(close, forKey: Self.collapseKey)
        CATransaction.commit()
    }

    /// Reopens the hole to the full screen height for a replay: without this a
    /// second entry would start under a scrim that has already closed.
    func reopen() {
        hole.removeAnimation(forKey: Self.collapseKey)
        isCollapsed = false
        setNeedsLayout()
    }

    #if DEBUG
    var isCollapsedForTesting: Bool { isCollapsed }
    #endif

    private func path(radius: CGFloat) -> CGPath {
        let path = UIBezierPath(rect: bounds)
        let center = CGPoint(x: focusRect.midX, y: focusRect.midY)
        path.append(UIBezierPath(ovalIn: CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2)))
        return path.cgPath
    }
}

/// The price tracker's Safari lesson, played over the mock product page.
///
/// The explainer page every other app opens on argues for the extension in
/// prose. A price tracker can do something better: run the extension's actual
/// answer on an actual product page. The pill looks for other sellers, finds
/// one cheaper, and the screen then closes down to it — so the thing the lesson
/// is about to ask the user to switch on has already been seen working, on the
/// page they were already looking at.
///
/// The order used to be three layers: the pill is page content, the scrim
/// dims everything but the hole over that pill, and a setup card sat above
/// both. The card is gone — the ask now comes from the shared
/// `OnboardingSafariSetupPopupView`, hosted by the enclosing
/// `SafariReplicaViewController` rather than by this view — so the trick is
/// just the first two layers: the pill, and the spotlight that closes on it.
/// The popup's own 30% scrim stacks on top of this spotlight's 70% once it
/// arrives; both stay visible, deliberately darker where they overlap.
final class OnboardingPriceComparisonOverlayView: UIView {
    private enum Stage {
        case idle
        case looking
        case found
        case offering
    }

    /// The lesson has said everything it has to say: the comparison is on the
    /// page and the closed spotlight is holding it there. The host raises the
    /// shared popup the instant this fires.
    var onDidReachSetupOffer: (() -> Void)?

    /// Where the pill floats, measured up from the page's bottom edge: clear of
    /// the mock browser bar, with the same air over it the extension's own
    /// `20px + env(safe-area-inset-bottom)` leaves over Safari's.
    private static var pillBottomInset: CGFloat {
        SafariBottomBar.reservedPageHeight + 24
    }

    private let pill = OnboardingSellerPillView()
    private let spotlight = OnboardingSpotlightScrimView()
    private var stage = Stage.idle
    private var generation = 0

    init(configuration: OnboardingSurfaceConfiguration) {
        super.init(frame: .zero)
        backgroundColor = .clear

        pill.alpha = 0
        addSubview(pill)

        spotlight.alpha = 0
        addSubview(spotlight)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Nothing here answers a tap: the popup that ends the lesson is a
    /// separate, window-hosted view.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let pillSize = pill.sizeThatFits(bounds.size)
        pill.frame = CGRect(
            x: bounds.width - OnboardingSellerPillView.trailingInset - pillSize.width,
            y: bounds.height - Self.pillBottomInset - pillSize.height,
            width: pillSize.width,
            height: pillSize.height)
        spotlight.frame = bounds
        spotlight.focusRect = pill.frame
    }

    /// Runs the whole lesson: the lookup, its answer, and the spotlight
    /// closing on it — the setup offer fires the instant that closing lands.
    func begin(afterEnablingExtension: Bool = false) {
        guard stage == .idle else { return }
        stage = .looking
        generation += 1
        setNeedsLayout()
        layoutIfNeeded()

        if afterEnablingExtension {
            revealPill()
        } else {
            after(OnboardingPriceComparisonTiming.pageHoldDuration) { view in
                view.revealPill()
            }
        }
    }

    /// Rewinds to the page as it loads, so a second entry into the lesson plays
    /// the whole sequence rather than landing on its finished last frame. Also
    /// what the host's forever-loop uses to replay this lesson under the
    /// popup once the freeze ends.
    func reset() {
        generation += 1
        stage = .idle
        pill.alpha = 0
        pill.transform = .identity
        pill.prepareToLookAgain()
        spotlight.alpha = 0
        spotlight.reopen()
        accessibilityViewIsModal = false
        setNeedsLayout()
    }

    private func revealPill() {
        pill.startLookingIndication()
        let reveal = {
            self.pill.alpha = 1
            self.pill.transform = .identity
        }
        if UIAccessibility.isReduceMotionEnabled {
            reveal()
        } else {
            pill.transform = CGAffineTransform(translationX: 0, y: 8)
            UIView.animate(
                withDuration: OnboardingPriceComparisonTiming.pillRevealDuration,
                delay: 0,
                options: [.curveEaseOut, .beginFromCurrentState],
                animations: reveal)
        }
        // The spotlight sets out with the pill rather than after it. The lesson
        // is entered from the Manage Extensions sheet sliding away, and a beat
        // spent watching a searching pill in the corner before anything moved
        // toward it read as the demonstration having stalled. The searching
        // state is still held — the zoom's own fade, close and
        // `resultRevealDelay` are what hold it — so the answer still lands after
        // work the user has watched happen.
        zoomSpotlightOntoLookup()
    }

    /// The black overlay closes around the still-searching pill first. The
    /// answer is intentionally withheld until that zoom has landed, which makes
    /// the comparison feel like work the extension just completed rather than
    /// text that was waiting behind a transition.
    private func zoomSpotlightOntoLookup() {
        spotlight.layoutIfNeeded()
        let generation = self.generation
        UIView.animate(
            withDuration: UIAccessibility.isReduceMotionEnabled
                ? 0
                : OnboardingPriceComparisonTiming.spotlightFadeDuration,
            delay: 0,
            options: [.curveEaseOut, .beginFromCurrentState]
        ) {
            self.spotlight.alpha = 1
        } completion: { [weak self] _ in
            guard let self, generation == self.generation else { return }
            self.spotlight.collapse {}
        }
        after(
            OnboardingPriceComparisonTiming.spotlightFadeDuration
                + OnboardingPriceComparisonTiming.spotlightCollapseDuration
                + OnboardingPriceComparisonTiming.resultRevealDelay
        ) { view in
            view.showFoundPrice()
        }
    }

    private func showFoundPrice() {
        stage = .found
        pill.showFoundPrice(OnboardingStrings.Safari.pricePillFound(
            price: OnboardingStrings.Demo.amayzonSellerPrice.value(),
            seller: OnboardingStrings.Demo.amayzonSellerName.value()))
        // The pill grows into its answer where it stands: the trailing edge is
        // pinned, so the text arrives leftward out of the waiting state.
        let settle = {
            self.setNeedsLayout()
            self.layoutIfNeeded()
        }
        if UIAccessibility.isReduceMotionEnabled {
            settle()
        } else {
            UIView.animate(
                withDuration: 0.3,
                delay: 0,
                options: [.curveEaseOut, .beginFromCurrentState],
                animations: settle)
        }
        after(OnboardingPriceComparisonTiming.instructionsDelay) { view in
            view.reportSetupOffer()
        }
    }

    private func reportSetupOffer() {
        stage = .offering
        // The shared popup owns the interaction from here; the page behind it
        // is a finished demonstration, closed spotlight and all.
        accessibilityViewIsModal = true
        onDidReachSetupOffer?()
    }

    /// A generation-guarded, clock-scaled main-queue delay: anything scheduled
    /// before a reset is dropped rather than firing over the newer sequence.
    private func after(
        _ delay: TimeInterval,
        _ work: @escaping (OnboardingPriceComparisonOverlayView) -> Void
    ) {
        let generation = self.generation
        DispatchQueue.main.asyncAfter(
            deadline: .now() + OnboardingAnimationClock.delay(delay)
        ) { [weak self] in
            guard let self, generation == self.generation else { return }
            work(self)
        }
    }

    #if DEBUG
    var sellerPillForTesting: OnboardingSellerPillView { pill }
    var spotlightForTesting: OnboardingSpotlightScrimView { spotlight }
    #endif
}

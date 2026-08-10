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
    /// How long the mock fan-out "takes". The real one is a native round trip
    /// with an 18s budget; what matters here is that the spinner is up long
    /// enough to be read as work rather than as decoration.
    static let lookupDuration: TimeInterval = 2.4
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

/// The Safari setup instructions on a card of their own: the same three enable
/// steps and the same two actions the `luna.app` explainer prints down its page,
/// wearing the launch eclipse corona as its border.
///
/// It sizes itself to its contents — the widest step line, never wider than a
/// readable column — because it is a card over somebody else's page rather than
/// a page of its own, and a full-width panel here would read as the site having
/// been replaced.
final class OnboardingSafariSetupCardView: UIView {
    static let cornerRadius: CGFloat = 26
    private static let horizontalInset: CGFloat = 20
    private static let verticalInset: CGFloat = 22
    private static let headingHeight: CGFloat = 18
    private static let headingGap: CGFloat = 10
    private static let stepGap: CGFloat = 8
    private static let stepsToActionsGap: CGFloat = 18
    private static let pulseKey =
        "onboarding.priceLesson.attentionPulse"

    var onActivate: (() -> Void)?
    var onSkip: (() -> Void)?

    private let body = UIView()
    private var corona: EclipseCoronaView?
    private var activateCorona: EclipseCoronaView?
    private let heading = UILabel()
    private let stepTexts: [String]
    private let stepRows: [OnboardingSafariEnableStepRowView]
    private let actionsView = OnboardingSafariActionsView()
    private var isPulsing = false

    init(configuration: OnboardingSurfaceConfiguration) {
        let steps = OnboardingSafariExtensionCopy.steps(
            appName: configuration.demonstrationApp.displayName)
        stepTexts = steps.map(\.text)
        stepRows = steps.map(OnboardingSafariEnableStepRowView.init(step:))
        super.init(frame: .zero)
        accessibilityIdentifier =
            OnboardingStrings.Accessibility.safariSetupCard.value()
        clipsToBounds = false

        body.backgroundColor = LunaColors.background
        body.layer.cornerRadius = Self.cornerRadius
        body.layer.cornerCurve = .continuous
        body.clipsToBounds = true
        addSubview(body)

        heading.text = OnboardingSafariExtensionCopy.stepsHeading
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        heading.textColor = OnboardingSafariPagePalette.quietCopy
        heading.accessibilityIdentifier =
            OnboardingStrings.Accessibility.safariStepsHeading.value()
        body.addSubview(heading)

        for (index, row) in stepRows.enumerated() {
            row.isAccessibilityElement = true
            row.accessibilityLabel = stepTexts[index]
            row.accessibilityIdentifier =
                OnboardingStrings.Accessibility.safariStep(index)
            body.addSubview(row)
        }

        actionsView.onActivate = { [weak self] in
            self?.endPulse()
            self?.onActivate?()
        }
        actionsView.onSkip = { [weak self] in
            self?.endPulse()
            self?.onSkip?()
        }
        // Inert until the card is on screen: the lesson mounts it at alpha 0
        // while the page is still being demonstrated.
        actionsView.setActionsEnabled(false)
        body.addSubview(actionsView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Hugging, not filling: the card is as wide as its widest line of copy
    /// needs, bounded by a readable column and by the room it is given.
    func preferredSize(fitting available: CGSize) -> CGSize {
        let maximumWidth = min(available.width, LunaLayout.readableWidth)
        let maximumContent = max(maximumWidth - Self.horizontalInset * 2, 0)
        let textColumn = OnboardingSafariEnableStepRowView.visualColumnWidth
            + OnboardingSafariEnableStepRowView.visualToTextGap
        let naturalText = stepTexts.reduce(CGFloat.zero) { widest, text in
            max(widest, ceil((text as NSString).size(withAttributes: [
                .font: OnboardingSafariEnableStepRowView.labelFont,
            ]).width))
        }
        let naturalRow = textColumn + min(naturalText, max(maximumContent - textColumn, 0))
        let content = min(
            maximumContent,
            max(
                OnboardingSafariActionsView.minimumActivateWidth,
                max(naturalRow, ceil(heading.intrinsicContentSize.width))))
        let rowHeight = OnboardingSafariEnableStepRowView.preferredHeight
        let height = Self.verticalInset * 2
            + Self.headingHeight + Self.headingGap
            + CGFloat(stepRows.count) * rowHeight
            + CGFloat(max(stepRows.count - 1, 0)) * Self.stepGap
            + Self.stepsToActionsGap
            + OnboardingSafariActionsView.preferredHeight
        return CGSize(width: content + Self.horizontalInset * 2, height: height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        body.frame = bounds
        layOutCorona()
        let contentWidth = max(bounds.width - Self.horizontalInset * 2, 0)
        var y = Self.verticalInset
        heading.frame = CGRect(
            x: Self.horizontalInset,
            y: y,
            width: contentWidth,
            height: Self.headingHeight)
        y += Self.headingHeight + Self.headingGap
        for row in stepRows {
            row.frame = CGRect(
                x: Self.horizontalInset,
                y: y,
                width: contentWidth,
                height: OnboardingSafariEnableStepRowView.preferredHeight)
            y += OnboardingSafariEnableStepRowView.preferredHeight + Self.stepGap
        }
        y += Self.stepsToActionsGap - Self.stepGap
        actionsView.frame = CGRect(
            x: Self.horizontalInset,
            y: y,
            width: contentWidth,
            height: OnboardingSafariActionsView.preferredHeight)
        layOutActivateCorona()
    }

    /// The corona is the card's border, so it takes the card's own geometry and
    /// sits directly behind it. Rebuilt only when the card resizes — the raster
    /// is cached per geometry, and this card's geometry is settled long before
    /// it is ever shown.
    private func layOutCorona() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        if corona?.bounds.size != bounds.size {
            corona?.removeFromSuperview()
            let halo = EclipseCoronaView(
                bodySize: bounds.size,
                cornerRadius: Self.cornerRadius,
                tint: LunaSurfacePalette.atmosphereTint)
            insertSubview(halo, belowSubview: body)
            corona = halo
        }
        corona?.frame = bounds
    }

    /// The card has its own eclipse edge, while the actionable Safari control
    /// needs the Reader flow's tighter corona wrapped directly around its
    /// capsule. Keeping them separate makes the instruction card legible AND
    /// makes the exact button asking for a tap unmistakable.
    private func layOutActivateCorona() {
        let button = actionsView.activateButton
        let frame = body.convert(button.bounds, from: button)
        guard frame.width > 0, frame.height > 0 else { return }
        if activateCorona?.bounds.size != frame.size {
            activateCorona?.removeFromSuperview()
            let halo = EclipseCoronaView(
                bodySize: frame.size,
                cornerRadius: frame.height / 2,
                tint: LunaSurfacePalette.atmosphereTint)
            body.insertSubview(halo, belowSubview: actionsView)
            activateCorona = halo
            applyPulse()
        }
        activateCorona?.frame = frame
    }

    /// Brings the card up over the closed spotlight and asks for its tap.
    func present() {
        actionsView.setActionsEnabled(true)
        guard !UIAccessibility.isReduceMotionEnabled else {
            alpha = 1
            transform = .identity
            return
        }
        alpha = 0
        transform = CGAffineTransform(translationX: 0, y: 14)
            .scaledBy(x: 0.97, y: 0.97)
        UIView.animate(
            withDuration: OnboardingPriceComparisonTiming.cardRevealDuration,
            delay: 0,
            options: [.curveEaseOut, .beginFromCurrentState]
        ) {
            self.alpha = 1
            self.transform = .identity
        } completion: { [weak self] _ in
            self?.beginPulse()
        }
    }

    /// Takes the card back off screen and out of the interaction, inert, for a
    /// replay of the lesson.
    func prepareToPresentAgain() {
        endPulse()
        actionsView.setActionsEnabled(false)
        alpha = 0
        transform = .identity
    }

    /// Returning from Safari without the extension having run re-offers the
    /// card's actions — and asks for the tap again.
    func reactivateActions() {
        actionsView.setActionsEnabled(true)
        beginPulse()
    }

    /// The same breath the explainer page's own call to action wears, for the
    /// same reason it is not guarded on already-pulsing: Core Animation strips
    /// every animation off a layer when the app backgrounds, which is exactly
    /// what the hop out to Safari does.
    private func beginPulse() {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        isPulsing = true
        applyPulse()
    }

    private func applyPulse() {
        guard isPulsing else { return }
        actionsView.activateButton.layer.add(
            OnboardingAttentionPulse.scale(), forKey: Self.pulseKey)
        activateCorona?.layer.add(
            OnboardingAttentionPulse.scale(), forKey: "\(Self.pulseKey).coronaScale")
        activateCorona?.layer.add(
            OnboardingAttentionPulse.glow(
                from: OnboardingAttentionPulse.litCoronaTroughAlpha),
            forKey: "\(Self.pulseKey).coronaGlow")
    }

    private func endPulse() {
        isPulsing = false
        actionsView.activateButton.layer.removeAnimation(forKey: Self.pulseKey)
        activateCorona?.layer.removeAnimation(forKey: "\(Self.pulseKey).coronaScale")
        activateCorona?.layer.removeAnimation(forKey: "\(Self.pulseKey).coronaGlow")
    }

    #if DEBUG
    /// The flag, not the animations: Core Animation drops an animation off a
    /// backgrounded layer, so only this survives a test that spins the run loop.
    var isPulsingForTesting: Bool { isPulsing }
    var activateButtonForTesting: UIButton { actionsView.activateButton }
    #endif
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
/// The order of the three layers is the whole trick: the pill is page content,
/// the scrim dims everything but the hole over that pill, and the setup card
/// sits above both.
final class OnboardingPriceComparisonOverlayView: UIView {
    private enum Stage {
        case idle
        case looking
        case found
        case offering
    }

    var onActivateSafari: (() -> Void)?
    var onSkipSafariSetup: (() -> Void)?
    /// The lesson has said everything it has to say: the comparison is on the
    /// page and the setup card is coming up over it. Central Luna, which plays
    /// this lesson as one of three, uses it to hand over to the next sibling.
    var onDidReachSetupOffer: (() -> Void)?

    /// Where the pill floats, measured up from the page's bottom edge: clear of
    /// the mock browser bar, with the same air over it the extension's own
    /// `20px + env(safe-area-inset-bottom)` leaves over Safari's.
    private static var pillBottomInset: CGFloat {
        SafariBottomBar.reservedPageHeight + 24
    }
    /// What the card keeps clear of the closed circle.
    private static let cardToSpotlightGap: CGFloat = 24
    private static let cardEdgeInset: CGFloat = 24

    private let pill = OnboardingSellerPillView()
    private let spotlight = OnboardingSpotlightScrimView()
    private let card: OnboardingSafariSetupCardView
    private var stage = Stage.idle
    private var generation = 0

    init(configuration: OnboardingSurfaceConfiguration) {
        card = OnboardingSafariSetupCardView(configuration: configuration)
        super.init(frame: .zero)
        backgroundColor = .clear

        pill.alpha = 0
        addSubview(pill)

        spotlight.alpha = 0
        addSubview(spotlight)

        card.alpha = 0
        card.onActivate = { [weak self] in self?.onActivateSafari?() }
        card.onSkip = { [weak self] in self?.onSkipSafariSetup?() }
        addSubview(card)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Nothing here is in the way until the card is up: a tap that lands on the
    /// overlay itself belongs to whatever is under it.
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
        layOutCard()
    }

    /// The card fills the room ABOVE the closed circle, centred in what is left
    /// of it — the one place it can sit without covering the very pill the
    /// spotlight just isolated.
    private func layOutCard() {
        let available = CGSize(
            width: max(bounds.width - Self.cardEdgeInset * 2, 0),
            height: max(bounds.height - Self.cardEdgeInset * 2, 0))
        guard available.width > 0 else { return }
        let size = card.preferredSize(fitting: available)
        let ceiling = safeAreaInsets.top + Self.cardEdgeInset
        let floor = spotlight.focusRect.midY - spotlight.collapsedRadius
            - Self.cardToSpotlightGap
        // Centred in the room above the circle when there is room to centre it
        // in; otherwise as high as it may sit. The card is never SHRUNK to fit
        // — a clipped button is worse than a card that reaches down toward the
        // light it is standing over.
        let room = max(floor - ceiling, 0)
        let y = ceiling + max((room - size.height) / 2, 0)
        card.frame = CGRect(
            x: ((bounds.width - size.width) / 2).rounded(),
            y: y.rounded(),
            width: size.width,
            height: size.height)
    }

    /// Runs the whole lesson: the lookup, its answer, the spotlight closing on
    /// it, and the setup card over the top.
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
    /// the whole sequence rather than landing on its finished last frame.
    func reset() {
        generation += 1
        stage = .idle
        pill.alpha = 0
        pill.transform = .identity
        pill.prepareToLookAgain()
        spotlight.alpha = 0
        spotlight.reopen()
        card.prepareToPresentAgain()
        accessibilityViewIsModal = false
        setNeedsLayout()
    }

    /// The return leg from real Safari with nothing to show for it: the card's
    /// actions come back, and it asks again.
    func reactivateActions() {
        guard stage == .offering else { return }
        card.reactivateActions()
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
        after(OnboardingPriceComparisonTiming.lookupDuration) { view in
            view.zoomSpotlightOntoLookup()
        }
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
            view.presentSetupCard()
        }
    }

    private func presentSetupCard() {
        stage = .offering
        // The card owns the interaction from here; the page behind it is a
        // finished demonstration.
        accessibilityViewIsModal = true
        card.present()
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
    var setupCardForTesting: OnboardingSafariSetupCardView { card }
    var sellerPillForTesting: OnboardingSellerPillView { pill }
    var spotlightForTesting: OnboardingSpotlightScrimView { spotlight }
    #endif
}

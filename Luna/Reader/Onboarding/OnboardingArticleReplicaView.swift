//
//  OnboardingArticleReplicaView.swift
//  Luna
//

import LunaDesignSystem
import UIKit

private enum OnboardingArticleReplicaPalette {
    static let background = UIColor(
        red: 0.31, green: 0.32, blue: 0.34, alpha: 1)
    static let paper = UIColor(white: 0.98, alpha: 1)
    static let ink = UIColor(white: 0.10, alpha: 1)
    static let inkSecondary = UIColor(white: 0.44, alpha: 1)
}

enum OnboardingArticleReplicaTiming {
    /// The clean article registers before the takeover begins.
    static let contentHoldDuration: TimeInterval = 0.6
    /// Each piece of clutter arrives on its own beat.
    static let clutterStagger: TimeInterval = 0.14
    static let clutterEntranceDuration: TimeInterval = 0.52
    static let sheetEntranceDuration: TimeInterval = 0.56
    /// The fully blocked page holds before the cleanup runs on its own
    /// (a tap anywhere runs it early).
    static let blockedHoldDuration: TimeInterval = 1.0
    static let shatterDuration: TimeInterval = 0.86
    /// One continuous lunar edge crosses the whole page in this time; every
    /// element's reveal is cut from the same constant-speed front.
    static let revealSweepDuration: TimeInterval = 2.2
    /// Tiles detach just barely ahead of the arriving light — the same front
    /// shatters the clutter and brightens the text in one pass.
    static let shatterLeadDuration: TimeInterval = 0.08
}

/// Luna's fictional Safari article. The page loads clean and fully readable,
/// is then buried under an animated pile of ads, popups and a subscription
/// wall, and finally has the clutter shattered top-to-bottom while the same
/// lunar eclipse reveal that opened the app re-exposes the content beneath.
/// It is native instead of HTML so those glyph-level effects are possible.
final class OnboardingArticleReplicaView: UIView {
    static let fullArticleText = """
    Your article, your browsing history, and every page you save stay private. Luna strips away subscription popups, sticky ads, autoplay distractions, and the clutter that gets between you and the story. Unlock supported articles, keep clean copies for flights and dead zones, search everything you have saved, and return to the exact piece you wanted without retracing your browsing history. Read in a calm scrolling view or switch to the RSVP speed reader when you want to move quickly. Inline web sections preserve the useful context of the original page while the focused reader keeps the surrounding noise out of your way. Save links from Safari, Messages, the Share Sheet, Shortcuts, or the Action Button; organise them once and find them on every return. Send finished articles to Kindle, preserve useful documents, and keep the original link close whenever you need it. Luna handles ordinary stories, paywalled articles, PDFs, and other documents in the same reading list, so research does not disappear across a pile of open tabs. Search your collection instead of your browser history, revisit a clean offline copy on the train or in the air, and choose the reading pace that suits the moment. The extension works where you already browse, and one press is enough to move something worth keeping into a quieter place. Nothing needs an account just to build your own reading list, and the pages you keep remain yours to revisit offline.
    """

    var onActivateSafari: (() -> Void)?
    var onSkipSafariSetup: (() -> Void)?
    /// The staged post-reveal scroll is starting and will run this long — the
    /// browser chrome minimizes and hides alongside it, like real Safari.
    var onSetupScrollBegan: ((TimeInterval) -> Void)?

    private enum Stage {
        case pristine
        case cluttering
        case blocked
        case cleaning
        case revealed
    }

    /// Hosts the article content plus the below-the-fold setup card. It never
    /// scrolls under the user's finger — only the staged post-reveal scroll —
    /// so every coordinate the clutter and shatter use stays screen-fixed.
    private let scrollView = UIScrollView()
    private let setupCard = OnboardingSafariSetupCardView()
    private var setupCorona: EclipseCoronaView?
    private var setupCurtain: MoonRevealCurtainView?

    private let appIcon = MoonRevealImageView(
        image: OnboardingAppIcon.image()
            ?? UIImage(systemName: "moon.stars.fill"),
        occluderColor: OnboardingArticleReplicaPalette.background,
        cornerRadius: 17,
        initiallyRevealed: true)
    private let headline = MoonRevealLineView(
        text: "An article you want to read",
        initiallyRevealed: true,
        font: UIFont.systemFont(ofSize: 29, weight: .bold),
        textAlignment: .left,
        numberOfLines: 2,
        minimumScaleFactor: 0.82,
        occluderColor: OnboardingArticleReplicaPalette.background)
    private let byline = MoonRevealLineView(
        text: "A safari extension • by Luna",
        initiallyRevealed: true,
        font: .systemFont(ofSize: 13, weight: .semibold),
        textAlignment: .left,
        numberOfLines: 1,
        minimumScaleFactor: 0.9,
        occluderColor: OnboardingArticleReplicaPalette.background)
    private static func bundledEclipseComposite() -> UIImage? {
        guard let path = Bundle.main.path(
            forResource: "LunaEclipseComposite", ofType: "jpg")
        else { return nil }
        return UIImage(contentsOfFile: path)
    }
    private let eclipseImage = MoonRevealImageView(
        image: bundledEclipseComposite(),
        occluderColor: OnboardingArticleReplicaPalette.background,
        cornerRadius: 12,
        initiallyRevealed: true)
    private let body = MoonRevealLineView(
        text: "",
        initiallyRevealed: true,
        font: .systemFont(ofSize: 17, weight: .regular),
        textAlignment: .left,
        numberOfLines: 0,
        minimumScaleFactor: 1,
        lineSpacing: 5,
        occluderColor: OnboardingArticleReplicaPalette.background)

    private let clutterContainer = UIView()
    private let adBanners: [OnboardingAdBannerView] = [
        OnboardingAdBannerView(
            text: "🔥 80% OFF EVERYTHING — TODAY ONLY 🔥",
            colors: [
                UIColor(red: 1, green: 0.08, blue: 0.38, alpha: 1),
                UIColor(red: 1, green: 0.55, blue: 0.02, alpha: 1),
            ]),
        OnboardingAdBannerView(
            text: "You won't BELIEVE this one weird trick",
            colors: [
                UIColor(red: 0.58, green: 0.12, blue: 0.95, alpha: 1),
                UIColor(red: 0.95, green: 0.1, blue: 0.72, alpha: 1),
            ]),
        OnboardingAdBannerView(
            text: "WIN A FREE CRUISE 🚢 TAP NOW",
            colors: [
                UIColor(red: 0.02, green: 0.6, blue: 0.66, alpha: 1),
                UIColor(red: 0.05, green: 0.3, blue: 0.9, alpha: 1),
            ]),
        OnboardingAdBannerView(
            text: "HOT DEALS NEAR YOU ▸▸▸",
            colors: [
                UIColor(red: 0.1, green: 0.62, blue: 0.24, alpha: 1),
                UIColor(red: 0.72, green: 0.8, blue: 0.05, alpha: 1),
            ]),
    ]
    private let newsletterPopup = OnboardingNewsletterPopupView()
    private let subscriptionSheet = OnboardingSubscriptionSheetView()
    private let tapToClean = UITapGestureRecognizer()

    private var didStart = false
    private var stage = Stage.pristine
    private var sequenceGeneration = 0
    private var cleanupCompletion: (() -> Void)?
    private var fittedArticlePrefix = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = OnboardingArticleReplicaPalette.background
        accessibilityIdentifier = "onboarding.safari.lunaArticle"

        appIcon.accessibilityIdentifier = "onboarding.safari.article.appIcon"
        headline.accessibilityIdentifier = "onboarding.safari.article.headline"
        byline.accessibilityIdentifier = "onboarding.safari.article.byline"
        eclipseImage.accessibilityIdentifier =
            "onboarding.safari.article.eclipseImage"
        body.accessibilityIdentifier = "onboarding.safari.article.body"

        scrollView.isScrollEnabled = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        addSubview(scrollView)

        scrollView.addSubview(appIcon)
        scrollView.addSubview(headline)
        scrollView.addSubview(byline)
        scrollView.addSubview(eclipseImage)
        scrollView.addSubview(body)

        setupCard.onActivate = { [weak self] in self?.onActivateSafari?() }
        setupCard.onSkip = { [weak self] in self?.onSkipSafariSetup?() }
        scrollView.addSubview(setupCard)

        // Every fake obstruction is a decoration: nothing inside is
        // interactive, so a tap lands on the page and runs the cleanup.
        clutterContainer.isUserInteractionEnabled = false
        clutterContainer.accessibilityIdentifier =
            "onboarding.safari.article.clutter"
        addSubview(clutterContainer)
        for (index, ad) in adBanners.enumerated() {
            ad.accessibilityIdentifier = "onboarding.safari.article.ad.\(index)"
            ad.alpha = 0
            clutterContainer.addSubview(ad)
        }
        newsletterPopup.alpha = 0
        clutterContainer.addSubview(newsletterPopup)
        subscriptionSheet.alpha = 0
        clutterContainer.addSubview(subscriptionSheet)

        tapToClean.addTarget(self, action: #selector(pageTapped))
        tapToClean.isEnabled = false
        addGestureRecognizer(tapToClean)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        let horizontalInset: CGFloat = 24
        let contentWidth = bounds.width - horizontalInset * 2
        let browserChromeTop = bounds.height
            - SafariBottomBar.chromeHeight
            - 34
        let urlBarTop = browserChromeTop + 7

        appIcon.frame = CGRect(x: horizontalInset, y: 31, width: 68, height: 68)
        headline.frame = CGRect(
            x: appIcon.frame.maxX + 16,
            y: 27,
            width: bounds.width - appIcon.frame.maxX - horizontalInset - 16,
            height: 78)
        byline.frame = CGRect(
            x: horizontalInset,
            y: max(appIcon.frame.maxY, headline.frame.maxY) + 12,
            width: contentWidth,
            height: 22)
        // The NASA composite is 1920×708; showing it at its own aspect keeps
        // the seven eclipse phases unstretched.
        eclipseImage.frame = CGRect(
            x: horizontalInset,
            y: byline.frame.maxY + 14,
            width: contentWidth,
            height: (contentWidth * 708 / 1920).rounded())
        let bodyY = eclipseImage.frame.maxY + 14
        let bodyBottom = urlBarTop - 8
        let fittedBodyHeight = max(bodyBottom - bodyY, 44)
        // The card's resting place is measured from the WHOLE article so it
        // never moves: the body wears the viewport-fitted frame (and prefix)
        // until the cleanup swaps in the full text and the taller frame.
        let fullBodyHeight = max(
            Self.height(
                of: Self.fullArticleText,
                width: contentWidth,
                font: .systemFont(ofSize: 17, weight: .regular)),
            fittedBodyHeight)
        body.frame = CGRect(
            x: horizontalInset,
            y: bodyY,
            width: contentWidth,
            height: stage == .cleaning || stage == .revealed
                ? fullBodyHeight
                : fittedBodyHeight)

        scrollView.frame = bounds
        // A tight reading gap under the full text; the article copy is long
        // enough that this always lands below the fold (the max() is a
        // safety net for pathologically wide layouts, not the design).
        let cardFrame = CGRect(
            x: horizontalInset,
            y: max(bodyY + fullBodyHeight + 20, bounds.height + 16),
            width: contentWidth,
            height: OnboardingSafariSetupCardView.preferredHeight)
        setupCard.frame = cardFrame
        if setupCorona?.bounds.size != cardFrame.size {
            setupCorona?.removeFromSuperview()
            let corona = EclipseCoronaView(
                bodySize: cardFrame.size,
                cornerRadius: OnboardingSafariSetupCardView.cornerRadius,
                tint: LunaSurfacePalette.atmosphereTint)
            scrollView.insertSubview(corona, belowSubview: setupCard)
            setupCorona = corona
        }
        setupCorona?.frame = cardFrame
        scrollView.contentSize = CGSize(
            width: bounds.width,
            height: cardFrame.maxY + 130)

        clutterContainer.frame = bounds
        adBanners[0].frame = CGRect(
            x: 10, y: 6, width: bounds.width - 20, height: 60)
        adBanners[1].frame = CGRect(
            x: bounds.width - 158, y: 84, width: 148, height: 212)
        adBanners[2].frame = CGRect(
            x: 10, y: 232, width: 152, height: 196)
        adBanners[3].frame = CGRect(
            x: (bounds.width * 0.42).rounded(),
            y: 316,
            width: (bounds.width * 0.58).rounded() - 10,
            height: 86)
        let popupWidth = min(340, bounds.width - 56)
        newsletterPopup.frame = CGRect(
            x: ((bounds.width - popupWidth) / 2).rounded(),
            y: 178,
            width: popupWidth,
            height: 268)
        let sheetHeight = min(400, bounds.height * 0.48)
        subscriptionSheet.frame = CGRect(
            x: 0,
            y: bounds.height - sheetHeight,
            width: bounds.width,
            height: sheetHeight)

        if stage == .pristine || stage == .cluttering || stage == .blocked {
            let prefix = Self.prefix(
                of: Self.fullArticleText,
                fitting: body.bounds.size,
                font: .systemFont(ofSize: 17, weight: .regular))
            if prefix != fittedArticlePrefix {
                fittedArticlePrefix = prefix
                body.setText(prefix)
            }
        }
    }

    /// Plays the whole staged takeover: a clean readable beat, the clutter
    /// pile-on, the subscription wall, then the tap-or-timeout cleanup. The
    /// completion fires once the content has finished its re-reveal.
    func start(completion: @escaping () -> Void) {
        guard !didStart else {
            completion()
            return
        }
        didStart = true
        cleanupCompletion = completion
        layoutIfNeeded()
        afterDelay(OnboardingArticleReplicaTiming.contentHoldDuration) {
            $0.beginClutterInvasion()
        }
    }

    // MARK: - Clutter invasion

    private func beginClutterInvasion() {
        guard stage == .pristine else { return }
        stage = .cluttering
        let stagger = OnboardingArticleReplicaTiming.clutterStagger

        animateEntrance(adBanners[0], .slideFromLeft, delay: 0)
        animateEntrance(adBanners[1], .slideFromRight, delay: stagger)
        animateEntrance(adBanners[2], .slideFromLeft, delay: stagger * 2)
        animateEntrance(adBanners[3], .slideFromRight, delay: stagger * 3)
        animateEntrance(newsletterPopup, .pop, delay: stagger * 3 + 0.2)

        let sheetDelay = stagger * 3 + 0.5
        afterDelay(sheetDelay) { view in
            view.tapToClean.isEnabled = true
            view.animateEntrance(view.subscriptionSheet, .slideFromBottom, delay: 0)
            let settled = OnboardingArticleReplicaTiming.sheetEntranceDuration
                + OnboardingArticleReplicaTiming.blockedHoldDuration
            view.stage = .blocked
            view.afterDelay(settled) { $0.cleanUpClutter() }
        }
    }

    private enum Entrance {
        case slideFromLeft
        case slideFromRight
        case pop
        case slideFromBottom
    }

    private func animateEntrance(
        _ view: UIView, _ entrance: Entrance, delay: TimeInterval
    ) {
        if UIAccessibility.isReduceMotionEnabled {
            UIView.animate(
                withDuration: 0.2,
                delay: OnboardingAnimationClock.delay(delay),
                options: [.beginFromCurrentState]
            ) {
                view.alpha = 1
            }
            return
        }
        switch entrance {
        case .slideFromLeft:
            view.transform = CGAffineTransform(
                translationX: -(view.frame.maxX + 40), y: 0)
        case .slideFromRight:
            view.transform = CGAffineTransform(
                translationX: bounds.width - view.frame.minX + 40, y: 0)
        case .pop:
            view.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
        case .slideFromBottom:
            view.transform = CGAffineTransform(
                translationX: 0, y: view.frame.height + 40)
        }
        view.alpha = entrance == .pop ? 0 : 1
        let duration = entrance == .slideFromBottom
            ? OnboardingArticleReplicaTiming.sheetEntranceDuration
            : OnboardingArticleReplicaTiming.clutterEntranceDuration
        UIView.animate(
            withDuration: duration,
            delay: OnboardingAnimationClock.delay(delay),
            usingSpringWithDamping: entrance == .slideFromBottom ? 0.86 : 0.74,
            initialSpringVelocity: 0.2,
            options: [.curveEaseOut, .beginFromCurrentState]
        ) {
            view.alpha = 1
            view.transform = .identity
        }
    }

    @objc private func pageTapped() {
        cleanUpClutter()
    }

    // MARK: - Cleanup

    /// Shatters every obstruction in a single top-to-bottom sweep while the
    /// same descending lunar edge that opened the app re-reveals the content
    /// underneath.
    func cleanUpClutter(completion: (() -> Void)? = nil) {
        guard stage != .cleaning, stage != .revealed else {
            completion?()
            return
        }
        stage = .cleaning
        sequenceGeneration += 1
        tapToClean.isEnabled = false

        var shatterFinish: TimeInterval = 0
        for view in clutterContainer.subviews {
            shatterFinish = max(shatterFinish, shatter(view))
        }

        body.setText(Self.fullArticleText)
        setNeedsLayout()
        revealContentTopToBottom()
        mountSetupCurtain()

        // The page scrolls on to the setup card the moment the front reaches
        // the bottom of the SCREEN — the article now extends below the fold,
        // and that tail finishes its reveal while the scroll is already
        // carrying it up through the parked front.
        afterDelay(OnboardingArticleReplicaTiming.revealSweepDuration) { view in
            view.scrollToSetupCard {
                view.stage = .revealed
                let startCompletion = view.cleanupCompletion
                view.cleanupCompletion = nil
                startCompletion?()
                completion?()
            }
        }
    }

    /// Covers the below-the-fold setup card (and its corona) with the page
    /// background so the continuing front can uncover it with the same bright
    /// eclipse edge as the content above.
    private func mountSetupCurtain() {
        layoutIfNeeded()
        let top = body.frame.maxY + 2
        let curtain = MoonRevealCurtainView(
            fillColor: OnboardingArticleReplicaPalette.background)
        curtain.frame = CGRect(
            x: 0,
            y: top,
            width: bounds.width,
            height: max(scrollView.contentSize.height - top, 1))
        scrollView.addSubview(curtain)
        setupCurtain = curtain
    }

    /// The scroll continues the reveal at the front's exact speed: the edge
    /// parks at the bottom of the screen and the page flows up through it,
    /// the setup card brightening as it crosses.
    private func scrollToSetupCard(completion: @escaping () -> Void) {
        layoutIfNeeded()
        let chromeTop = bounds.height - SafariBottomBar.chromeHeight - 34
        let offset = CGPoint(
            x: 0,
            y: max(0, setupCard.frame.maxY + 20 - chromeTop))
        let frontSpeed = bounds.height
            / max(OnboardingArticleReplicaTiming.revealSweepDuration, 0.001)
        let duration = UIAccessibility.isReduceMotionEnabled
            ? 0.2
            : TimeInterval(offset.y / frontSpeed)
        onSetupScrollBegan?(duration)

        if let curtain = setupCurtain {
            if UIAccessibility.isReduceMotionEnabled {
                curtain.removeFromSuperview()
                setupCurtain = nil
            } else {
                // The front sits at the screen bottom (content y = height at
                // scroll start) and the curtain rises through it.
                let delay = max(
                    0,
                    TimeInterval((curtain.frame.minY - bounds.height) / frontSpeed))
                let revealDuration = TimeInterval(
                    (curtain.frame.height + 30) / frontSpeed)
                afterDelay(delay) { view in
                    view.setupCurtain?.reveal(duration: revealDuration) {
                        view.setupCurtain?.removeFromSuperview()
                        view.setupCurtain = nil
                    }
                }
            }
        }

        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: [.curveLinear, .beginFromCurrentState]
        ) {
            self.scrollView.contentOffset = offset
        } completion: { _ in
            completion()
        }
    }

    /// Returning from Safari without the extension having run re-offers the
    /// already-visible setup card.
    func reactivateSetupCard() {
        setupCard.setActionsEnabled(true)
    }

    /// Re-arms each content element and cuts its reveal from one shared
    /// constant-speed front: each view's edge begins exactly when the front
    /// reaches its top and exits exactly when the front passes its bottom, so
    /// the body's light visibly continues from the title's instead of every
    /// element replaying its own sweep.
    @discardableResult
    private func revealContentTopToBottom() -> TimeInterval {
        let height = max(bounds.height, 1)
        var finish: TimeInterval = 0
        let sweep = OnboardingArticleReplicaTiming.revealSweepDuration

        appIcon.prepareToRevealAgain()
        headline.prepareToRevealAgain()
        byline.prepareToRevealAgain()
        eclipseImage.prepareToRevealAgain()
        body.prepareToRevealAgain()
        layoutIfNeeded()

        let plans: [(view: UIView, reveal: (TimeInterval) -> Void)] = [
            (appIcon, { [appIcon] in appIcon.reveal(duration: $0) }),
            (headline, { [headline] in headline.reveal(duration: $0) { } }),
            (byline, { [byline] in byline.reveal(duration: $0) { } }),
            (eclipseImage, { [eclipseImage] in eclipseImage.reveal(duration: $0) }),
            (body, { [body] in body.reveal(duration: $0) { } }),
        ]
        for plan in plans {
            let frame = plan.view.frame
            // Each occluding circle starts ~22pt above its view's top (the
            // wide circle's sagitta) and travels to ~6pt past its bottom, so
            // the front's constant speed maps to these paddings.
            let delay = max(0, TimeInterval((frame.minY - 22) / height)) * sweep
            let duration = TimeInterval((frame.height + 28) / height) * sweep
            finish = max(finish, delay + duration)
            afterDelay(delay) { _ in plan.reveal(duration) }
        }
        return finish
    }

    /// Splits one obstruction into image tiles whose flight is staggered by
    /// their position in the downward sweep. Returns when its last tile lands.
    @discardableResult
    private func shatter(_ target: UIView) -> TimeInterval {
        guard target.alpha > 0.01 else {
            target.isHidden = true
            return 0
        }
        guard let snapshot = snapshot(of: target), let image = snapshot.cgImage
        else {
            target.isHidden = true
            return 0
        }
        let columns = min(max(Int(target.bounds.width / 56), 3), 8)
        let rows = min(max(Int(target.bounds.height / 56), 2), 8)
        let targetFrame = clutterContainer.convert(target.frame, to: self)
        let sweep = OnboardingArticleReplicaTiming.revealSweepDuration
        let lead = OnboardingArticleReplicaTiming.shatterLeadDuration
        let height = max(bounds.height, 1)
        var pieces: [(UIView, TimeInterval, CGAffineTransform)] = []

        for row in 0..<rows {
            for column in 0..<columns {
                let unit = CGRect(
                    x: CGFloat(column) / CGFloat(columns),
                    y: CGFloat(row) / CGFloat(rows),
                    width: 1 / CGFloat(columns),
                    height: 1 / CGFloat(rows))
                let frame = CGRect(
                    x: targetFrame.minX + unit.minX * targetFrame.width,
                    y: targetFrame.minY + unit.minY * targetFrame.height,
                    width: unit.width * targetFrame.width + 0.5,
                    height: unit.height * targetFrame.height + 0.5)
                let piece = UIView(frame: frame)
                piece.isUserInteractionEnabled = false
                piece.layer.contents = image
                piece.layer.contentsGravity = .resize
                piece.layer.contentsRect = unit
                piece.layer.contentsScale = snapshot.scale
                piece.layer.cornerRadius = 1.5
                addSubview(piece)

                // The front is a horizontal line travelling downward at the
                // reveal sweep's speed, detaching tiles a beat ahead of the
                // arriving light, with a small horizontal jitter so rows
                // don't detach in lockstep.
                let parity: CGFloat = (row + column).isMultiple(of: 2) ? 1 : -1
                let jitter = abs(frame.midX - bounds.midX) / max(bounds.width, 1)
                let delay = max(
                    0,
                    TimeInterval(frame.midY / height) * sweep - lead)
                    + TimeInterval(jitter) * 0.05
                let delta = CGPoint(
                    x: frame.midX - bounds.midX,
                    y: frame.midY + height)
                let distance = max(hypot(delta.x, delta.y), 1)
                let direction = CGPoint(
                    x: delta.x / distance,
                    y: delta.y / distance)
                let transform = CGAffineTransform(
                    translationX: direction.x * 86 + parity * 18,
                    y: direction.y * 86 + 42)
                    .rotated(by: parity * (0.28 + CGFloat(column % 3) * 0.11))
                    .scaledBy(x: 0.72, y: 0.72)
                pieces.append((piece, delay, transform))
            }
        }

        // The static tiles exactly cover the original, so it can vanish now —
        // hiding it later leaves a "copy" behind the already-flying tiles.
        target.isHidden = true
        let pieceDuration = OnboardingArticleReplicaTiming.shatterDuration * 0.54
        for (piece, delay, transform) in pieces {
            UIView.animate(
                withDuration: UIAccessibility.isReduceMotionEnabled
                    ? 0.18 : pieceDuration,
                delay: UIAccessibility.isReduceMotionEnabled
                    ? 0 : OnboardingAnimationClock.delay(delay),
                options: [.curveEaseOut, .beginFromCurrentState]
            ) {
                piece.transform = transform
                piece.alpha = 0
            } completion: { _ in
                piece.removeFromSuperview()
            }
        }
        return (pieces.map(\.1).max() ?? 0) + pieceDuration
    }

    private func snapshot(of view: UIView) -> UIImage? {
        guard view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = traitCollection.displayScale
        format.opaque = false
        return UIGraphicsImageRenderer(
            bounds: view.bounds, format: format
        ).image { context in
            view.layer.render(in: context.cgContext)
        }
    }

    /// A generation-guarded, clock-scaled main-queue delay: any step scheduled
    /// before a stage change (for example the tap-driven early cleanup) is
    /// silently dropped rather than firing over the newer stage.
    private func afterDelay(
        _ delay: TimeInterval, _ action: @escaping (OnboardingArticleReplicaView) -> Void
    ) {
        let generation = sequenceGeneration
        DispatchQueue.main.asyncAfter(
            deadline: .now() + OnboardingAnimationClock.delay(delay)
        ) { [weak self] in
            guard let self, self.sequenceGeneration == generation else { return }
            action(self)
        }
    }

    private static func height(
        of text: String,
        width: CGFloat,
        font: UIFont
    ) -> CGFloat {
        guard width > 0 else { return 0 }
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 5
        return ceil((text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font, .paragraphStyle: style],
            context: nil).height)
    }

    private static func prefix(
        of text: String,
        fitting size: CGSize,
        font: UIFont
    ) -> String {
        let words = text.split(separator: " ")
        guard !words.isEmpty, size.width > 0, size.height > 0 else { return "" }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: {
                let style = NSMutableParagraphStyle()
                style.lineSpacing = 5
                return style
            }(),
        ]
        var lower = 0
        var upper = words.count
        while lower < upper {
            let candidateCount = (lower + upper + 1) / 2
            let candidate = words.prefix(candidateCount).joined(separator: " ")
            let measured = (candidate as NSString).boundingRect(
                with: CGSize(width: size.width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes,
                context: nil)
            if measured.height <= size.height {
                lower = candidateCount
            } else {
                upper = candidateCount - 1
            }
        }
        return words.prefix(lower).joined(separator: " ")
    }
}

/// The article icon and banner image share the same descending lunar edge as
/// the nearby text. The image alpha is geometrically excluded inside the moon,
/// while a narrow luminous rim echoes the glyph-edge bloom.
private final class MoonRevealImageView: UIView {
    private let imageView = UIImageView()
    private let moonLayer = CAShapeLayer()
    private let revealMaskLayer = CAShapeLayer()
    private let rimLayer = CAShapeLayer()
    private let occluderColor: UIColor
    private var initialCircleFrame = CGRect.zero
    private var didReveal: Bool

    init(
        image: UIImage?,
        occluderColor: UIColor,
        cornerRadius: CGFloat,
        initiallyRevealed: Bool = false
    ) {
        self.occluderColor = occluderColor
        self.didReveal = initiallyRevealed
        super.init(frame: .zero)
        clipsToBounds = true
        isAccessibilityElement = initiallyRevealed
        accessibilityLabel = "Luna"

        imageView.image = image
        imageView.contentMode = .scaleAspectFill
        imageView.layer.cornerRadius = cornerRadius
        imageView.layer.cornerCurve = .continuous
        imageView.clipsToBounds = true
        addSubview(imageView)

        revealMaskLayer.fillColor = UIColor.white.cgColor
        revealMaskLayer.fillRule = .evenOdd

        moonLayer.fillColor = occluderColor.cgColor

        rimLayer.fillColor = UIColor.clear.cgColor
        rimLayer.strokeColor = UIColor.white.withAlphaComponent(0.88).cgColor
        rimLayer.lineWidth = 2.5
        rimLayer.shadowColor = UIColor.white.cgColor
        rimLayer.shadowOpacity = 0.9
        rimLayer.shadowRadius = 7
        rimLayer.shadowOffset = .zero

        guard !initiallyRevealed else { return }
        installOcclusion()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func installOcclusion() {
        imageView.layer.mask = revealMaskLayer
        layer.addSublayer(moonLayer)
        layer.addSublayer(rimLayer)
    }

    /// Returns an already-visible image to its occluded state so `reveal` can
    /// play again during the cleanup pass.
    func prepareToRevealAgain() {
        guard didReveal else { return }
        didReveal = false
        isAccessibilityElement = false
        installOcclusion()
        setNeedsLayout()
        layoutIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
        guard !didReveal, bounds.width > 0, bounds.height > 0 else { return }
        prepareLayers()
    }

    func reveal(duration: TimeInterval, completion: @escaping () -> Void = {}) {
        guard !didReveal else {
            completion()
            return
        }
        layoutIfNeeded()
        didReveal = true
        let travel = bounds.maxY + 6 - initialCircleFrame.minY
        let finalCircle = initialCircleFrame.offsetBy(dx: 0, dy: travel)
        let transform = CATransform3DMakeTranslation(0, travel, 0)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        moonLayer.transform = transform
        rimLayer.transform = transform
        revealMaskLayer.path = revealPath(excluding: finalCircle)
        CATransaction.commit()

        let resolvedDuration = UIAccessibility.isReduceMotionEnabled ? 0.24 : duration
        for layer in [moonLayer, rimLayer] {
            let animation = CABasicAnimation(keyPath: "transform")
            animation.fromValue = CATransform3DIdentity
            animation.toValue = transform
            animation.duration = resolvedDuration
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            layer.add(animation, forKey: "moonReveal")
        }

        let maskAnimation = CABasicAnimation(keyPath: "path")
        maskAnimation.fromValue = revealPath(excluding: initialCircleFrame)
        maskAnimation.toValue = revealPath(excluding: finalCircle)
        maskAnimation.duration = resolvedDuration
        maskAnimation.timingFunction = CAMediaTimingFunction(name: .linear)
        revealMaskLayer.add(maskAnimation, forKey: "moonReveal")

        DispatchQueue.main.asyncAfter(
            deadline: .now() + OnboardingAnimationClock.delay(resolvedDuration)
        ) { [weak self] in
            guard let self, self.didReveal else { return }
            self.imageView.layer.mask = nil
            self.moonLayer.removeFromSuperlayer()
            self.rimLayer.removeFromSuperlayer()
            self.isAccessibilityElement = true
            completion()
        }
    }

    private func prepareLayers() {
        let diameter = max(bounds.width * 8, 1_200)
        let radius = diameter / 2
        let halfWidth = bounds.width / 2
        let sagitta = radius - sqrt(max(radius * radius - halfWidth * halfWidth, 0))
        initialCircleFrame = CGRect(
            x: bounds.midX - radius,
            y: 4 - sagitta,
            width: diameter,
            height: diameter)
        let circle = UIBezierPath(ovalIn: initialCircleFrame).cgPath
        moonLayer.frame = bounds
        moonLayer.path = circle
        moonLayer.transform = CATransform3DIdentity
        rimLayer.frame = bounds
        rimLayer.path = circle
        rimLayer.transform = CATransform3DIdentity
        revealMaskLayer.frame = bounds
        revealMaskLayer.path = revealPath(excluding: initialCircleFrame)
    }

    private func revealPath(excluding circleFrame: CGRect) -> CGPath {
        let path = UIBezierPath(rect: bounds)
        path.append(UIBezierPath(ovalIn: circleFrame))
        path.usesEvenOddFillRule = true
        return path.cgPath
    }
}

/// An opaque page-coloured cover whose top edge is the same luminous lunar
/// rim as the reveal above: as the huge circle translates down, whatever the
/// curtain was hiding is uncovered behind the bright edge.
private final class MoonRevealCurtainView: UIView {
    private let occluder = CAShapeLayer()
    private let rim = CAShapeLayer()
    private var initialCircleFrame = CGRect.zero
    private var didReveal = false

    init(fillColor: UIColor) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        clipsToBounds = true

        occluder.fillColor = fillColor.cgColor
        layer.addSublayer(occluder)

        rim.fillColor = UIColor.clear.cgColor
        rim.strokeColor = UIColor.white.withAlphaComponent(0.88).cgColor
        rim.lineWidth = 2.5
        rim.shadowColor = UIColor.white.cgColor
        rim.shadowOpacity = 0.9
        rim.shadowRadius = 7
        rim.shadowOffset = .zero
        layer.addSublayer(rim)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !didReveal, bounds.width > 0, bounds.height > 0 else { return }
        let diameter = max(bounds.width * 8, 1_200)
        let radius = diameter / 2
        let halfWidth = bounds.width / 2
        let sagitta = radius - sqrt(max(radius * radius - halfWidth * halfWidth, 0))
        initialCircleFrame = CGRect(
            x: bounds.midX - radius,
            y: -2 - sagitta,
            width: diameter,
            height: diameter)
        let circle = UIBezierPath(ovalIn: initialCircleFrame).cgPath
        occluder.frame = bounds
        occluder.path = circle
        rim.frame = bounds
        rim.path = circle
    }

    func reveal(duration: TimeInterval, completion: @escaping () -> Void) {
        guard !didReveal else {
            completion()
            return
        }
        layoutIfNeeded()
        didReveal = true
        let travel = bounds.maxY + 8 - initialCircleFrame.minY
        let transform = CATransform3DMakeTranslation(0, travel, 0)
        let resolvedDuration = UIAccessibility.isReduceMotionEnabled
            ? 0.24 : duration

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        occluder.transform = transform
        rim.transform = transform
        CATransaction.commit()

        for layer in [occluder, rim] {
            let animation = CABasicAnimation(keyPath: "transform")
            animation.fromValue = CATransform3DIdentity
            animation.toValue = transform
            animation.duration = resolvedDuration
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            layer.add(animation, forKey: "moonReveal")
        }

        DispatchQueue.main.asyncAfter(
            deadline: .now() + OnboardingAnimationClock.delay(resolvedDuration)
        ) {
            completion()
        }
    }
}

/// One garish fake display ad: hot gradient, radial sunburst stripes, heavy
/// white copy. Deliberately the visual opposite of the page underneath.
final class OnboardingAdBannerView: UIView {
    private let gradient = CAGradientLayer()
    private let radialStripes = CAShapeLayer()
    private let label = UILabel()

    init(text: String, colors: [UIColor]) {
        super.init(frame: .zero)
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        clipsToBounds = true
        layer.borderWidth = 2
        layer.borderColor = UIColor.white.withAlphaComponent(0.92).cgColor

        gradient.colors = colors.map(\.cgColor)
        gradient.startPoint = CGPoint(x: 0, y: 0.25)
        gradient.endPoint = CGPoint(x: 1, y: 0.75)
        layer.insertSublayer(gradient, at: 0)

        radialStripes.fillColor = UIColor.white.withAlphaComponent(0.22).cgColor
        layer.insertSublayer(radialStripes, above: gradient)

        label.text = text
        label.font = .systemFont(ofSize: 19, weight: .heavy)
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 0
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.7
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = bounds
        layoutRadialStripes()
        label.frame = bounds.insetBy(dx: 14, dy: 8)
    }

    private func layoutRadialStripes() {
        let side = max(bounds.width, bounds.height) * 2.4
        radialStripes.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        radialStripes.position = CGPoint(x: bounds.midX, y: bounds.midY)

        let center = CGPoint(x: side / 2, y: side / 2)
        let radius = side * 0.7
        let stripeCount = 24
        let angle = CGFloat.pi * 2 / CGFloat(stripeCount)
        let path = UIBezierPath()
        for index in stride(from: 0, to: stripeCount, by: 2) {
            let start = -CGFloat.pi / 2 + CGFloat(index) * angle
            path.move(to: center)
            path.addArc(
                withCenter: center,
                radius: radius,
                startAngle: start,
                endAngle: start + angle,
                clockwise: true)
            path.close()
        }
        radialStripes.path = path.cgPath
    }
}

/// A pixel-faithful fake of the newsletter popups real sites throw over the
/// story: white card, email field, submit button. Nothing is interactive.
final class OnboardingNewsletterPopupView: UIView {
    private let title = UILabel()
    private let subtitle = UILabel()
    private let emailField = UIView()
    private let emailPlaceholder = UILabel()
    private let submitButton = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "onboarding.safari.article.newsletterPopup"
        backgroundColor = OnboardingArticleReplicaPalette.paper
        layer.cornerRadius = 18
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.5
        layer.shadowRadius = 26
        layer.shadowOffset = CGSize(width: 0, height: 14)

        title.text = "Subscribe to our newsletter"
        title.font = .systemFont(ofSize: 22, weight: .bold)
        title.textColor = OnboardingArticleReplicaPalette.ink
        title.textAlignment = .center
        title.numberOfLines = 2
        title.adjustsFontSizeToFitWidth = true
        title.minimumScaleFactor = 0.8
        title.accessibilityIdentifier =
            "onboarding.safari.article.newsletterTitle"
        addSubview(title)

        subtitle.text = "We promise to spam you"
        subtitle.font = .systemFont(ofSize: 15, weight: .regular)
        subtitle.textColor = OnboardingArticleReplicaPalette.inkSecondary
        subtitle.textAlignment = .center
        subtitle.accessibilityIdentifier =
            "onboarding.safari.article.newsletterSubtitle"
        addSubview(subtitle)

        emailField.backgroundColor = UIColor(white: 0.94, alpha: 1)
        emailField.layer.cornerRadius = 10
        emailField.layer.cornerCurve = .continuous
        emailField.layer.borderWidth = 1
        emailField.layer.borderColor = UIColor(white: 0.84, alpha: 1).cgColor
        emailField.accessibilityIdentifier =
            "onboarding.safari.article.newsletterEmail"
        addSubview(emailField)

        emailPlaceholder.text = "you@example.com"
        emailPlaceholder.font = .systemFont(ofSize: 16, weight: .regular)
        emailPlaceholder.textColor = UIColor(white: 0.62, alpha: 1)
        emailField.addSubview(emailPlaceholder)

        submitButton.text = "Subscribe"
        submitButton.font = .systemFont(ofSize: 17, weight: .semibold)
        submitButton.textColor = .white
        submitButton.textAlignment = .center
        submitButton.backgroundColor = UIColor(
            red: 0.07, green: 0.36, blue: 0.86, alpha: 1)
        submitButton.layer.cornerRadius = 10
        submitButton.layer.cornerCurve = .continuous
        submitButton.clipsToBounds = true
        submitButton.accessibilityIdentifier =
            "onboarding.safari.article.newsletterSubmit"
        addSubview(submitButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset: CGFloat = 22
        let width = bounds.width - inset * 2
        title.frame = CGRect(x: inset, y: 26, width: width, height: 56)
        subtitle.frame = CGRect(
            x: inset, y: title.frame.maxY + 4, width: width, height: 22)
        emailField.frame = CGRect(
            x: inset, y: subtitle.frame.maxY + 22, width: width, height: 46)
        emailPlaceholder.frame = emailField.bounds.insetBy(dx: 14, dy: 0)
        submitButton.frame = CGRect(
            x: inset, y: emailField.frame.maxY + 12, width: width, height: 48)
    }
}

/// The one real thing on the fake page: a mini deck card — the usual black
/// card surface riding the launch eclipse corona — sitting below the fold
/// with the extension explainer, the Activate Safari action, and the
/// skip-out.
final class OnboardingSafariSetupCardView: UIView {
    static let cornerRadius = CardSurfaceView.cornerRadius
    static let preferredHeight: CGFloat = 214

    var onActivate: (() -> Void)?
    var onSkip: (() -> Void)?

    private let surface = CardSurfaceView()
    private let content = UIView()
    private let explainer = UILabel()
    private let activateButton = UIButton(type: .system)
    private let skipButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "onboarding.safari.article.setupCard"

        surface.backgroundColor = .black
        surface.setBorderEnabled(true)
        addSubview(surface)
        content.backgroundColor = .black
        surface.installContentView(content)

        explainer.text = "Luna in Safari automatically gives you "
            + "the web experience you want"
        explainer.font = .systemFont(ofSize: 17, weight: .medium)
        explainer.textColor = .white
        explainer.textAlignment = .center
        explainer.numberOfLines = 3
        explainer.adjustsFontSizeToFitWidth = true
        explainer.minimumScaleFactor = 0.85
        explainer.accessibilityIdentifier =
            "onboarding.safari.article.setupExplainer"
        content.addSubview(explainer)

        activateButton.configuration = GlassStyle.actionButtonConfiguration(
            title: "Activate Safari",
            symbol: "safari.fill",
            prominent: true)
        activateButton.accessibilityLabel = "Activate Safari"
        activateButton.accessibilityIdentifier =
            "onboarding.safari.article.setupActivate"
        activateButton.addTarget(
            self, action: #selector(activateTapped), for: .touchUpInside)
        content.addSubview(activateButton)

        var skipConfiguration = UIButton.Configuration.plain()
        skipConfiguration.title = "Skip"
        skipConfiguration.baseForegroundColor =
            UIColor.white.withAlphaComponent(0.62)
        skipConfiguration.contentInsets = NSDirectionalEdgeInsets(
            top: 8, leading: 14, bottom: 8, trailing: 14)
        skipConfiguration.titleTextAttributesTransformer =
            UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.font = .systemFont(ofSize: 16, weight: .medium)
                return outgoing
            }
        skipButton.configuration = skipConfiguration
        skipButton.accessibilityLabel = "Skip"
        skipButton.accessibilityIdentifier =
            "onboarding.safari.article.setupSkip"
        skipButton.addTarget(
            self, action: #selector(skipTapped), for: .touchUpInside)
        content.addSubview(skipButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        surface.frame = bounds
        surface.layoutIfNeeded()
        let inset: CGFloat = 22
        let width = bounds.width - inset * 2
        explainer.frame = CGRect(x: inset, y: 20, width: width, height: 66)
        let skipSize = skipButton.sizeThatFits(
            CGSize(width: width, height: 44))
        skipButton.frame = CGRect(
            x: (bounds.width - max(80, skipSize.width)) / 2,
            y: bounds.height - max(38, skipSize.height) - 12,
            width: max(80, skipSize.width),
            height: max(38, skipSize.height))
        let buttonSize = activateButton.sizeThatFits(
            CGSize(width: width, height: 56))
        let buttonWidth = min(width, max(186, buttonSize.width))
        activateButton.frame = CGRect(
            x: (bounds.width - buttonWidth) / 2,
            y: skipButton.frame.minY - max(52, buttonSize.height) - 8,
            width: buttonWidth,
            height: max(52, buttonSize.height))
    }

    func setActionsEnabled(_ enabled: Bool) {
        activateButton.isUserInteractionEnabled = enabled
        skipButton.isUserInteractionEnabled = enabled
    }

    @objc private func activateTapped() {
        setActionsEnabled(false)
        onActivate?()
    }

    @objc private func skipTapped() {
        setActionsEnabled(false)
        onSkip?()
    }
}

/// A fake of the full-width subscription wall news sites slide over the
/// bottom of an article. Nothing is interactive.
final class OnboardingSubscriptionSheetView: UIView {
    private let grabber = UIView()
    private let title = UILabel()
    private let bodyText = UILabel()
    private let subscribeButton = UILabel()
    private let signIn = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "onboarding.safari.article.subscriptionSheet"
        backgroundColor = OnboardingArticleReplicaPalette.paper
        layer.cornerRadius = 28
        layer.cornerCurve = .continuous
        layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.55
        layer.shadowRadius = 30
        layer.shadowOffset = CGSize(width: 0, height: -12)

        grabber.backgroundColor = UIColor(white: 0.82, alpha: 1)
        grabber.layer.cornerRadius = 2.5
        addSubview(grabber)

        title.text = "Subscribe to keep reading"
        title.font = .systemFont(ofSize: 24, weight: .bold)
        title.textColor = OnboardingArticleReplicaPalette.ink
        title.textAlignment = .center
        title.numberOfLines = 2
        title.adjustsFontSizeToFitWidth = true
        title.minimumScaleFactor = 0.8
        title.accessibilityIdentifier =
            "onboarding.safari.article.subscriptionTitle"
        addSubview(title)

        bodyText.text = "You've reached your free article limit for this "
            + "month. Get unlimited access to independent journalism."
        bodyText.font = .systemFont(ofSize: 15, weight: .regular)
        bodyText.textColor = OnboardingArticleReplicaPalette.inkSecondary
        bodyText.textAlignment = .center
        bodyText.numberOfLines = 3
        bodyText.accessibilityIdentifier =
            "onboarding.safari.article.subscriptionBody"
        addSubview(bodyText)

        subscribeButton.text = "Subscribe for $4.99/month"
        subscribeButton.font = .systemFont(ofSize: 17, weight: .semibold)
        subscribeButton.textColor = .white
        subscribeButton.textAlignment = .center
        subscribeButton.backgroundColor = OnboardingArticleReplicaPalette.ink
        subscribeButton.layer.cornerRadius = 12
        subscribeButton.layer.cornerCurve = .continuous
        subscribeButton.clipsToBounds = true
        subscribeButton.accessibilityIdentifier =
            "onboarding.safari.article.subscriptionSubmit"
        addSubview(subscribeButton)

        signIn.text = "Already a subscriber? Sign in"
        signIn.font = .systemFont(ofSize: 14, weight: .medium)
        signIn.textColor = UIColor(red: 0.07, green: 0.36, blue: 0.86, alpha: 1)
        signIn.textAlignment = .center
        signIn.accessibilityIdentifier =
            "onboarding.safari.article.subscriptionSignIn"
        addSubview(signIn)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset: CGFloat = 26
        let width = bounds.width - inset * 2
        grabber.frame = CGRect(
            x: (bounds.width - 36) / 2, y: 8, width: 36, height: 5)
        title.frame = CGRect(x: inset, y: 30, width: width, height: 60)
        bodyText.frame = CGRect(
            x: inset, y: title.frame.maxY + 6, width: width, height: 62)
        subscribeButton.frame = CGRect(
            x: inset, y: bodyText.frame.maxY + 16, width: width, height: 52)
        signIn.frame = CGRect(
            x: inset,
            y: subscribeButton.frame.maxY + 14,
            width: width,
            height: 20)
    }
}

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
    static let shatterDuration: TimeInterval = 0.86
    /// The cascade edge's speed down each element. Much brisker than the
    /// intro line's own ~46pt/s — the page is tall — while the bloom's
    /// falloff bands stretch with the ratio, so every glyph's
    /// brighten-and-cool still takes exactly the intro's TIME; only the
    /// edge travels faster.
    static let cascadeFrontSpeed: CGFloat = 140
    /// The next element's reveal sets out when the one above it is this far
    /// through — the cascade equivalent of the intro's reading beat between
    /// its two lines.
    static let cascadeOverlap: Double = 0.35
    /// The setup-card curtain has no light of its own, so it need not crawl
    /// at the cascade's pace; it just slides off within this long.
    static let curtainMaxDuration: TimeInterval = 0.8
}

/// Luna's fictional Safari article. The page loads already buried under ads,
/// popups and a subscription wall; once the mock extension-enable sequence
/// completes, the clutter is shattered top-to-bottom while the content
/// beneath reveals as a cascade of the SAME lunar reveals that opened the
/// app — element by element at the intro's own pace, the setup card last.
/// It is native instead of HTML so those glyph-level effects are possible.
final class OnboardingArticleReplicaView: UIView {
    static let fullArticleText = OnboardingLunaArticleCopy.plainText

    var onActivateSafari: (() -> Void)?
    var onSkipSafariSetup: (() -> Void)?

    private enum Stage {
        case blocked
        /// Everything heavy is done and committed: the clutter is swapped for
        /// still tiles, the content re-occluded, the light rasters drawn. The
        /// sweep can now start with nothing left to stall its first frames.
        case primed
        case cleaning
        case revealed
    }

    private struct ShatterPiece {
        let view: UIView
        let midY: CGFloat
        var arrival: TimeInterval
        let scatter: TimeInterval
        let flight: CGAffineTransform

        var delay: TimeInterval { arrival + scatter }
    }

    /// One stretch of the cascading front: within [top, bottom] the light
    /// arrives at `start + (y - top) / speed`. Tiles look their own page-y
    /// up in these legs so every tile detaches exactly when the light below
    /// it arrives, even though each element runs its own intro-paced reveal.
    private struct FrontLeg {
        let top: CGFloat
        let bottom: CGFloat
        let start: TimeInterval
        let speed: CGFloat

        func arrival(at y: CGFloat) -> TimeInterval {
            start + TimeInterval(max(0, min(y, bottom) - top) / speed)
        }
    }

    private struct CascadeEntry {
        let start: TimeInterval
        let duration: TimeInterval
        let reveal: (TimeInterval) -> Void
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
        text: OnboardingLunaArticleCopy.title,
        initiallyRevealed: true,
        font: UIFont.systemFont(ofSize: 29, weight: .bold),
        textAlignment: .left,
        numberOfLines: 2,
        minimumScaleFactor: 0.82,
        occluderColor: OnboardingArticleReplicaPalette.background)
    private let byline = MoonRevealLineView(
        text: OnboardingLunaArticleCopy.byline,
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

    private var stage = Stage.blocked
    private var sequenceGeneration = 0
    private var preparedShatterPieces: [ShatterPiece] = []
    private var revealSchedule: [CascadeEntry] = []
    private var frontLegs: [FrontLeg] = []
    private var curtainSchedule: (start: TimeInterval, duration: TimeInterval) = (0, 0)

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

        // Every fake obstruction is a decoration, buried over the page from
        // the very first frame; the mock extension-enable pass clears them.
        clutterContainer.isUserInteractionEnabled = false
        clutterContainer.accessibilityIdentifier =
            "onboarding.safari.article.clutter"
        addSubview(clutterContainer)
        for (index, ad) in adBanners.enumerated() {
            ad.accessibilityIdentifier = "onboarding.safari.article.ad.\(index)"
            clutterContainer.addSubview(ad)
        }
        clutterContainer.addSubview(newsletterPopup)
        clutterContainer.addSubview(subscriptionSheet)
        body.setText(Self.fullArticleText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        let horizontalInset: CGFloat = 24
        let contentWidth = bounds.width - horizontalInset * 2

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
        // The copy is deliberately short: article and setup card share one
        // screen, so the wipe alone brings the card into view — no scroll.
        body.frame = CGRect(
            x: horizontalInset,
            y: eclipseImage.frame.maxY + 14,
            width: contentWidth,
            height: Self.height(
                of: Self.fullArticleText,
                width: contentWidth,
                font: .systemFont(ofSize: 17, weight: .regular)))

        scrollView.frame = bounds
        let cardFrame = CGRect(
            x: horizontalInset,
            y: body.frame.maxY + 20,
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
            height: max(bounds.height, cardFrame.maxY + 16))

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
    }

    // MARK: - Cleanup

    /// Everything expensive the wipe needs, done ahead of it while the page
    /// is still covered (the extension-enable pass calls this under the
    /// Manage Extensions sheet): swaps each obstruction for still image
    /// tiles, re-occludes the content and draws every element's light raster.
    /// Idempotent; `cleanUpClutter` runs it if the host didn't.
    func prepareCleanUp() {
        guard stage == .blocked else { return }
        stage = .primed
        sequenceGeneration += 1
        layoutIfNeeded()

        appIcon.prepareToRevealAgain()
        headline.prepareToRevealAgain()
        byline.prepareToRevealAgain()
        eclipseImage.prepareToRevealAgain()
        body.prepareToRevealAgain()
        layoutIfNeeded()
        computeCascade()
        preparedShatterPieces = clutterContainer.subviews.flatMap {
            buildShatterPieces(for: $0)
        }
        // Strictly top-to-bottom, across every view at once: the cascade's
        // overlapping legs make raw arrival dip at element boundaries (a
        // lower element's light sets out while the one above is still
        // mid-crossing), and those dips read as a chunk mid-popup flying
        // before the rows above it. A running maximum down the page keeps
        // each tile at or after every tile above it; the dipped stretches
        // just detach together, textured by their scatter.
        preparedShatterPieces.sort { $0.midY < $1.midY }
        var runningArrival: TimeInterval = 0
        for index in preparedShatterPieces.indices {
            runningArrival = max(
                runningArrival, preparedShatterPieces[index].arrival)
            preparedShatterPieces[index].arrival = runningArrival
        }
    }

    /// THE ARTICLE IS THE INTRO'S ANIMATION, ELEMENT BY ELEMENT. Every
    /// element's edge crosses it at `cascadeFrontSpeed`, a brisk multiple
    /// of the intro line's pace whose band stretch keeps each glyph's
    /// brighten-and-cool at the intro's exact TIME — the same deliberate
    /// light of “You want to read more.”, just a faster-travelling edge.
    /// The reveals cascade: the icon and headline set out together (they
    /// share the first row), and each following element sets out when the
    /// one above it is `cascadeOverlap` through, echoing the intro's
    /// line-after-line rhythm. The tiles and the setup-card curtain are cut
    /// from the same schedule so nothing leads or trails the light.
    private func computeCascade() {
        let speed = OnboardingArticleReplicaTiming.cascadeFrontSpeed
        let rows: [[(view: UIView, crossing: CGFloat, reveal: (TimeInterval) -> Void)]] = [
            [
                (appIcon, appIcon.revealFrontCrossingDistance,
                 { [appIcon] in appIcon.reveal(duration: $0) }),
                (headline, headline.revealFrontCrossingDistance,
                 { [headline] in headline.reveal(duration: $0) { } }),
            ],
            [
                (byline, byline.revealFrontCrossingDistance,
                 { [byline] in byline.reveal(duration: $0) { } }),
            ],
            [
                (eclipseImage, eclipseImage.revealFrontCrossingDistance,
                 { [eclipseImage] in eclipseImage.reveal(duration: $0) }),
            ],
            [
                (body, body.revealFrontCrossingDistance,
                 { [body] in body.reveal(duration: $0) { } }),
            ],
        ]

        revealSchedule = []
        frontLegs = []
        var rowStart: TimeInterval = 0
        var previousRowDuration: TimeInterval = 0
        for (index, row) in rows.enumerated() {
            if index > 0 {
                rowStart += previousRowDuration
                    * OnboardingArticleReplicaTiming.cascadeOverlap
            }
            var rowDuration: TimeInterval = 0
            for element in row {
                let duration = TimeInterval(element.crossing / speed)
                rowDuration = max(rowDuration, duration)
                revealSchedule.append(CascadeEntry(
                    start: rowStart, duration: duration, reveal: element.reveal))
                // The icon shares its row with the wider headline; the
                // headline's leg covers that band of the page for tiles.
                if element.view !== appIcon {
                    frontLegs.append(FrontLeg(
                        top: element.view.frame.minY,
                        bottom: element.view.frame.maxY,
                        start: rowStart,
                        speed: element.crossing
                            / CGFloat(max(duration, 0.001))))
                }
            }
            previousRowDuration = rowDuration
        }

        let curtainTop = body.frame.maxY + 2
        let curtainBottom = max(scrollView.contentSize.height, curtainTop + 1)
        let curtainCrossing = curtainBottom - curtainTop + 2
        let curtainDuration = min(
            TimeInterval(curtainCrossing / speed),
            OnboardingArticleReplicaTiming.curtainMaxDuration)
        curtainSchedule = (
            start: rowStart + previousRowDuration
                * OnboardingArticleReplicaTiming.cascadeOverlap,
            duration: curtainDuration)
        frontLegs.append(FrontLeg(
            top: curtainTop,
            bottom: curtainBottom,
            start: curtainSchedule.start,
            speed: curtainCrossing / CGFloat(max(curtainDuration, 0.001))))
    }

    /// When the cascading light reaches a page-level y: inside an element,
    /// its own leg answers; in the dead space between elements, the next
    /// leg's start does (its `arrival` clamps y above its top).
    private func frontArrival(atPageY y: CGFloat) -> TimeInterval {
        for leg in frontLegs where y <= leg.bottom {
            return leg.arrival(at: y)
        }
        return frontLegs.last.map { $0.arrival(at: $0.bottom) } ?? 0
    }

    /// Shatters every obstruction top-to-bottom while the content underneath
    /// reveals as a cascade of INTRO reveals — each element crossed by the
    /// same descending lunar edge, at the same speed, with the same light as
    /// “You want to read more.” — the setup card included, since everything
    /// shares one screen.
    ///
    /// The cascade starts one run-loop turn after `prepareCleanUp`'s work,
    /// never in the same turn: the preparation's heavy commit (tiles,
    /// occluders, rasters) otherwise lands between an animation's added
    /// wall-clock anchor and its first rendered frame, and the reveals at
    /// the top of the page — shine and all — start already finished.
    func cleanUpClutter(completion: (() -> Void)? = nil) {
        guard stage == .blocked || stage == .primed else {
            completion?()
            return
        }
        prepareCleanUp()
        stage = .cleaning

        afterDelay(0) { view in
            let shatterFinish = view.animatePreparedShatterPieces()
            let revealFinish = view.revealContentTopToBottom()
            let curtainFinish = view.revealSetupCardBehindCurtain()

            view.afterDelay(
                max(revealFinish, max(curtainFinish, shatterFinish)) + 0.05
            ) { view in
                view.stage = .revealed
                view.setupCard.setActionsEnabled(true)
                completion?()
            }
        }
    }

    /// Covers the setup card (and its corona) with the page background and
    /// sweeps the cover away as the shared front passes over it, so the card
    /// comes out from the same invisible edge as the content above. Returns
    /// when the curtain has fully cleared.
    private func revealSetupCardBehindCurtain() -> TimeInterval {
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

        if UIAccessibility.isReduceMotionEnabled {
            curtain.removeFromSuperview()
            setupCurtain = nil
            return 0
        }

        curtain.layoutIfNeeded()
        let schedule = curtainSchedule
        afterDelay(schedule.start) { view in
            view.setupCurtain?.reveal(duration: schedule.duration) {
                view.setupCurtain?.removeFromSuperview()
                view.setupCurtain = nil
            }
        }
        return schedule.start + schedule.duration
    }

    /// Returning from Safari without the extension having run re-offers the
    /// already-visible setup card.
    func reactivateSetupCard() {
        setupCard.setActionsEnabled(true)
    }

    /// Plays the cascade computed in `prepareCleanUp`: each element's reveal
    /// is the intro's own animation, staggered down the page.
    @discardableResult
    private func revealContentTopToBottom() -> TimeInterval {
        var finish: TimeInterval = 0
        for entry in revealSchedule {
            finish = max(finish, entry.start + entry.duration)
            afterDelay(entry.start) { _ in entry.reveal(entry.duration) }
        }
        return finish
    }

    /// Splits one obstruction into still image tiles that exactly cover it,
    /// each carrying the flight (delay and transform) the sweep will give it.
    /// Nothing moves yet — this is the wipe's preparation half.
    private func buildShatterPieces(for target: UIView) -> [ShatterPiece] {
        guard target.alpha > 0.01 else {
            target.isHidden = true
            return []
        }
        guard let snapshot = snapshot(of: target), let image = snapshot.cgImage
        else {
            target.isHidden = true
            return []
        }
        // ~11pt tiles: fine enough that the crumble reads as grains, not
        // pieces — larger tiles came off as discernible slabs.
        let columns = min(max(Int(target.bounds.width / 11), 4), 36)
        let rows = min(max(Int(target.bounds.height / 11), 3), 36)
        let targetFrame = clutterContainer.convert(target.frame, to: self)
        let height = max(bounds.height, 1)
        var pieces: [ShatterPiece] = []

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

                // Each tile detaches the moment the cascading light beneath
                // its center arrives, plus a deterministic 0–33ms TRAILING
                // scatter: it breaks the row-at-a-time lockstep so the
                // crumble reads as continuous, and because it only ever
                // trails, no tile flies before the light has arrived.
                let parity: CGFloat = (row + column).isMultiple(of: 2) ? 1 : -1
                let scatter = TimeInterval((row * 3 + column * 7) % 4) * 0.011
                let arrival = frontArrival(atPageY: frame.midY)
                let delta = CGPoint(
                    x: frame.midX - bounds.midX,
                    y: frame.midY + height)
                let distance = max(hypot(delta.x, delta.y), 1)
                let direction = CGPoint(
                    x: delta.x / distance,
                    y: delta.y / distance)
                let flight = CGAffineTransform(
                    translationX: direction.x * 86 + parity * 18,
                    y: direction.y * 86 + 42)
                    .rotated(by: parity * (0.28 + CGFloat(column % 3) * 0.11))
                    .scaledBy(x: 0.72, y: 0.72)
                pieces.append(ShatterPiece(
                    view: piece,
                    midY: frame.midY,
                    arrival: arrival,
                    scatter: scatter,
                    flight: flight))
            }
        }

        // The static tiles exactly cover the original, so it can vanish now —
        // hiding it later leaves a "copy" behind the already-flying tiles.
        target.isHidden = true
        return pieces
    }

    /// Sends every prepared tile on its staggered flight. Each flight starts
    /// through the same generation-guarded dispatch clock the reveals use,
    /// so tiles and light share one timeline to the frame — pre-scheduled
    /// `UIView.animate(delay:)` counted from its own commit instead, which
    /// put every tile a beat ahead of the front. Returns when the last tile
    /// lands.
    private func animatePreparedShatterPieces() -> TimeInterval {
        let pieces = preparedShatterPieces
        preparedShatterPieces = []
        if UIAccessibility.isReduceMotionEnabled {
            for piece in pieces {
                UIView.animate(withDuration: 0.18) {
                    piece.view.transform = piece.flight
                    piece.view.alpha = 0
                } completion: { _ in
                    piece.view.removeFromSuperview()
                }
            }
            return 0.18
        }
        let pieceDuration = OnboardingArticleReplicaTiming.shatterDuration * 0.54
        // One dispatch turn (one transaction) per frame-width bucket instead
        // of one per tile — the finer tiles roughly double the count, and a
        // few hundred separate commits queue the render server up enough to
        // delay the reveals' first frames.
        let buckets = Dictionary(grouping: pieces) {
            Int(($0.delay * 60).rounded())
        }
        for (_, group) in buckets {
            guard let earliest = group.map(\.delay).min() else { continue }
            afterDelay(earliest) { _ in
                for piece in group {
                    UIView.animate(
                        withDuration: pieceDuration,
                        delay: 0,
                        options: [.curveEaseOut, .beginFromCurrentState]
                    ) {
                        piece.view.transform = piece.flight
                        piece.view.alpha = 0
                    } completion: { _ in
                        piece.view.removeFromSuperview()
                    }
                }
            }
        }
        return (pieces.map(\.delay).max() ?? 0) + pieceDuration
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

}

/// The article icon and banner image share the same descending lunar edge as
/// the nearby text — including the glyph-style light pass: a raster of the
/// image feeds the same `GlyphPixelBloomView`, so the image's bright pixels
/// flare white-hot as the edge exposes them and cool back to their normal
/// colors, exactly like the intro lines' letters. The image alpha is
/// geometrically excluded inside the moon; the front itself has no marker —
/// only its light.
private final class MoonRevealImageView: UIView {
    /// Clips the occluder circle (which is page-sized) to the image's frame;
    /// the bloom lives outside it so the glow can spill past the edges.
    private let clippedContent = UIView()
    private let imageView = UIImageView()
    private let moonLayer = CAShapeLayer()
    private let revealMaskLayer = CAShapeLayer()
    private let pixelBloomView = GlyphPixelBloomView()
    private let occluderColor: UIColor
    private var initialCircleFrame = CGRect.zero
    private var edgeSagitta: CGFloat = 0
    private var didReveal: Bool

    /// See `MoonRevealLineView.revealFrontCrossingDistance`.
    var revealFrontCrossingDistance: CGFloat {
        bounds.height + 2 + edgeSagitta
    }

    init(
        image: UIImage?,
        occluderColor: UIColor,
        cornerRadius: CGFloat,
        initiallyRevealed: Bool = false
    ) {
        self.occluderColor = occluderColor
        self.didReveal = initiallyRevealed
        super.init(frame: .zero)
        clipsToBounds = false
        isAccessibilityElement = initiallyRevealed
        accessibilityLabel = "Luna"

        clippedContent.clipsToBounds = true
        clippedContent.isUserInteractionEnabled = false
        addSubview(clippedContent)

        imageView.image = image
        imageView.contentMode = .scaleAspectFill
        imageView.layer.cornerRadius = cornerRadius
        imageView.layer.cornerCurve = .continuous
        imageView.clipsToBounds = true
        clippedContent.addSubview(imageView)

        revealMaskLayer.fillColor = UIColor.white.cgColor
        revealMaskLayer.fillRule = .evenOdd

        moonLayer.fillColor = occluderColor.cgColor

        guard !initiallyRevealed else { return }
        installOcclusion()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func installOcclusion() {
        imageView.layer.mask = revealMaskLayer
        clippedContent.layer.addSublayer(moonLayer)
        pixelBloomView.isUserInteractionEnabled = false
        addSubview(pixelBloomView)
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
        clippedContent.frame = bounds
        imageView.frame = clippedContent.bounds
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
        let travel = revealFrontCrossingDistance
        let finalCircle = initialCircleFrame.offsetBy(dx: 0, dy: travel)
        let transform = CATransform3DMakeTranslation(0, travel, 0)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        moonLayer.transform = transform
        revealMaskLayer.path = revealPath(excluding: finalCircle)
        CATransaction.commit()

        let resolvedDuration = UIAccessibility.isReduceMotionEnabled ? 0.24 : duration
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = CATransform3DIdentity
        animation.toValue = transform
        animation.duration = resolvedDuration
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        moonLayer.add(animation, forKey: "moonReveal")

        let maskAnimation = CABasicAnimation(keyPath: "path")
        maskAnimation.fromValue = revealPath(excluding: initialCircleFrame)
        maskAnimation.toValue = revealPath(excluding: finalCircle)
        maskAnimation.duration = resolvedDuration
        maskAnimation.timingFunction = CAMediaTimingFunction(name: .linear)
        revealMaskLayer.add(maskAnimation, forKey: "moonReveal")

        // The image's own light: same front, same time-constant cooling as
        // the glyph bloom beside it, slaved to the same rendered edge. The
        // lowered gain keeps a photograph's mid-tones from saturating —
        // only its genuinely bright pixels go white-hot, the way only
        // glyph strokes do in text.
        let frontSpeed = travel / CGFloat(max(resolvedDuration, 0.001))
        pixelBloomView.reveal(
            circleTravel: travel,
            duration: OnboardingAnimationClock.displayLinkDuration(
                resolvedDuration),
            edgeBandScale: max(
                1, frontSpeed / GlyphPixelBloomView.referenceFrontSpeed),
            emitterGain: 0.45,
            offsetProvider: { [weak moonLayer] in
                moonLayer?.presentation().map { CGFloat($0.transform.m42) }
            })

        DispatchQueue.main.asyncAfter(
            deadline: .now() + OnboardingAnimationClock.delay(resolvedDuration)
        ) { [weak self] in
            guard let self, self.didReveal else { return }
            self.imageView.layer.mask = nil
            self.moonLayer.removeFromSuperlayer()
            self.pixelBloomView.stop()
            self.pixelBloomView.removeFromSuperview()
            self.isAccessibilityElement = true
            completion()
        }
    }

    private func prepareLayers() {
        let diameter = max(bounds.width * 8, 1_200)
        let radius = diameter / 2
        let halfWidth = bounds.width / 2
        let sagitta = radius - sqrt(max(radius * radius - halfWidth * halfWidth, 0))
        edgeSagitta = sagitta
        initialCircleFrame = CGRect(
            x: bounds.midX - radius,
            y: -1 - sagitta,
            width: diameter,
            height: diameter)
        let circle = UIBezierPath(ovalIn: initialCircleFrame).cgPath
        moonLayer.frame = bounds
        moonLayer.path = circle
        moonLayer.transform = CATransform3DIdentity
        revealMaskLayer.frame = bounds
        revealMaskLayer.path = revealPath(excluding: initialCircleFrame)

        let padding = GlyphPixelBloomView.renderPadding
        pixelBloomView.frame = bounds.insetBy(dx: -padding, dy: -padding)
        if let raster = rasterizedContent() {
            pixelBloomView.configure(
                raster: raster,
                rasterFrame: CGRect(
                    x: padding,
                    y: padding,
                    width: bounds.width,
                    height: bounds.height),
                circleFrame: initialCircleFrame.offsetBy(dx: padding, dy: padding),
                scale: traitCollection.displayScale)
        }
    }

    /// The bloom's emitter: the image exactly as displayed (aspect fill and
    /// corner mask included), with its alpha rebuilt from LUMINANCE. The
    /// bloom's halos are Quartz shadows, and shadows key off alpha — a
    /// photograph is opaque everywhere, so left as-is its black sky would
    /// cast the same white glow as a full moon and the band read as a solid
    /// white slab crossing the frame. With luminance as alpha the light
    /// lands on the image's bright pixels exactly the way it lands on glyph
    /// strokes. The occlusion mask is lifted for the render — rasterizing
    /// through it left only the sliver above the initial edge, killing the
    /// image's light a few points into the sweep.
    private func rasterizedContent() -> UIImage? {
        guard imageView.image != nil,
              imageView.bounds.width > 0, imageView.bounds.height > 0
        else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = traitCollection.displayScale
        format.opaque = false
        let occlusionMask = imageView.layer.mask
        imageView.layer.mask = nil
        defer { imageView.layer.mask = occlusionMask }
        let photo = UIGraphicsImageRenderer(
            bounds: imageView.bounds, format: format
        ).image { context in
            imageView.layer.render(in: context.cgContext)
        }
        guard let cgPhoto = photo.cgImage else { return nil }

        // A GRAYSCALE masking image sets the result's alpha to its own
        // sample value — white keeps, black removes (verified empirically;
        // the black-shows rule belongs to true image masks). The photo's
        // plain luminance therefore leaves alpha proportional to
        // brightness. Transparent raster regions (the corner mask) land on
        // the black prefill: masked out, as they should be.
        let width = cgPhoto.width
        let height = cgPhoto.height
        guard let gray = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return photo }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        gray.setFillColor(gray: 0, alpha: 1)
        gray.fill(rect)
        gray.draw(cgPhoto, in: rect)
        guard let luminance = gray.makeImage(),
              let emitter = cgPhoto.masking(luminance)
        else { return photo }
        return UIImage(
            cgImage: emitter, scale: photo.scale, orientation: .up)
    }

    private func revealPath(excluding circleFrame: CGRect) -> CGPath {
        let path = UIBezierPath(rect: bounds)
        path.append(UIBezierPath(ovalIn: circleFrame))
        path.usesEvenOddFillRule = true
        return path.cgPath
    }
}

/// An opaque page-coloured cover: as the huge circle translates down,
/// whatever the curtain was hiding is uncovered by the same descending edge
/// as everything above it. The front itself is invisible — only its effect.
private final class MoonRevealCurtainView: UIView {
    private let occluder = CAShapeLayer()
    private var initialCircleFrame = CGRect.zero
    private var edgeSagitta: CGFloat = 0
    private var didReveal = false

    /// See `MoonRevealLineView.revealFrontCrossingDistance`.
    var revealFrontCrossingDistance: CGFloat {
        bounds.height + 2 + edgeSagitta
    }

    init(fillColor: UIColor) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        clipsToBounds = true

        occluder.fillColor = fillColor.cgColor
        layer.addSublayer(occluder)
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
        edgeSagitta = sagitta
        initialCircleFrame = CGRect(
            x: bounds.midX - radius,
            y: -1 - sagitta,
            width: diameter,
            height: diameter)
        occluder.frame = bounds
        occluder.path = UIBezierPath(ovalIn: initialCircleFrame).cgPath
    }

    func reveal(duration: TimeInterval, completion: @escaping () -> Void) {
        guard !didReveal else {
            completion()
            return
        }
        layoutIfNeeded()
        didReveal = true
        let travel = revealFrontCrossingDistance
        let transform = CATransform3DMakeTranslation(0, travel, 0)
        let resolvedDuration = UIAccessibility.isReduceMotionEnabled
            ? 0.24 : duration

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        occluder.transform = transform
        CATransaction.commit()

        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = CATransform3DIdentity
        animation.toValue = transform
        animation.duration = resolvedDuration
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        occluder.add(animation, forKey: "moonReveal")

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

        // Buried under the clutter, the card is invisible — but the clutter is
        // NON-interactive, so a tap at its position would still reach these
        // buttons. They stay inert until the wipe actually reveals the card.
        setActionsEnabled(false)
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

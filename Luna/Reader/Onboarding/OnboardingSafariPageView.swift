//
//  OnboardingSafariPageView.swift
//  Luna
//

import LunaDesignSystem
import LunaModels
import UIKit

enum OnboardingSafariPagePalette {
    static let background = UIColor(
        red: 0.31, green: 0.32, blue: 0.34, alpha: 1)
    static let paper = UIColor(white: 0.98, alpha: 1)
    static let ink = UIColor(white: 0.10, alpha: 1)
    static let inkSecondary = UIColor(white: 0.44, alpha: 1)
}

enum OnboardingSafariPageTiming {
    static let shatterDuration: TimeInterval = 0.86
    /// The cascade edge's speed through each element. Much brisker than the
    /// intro line's own ~46pt/s — the page is tall — while the bloom's
    /// falloff bands stretch with the ratio, so every glyph's
    /// brighten-and-cool still takes exactly the intro's TIME; only the
    /// edge travels faster.
    static let cascadeFrontSpeed: CGFloat = 420
}

/// Luna's own `luna.app` page — a plausible-looking mock article, not a real
/// explanation of the extension — as Safari would show it. The page loads
/// already buried under ads, popups and a subscription wall; once the mock
/// extension-enable sequence completes, the clutter crumbles bottom-to-top
/// and reveals the article underneath. The content itself never goes
/// anywhere or animates: what the extension takes away is the clutter, so
/// the page underneath stays exactly where the reader last saw it.
///
/// This view holds only decoration: the app icon, a lorem ipsum headline,
/// and lorem ipsum body copy that fills the page like a real article once
/// the wave has revealed it. The instructions live on the hosted setup web
/// page, and the call to action is the shared, window-hosted
/// `OnboardingSafariSetupPopupView` — raised by `SafariReplicaViewController`
/// off this page's `cleanUpClutter` completion, not by anything in here.
///
/// It is native instead of HTML so the wave's glyph-level effects are possible.
final class OnboardingSafariPageView: UIView {
    /// The first Safari lesson teaches the switch; replayed lessons run the
    /// revealed-page animation on the faster cycle timeline.
    var animationSpeedMultiplier: TimeInterval = 1
    private enum Stage {
        case blocked
        /// Everything heavy is done and committed: the clutter is swapped for
        /// still tiles and every element's light raster is drawn. The sweep can
        /// now start with nothing left to stall its first frames.
        case primed
        case cleaning
        case revealed
    }

    private struct ShatterPiece {
        let view: UIView
        let arrival: TimeInterval
        let scatter: TimeInterval
        let flight: CGAffineTransform

        var delay: TimeInterval { arrival + scatter }
    }

    /// Hosts every piece of the page. It never scrolls — nothing on the page
    /// sits below the fold — so every coordinate the clutter and the shatter
    /// use stays screen-fixed, and content frames are directly comparable
    /// with the clutter's.
    private let scrollView = UIScrollView()

    private let appIcon: MoonRevealContentView
    private let headline: MoonRevealLineView
    /// The mock article's body — lorem ipsum now, filling whatever room is
    /// left below the header like a real article would.
    private let explainer: MoonRevealLineView

    private let clutterContainer = UIView()
    private let adBanners: [OnboardingAdBannerView] = [
        OnboardingAdBannerView(
            text: OnboardingStrings.Safari.adSale.value(),
            colors: [
                UIColor(red: 1, green: 0.08, blue: 0.38, alpha: 1),
                UIColor(red: 1, green: 0.55, blue: 0.02, alpha: 1),
            ]),
        OnboardingAdBannerView(
            text: OnboardingStrings.Safari.adTrick.value(),
            colors: [
                UIColor(red: 0.58, green: 0.12, blue: 0.95, alpha: 1),
                UIColor(red: 0.95, green: 0.1, blue: 0.72, alpha: 1),
            ]),
        OnboardingAdBannerView(
            text: OnboardingStrings.Safari.adCruise.value(),
            colors: [
                UIColor(red: 0.02, green: 0.6, blue: 0.66, alpha: 1),
                UIColor(red: 0.05, green: 0.3, blue: 0.9, alpha: 1),
            ]),
        OnboardingAdBannerView(
            text: OnboardingStrings.Safari.adDeals.value(),
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
    /// Every tile the current wipe put on screen. `preparedShatterPieces`
    /// empties the moment the flights are handed out, so a replay needs its
    /// own handle on them to clear a wipe that is still in the air.
    private var shatterTiles: [UIView] = []
    /// Where the climbing front enters the page: the lowest edge anything the
    /// wipe covers reaches, measured when the cascade is cut. Zero while no
    /// wipe is prepared.
    private var waveOrigin: CGFloat = 0

    init(configuration: OnboardingSurfaceConfiguration = .current) {
        let appName = configuration.demonstrationApp.displayName
        let background = OnboardingSafariPagePalette.background
        appIcon = MoonRevealContentView(
            image: LunaAppIconImage.image(for: configuration.demonstrationApp)
                ?? UIImage(systemName: "moon.stars.fill"),
            cornerRadius: 17,
            accessibilityLabel: appName,
            sweepsUpward: true)
        headline = MoonRevealLineView(
            text: OnboardingStrings.Safari.mockHeadline.value(),
            initiallyRevealed: true,
            font: UIFont.systemFont(ofSize: 26, weight: .bold),
            textAlignment: .left,
            numberOfLines: 2,
            minimumScaleFactor: 0.82,
            occluderColor: background,
            sweepsUpward: true)
        // The shortest valid prose, so the page is publishable before it has a
        // size; `layOutContent` grows it to whatever the screen can hold.
        explainer = MoonRevealLineView(
            text: Self.mockParagraphPrefix(1),
            initiallyRevealed: true,
            font: Self.proseFont,
            textAlignment: .left,
            numberOfLines: 0,
            minimumScaleFactor: 1,
            lineSpacing: Self.proseLineSpacing,
            occluderColor: background,
            sweepsUpward: true)

        super.init(frame: .zero)
        backgroundColor = background
        accessibilityIdentifier = OnboardingStrings.Accessibility.safariPage.value()

        appIcon.accessibilityIdentifier = OnboardingStrings.Accessibility.safariAppIcon.value()
        headline.accessibilityIdentifier = OnboardingStrings.Accessibility.safariHeadline.value()
        explainer.accessibilityIdentifier = OnboardingStrings.Accessibility.safariExplainer.value()
        scrollView.isScrollEnabled = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        addSubview(scrollView)

        scrollView.addSubview(appIcon)
        scrollView.addSubview(headline)
        scrollView.addSubview(explainer)

        // Every fake obstruction is a decoration, buried over the page from
        // the very first frame; the mock extension-enable pass clears them.
        // The clutter sits ABOVE the whole page so no element's own light can
        // spill over a white popup during the wave.
        clutterContainer.isUserInteractionEnabled = false
        clutterContainer.accessibilityIdentifier =
            OnboardingStrings.Accessibility.safariClutter.value()
        addSubview(clutterContainer)
        for (index, ad) in adBanners.enumerated() {
            ad.accessibilityIdentifier =
            "\(OnboardingStrings.Accessibility.safariAdPrefix.value())\(index)"
            clutterContainer.addSubview(ad)
        }
        clutterContainer.addSubview(newsletterPopup)
        clutterContainer.addSubview(subscriptionSheet)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// What the mock browser bar covers at the bottom of the page, plus a
    /// little air. The page's content stops here, for the whole of the lesson:
    /// the bar stays up from the first frame to the last, so this reserve never
    /// changes and the wave never has to be measured against a moving layout.
    static var chromeReserve: CGFloat {
        SafariBottomBar.reservedPageHeight + 12
    }

    private var bottomReserve: CGFloat { Self.chromeReserve }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The fake page keeps a readable column on a wide screen, exactly as the
        // real reader does. 17pt copy run across an iPad is not what any
        // publisher's page looks like. On a phone this resolves to the same 24pt
        // inset it always had.
        let columnWidth = min(bounds.width - 48, LunaLayout.readableWidth)
        let horizontalInset = ((bounds.width - columnWidth) / 2).rounded()
        layOutContent(columnWidth: columnWidth, horizontalInset: horizontalInset)
        layOutClutter()
    }

    /// THE HEADER IS PINNED AT THE TOP, AND THE BODY FILLS WHAT IS LEFT.
    ///
    /// The header starts at `minimumTopInset`; the body copy runs from below it
    /// down to the browser chrome's current reserve, taking the largest
    /// cumulative prefix of the lorem ipsum paragraphs that fits — so a short
    /// phone shows one paragraph and a tall iPad shows several, exactly the way
    /// a real article's copy would fill more or less of a taller page. This is
    /// decoration now, not content anyone reads for meaning, so nothing
    /// protects a minimum: a container too short even for paragraph one just
    /// truncates it.
    private func layOutContent(columnWidth: CGFloat, horizontalInset: CGFloat) {
        let bottomLimit = bounds.height - bottomReserve
        var y = Self.minimumTopInset
        let bodyTop = y + Self.headerHeight + Self.bodyGap
        // The body is fitted against the FULL chrome reserve however much room
        // the page currently has: releasing the browser bar's strip mid-lesson
        // must not make another paragraph appear out of nowhere.
        let bodyRoom = max(0, bounds.height - Self.chromeReserve - bodyTop)
        let prose = fittedProse(columnWidth: columnWidth, room: bodyRoom)
        explainer.setStyledText(prose.attributedText, accessibilityText: prose.text)

        appIcon.frame = CGRect(
            x: horizontalInset,
            y: y + ((Self.headerHeight - Self.headerIconSide) / 2).rounded(),
            width: Self.headerIconSide,
            height: Self.headerIconSide)
        headline.frame = CGRect(
            x: appIcon.frame.maxX + Self.headerIconGap,
            y: y,
            width: max(
                bounds.width - appIcon.frame.maxX - horizontalInset
                    - Self.headerIconGap,
                0),
            height: Self.headerHeight)
        y += Self.headerHeight + Self.bodyGap
        explainer.frame = CGRect(
            x: horizontalInset,
            y: y,
            width: columnWidth,
            height: min(prose.height, max(bottomLimit - y, 0)))

        scrollView.frame = bounds
        scrollView.contentSize = bounds.size
    }

    /// The largest cumulative paragraph prefix that fits `room`, with the
    /// height to draw it at. Pure geometry over a width and a height — never an
    /// idiom or a size class (see CLAUDE.md's iPad rule): an iPad in
    /// half-screen Split View and a phone are the same fitting problem.
    private func fittedProse(
        columnWidth: CGFloat,
        room: CGFloat
    ) -> (text: String, attributedText: NSAttributedString, height: CGFloat) {
        let paragraphs = OnboardingStrings.Safari.mockParagraphs.value()
        guard !paragraphs.isEmpty else { return ("", NSAttributedString(), 0) }
        var prose = Self.formattedProse(paragraphs: Array(paragraphs.prefix(1)))
        var height = Self.proseHeight(of: prose.attributedText, width: columnWidth)
        guard paragraphs.count > 1 else {
            return (prose.text, prose.attributedText, min(height, room))
        }
        for count in 2...paragraphs.count {
            let candidate = Self.formattedProse(
                paragraphs: Array(paragraphs.prefix(count)))
            let candidateHeight = Self.proseHeight(
                of: candidate.attributedText, width: columnWidth)
            guard candidateHeight <= room else { break }
            prose = candidate
            height = candidateHeight
        }
        return (prose.text, prose.attributedText, min(height, room))
    }

    /// The prefix of the lorem ipsum body the page is publishable with before
    /// it has a size; `layOutContent` grows it to whatever the screen can hold.
    private static func mockParagraphPrefix(_ count: Int) -> String {
        OnboardingStrings.Safari.mockParagraphs.value()
            .prefix(max(count, 1))
            .joined(separator: "\n")
    }

    /// THE prose typography, defined once. The measurement below and the label
    /// the page builds both read these, rather than each carrying their own
    /// copy of "17pt regular, lineSpacing 5".
    static let proseFont = UIFont.systemFont(ofSize: 17, weight: .regular)
    static let proseLineSpacing: CGFloat = 5

    static func proseAttributes() -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = proseLineSpacing
        return [.font: proseFont, .paragraphStyle: style]
    }

    /// Plain paragraphs, each with a little breathing room under it — no
    /// bullets or hierarchy, since this is filler copy rather than a feature
    /// list.
    static func formattedProse(
        paragraphs: [String]
    ) -> (text: String, attributedText: NSAttributedString) {
        let result = NSMutableAttributedString()
        for (index, paragraph) in paragraphs.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n")) }
            let style = NSMutableParagraphStyle()
            style.lineSpacing = proseLineSpacing
            style.paragraphSpacing = 9
            result.append(NSAttributedString(
                string: paragraph,
                attributes: [.font: proseFont, .paragraphStyle: style]))
        }
        return (paragraphs.joined(separator: "\n"), result)
    }

    static func proseHeight(of text: String, width: CGFloat) -> CGFloat {
        proseHeight(
            of: NSAttributedString(string: text, attributes: proseAttributes()),
            width: width)
    }

    static func proseHeight(of text: NSAttributedString, width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        return ceil(text.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil).height)
    }

    /// The header's own row: the headline's two lines, with the app icon
    /// centred against them.
    private static let headerHeight: CGFloat = 64
    private static let headerIconSide: CGFloat = 60
    private static let headerIconGap: CGFloat = 14
    /// The gap between the header row and the body copy underneath it.
    private static let bodyGap: CGFloat = 10
    /// Where the page starts when there is no air left to give it.
    static let minimumTopInset: CGFloat = 24

    private func layOutClutter() {
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
    /// tiles and draws every element's light raster. The content itself is
    /// left exactly as it is — the page the reader has been looking at is the
    /// page the wave lights.
    /// Idempotent; `cleanUpClutter` runs it if the host didn't.
    func prepareCleanUp() {
        guard stage == .blocked else { return }
        stage = .primed
        sequenceGeneration += 1
        shatterTiles = []
        layoutIfNeeded()

        measureWaveOrigin()
        preparedShatterPieces = clutterContainer.subviews.flatMap {
            buildShatterPieces(for: $0)
        }
    }

    /// Where the front enters, so that a tile's arrival is a straight line in
    /// its own y. It climbs from the lowest edge the wipe has to cross — the
    /// bottom-most obstruction, which is the subscription sheet sitting on the
    /// page's bottom edge — rather than from the bottom-most piece of CONTENT:
    /// anything below the latter would otherwise share one arrival and leave
    /// as a slab.
    ///
    /// Cutting this front into per-element legs, each starting when the light
    /// reaches that element's bottom, stalls: between two elements the
    /// arrival would be constant (the leg above answers for the whole gap),
    /// so the front stalls for the height of every gap and then wipes it in a
    /// single frame. The air the page leaves above its steps is the biggest
    /// of those gaps, and a popup spanning it would detach in one piece —
    /// the hitch a crumble shows at the popup boundaries. Legs would earn
    /// their keep only if an element bloomed on its own clock; nothing on
    /// this page blooms, so one uninterrupted front is both simpler and
    /// continuous by construction.
    private func measureWaveOrigin() {
        let lowestObstruction = clutterContainer.subviews
            .filter { !$0.isHidden }
            .map { clutterContainer.convert($0.frame, to: self).maxY }
            .max()
        waveOrigin = max(lowestObstruction ?? bounds.maxY, bounds.maxY)
    }

    /// When the climbing light reaches a page-level y: one constant-speed
    /// front, so every tile detaches in step with the tiles beside and beneath
    /// it whatever the page's layout does between them.
    private func frontArrival(atPageY y: CGFloat) -> TimeInterval {
        TimeInterval(
            max(0, waveOrigin - y)
                / (OnboardingSafariPageTiming.cascadeFrontSpeed
                    / animationSpeedMultiplier))
    }

    /// Shatters every obstruction bottom-to-top. The content beneath stays
    /// stationary; only the obstruction tiles move.
    ///
    /// The cascade starts one run-loop turn after `prepareCleanUp`'s work,
    /// never in the same turn: the preparation's heavy commit (tiles and
    /// rasters) otherwise lands between an animation's added wall-clock anchor
    /// and its first rendered frame, and the light at the top of the page —
    /// shine and all — starts already finished.
    ///
    /// `completion` is what raises the shared setup popup
    /// (`SafariReplicaViewController.presentExtensionsSheet`'s call site) —
    /// this page carries no ask of its own.
    func cleanUpClutter(completion: (() -> Void)? = nil) {
        guard stage == .blocked || stage == .primed else {
            completion?()
            return
        }
        prepareCleanUp()
        stage = .cleaning

        afterDelay(0) { view in
            let shatterFinish = view.animatePreparedShatterPieces()

            view.afterDelay(shatterFinish + 0.12) { view in
                view.stage = .revealed
                completion?()
            }
        }
    }

    /// Puts the page back exactly as it loads — buried under every
    /// obstruction, content beneath them — so the whole demonstration can
    /// play again.
    ///
    /// The Safari lesson is deliberately re-enterable: skipping returns to the
    /// intro with its button still live, and central Luna's forever-loop
    /// replays each sibling lesson under the shared popup. Without this, a
    /// second entry landed on the finished page with nothing left to run.
    func restoreBuriedPage() {
        // Drops anything the previous wipe still has scheduled.
        sequenceGeneration += 1
        stage = .blocked
        preparedShatterPieces = []
        waveOrigin = 0
        for tile in shatterTiles {
            tile.layer.removeAllAnimations()
            tile.removeFromSuperview()
        }
        shatterTiles = []
        for obstruction in clutterContainer.subviews {
            obstruction.isHidden = false
            obstruction.alpha = 1
            obstruction.transform = .identity
        }
        setNeedsLayout()
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
                shatterTiles.append(piece)

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

    /// Sends every prepared tile on its staggered flight. All flights are
    /// committed to Core Animation in one transaction before the first tile
    /// moves. Starting UIKit animations as each popup's tiles were reached made
    /// the render server do another large commit mid-wipe, visibly stuttering
    /// at those popup boundaries.
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
        let pieceDuration = OnboardingSafariPageTiming.shatterDuration
            * 0.54 * animationSpeedMultiplier
        let lastFinish = (pieces.map(\.delay).max() ?? 0) + pieceDuration
        let commitTime = CACurrentMediaTime()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for piece in pieces {
            let transform = CATransform3DMakeAffineTransform(piece.flight)
            let transformAnimation = CABasicAnimation(keyPath: "transform")
            transformAnimation.fromValue = CATransform3DIdentity
            transformAnimation.toValue = transform

            let opacityAnimation = CABasicAnimation(keyPath: "opacity")
            opacityAnimation.fromValue = 1
            opacityAnimation.toValue = 0

            let animation = CAAnimationGroup()
            animation.animations = [transformAnimation, opacityAnimation]
            animation.beginTime = commitTime + OnboardingAnimationClock.delay(
                piece.delay * animationSpeedMultiplier)
            animation.duration = pieceDuration
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            // Preserve the first value until each tile's own scheduled start;
            // otherwise setting the model layer to its final state would hide
            // tiles that have not reached the front yet.
            animation.fillMode = .both
            animation.isRemovedOnCompletion = false

            piece.view.layer.transform = transform
            piece.view.layer.opacity = 0
            piece.view.layer.add(
                animation,
                forKey: OnboardingStrings.AnimationKeys.safariShatter.value())
        }
        CATransaction.commit()

        // A single cleanup after every flight avoids another burst of layer
        // transactions at each obstruction boundary. The tiles are already
        // fully transparent for their final beat.
        afterDelay(lastFinish) { _ in
            for piece in pieces {
                piece.view.removeFromSuperview()
            }
        }
        return lastFinish
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
        _ delay: TimeInterval,
        _ action: @escaping (OnboardingSafariPageView) -> Void
    ) {
        let generation = sequenceGeneration
        DispatchQueue.main.asyncAfter(
            deadline: .now() + OnboardingAnimationClock.delay(
                delay * animationSpeedMultiplier)
        ) { [weak self] in
            guard let self, self.sequenceGeneration == generation else { return }
            action(self)
        }
    }

}

/// A stable host for the Safari page's pictures and live controls. It retains
/// the clipping/accessibility behavior that its content needs, but does not
/// animate when the obstruction layer shatters above it.
final class MoonRevealContentView: UIView {
    private let clippedContent = UIView()
    private let contentHost: UIView
    /// A picture — or a fixed row of chrome — IS one accessibility element,
    /// with a label of its own. A block of live controls is not: its own
    /// buttons are what a reader reaches for.
    private let standsInForItsContent: Bool
    init(
        image: UIImage?,
        cornerRadius: CGFloat,
        accessibilityLabel: String?,
        sweepsUpward _: Bool = false
    ) {
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFill
        imageView.layer.cornerRadius = cornerRadius
        imageView.layer.cornerCurve = .continuous
        imageView.clipsToBounds = true
        contentHost = imageView
        standsInForItsContent = true
        super.init(frame: .zero)
        configure(accessibilityLabel: accessibilityLabel)
    }

    init(
        content: UIView,
        accessibilityLabel: String?,
        sweepsUpward _: Bool = false
    ) {
        contentHost = content
        standsInForItsContent = accessibilityLabel != nil
        super.init(frame: .zero)
        configure(accessibilityLabel: accessibilityLabel)
    }

    private func configure(accessibilityLabel: String?) {
        clipsToBounds = false
        isAccessibilityElement = standsInForItsContent
        self.accessibilityLabel = accessibilityLabel

        clippedContent.clipsToBounds = true
        clippedContent.isUserInteractionEnabled = !standsInForItsContent
        addSubview(clippedContent)
        clippedContent.addSubview(contentHost)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        clippedContent.frame = bounds
        contentHost.frame = clippedContent.bounds
        contentHost.layoutIfNeeded()
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
        accessibilityIdentifier =
            OnboardingStrings.Accessibility.safariNewsletterPopup.value()
        backgroundColor = OnboardingSafariPagePalette.paper
        layer.cornerRadius = 18
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.5
        layer.shadowRadius = 26
        layer.shadowOffset = CGSize(width: 0, height: 14)

        title.text = OnboardingStrings.Safari.newsletterTitle.value()
        title.font = .systemFont(ofSize: 22, weight: .bold)
        title.textColor = OnboardingSafariPagePalette.ink
        title.textAlignment = .center
        title.numberOfLines = 2
        title.adjustsFontSizeToFitWidth = true
        title.minimumScaleFactor = 0.8
        title.accessibilityIdentifier =
            OnboardingStrings.Accessibility.safariNewsletterTitle.value()
        addSubview(title)

        subtitle.text = OnboardingStrings.Safari.newsletterSubtitle.value()
        subtitle.font = .systemFont(ofSize: 15, weight: .regular)
        subtitle.textColor = OnboardingSafariPagePalette.inkSecondary
        subtitle.textAlignment = .center
        subtitle.accessibilityIdentifier =
            OnboardingStrings.Accessibility.safariNewsletterSubtitle.value()
        addSubview(subtitle)

        emailField.backgroundColor = UIColor(white: 0.94, alpha: 1)
        emailField.layer.cornerRadius = 10
        emailField.layer.cornerCurve = .continuous
        emailField.layer.borderWidth = 1
        emailField.layer.borderColor = UIColor(white: 0.84, alpha: 1).cgColor
        emailField.accessibilityIdentifier =
            OnboardingStrings.Accessibility.safariNewsletterEmail.value()
        addSubview(emailField)

        emailPlaceholder.text = OnboardingStrings.Safari.newsletterEmail.value()
        emailPlaceholder.font = .systemFont(ofSize: 16, weight: .regular)
        emailPlaceholder.textColor = UIColor(white: 0.62, alpha: 1)
        emailField.addSubview(emailPlaceholder)

        submitButton.text = OnboardingStrings.Safari.newsletterSubmit.value()
        submitButton.font = .systemFont(ofSize: 17, weight: .semibold)
        submitButton.textColor = .white
        submitButton.textAlignment = .center
        submitButton.backgroundColor = UIColor(
            red: 0.07, green: 0.36, blue: 0.86, alpha: 1)
        submitButton.layer.cornerRadius = 10
        submitButton.layer.cornerCurve = .continuous
        submitButton.clipsToBounds = true
        submitButton.accessibilityIdentifier =
            OnboardingStrings.Accessibility.safariNewsletterSubmit.value()
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
        accessibilityIdentifier =
            OnboardingStrings.Accessibility.safariSubscriptionSheet.value()
        backgroundColor = OnboardingSafariPagePalette.paper
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

        title.text = OnboardingStrings.Safari.subscriptionTitle.value()
        title.font = .systemFont(ofSize: 24, weight: .bold)
        title.textColor = OnboardingSafariPagePalette.ink
        title.textAlignment = .center
        title.numberOfLines = 2
        title.adjustsFontSizeToFitWidth = true
        title.minimumScaleFactor = 0.8
        title.accessibilityIdentifier =
            OnboardingStrings.Accessibility.safariSubscriptionTitle.value()
        addSubview(title)

        bodyText.text = OnboardingStrings.Safari.subscriptionBody.value()
        bodyText.font = .systemFont(ofSize: 15, weight: .regular)
        bodyText.textColor = OnboardingSafariPagePalette.inkSecondary
        bodyText.textAlignment = .center
        bodyText.numberOfLines = 3
        bodyText.accessibilityIdentifier =
            OnboardingStrings.Accessibility.safariSubscriptionBody.value()
        addSubview(bodyText)

        subscribeButton.text = OnboardingStrings.Safari.subscriptionSubmit.value()
        subscribeButton.font = .systemFont(ofSize: 17, weight: .semibold)
        subscribeButton.textColor = .white
        subscribeButton.textAlignment = .center
        subscribeButton.backgroundColor = OnboardingSafariPagePalette.ink
        subscribeButton.layer.cornerRadius = 12
        subscribeButton.layer.cornerCurve = .continuous
        subscribeButton.clipsToBounds = true
        subscribeButton.accessibilityIdentifier =
            OnboardingStrings.Accessibility.safariSubscriptionSubmit.value()
        addSubview(subscribeButton)

        signIn.text = OnboardingStrings.Safari.subscriptionSignIn.value()
        signIn.font = .systemFont(ofSize: 14, weight: .medium)
        signIn.textColor = UIColor(red: 0.07, green: 0.36, blue: 0.86, alpha: 1)
        signIn.textAlignment = .center
        signIn.accessibilityIdentifier =
            OnboardingStrings.Accessibility.safariSubscriptionSignIn.value()
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

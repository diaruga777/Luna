//
//  OnboardingSafariPageView.swift
//  Luna
//

import LunaDesignSystem
import UIKit

enum OnboardingSafariPagePalette {
    static let background = UIColor(
        red: 0.31, green: 0.32, blue: 0.34, alpha: 1)
    static let paper = UIColor(white: 0.98, alpha: 1)
    static let ink = UIColor(white: 0.10, alpha: 1)
    static let inkSecondary = UIColor(white: 0.44, alpha: 1)
    /// The page's own quieter type — byline and section heading — against its
    /// dark neutral grey.
    static let quietCopy = UIColor(white: 1, alpha: 0.62)
}

enum OnboardingSafariPageTiming {
    static let shatterDuration: TimeInterval = 0.86
    /// The cascade edge's speed through each element. Much brisker than the
    /// intro line's own ~46pt/s — the page is tall — while the bloom's
    /// falloff bands stretch with the ratio, so every glyph's
    /// brighten-and-cool still takes exactly the intro's TIME; only the
    /// edge travels faster.
    static let cascadeFrontSpeed: CGFloat = 420
    /// The content reveals (and their bloom) set out this far behind the
    /// shatter front: the tiles directly above a stretch of content are
    /// mid-flight when its light arrives, and without the lag they obscured
    /// the bloom underneath.
    static let contentBloomLag: TimeInterval = 0.14
    /// The page's text, amplified past the intro reference — at the wave's
    /// speed the reference gain read as too soft.
    static let textBloomGain: CGFloat = 1.6
    /// The pictures ride the same amplified light, backed off just enough that
    /// artwork blooms a shade less brightly than the glyph strokes.
    static let imageBloomGain: CGFloat = 1.0
    /// The luminance-keyed emitters clamp from below: even an image's dark
    /// pixels bloom under the front, just less brightly than its bright ones.
    static let imageLuminanceFloor: CGFloat = 0.55
}

/// The wave's contract. Every piece of the page's content is crossed by the
/// same climbing lunar edge, whether it is a line of type or a block of live,
/// tappable views.
protocol OnboardingWaveRevealing: UIView {
    var revealFrontCrossingDistance: CGFloat { get }
    func prepareToRevealAgain()
    func reveal(duration: TimeInterval, completion: @escaping () -> Void)
}

/// Luna's own `luna.app` page about the Safari extension, as Safari would show
/// it. The page loads already buried under ads, popups and a subscription wall;
/// once the mock extension-enable sequence completes, a wave CLIMBS the page —
/// the clutter crumbles bottom-to-top while the content beneath reveals as a
/// cascade of the SAME lunar reveals that opened the app, each element's edge
/// rising.
///
/// The content is the explanation (`OnboardingSafariExtensionCopy`): what the
/// extension takes off a page, that it all happens on the device, that anything
/// worth keeping is one tap from Luna — then the three steps that switch it on,
/// each beside a picture of the exact chrome it names. Its own call to action is
/// the LAST thing on the page rather than a card floating over it, and the
/// steps and actions are anchored to the bottom above the browser chrome
/// whatever the screen's height: the Safari button — wearing the launch eclipse
/// corona — sits where the wave first enters, and the copy stacks upward from
/// it.
///
/// It is native instead of HTML so those glyph-level effects are possible.
final class OnboardingSafariPageView: UIView {
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

    /// One stretch of the climbing front: within [top, bottom] the light
    /// arrives at `start + (bottom - y) / speed` — the wave enters each
    /// element at its BOTTOM and climbs. Tiles look their own page-y up in
    /// these legs so every tile detaches exactly when the light beneath it
    /// arrives, even though each element runs its own reveal.
    private struct FrontLeg {
        let top: CGFloat
        let bottom: CGFloat
        let start: TimeInterval
        let speed: CGFloat

        func arrival(at y: CGFloat) -> TimeInterval {
            start + TimeInterval(max(0, bottom - max(y, top)) / speed)
        }
    }

    private struct CascadeEntry {
        let start: TimeInterval
        let duration: TimeInterval
        let reveal: (TimeInterval) -> Void
    }

    /// One element the climbing wave crosses.
    private struct WaveElement {
        let view: any OnboardingWaveRevealing
        /// False for an element whose band of the page is covered by a wider
        /// sibling — the app icon beside the headline. The sibling's leg
        /// answers for the tiles over that stretch, so the two can never
        /// disagree about when a tile there detaches.
        let contributesLeg: Bool
    }

    /// Hosts every piece of the page, the actions included. It never scrolls —
    /// nothing on the page sits below the fold — so every coordinate the
    /// clutter and the shatter use stays screen-fixed, and content frames are
    /// directly comparable with the clutter's.
    private let scrollView = UIScrollView()

    private let appIcon: MoonRevealContentView
    private let headline: MoonRevealLineView
    private let byline: MoonRevealLineView
    private let explainer: MoonRevealLineView
    private let stepsHeading: MoonRevealLineView
    private let stepRows: [MoonRevealContentView]
    private let actionsView: OnboardingSafariActionsView
    private let actions: MoonRevealContentView
    /// The eclipse corona rides behind the Safari button itself, swelling in
    /// once the page is clean.
    private var actionsCorona: EclipseCoronaView?

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
    private var waveElements: [WaveElement] = []
    private var preparedShatterPieces: [ShatterPiece] = []
    private var revealSchedule: [CascadeEntry] = []
    private var frontLegs: [FrontLeg] = []

    init(configuration: OnboardingSurfaceConfiguration = .current) {
        let appName = configuration.app.displayName
        let background = OnboardingSafariPagePalette.background
        appIcon = MoonRevealContentView(
            image: OnboardingAppIcon.image()
                ?? UIImage(systemName: "moon.stars.fill"),
            occluderColor: background,
            cornerRadius: 17,
            accessibilityLabel: appName,
            initiallyRevealed: true,
            sweepsUpward: true)
        headline = MoonRevealLineView(
            text: OnboardingSafariExtensionCopy.title,
            initiallyRevealed: true,
            font: UIFont.systemFont(ofSize: 26, weight: .bold),
            textAlignment: .left,
            numberOfLines: 2,
            minimumScaleFactor: 0.82,
            occluderColor: background,
            sweepsUpward: true)
        byline = MoonRevealLineView(
            text: OnboardingSafariExtensionCopy.byline(appName: appName),
            initiallyRevealed: true,
            font: .systemFont(ofSize: 13, weight: .semibold),
            textAlignment: .left,
            numberOfLines: 1,
            minimumScaleFactor: 0.9,
            textColor: OnboardingSafariPagePalette.quietCopy,
            occluderColor: background,
            sweepsUpward: true)
        explainer = MoonRevealLineView(
            text: OnboardingSafariExtensionCopy.explainer,
            initiallyRevealed: true,
            font: .systemFont(ofSize: 17, weight: .regular),
            textAlignment: .left,
            numberOfLines: 0,
            minimumScaleFactor: 1,
            lineSpacing: 5,
            occluderColor: background,
            sweepsUpward: true)
        stepsHeading = MoonRevealLineView(
            text: OnboardingSafariExtensionCopy.stepsHeading,
            initiallyRevealed: true,
            font: .systemFont(ofSize: 13, weight: .semibold),
            textAlignment: .left,
            numberOfLines: 1,
            minimumScaleFactor: 0.9,
            textColor: OnboardingSafariPagePalette.quietCopy,
            occluderColor: background,
            sweepsUpward: true)
        stepRows = OnboardingSafariExtensionCopy.steps(appName: appName)
            .map { step in
                MoonRevealContentView(
                    content: OnboardingSafariEnableStepRowView(step: step),
                    occluderColor: background,
                    accessibilityLabel: step.text,
                    initiallyRevealed: true,
                    sweepsUpward: true)
            }
        let actionsView = OnboardingSafariActionsView()
        self.actionsView = actionsView
        actions = MoonRevealContentView(
            content: actionsView,
            occluderColor: background,
            accessibilityLabel: nil,
            initiallyRevealed: true,
            sweepsUpward: true)

        super.init(frame: .zero)
        backgroundColor = background
        accessibilityIdentifier = "onboarding.safari.lunaPage"

        appIcon.accessibilityIdentifier = "onboarding.safari.page.appIcon"
        headline.accessibilityIdentifier = "onboarding.safari.page.headline"
        byline.accessibilityIdentifier = "onboarding.safari.page.byline"
        explainer.accessibilityIdentifier = "onboarding.safari.page.explainer"
        stepsHeading.accessibilityIdentifier =
            "onboarding.safari.page.stepsHeading"
        for (index, row) in stepRows.enumerated() {
            row.accessibilityIdentifier = "onboarding.safari.page.step.\(index)"
        }
        actions.accessibilityIdentifier = "onboarding.safari.page.actions"
        for line in [headline, byline, explainer, stepsHeading] {
            line.bloomGain = OnboardingSafariPageTiming.textBloomGain
        }

        scrollView.isScrollEnabled = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        addSubview(scrollView)

        scrollView.addSubview(appIcon)
        scrollView.addSubview(headline)
        scrollView.addSubview(byline)
        scrollView.addSubview(explainer)
        scrollView.addSubview(stepsHeading)
        for row in stepRows {
            scrollView.addSubview(row)
        }
        scrollView.addSubview(actions)

        actionsView.onActivate = { [weak self] in self?.onActivateSafari?() }
        actionsView.onSkip = { [weak self] in self?.onSkipSafariSetup?() }

        // Every fake obstruction is a decoration, buried over the page from
        // the very first frame; the mock extension-enable pass clears them.
        // The clutter sits ABOVE the whole page — the actions included — so no
        // element's occluder can paint over a white popup during the wave.
        clutterContainer.isUserInteractionEnabled = false
        clutterContainer.accessibilityIdentifier =
            "onboarding.safari.page.clutter"
        addSubview(clutterContainer)
        for (index, ad) in adBanners.enumerated() {
            ad.accessibilityIdentifier = "onboarding.safari.page.ad.\(index)"
            clutterContainer.addSubview(ad)
        }
        clutterContainer.addSubview(newsletterPopup)
        clutterContainer.addSubview(subscriptionSheet)

        // Bottom to top, so the front enters at the actions block's own bottom
        // edge and climbs. The icon shares its band with the wider headline.
        waveElements = [WaveElement(view: actions, contributesLeg: true)]
            + stepRows.reversed().map {
                WaveElement(view: $0, contributesLeg: true)
            }
            + [
                WaveElement(view: stepsHeading, contributesLeg: true),
                WaveElement(view: explainer, contributesLeg: true),
                WaveElement(view: byline, contributesLeg: true),
                WaveElement(view: headline, contributesLeg: true),
                WaveElement(view: appIcon, contributesLeg: false),
            ]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// What the mock browser bar covers at the bottom of the page, plus a
    /// little air. The page's content stops here.
    static var chromeReserve: CGFloat {
        SafariBottomBar.reservedPageHeight + 12
    }

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

    /// THE WHOLE PAGE IS ANCHORED TO THE BOTTOM. The actions sit on the browser
    /// chrome and everything else stacks upward from them, so the Safari button
    /// is in the same place on every screen and the wave has no dead middle to
    /// climb through. Air collects above the header — a taller screen simply
    /// starts the page lower — and on a screen too short for all of it the prose
    /// gives way (its label truncates) rather than the actions sliding under the
    /// chrome.
    private func layOutContent(columnWidth: CGFloat, horizontalInset: CGFloat) {
        let bottomLimit = bounds.height - Self.chromeReserve
        let rowHeight = OnboardingSafariEnableStepRowView.preferredHeight
        let actionsHeight = OnboardingSafariActionsView.preferredHeight
        let stepsHeight = CGFloat(stepRows.count) * rowHeight
            + CGFloat(max(stepRows.count - 1, 0)) * Self.stepGap
        let bottomGroupTop = bottomLimit
            - (Self.headingHeight + Self.headingGap + stepsHeight
                + Self.stepsToActionsGap + actionsHeight)

        let proseHeight = Self.height(
            of: OnboardingSafariExtensionCopy.explainer,
            width: columnWidth,
            font: .systemFont(ofSize: 17, weight: .regular))
        let headerTop = bottomGroupTop - Self.proseToStepsGap - proseHeight
            - Self.proseGap - Self.bylineHeight - Self.bylineGap
            - Self.headerHeight
        var y = max(Self.minimumTopInset, headerTop)

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
        y += Self.headerHeight + Self.bylineGap
        byline.frame = CGRect(
            x: horizontalInset, y: y, width: columnWidth, height: Self.bylineHeight)
        y += Self.bylineHeight + Self.proseGap
        explainer.frame = CGRect(
            x: horizontalInset,
            y: y,
            width: columnWidth,
            height: min(
                proseHeight,
                max(0, bottomGroupTop - Self.proseToStepsGap - y)))

        y = bottomGroupTop
        stepsHeading.frame = CGRect(
            x: horizontalInset,
            y: y,
            width: columnWidth,
            height: Self.headingHeight)
        y += Self.headingHeight + Self.headingGap
        for row in stepRows {
            row.frame = CGRect(
                x: horizontalInset, y: y, width: columnWidth, height: rowHeight)
            y += rowHeight + Self.stepGap
        }
        actions.frame = CGRect(
            x: horizontalInset,
            y: bottomLimit - actionsHeight,
            width: columnWidth,
            height: actionsHeight)

        scrollView.frame = bounds
        scrollView.contentSize = bounds.size
        layOutActionsCorona()
    }

    /// The header's own row: the headline's two lines, with the app icon
    /// centred against them.
    private static let headerHeight: CGFloat = 68
    private static let headerIconSide: CGFloat = 60
    private static let headerIconGap: CGFloat = 14
    private static let bylineHeight: CGFloat = 20
    private static let bylineGap: CGFloat = 10
    private static let proseGap: CGFloat = 12
    private static let headingHeight: CGFloat = 18
    private static let headingGap: CGFloat = 8
    private static let stepGap: CGFloat = 10
    private static let stepsToActionsGap: CGFloat = 20
    /// The least the prose above may be left from the steps below it.
    private static let proseToStepsGap: CGFloat = 22
    /// Where the page starts when there is no air left to give it.
    static let minimumTopInset: CGFloat = 24

    /// The corona is the Safari button's own, not the block's: it takes the
    /// button's exact capsule geometry and sits directly behind it.
    private func layOutActionsCorona() {
        actions.layoutIfNeeded()
        let button = actionsView.activateButton
        let coronaFrame = scrollView.convert(button.bounds, from: button)
        guard coronaFrame.width > 0, coronaFrame.height > 0 else { return }
        if actionsCorona?.bounds.size != coronaFrame.size {
            actionsCorona?.removeFromSuperview()
            let corona = EclipseCoronaView(
                bodySize: coronaFrame.size,
                cornerRadius: coronaFrame.height / 2,
                tint: LunaSurfacePalette.atmosphereTint)
            corona.alpha = stage == .revealed ? 1 : 0
            scrollView.insertSubview(corona, belowSubview: actions)
            actionsCorona = corona
        }
        actionsCorona?.frame = coronaFrame
    }

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
    /// tiles, re-occludes the content and draws every element's light raster.
    /// Idempotent; `cleanUpClutter` runs it if the host didn't.
    func prepareCleanUp() {
        guard stage == .blocked else { return }
        stage = .primed
        sequenceGeneration += 1
        layoutIfNeeded()

        for element in waveElements {
            element.view.prepareToRevealAgain()
        }
        layoutIfNeeded()
        computeCascade()
        preparedShatterPieces = clutterContainer.subviews.flatMap {
            buildShatterPieces(for: $0)
        }
        // Strictly bottom-to-top, across every view at once: the legs are
        // cut from one continuous front, but the sagitta slack at element
        // boundaries can still dip a raw arrival below the tile beneath it.
        // A running maximum up the page keeps each tile at or after every
        // tile below it, textured by their scatter.
        preparedShatterPieces.sort { $0.midY > $1.midY }
        var runningArrival: TimeInterval = 0
        for index in preparedShatterPieces.indices {
            runningArrival = max(
                runningArrival, preparedShatterPieces[index].arrival)
            preparedShatterPieces[index].arrival = runningArrival
        }
    }

    /// THE PAGE IS THE INTRO'S ANIMATION, ELEMENT BY ELEMENT. Every element's
    /// edge crosses it at `cascadeFrontSpeed`, a brisk multiple of the intro
    /// line's pace whose band stretch keeps each glyph's brighten-and-cool at
    /// the intro's exact TIME — the same deliberate light of “You want to read
    /// more.”, just a faster-travelling edge.
    /// ONE front climbs the page: it enters at the bottom-most element's edge —
    /// the actions block, anchored to the page's bottom — and every element's
    /// reveal sets out exactly when the front reaches its OWN bottom, so the
    /// steps, then the prose, then the headline reappear only after whatever
    /// sits beneath them; nothing ever leads the wave. The tiles ride the
    /// unlagged front; each reveal (and its bloom) trails it by
    /// `contentBloomLag` so the tiles flying just above a stretch of content
    /// have cleared before its light comes up.
    private func computeCascade() {
        let speed = OnboardingSafariPageTiming.cascadeFrontSpeed
        let lag = OnboardingSafariPageTiming.contentBloomLag
        revealSchedule = []
        frontLegs = []
        // Sorted rather than trusted: a layout change that reorders the page
        // must not be able to send the wave down it.
        let ordered = waveElements.sorted {
            $0.view.frame.maxY > $1.view.frame.maxY
        }
        guard let waveOrigin = ordered.first?.view.frame.maxY else { return }
        for element in ordered {
            let view = element.view
            let start = TimeInterval((waveOrigin - view.frame.maxY) / speed)
            let duration = TimeInterval(view.revealFrontCrossingDistance / speed)
            revealSchedule.append(CascadeEntry(
                start: start + lag,
                duration: duration,
                reveal: { view.reveal(duration: $0) { } }))
            guard element.contributesLeg else { continue }
            frontLegs.append(FrontLeg(
                top: view.frame.minY,
                bottom: view.frame.maxY,
                start: start,
                speed: speed))
        }
    }

    /// When the climbing light reaches a page-level y: inside an element,
    /// its own leg answers; in the dead space between elements, the leg
    /// ABOVE it does (its `arrival` clamps y below its bottom to its start).
    /// Above the topmost content, the wave's very end.
    private func frontArrival(atPageY y: CGFloat) -> TimeInterval {
        for leg in frontLegs where y >= leg.top {
            return leg.arrival(at: y)
        }
        return frontLegs.last.map { $0.arrival(at: $0.top) } ?? 0
    }

    /// Shatters every obstruction bottom-to-top while the content underneath
    /// reveals as a cascade of INTRO reveals — each element crossed by the
    /// same climbing lunar edge, at the same speed, with the same light as
    /// “You want to read more.” The page's own actions are the first thing the
    /// front crosses and the last thing to come alive: they stay inert until
    /// the whole page is clean, and the corona then swells in behind the
    /// Safari button.
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
            let revealFinish = view.revealContentAlongCascade()

            view.afterDelay(max(shatterFinish, revealFinish) + 0.12) { view in
                view.stage = .revealed
                view.actionsView.setActionsEnabled(true)
                view.igniteActionsCorona()
                completion?()
            }
        }
    }

    /// The corona blooms only once the page is whole. Bringing it up with the
    /// wave still climbing put a lamp behind the one element the light had
    /// already left.
    private func igniteActionsCorona() {
        guard let corona = actionsCorona else { return }
        guard !UIAccessibility.isReduceMotionEnabled else {
            corona.alpha = 1
            return
        }
        UIView.animate(withDuration: 0.5) {
            corona.alpha = 1
        }
    }

    /// Returning from Safari without the extension having run re-offers the
    /// page's own actions.
    func reactivateActions() {
        actionsView.setActionsEnabled(true)
    }

    /// Plays the cascade computed in `prepareCleanUp`: each element's reveal
    /// climbs it, staggered up the page.
    @discardableResult
    private func revealContentAlongCascade() -> TimeInterval {
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
        let pieceDuration = OnboardingSafariPageTiming.shatterDuration * 0.54
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
        _ delay: TimeInterval,
        _ action: @escaping (OnboardingSafariPageView) -> Void
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

extension MoonRevealLineView: OnboardingWaveRevealing {}
extension MoonRevealContentView: OnboardingWaveRevealing {}

/// The page's pictures — and its one block of live, tappable views — share the
/// same lunar edge as the type beside them, including the glyph-style light
/// pass: a raster of the content feeds the same `GlyphPixelBloomView`, so its
/// bright pixels flare white-hot as the edge exposes them and cool back to
/// their normal colors, exactly like the intro lines' letters. The content is
/// geometrically excluded inside the moon; the front itself has no marker —
/// only its light.
final class MoonRevealContentView: UIView {
    /// Clips the occluder circle (which is page-sized) to the content's frame;
    /// the bloom lives outside it so the glow can spill past the edges.
    private let clippedContent = UIView()
    /// What the reveal exposes: an image view for a picture, or a caller's own
    /// (possibly interactive) view.
    private let contentHost: UIView
    private let moonLayer = CAShapeLayer()
    private let revealMaskLayer = CAShapeLayer()
    private let pixelBloomView = GlyphPixelBloomView()
    private let occluderColor: UIColor
    private let sweepsUpward: Bool
    /// A picture — or a fixed row of chrome — IS one accessibility element,
    /// with a label of its own. A block of live controls is not: its buttons
    /// must stay reachable, so it hides its elements while occluded instead.
    private let standsInForItsContent: Bool
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
        accessibilityLabel: String?,
        initiallyRevealed: Bool = false,
        sweepsUpward: Bool = false
    ) {
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFill
        imageView.layer.cornerRadius = cornerRadius
        imageView.layer.cornerCurve = .continuous
        imageView.clipsToBounds = true
        contentHost = imageView
        standsInForItsContent = true
        self.occluderColor = occluderColor
        self.sweepsUpward = sweepsUpward
        self.didReveal = initiallyRevealed
        super.init(frame: .zero)
        configure(
            accessibilityLabel: accessibilityLabel,
            initiallyRevealed: initiallyRevealed)
    }

    init(
        content: UIView,
        occluderColor: UIColor,
        accessibilityLabel: String?,
        initiallyRevealed: Bool = false,
        sweepsUpward: Bool = false
    ) {
        contentHost = content
        standsInForItsContent = accessibilityLabel != nil
        self.occluderColor = occluderColor
        self.sweepsUpward = sweepsUpward
        self.didReveal = initiallyRevealed
        super.init(frame: .zero)
        configure(
            accessibilityLabel: accessibilityLabel,
            initiallyRevealed: initiallyRevealed)
    }

    private func configure(
        accessibilityLabel: String?,
        initiallyRevealed: Bool
    ) {
        clipsToBounds = false
        isAccessibilityElement = standsInForItsContent && initiallyRevealed
        self.accessibilityLabel = accessibilityLabel
        accessibilityElementsHidden =
            !standsInForItsContent && !initiallyRevealed

        clippedContent.clipsToBounds = true
        clippedContent.isUserInteractionEnabled = !standsInForItsContent
        addSubview(clippedContent)
        clippedContent.addSubview(contentHost)

        revealMaskLayer.fillColor = UIColor.white.cgColor
        revealMaskLayer.fillRule = .evenOdd
        moonLayer.fillColor = occluderColor.cgColor

        guard !initiallyRevealed else { return }
        installOcclusion()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func installOcclusion() {
        contentHost.layer.mask = revealMaskLayer
        clippedContent.layer.addSublayer(moonLayer)
        pixelBloomView.isUserInteractionEnabled = false
        addSubview(pixelBloomView)
    }

    /// Returns already-visible content to its occluded state so `reveal` can
    /// play again during the cleanup pass.
    func prepareToRevealAgain() {
        guard didReveal else { return }
        didReveal = false
        isAccessibilityElement = false
        accessibilityElementsHidden = !standsInForItsContent
        installOcclusion()
        setNeedsLayout()
        layoutIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        clippedContent.frame = bounds
        contentHost.frame = clippedContent.bounds
        contentHost.layoutIfNeeded()
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
        let signedTravel = sweepsUpward ? -travel : travel
        let finalCircle = initialCircleFrame.offsetBy(dx: 0, dy: signedTravel)
        let transform = CATransform3DMakeTranslation(0, signedTravel, 0)

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

        // The content's own light: same front, same time-constant cooling as
        // the glyph bloom beside it, slaved to the same rendered edge. The
        // emitter's luminance floor guarantees even its dark pixels bloom;
        // the gain sits below the text's so a picture reads a shade dimmer
        // than the glyph strokes beside it.
        let frontSpeed = travel / CGFloat(max(resolvedDuration, 0.001))
        pixelBloomView.reveal(
            circleTravel: signedTravel,
            duration: OnboardingAnimationClock.displayLinkDuration(
                resolvedDuration),
            edgeBandScale: max(
                1, frontSpeed / GlyphPixelBloomView.referenceFrontSpeed),
            emitterGain: OnboardingSafariPageTiming.imageBloomGain,
            offsetProvider: { [weak moonLayer] in
                moonLayer?.presentation().map { CGFloat($0.transform.m42) }
            })

        DispatchQueue.main.asyncAfter(
            deadline: .now() + OnboardingAnimationClock.delay(resolvedDuration)
        ) { [weak self] in
            guard let self, self.didReveal else { return }
            self.contentHost.layer.mask = nil
            self.moonLayer.removeFromSuperlayer()
            self.pixelBloomView.stop()
            self.pixelBloomView.removeFromSuperview()
            self.isAccessibilityElement = self.standsInForItsContent
            self.accessibilityElementsHidden = false
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
            y: sweepsUpward
                ? bounds.height + 1 + sagitta - diameter
                : -1 - sagitta,
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

    /// The bloom's emitter: the content exactly as displayed (aspect fill and
    /// corner mask included), with its alpha rebuilt from LUMINANCE. The
    /// bloom's halos are Quartz shadows, and shadows key off alpha — a
    /// photograph is opaque everywhere, so left as-is its black sky would cast
    /// the same white glow as a full moon and the band would read as a solid
    /// white slab crossing the frame. With luminance as alpha the light lands
    /// on the content's bright pixels exactly the way it lands on glyph
    /// strokes. The occlusion mask is lifted for the render — rasterizing
    /// through it left only the sliver above the initial edge, killing the
    /// light a few points into the sweep.
    private func rasterizedContent() -> UIImage? {
        guard contentHost.bounds.width > 0, contentHost.bounds.height > 0
        else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = traitCollection.displayScale
        format.opaque = false
        let occlusionMask = contentHost.layer.mask
        contentHost.layer.mask = nil
        defer { contentHost.layer.mask = occlusionMask }
        let rendered = UIGraphicsImageRenderer(
            bounds: contentHost.bounds, format: format
        ).image { context in
            contentHost.layer.render(in: context.cgContext)
        }
        guard let cgContent = rendered.cgImage else { return nil }

        // A GRAYSCALE masking image sets the result's alpha to its own
        // sample value — white keeps, black removes (verified empirically;
        // the black-shows rule belongs to true image masks). The content's
        // plain luminance therefore leaves alpha proportional to
        // brightness. Transparent raster regions (the corner mask) land on
        // the black prefill: masked out, as they should be. The luminance
        // is then clamped from below WITHIN the content's own alpha — a
        // lighten fill clipped to it — so dark pixels still bloom under the
        // front while the corner-masked regions stay dark.
        let width = cgContent.width
        let height = cgContent.height
        guard let gray = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return rendered }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        gray.setFillColor(gray: 0, alpha: 1)
        gray.fill(rect)
        gray.draw(cgContent, in: rect)
        gray.saveGState()
        gray.clip(to: rect, mask: cgContent)
        gray.setBlendMode(.lighten)
        gray.setFillColor(
            gray: OnboardingSafariPageTiming.imageLuminanceFloor, alpha: 1)
        gray.fill(rect)
        gray.restoreGState()
        guard let luminance = gray.makeImage(),
              let emitter = cgContent.masking(luminance)
        else { return rendered }
        return UIImage(
            cgImage: emitter, scale: rendered.scale, orientation: .up)
    }

    private func revealPath(excluding circleFrame: CGRect) -> CGPath {
        let path = UIBezierPath(rect: bounds)
        path.append(UIBezierPath(ovalIn: circleFrame))
        path.usesEvenOddFillRule = true
        return path.cgPath
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
        accessibilityIdentifier = "onboarding.safari.page.newsletterPopup"
        backgroundColor = OnboardingSafariPagePalette.paper
        layer.cornerRadius = 18
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.5
        layer.shadowRadius = 26
        layer.shadowOffset = CGSize(width: 0, height: 14)

        title.text = "Subscribe to our newsletter"
        title.font = .systemFont(ofSize: 22, weight: .bold)
        title.textColor = OnboardingSafariPagePalette.ink
        title.textAlignment = .center
        title.numberOfLines = 2
        title.adjustsFontSizeToFitWidth = true
        title.minimumScaleFactor = 0.8
        title.accessibilityIdentifier =
            "onboarding.safari.page.newsletterTitle"
        addSubview(title)

        subtitle.text = "We promise to spam you"
        subtitle.font = .systemFont(ofSize: 15, weight: .regular)
        subtitle.textColor = OnboardingSafariPagePalette.inkSecondary
        subtitle.textAlignment = .center
        subtitle.accessibilityIdentifier =
            "onboarding.safari.page.newsletterSubtitle"
        addSubview(subtitle)

        emailField.backgroundColor = UIColor(white: 0.94, alpha: 1)
        emailField.layer.cornerRadius = 10
        emailField.layer.cornerCurve = .continuous
        emailField.layer.borderWidth = 1
        emailField.layer.borderColor = UIColor(white: 0.84, alpha: 1).cgColor
        emailField.accessibilityIdentifier =
            "onboarding.safari.page.newsletterEmail"
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
            "onboarding.safari.page.newsletterSubmit"
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
        accessibilityIdentifier = "onboarding.safari.page.subscriptionSheet"
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

        title.text = "Subscribe to keep reading"
        title.font = .systemFont(ofSize: 24, weight: .bold)
        title.textColor = OnboardingSafariPagePalette.ink
        title.textAlignment = .center
        title.numberOfLines = 2
        title.adjustsFontSizeToFitWidth = true
        title.minimumScaleFactor = 0.8
        title.accessibilityIdentifier =
            "onboarding.safari.page.subscriptionTitle"
        addSubview(title)

        bodyText.text = "You've reached your free article limit for this "
            + "month. Get unlimited access to independent journalism."
        bodyText.font = .systemFont(ofSize: 15, weight: .regular)
        bodyText.textColor = OnboardingSafariPagePalette.inkSecondary
        bodyText.textAlignment = .center
        bodyText.numberOfLines = 3
        bodyText.accessibilityIdentifier =
            "onboarding.safari.page.subscriptionBody"
        addSubview(bodyText)

        subscribeButton.text = "Subscribe for $4.99/month"
        subscribeButton.font = .systemFont(ofSize: 17, weight: .semibold)
        subscribeButton.textColor = .white
        subscribeButton.textAlignment = .center
        subscribeButton.backgroundColor = OnboardingSafariPagePalette.ink
        subscribeButton.layer.cornerRadius = 12
        subscribeButton.layer.cornerCurve = .continuous
        subscribeButton.clipsToBounds = true
        subscribeButton.accessibilityIdentifier =
            "onboarding.safari.page.subscriptionSubmit"
        addSubview(subscribeButton)

        signIn.text = "Already a subscriber? Sign in"
        signIn.font = .systemFont(ofSize: 14, weight: .medium)
        signIn.textColor = UIColor(red: 0.07, green: 0.36, blue: 0.86, alpha: 1)
        signIn.textAlignment = .center
        signIn.accessibilityIdentifier =
            "onboarding.safari.page.subscriptionSignIn"
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

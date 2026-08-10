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
}

/// Luna's own `luna.app` page about the Safari extension, as Safari would show
/// it. The page loads already buried under ads, popups and a subscription wall;
/// once the mock extension-enable sequence completes, the clutter crumbles
/// bottom-to-top. The content itself never goes anywhere or animates: what the
/// extension takes away is the clutter, so the page underneath stays exactly
/// where the reader last saw it.
///
/// The content is the explanation (`OnboardingSafariExtensionCopy`): what the
/// extension takes off a page, that it all happens on the device, that anything
/// worth keeping is one tap from Luna — then the three steps that switch it on,
/// each beside a picture of the exact chrome it names. Its own call to action is
/// the LAST thing on the page rather than a card floating over it, and the
/// steps and actions are anchored to the bottom above the browser chrome
/// whatever the screen's height: the Safari button — wearing the launch eclipse
/// corona, and once the page is clean breathing for its tap exactly as the
/// Messages pills do — sits where the wave first enters, and the copy stacks
/// upward from it.
///
/// It is native instead of HTML so those glyph-level effects are possible.
final class OnboardingSafariPageView: UIView {
    var onActivateSafari: (() -> Void)?
    var onSkipSafariSetup: (() -> Void)?

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
    /// arrives, even though each element runs its own bloom.
    private struct FrontLeg {
        let top: CGFloat
        let bottom: CGFloat
        let start: TimeInterval
        let speed: CGFloat

        func arrival(at y: CGFloat) -> TimeInterval {
            start + TimeInterval(max(0, bottom - max(y, top)) / speed)
        }
    }

    /// One stationary page element whose frame gives the shatter front its
    /// timing. The content is deliberately not animated by that front.
    private struct WaveElement {
        let view: UIView
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
    /// True from the corona's ignition until the user takes one of the page's
    /// actions: the button and its corona are breathing for the tap.
    private var isPulsingActions = false

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
    private var waveElements: [WaveElement] = []
    private var preparedShatterPieces: [ShatterPiece] = []
    /// Every tile the current wipe put on screen. `preparedShatterPieces`
    /// empties the moment the flights are handed out, so a replay needs its
    /// own handle on them to clear a wipe that is still in the air.
    private var shatterTiles: [UIView] = []
    private var frontLegs: [FrontLeg] = []

    /// Whose prose the page prints. The chunks differ per app, so the fitting
    /// pass needs to know which list it is choosing a prefix of.
    private let app: LunaApp

    init(configuration: OnboardingSurfaceConfiguration = .current) {
        // Safari lists this app's own extension under this app's own name; the
        // page's steps have to say the same thing (see the copy's note).
        let appName = configuration.demonstrationApp.displayName
        let background = OnboardingSafariPagePalette.background
        app = configuration.demonstrationApp
        appIcon = MoonRevealContentView(
            image: LunaAppIconImage.image(for: configuration.demonstrationApp)
                ?? UIImage(systemName: "moon.stars.fill"),
            cornerRadius: 17,
            accessibilityLabel: appName,
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
        // The shortest valid prose, so the page is publishable before it has a
        // size; `layOutContent` grows it to whatever the screen can hold.
        explainer = MoonRevealLineView(
            text: OnboardingSafariExtensionCopy.explainerPrefix(
                1, for: configuration.app),
            initiallyRevealed: true,
            font: Self.proseFont,
            textAlignment: .left,
            numberOfLines: 0,
            minimumScaleFactor: 1,
            lineSpacing: Self.proseLineSpacing,
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
                    accessibilityLabel: step.text,
                    sweepsUpward: true)
            }
        let actionsView = OnboardingSafariActionsView()
        self.actionsView = actionsView
        actions = MoonRevealContentView(
            content: actionsView,
            accessibilityLabel: nil,
            sweepsUpward: true)

        super.init(frame: .zero)
        backgroundColor = background
        accessibilityIdentifier = OnboardingStrings.Accessibility.safariPage.value()

        appIcon.accessibilityIdentifier = OnboardingStrings.Accessibility.safariAppIcon.value()
        headline.accessibilityIdentifier = OnboardingStrings.Accessibility.safariHeadline.value()
        byline.accessibilityIdentifier = OnboardingStrings.Accessibility.safariByline.value()
        explainer.accessibilityIdentifier = OnboardingStrings.Accessibility.safariExplainer.value()
        stepsHeading.accessibilityIdentifier =
            OnboardingStrings.Accessibility.safariStepsHeading.value()
        for (index, row) in stepRows.enumerated() {
            row.accessibilityIdentifier = OnboardingStrings.Accessibility.safariStep(index)
        }
        actions.accessibilityIdentifier = OnboardingStrings.Accessibility.safariActions.value()
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

        // Either action answers the button's plea, so either one ends it.
        actionsView.onActivate = { [weak self] in
            self?.endActionsPulse()
            self?.onActivateSafari?()
        }
        actionsView.onSkip = { [weak self] in
            self?.endActionsPulse()
            self?.onSkipSafariSetup?()
        }

        // Every fake obstruction is a decoration, buried over the page from
        // the very first frame; the mock extension-enable pass clears them.
        // The clutter sits ABOVE the whole page — the actions included — so no
        // element's own light can spill over a white popup during the wave.
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
    /// little air. The page's content stops here while the bar is up.
    static var chromeReserve: CGFloat {
        SafariBottomBar.reservedPageHeight + 12
    }

    /// What a page with no bar over it still keeps clear: the home-area strip
    /// with air above it, never less than the bar's own controls were worth, so
    /// the Safari button stays a thumb's reach off the bottom edge.
    static var clearedChromeReserve: CGFloat {
        max(SafariBottomBar.chromeHeight, SafariBottomBar.homeAreaHeight + 20)
    }

    /// What the page currently keeps clear at its bottom — `chromeReserve`
    /// while the browser bar is up, `clearedChromeReserve` once it has gone.
    private var bottomReserve = OnboardingSafariPageView.chromeReserve

    /// The browser bar is leaving (or coming back), and the page's bottom
    /// reserve follows it: with the bar gone the steps and the actions take
    /// back its strip, and they dodge it again the moment it returns.
    ///
    /// Call this BEFORE `prepareCleanUp`, never during the wave: the cascade's
    /// legs and every shatter tile's arrival are cut from the content frames as
    /// they stand, so the geometry the front will cross has to be settled first.
    func setReservesBrowserChrome(_ reserves: Bool) {
        let reserve = reserves ? Self.chromeReserve : Self.clearedChromeReserve
        guard reserve != bottomReserve else { return }
        bottomReserve = reserve
        setNeedsLayout()
        layoutIfNeeded()
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

    /// THE PAGE IS PINNED AT BOTH ENDS, AND THE PROSE FILLS WHAT IS LEFT.
    ///
    /// The header starts at `minimumTopInset`; the actions block ends exactly on
    /// the browser chrome's reserve, with the steps and their heading stacked
    /// above it — so the Safari button is in the same place on every screen, the
    /// wave has no dead middle to climb through, and the furniture (icon,
    /// headline, three steps, both buttons) is identical at every size. The only
    /// thing that varies is the PROSE: it takes the largest cumulative prefix of
    /// its chunks that fits between the byline and the steps heading, and
    /// whatever is left over becomes air above the steps. That slack is the
    /// tolerance the chunk granularity needs — no screen has to land on an exact
    /// multiple of a sub-topic. A container too short even for chunk one falls
    /// back to truncating it, rather than pushing the actions under the chrome.
    private func layOutContent(columnWidth: CGFloat, horizontalInset: CGFloat) {
        let bottomLimit = bounds.height - bottomReserve
        let rowHeight = OnboardingSafariEnableStepRowView.preferredHeight
        let actionsHeight = OnboardingSafariActionsView.preferredHeight
        let stepsHeight = CGFloat(stepRows.count) * rowHeight
            + CGFloat(max(stepRows.count - 1, 0)) * Self.stepGap
        let bottomGroupHeight = Self.headingHeight + Self.headingGap
            + stepsHeight + Self.stepsToActionsGap + actionsHeight
        let bottomGroupTop = bottomLimit - bottomGroupHeight

        var y = Self.minimumTopInset
        let proseTop = y + Self.headerHeight + Self.bylineGap
            + Self.bylineHeight + Self.proseGap
        // The prose is fitted against the FULL chrome reserve however much room
        // the page currently has: releasing the browser bar's strip mid-lesson
        // must not make another chunk of copy appear out of nowhere. The
        // reclaimed room becomes air above the steps instead.
        let proseRoom = max(
            0,
            bounds.height - Self.chromeReserve - bottomGroupHeight
                - Self.proseToStepsGap - proseTop)
        let prose = fittedProse(columnWidth: columnWidth, room: proseRoom)
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
        y += Self.headerHeight + Self.bylineGap
        byline.frame = CGRect(
            x: horizontalInset, y: y, width: columnWidth, height: Self.bylineHeight)
        y += Self.bylineHeight + Self.proseGap
        explainer.frame = CGRect(
            x: horizontalInset,
            y: y,
            width: columnWidth,
            height: prose.height)

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

    /// The largest cumulative chunk prefix that fits `room`, with the height to
    /// draw it at. Pure geometry over a width and a height — never an idiom or a
    /// size class (see CLAUDE.md's iPad rule): an iPad in half-screen Split View
    /// and a phone are the same fitting problem.
    ///
    /// Chunk one is the floor. When even it overruns (a degenerately short
    /// container), it is kept and its label truncates — the page never drops its
    /// opening sentence, and never lets the prose push the actions down.
    private func fittedProse(
        columnWidth: CGFloat,
        room: CGFloat
    ) -> (text: String, attributedText: NSAttributedString, height: CGFloat) {
        let chunks = OnboardingSafariExtensionCopy.explainerChunks(for: app)
        guard !chunks.isEmpty else { return ("", NSAttributedString(), 0) }
        var prose = Self.formattedProse(chunks: Array(chunks.prefix(1)))
        var height = Self.proseHeight(of: prose.attributedText, width: columnWidth)
        guard chunks.count > 1 else {
            return (prose.text, prose.attributedText, min(height, room))
        }
        for count in 2...chunks.count {
            let candidate = Self.formattedProse(chunks: Array(chunks.prefix(count)))
            let candidateHeight = Self.proseHeight(
                of: candidate.attributedText, width: columnWidth)
            guard candidateHeight <= room else { break }
            prose = candidate
            height = candidateHeight
        }
        return (prose.text, prose.attributedText, min(height, room))
    }

    /// THE prose typography, defined once. The measurement above, the label the
    /// page builds, and the tests that assert the fit all read these — the three
    /// used to carry their own copies of "17pt regular, lineSpacing 5", which is
    /// three places for one number to drift.
    static let proseFont = UIFont.systemFont(ofSize: 17, weight: .regular)
    static let proseLineSpacing: CGFloat = 5

    static func proseAttributes() -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = proseLineSpacing
        return [.font: proseFont, .paragraphStyle: style]
    }

    /// The first three ideas are features, so they read as a compact list.
    /// Any later chunks remain ordinary paragraphs. This changes hierarchy,
    /// never the localized words themselves.
    static func formattedProse(chunks: [String]) -> (text: String, attributedText: NSAttributedString) {
        let result = NSMutableAttributedString()
        let featureCount = min(chunks.count, 3)
        for (index, chunk) in chunks.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n")) }
            let style = NSMutableParagraphStyle()
            style.lineSpacing = proseLineSpacing
            if index < featureCount {
                style.firstLineHeadIndent = 0
                style.headIndent = 20
                style.paragraphSpacing = index == featureCount - 1 ? 9 : 4
                result.append(NSAttributedString(
                    string: "• \(chunk)",
                    attributes: [.font: proseFont, .paragraphStyle: style]))
            } else {
                style.paragraphSpacing = 9
                result.append(NSAttributedString(
                    string: chunk,
                    attributes: [.font: proseFont, .paragraphStyle: style]))
            }
        }
        return (chunks.joined(separator: "\n"), result)
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

    // Every one of these is spent against ONE budget: the shortest phone Luna
    // ships to (375×667) has to hold the whole stack above the browser chrome
    // with the FIRST prose chunk at its natural height. There is about a line of
    // slack at these numbers —
    // `testSafariPageFitsTheShortestPhoneWithoutTruncatingItsProse`
    // fails the moment a gap or that chunk grows past it.
    /// The header's own row: the headline's two lines, with the app icon
    /// centred against them.
    private static let headerHeight: CGFloat = 64
    private static let headerIconSide: CGFloat = 60
    private static let headerIconGap: CGFloat = 14
    private static let bylineHeight: CGFloat = 20
    private static let bylineGap: CGFloat = 8
    private static let proseGap: CGFloat = 10
    private static let headingHeight: CGFloat = 18
    private static let headingGap: CGFloat = 8
    private static let stepGap: CGFloat = 8
    private static let stepsToActionsGap: CGFloat = 18
    /// The least the prose above may be left from the steps below it.
    private static let proseToStepsGap: CGFloat = 20
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
            // A resize builds a new corona; the breath it replaces has to carry
            // over, or a rotation mid-plea leaves the button pulsing alone.
            applyActionsPulse()
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

        computeShatterCascade()
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

    /// One front still climbs the page, but it now times only the clutter tiles.
    /// Page content remains static and readable throughout the cleanup.
    private func computeShatterCascade() {
        let speed = OnboardingSafariPageTiming.cascadeFrontSpeed
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

    /// Shatters every obstruction bottom-to-top. The content beneath stays
    /// stationary; only the obstruction tiles move. The page's own actions are
    /// inert until the whole page is clean, and the corona then swells in behind
    /// the Safari button.
    ///
    /// The cascade starts one run-loop turn after `prepareCleanUp`'s work,
    /// never in the same turn: the preparation's heavy commit (tiles and
    /// rasters) otherwise lands between an animation's added wall-clock anchor
    /// and its first rendered frame, and the light at the top of the page —
    /// shine and all — starts already finished.
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
                view.actionsView.setActionsEnabled(true)
                view.igniteActionsCorona()
                completion?()
            }
        }
    }

    /// The corona blooms only once the page is whole. Bringing it up with the
    /// wave still climbing put a lamp behind the one element the light had
    /// already left. The breath waits for the bloom to finish — an opacity
    /// pulse added mid-fade fights the fade for the same layer.
    private func igniteActionsCorona() {
        guard let corona = actionsCorona else { return }
        guard !UIAccessibility.isReduceMotionEnabled else {
            corona.alpha = 1
            return
        }
        UIView.animate(withDuration: 0.5) {
            corona.alpha = 1
        } completion: { [weak self] _ in
            self?.beginActionsPulse()
        }
    }

    /// The Safari button asks for its tap exactly as the Messages pills do:
    /// `OnboardingAttentionPulse`'s breath, at the same rate and the same
    /// scale. Its glow is the corona it already wears rather than a shadow of
    /// its own, so the corona scales WITH the button — the two share a centre,
    /// so the light stays wrapped around the capsule — and brightens up to its
    /// own full strength on every swell.
    ///
    /// Deliberately NOT guarded on already-pulsing: CoreAnimation strips every
    /// animation off a layer when the app backgrounds, which is exactly what
    /// the hop out to Safari does, so the return leg has to be able to put the
    /// breath back rather than believe its own flag.
    private static let pulseAnimationKey =
        OnboardingStrings.AnimationKeys.attentionPulse.value()
    /// The corona carries two of the breath's curves at once, and one layer
    /// cannot file both under the same key.
    private static let pulseScaleKey =
        OnboardingStrings.AnimationKeys.attentionPulseScale.value()

    private func beginActionsPulse() {
        guard stage == .revealed,
              !UIAccessibility.isReduceMotionEnabled
        else { return }
        isPulsingActions = true
        applyActionsPulse()
    }

    private func applyActionsPulse() {
        guard isPulsingActions else { return }
        actionsView.activateButton.layer.add(
            OnboardingAttentionPulse.scale(), forKey: Self.pulseAnimationKey)
        // The corona shares the button's centre, so it swells WITH it and the
        // light stays wrapped around the capsule. Unlike a pill's, this one is
        // already burning: its breath falls to the trough and back to full
        // rather than lighting from nothing.
        guard let corona = actionsCorona else { return }
        corona.layer.add(
            OnboardingAttentionPulse.scale(), forKey: Self.pulseScaleKey)
        corona.layer.add(
            OnboardingAttentionPulse.glow(
                from: OnboardingAttentionPulse.litCoronaTroughAlpha),
            forKey: Self.pulseAnimationKey)
    }

    private func endActionsPulse() {
        isPulsingActions = false
        actionsView.activateButton.layer.removeAnimation(
            forKey: Self.pulseAnimationKey)
        actionsCorona?.layer.removeAnimation(forKey: Self.pulseAnimationKey)
        actionsCorona?.layer.removeAnimation(forKey: Self.pulseScaleKey)
    }

    /// Returning from Safari without the extension having run re-offers the
    /// page's own actions — and asks for the tap again.
    func reactivateActions() {
        actionsView.setActionsEnabled(true)
        beginActionsPulse()
    }

    /// Puts the page back exactly as it loads — buried under every
    /// obstruction, content beneath them, actions inert, corona dark — so the
    /// whole demonstration can play again.
    ///
    /// The Safari lesson is deliberately re-enterable: skipping returns to the
    /// intro with its button still live. Without this, a second entry landed on
    /// the finished page with nothing left to run and both of its buttons
    /// disabled by the tap that left (`OnboardingSafariActionsView` disables
    /// them on the way out), which is a dead end with no way back to the intro.
    func restoreBuriedPage() {
        // Drops anything the previous wipe still has scheduled.
        sequenceGeneration += 1
        stage = .blocked
        preparedShatterPieces = []
        frontLegs = []
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
        actionsView.setActionsEnabled(false)
        // A buried page asks for nothing: the plea belongs to the clean page,
        // and the next cascade's corona ignition starts it again.
        endActionsPulse()
        actionsCorona?.alpha = 0
        setNeedsLayout()
    }

    #if DEBUG
    /// The flag, not the animations: CoreAnimation drops an animation off a
    /// backgrounded layer, so only this survives a test that spins the run loop.
    var isPulsingActionsForTesting: Bool { isPulsingActions }
    #endif

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
        let pieceDuration = OnboardingSafariPageTiming.shatterDuration * 0.54
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
            animation.beginTime = commitTime + OnboardingAnimationClock.delay(piece.delay)
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
            deadline: .now() + OnboardingAnimationClock.delay(delay)
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

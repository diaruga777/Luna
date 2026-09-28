//
//  ArticleCardsViewController.swift
//  Luna
//
//  The Reader's root screen: a carousel of full-height cards over the reading
//  list, one article per card, replacing the sectioned table. The generic
//  carousel machinery lives in LunaDesignSystem/CardCarousel (shared with the
//  Downloader); this controller adapts saved articles into cards:
//
//  - EVERY card embeds the full live reader, laid out to the card's bounds
//    (side cards too, so paging never shows a placeholder). The card view IS
//    the fullscreen reader view — one header, one layout — so "fullscreen"
//    is not a separate presentation.
//  - Going fullscreen fades the peeking side cards and bottom scrub strip, and
//    expands Scroll into the safe width. Wide windows browse a horizontal rail;
//    tapping or vertically scrolling a visible card expands it for reading.
//    Portrait phones keep directional scroll chrome (down hides, up restores).
//    In RSVP, playing fades them out and pausing fades them back. The
//    reader's own header never moves or changes.
//  - Long-pressing a card exposes its archive action through a context menu.
//  - Horizontal swipes INSIDE the card page to the neighbor (readers have no
//    timeline to scrub); the scrub strip shows mini-card chips, each badged
//    with the article's source (favicon / sender initials / symbol fallback).
//

import LunaArchiveReader
import LunaDesignSystem
import LunaFetch
import LunaModels
import LunaReaderUI
import LunaSaves
import LunaSavesUI
import LunaSocialUI
import LunaSocial
import LunaStorage
import LunaURLClassification
import UIKit

final class ArticleCardsViewController: CardCarouselHostViewController,
    CardDeckFallbackContentProviding {

    private let store = SavesStore.shared
    // Screen-level reader chrome (see mountTopChrome / configureTrailingBottomButton).
    private let readerChromeRow = ReaderChromeRowView()
    /// The focused RSVP reader's eye-tracking toggle while this deck has
    /// adopted it into `readerChromeRow` (see `syncAdoptedEyeTrackingToggle`).
    private weak var adoptedEyeTrackingToggle: UIButton?
    private let readerBackButton = UIButton(type: .system)
    private let readerAudioButton = UIButton(type: .system)
    private let readerModeControl = LunaSegmentedControl()
    /// The deck's trailing bottom circle, dressed as the reader's share pill.
    private var readerShareButton: UIButton { trailingBottomButton }
    private let footerContentFade = ReaderFooterContentFadeView()
    private weak var readerForChrome: ReaderChromeControlling?
    /// The reader's scroll indicator, hosted here (not inside the card) so it can
    /// slide from the card's trailing edge out to the screen edge as the card
    /// immerses — the card's own clip would otherwise trap it at the card edge.
    /// (Self-installed indicators inside the card remove themselves; see
    /// `HorizonScrollIndicator`.) It tracks the ROOT card reader; a link-opened
    /// inline reader is a screen-level eclipse overlay that keeps its own
    /// self-installed indicator, so the host one steps aside for it.
    private let cardScrollIndicator = HorizonScrollIndicator.makeHosted()
    private var chromeModes: [SavedItem.ReaderMode] = []
    /// An unarchive reload must not let normal pull-availability reconciliation
    /// snap the still-open tray shut before its coordinated dismissal begins.
    private var isAnimatingFromArchiveTray = false
    /// The nested reader currently living in the column beside the centered card
    /// (wide screens only). Strongly held through containment; this reference is
    /// the flag "the deck is paired" that immersion, paging, and the trays check.
    private weak var inlineColumn: SplitWebOverlayViewController?

    /// A dismissed scroll-reader card nearly fills the large/wide viewport.
    /// The remaining gap keeps the rounded mask legible against the screen.
    private static let expandedReaderHorizontalInset: CGFloat = 16

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LunaColors.background
        // Handed to the carousel as chrome, so it fades away with the scrub
        // strip and side cards when a reader takes over the screen.
        carousel.usesAdaptiveReaderRail = true
        carousel.chromeBackdrop = StarfieldView.install(behindContentsOf: view)

        var style = CardCarouselStyle()
        style.pageSwipeMovementMultiplier = 1.5
        // No card shape here: an article card's shape is the ARTICLE kind's
        // answer (`ArticleCardPresenter.cardStyle`), and in this app — the
        // central one — a media or product card beside it gets its own.
        // The strip's actual viewport begins/ends at the inner edges of the
        // flanking 44pt Settings/Share circles (12pt outer margin). Its chips
        // alpha-fade as they approach those bounds.
        style.scrubberHorizontalInset = 56
        style.scrubberEdgeFadeWidth = 28
        // Glass rim so the cards (and the dimmed side peeks, especially in dark
        // mode) read against a same-tone background; fades with the chrome on
        // immersion.
        style.showsCardBorder = true
        carousel.managesAudioSession = false   // Reader has its own audio stack.
        // The cards themselves come from the ONE provider, exactly as the other
        // three apps' roots do. This class contributes screen chrome and nothing
        // else — it holds no slots, no ordering and no kind logic.
        configure(style: style) { host in
            var configuration = CardDeckConfiguration()
            // Reader and the central app both have a reader card to fall back
            // on, so a save whose kind holds nothing yet is still a card here.
            configuration.showsSavesWithoutKindContent = true
            configuration.fallbackContentProvider = host as? ArticleCardsViewController
            return KindDeckProvider(host: host, configuration: configuration)
        }
        // The header row and the flanking Settings/Share circles persist through
        // immersion — only the carousel's own chrome (side cards, scrub strip,
        // card rims) fades while reading.
        mountDeck()
    }

    /// Above the carousel (so it clears the card's clip) but below the screen
    /// chrome the flanking circles add (so the header/footer pills stay on top).
    /// Host-positioned every layout — no Auto Layout.
    override func deckWillMountBottomControls() {
        cardScrollIndicator.isHidden = true
        view.addSubview(cardScrollIndicator)

        // Immersion extends the reader below its resting card edge. Keep that
        // extra content from entering the footer controls' safe area: the veil
        // becomes fully opaque exactly at the buttons' top edge.
        footerContentFade.alpha = 0
        footerContentFade.isUserInteractionEnabled = false
        view.addSubview(footerContentFade)
    }

    override func deckDidMountBottomControls() {
        mountModeSwitcher()
        mountTopChrome()
    }

    /// No tray pull while a second reader column is open beside the card.
    override var deckAllowsArchivePull: Bool { inlineColumn == nil }

    override func deckArchiveTrayOpenStateDidChange(_ open: Bool) {
        readerAudioButton.isHidden = open
        super.deckArchiveTrayOpenStateDidChange(open)
    }

    override var deckReconcilesArchivePullOnReload: Bool { !isAnimatingFromArchiveTray }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reconcileFooterContentFade()
    }

    override func deckCarouselInsetsDidChange() {
        updateExternalReaderInsets()
    }

    /// The footer veil belongs to an immersed, bottom-extended reader and to
    /// nothing else. It is raised and lowered from the immersion callbacks, so a
    /// card torn down — or a deck reloaded, or a fresh root swapped in, which is
    /// exactly what completing onboarding does — while it is up leaves it
    /// stranded OPAQUE. The one thing it sits above is the scrub strip, so that
    /// reads as a black shroud over the mini carousel with the flanking Settings
    /// and Share circles still drawn on top of it. Reconciled at the points
    /// where no immersion animation can be in flight, so a stranded veil cannot
    /// outlive the state that raised it.
    private func reconcileFooterContentFade() {
        guard !carousel.isImmersed, footerContentFade.alpha != 0 else { return }
        footerContentFade.alpha = 0
    }

    /// The height of the screen-level chrome row. It spans safeTop+4 …
    /// safeTop+48, and the 48 is `CardDeckGeometry.topClearance` — the clearance
    /// EVERY deck reserves above the card area is precisely this row, which is
    /// why the row's height is derived from it rather than agreeing with it by
    /// coincidence.
    private static let topChromeClearance: CGFloat = CardDeckGeometry.topClearance - 4

    /// Diameter of the row's circular chrome buttons. Pinned on BOTH axes: the
    /// glass configuration is a capsule, so a width free to follow the glyph's
    /// intrinsic size turns the circle into an oval the moment a wider symbol
    /// is swapped in (`speaker.wave.2` is wider than `speaker.slash`).
    private static let chromeButtonDiameter: CGFloat = 38

    /// How far inside the centered card's top corners the row's circles sit —
    /// the same corner inset the carousel's own card chrome uses.
    private static let chromeCardCornerInset: CGFloat = 12

    /// The depth of the dissolve at the card's top and bottom edges: scrolled
    /// content fades out over this run instead of hitting a hard clip. The
    /// resting scroll position sits just below the top fade so an unscrolled
    /// page starts fully legible.
    private static let contentEdgeFade: CGFloat = 28

    /// Floats the control row inside the centered card's top corners — no bar,
    /// fill, or blur behind it. Placement is driven by the live resting card
    /// frame (see `layoutReaderChromeRow`), not the screen edges: the card sits
    /// `peek + edgeGap` inside them, so screen-relative insets left the circles
    /// straddling the card's rim.
    private func mountTopChrome() {
        readerChromeRow.backgroundColor = .clear
        // The card's own reader carries buttons with these same labels (hidden
        // while the deck's row drives them), so the row is addressable by name.
        readerChromeRow.accessibilityIdentifier = "cards.readerChromeRow"
        view.addSubview(readerChromeRow)

        configureChromeButton(
            readerBackButton, symbol: "chevron.backward", action: #selector(readerBackTapped),
            label: L10n.string("Common_back"))
        configureChromeButton(
            readerAudioButton, symbol: "speaker.slash", action: #selector(readerAudioTapped),
            label: L10n.string("Reader_readAloudChromeAccessibilityLabel"))
        for control in [readerBackButton, readerAudioButton] {
            readerChromeRow.addSubview(control)
        }

        NSLayoutConstraint.activate([
            readerBackButton.leadingAnchor.constraint(equalTo: readerChromeRow.leadingAnchor),
            readerBackButton.centerYAnchor.constraint(equalTo: readerChromeRow.centerYAnchor),
            readerAudioButton.trailingAnchor.constraint(equalTo: readerChromeRow.trailingAnchor),
            readerAudioButton.centerYAnchor.constraint(equalTo: readerChromeRow.centerYAnchor),
        ])
        layoutReaderChromeRow()
        updateReaderChrome()
    }

    /// Sits the row's two circles `chromeCardCornerInset` inside the centered
    /// card's top corners, never above the safe area (a card clamped short of
    /// its aspect leaves its top edge below the row's minimum). The circles are
    /// centred in the taller row, so the row itself starts half the slack above
    /// where they should.
    ///
    /// Framed rather than constrained, deliberately: the card's own frame is not
    /// Auto Layout driven, so constants read back from it would only take effect
    /// on the NEXT layout pass — right on screen, wrong for anything (a test, a
    /// snapshot) that lays out exactly once.
    private func layoutReaderChromeRow() {
        // The carousel resolves its metrics in its OWN layout pass, which runs
        // after this one; without settling it first the very first pass has no
        // card frame to place the row against.
        carousel.view.layoutIfNeeded()
        let card = carousel.restingCenteredCardFrame(in: view)
        let inset = Self.chromeCardCornerInset
        let slack = (Self.topChromeClearance - Self.chromeButtonDiameter) / 2
        let minimumTop = view.safeAreaInsets.top + 4
        let top = max(minimumTop, (card?.minY ?? minimumTop) + inset - slack)
        let leading = (card?.minX ?? 12) + inset
        let trailing = (card?.maxX ?? (view.bounds.width - 12)) - inset
        readerChromeRow.frame = CGRect(
            x: leading, y: top,
            width: max(trailing - leading, Self.chromeButtonDiameter * 2),
            height: Self.topChromeClearance)
        readerChromeRow.layoutIfNeeded()
        layoutAdoptedEyeTrackingToggle()
    }

    /// The RSVP eye-tracking toggle is the reader's own control — the reader
    /// keeps driving its state and handling its taps — but its seat is this
    /// row's LEADING edge: the card's top-left, mirroring the read-aloud
    /// circle on the right. Adopted while the focused card renders RSVP,
    /// released the moment it doesn't (the reader reclaims it on its next
    /// layout pass, and hosts that never adopt keep the in-reader fallback).
    private func syncAdoptedEyeTrackingToggle() {
        let toggle = (readerForChrome as? RabbitHoleReaderViewController)?
            .focusedEyeTrackingToggle
        guard toggle !== adoptedEyeTrackingToggle else {
            layoutAdoptedEyeTrackingToggle()
            return
        }
        adoptedEyeTrackingToggle?.removeFromSuperview()
        adoptedEyeTrackingToggle = toggle
        if let toggle {
            readerChromeRow.addSubview(toggle)
            layoutAdoptedEyeTrackingToggle()
        }
    }

    /// Framed manually (the toggle returns to a manually-framed life inside
    /// the reader when released, so it never carries Auto Layout constraints).
    /// It yields the very corner to the back circle when a dive is showing.
    private func layoutAdoptedEyeTrackingToggle() {
        guard let toggle = adoptedEyeTrackingToggle else { return }
        let diameter = Self.chromeButtonDiameter
        let x = readerBackButton.isHidden ? 0 : diameter + 8
        toggle.frame = CGRect(
            x: x, y: (readerChromeRow.bounds.height - diameter) / 2,
            width: diameter, height: diameter)
    }

    private func configureChromeButton(
        _ button: UIButton, symbol: String, action: Selector, label: String
    ) {
        button.configuration = GlassStyle.circularButtonConfiguration(symbol: symbol, padding: 8)
        button.tintColor = GlassStyle.readingAccent
        button.accessibilityLabel = label
        button.addTarget(self, action: action, for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: Self.chromeButtonDiameter),
            button.heightAnchor.constraint(equalToConstant: Self.chromeButtonDiameter),
        ])
    }

    /// The reader's resting scroll position clears the card's top edge fade;
    /// content scrolled past it dissolves inside the fade run.
    private func updateExternalReaderInsets() {
        for index in [carousel.currentIndex - 1, carousel.currentIndex, carousel.currentIndex + 1] {
            (carousel.contentController(at: index) as? ReaderCardContentViewController)?
                .setTopContentInset(Self.contentEdgeFade)
        }
    }

    /// True only while the immersion slide is mid-flight, so routine layout
    /// passes (which the card's bottom-extension provokes) don't snap the
    /// indicator to its target and cut the animation short.
    private var isIndicatorSliding = false

    /// The read-aloud circle's twin of `isIndicatorSliding`.
    private var isAudioToggleSliding = false

    /// Parks the read-aloud circle at the safe screen top-right while the card
    /// is immersed: the widened card would otherwise run its text under the
    /// circle's card-corner seat. It keeps `chromeCardCornerInset` against its
    /// new edges (the same margin it keeps against the card's), slides on the
    /// immersion's own 0.32s ease-in-out, and returns to the card corner with
    /// the chrome. A transform, not a re-frame, so the row's layout stays the
    /// single card-corner answer for every circle.
    private func layoutReaderAudioToggle(animated: Bool) {
        let target: CGAffineTransform
        if carousel.isImmersed {
            let inset = Self.chromeCardCornerInset
            let diameter = Self.chromeButtonDiameter
            // `center` and the row's frame ignore the button's own transform,
            // so this is the circle's card-corner seat mid-slide too.
            let seat = CGRect(
                x: readerChromeRow.frame.minX + readerAudioButton.center.x - diameter / 2,
                y: readerChromeRow.frame.minY + readerAudioButton.center.y - diameter / 2,
                width: diameter, height: diameter)
            target = CGAffineTransform(
                translationX: view.bounds.maxX - inset - seat.maxX,
                y: view.safeAreaInsets.top + inset - seat.minY)
        } else {
            target = .identity
        }
        guard readerAudioButton.transform != target else { return }
        guard animated else {
            readerAudioButton.transform = target
            return
        }
        isAudioToggleSliding = true
        UIView.animate(
            withDuration: 0.32, delay: 0, options: [.curveEaseInOut, .allowUserInteraction],
            animations: { self.readerAudioButton.transform = target },
            completion: { [weak self] _ in self?.isAudioToggleSliding = false })
    }

    /// Places the reader's scroll indicator at the centered card's trailing edge,
    /// sliding it out to the screen edge while the card is immersed. Only the
    /// indicator moves — the reader keeps its inset, so nothing relayouts.
    /// Hidden when the centered card has no scrollable reader (no article yet,
    /// or RSVP, whose word display has nothing to scroll).
    private func layoutCardScrollIndicator(animated: Bool) {
        // Only the root card reader is host-tracked; a link-opened inline reader
        // (an over-screen eclipse overlay) keeps its own self-installed indicator.
        guard let reader = readerForChrome as? RabbitHoleReaderViewController,
              let scrollView = reader.focusedContentScrollView,
              let resting = carousel.restingCenteredCardFrame(in: view)
        else {
            cardScrollIndicator.isHidden = true
            cardScrollIndicator.track(nil)
            return
        }
        cardScrollIndicator.isHidden = false
        cardScrollIndicator.track(scrollView)

        let width = HorizonScrollIndicator.bloomDiameter
        let immersed = carousel.isImmersed
        // Trailing edge: the card's at rest, the screen's while immersed. The
        // bar keeps its card-mode height and vertical position in both modes —
        // immersion only slides it horizontally to the screen edge.
        let rightEdge = immersed ? view.bounds.maxX : resting.maxX
        let top = resting.minY
        let bottom = resting.maxY
        let frame = CGRect(
            x: rightEdge - width, y: top, width: width, height: max(bottom - top, 0))
        // Keep the dot inside the card's top/bottom edge dissolves.
        cardScrollIndicator.trackInsets = UIEdgeInsets(
            top: Self.contentEdgeFade, left: 0, bottom: Self.contentEdgeFade, right: 0)

        let apply = {
            self.cardScrollIndicator.frame = frame
            self.cardScrollIndicator.layoutIfNeeded()
        }
        if animated {
            isIndicatorSliding = true
            UIView.animate(
                withDuration: 0.32, delay: 0, options: [.curveEaseInOut, .allowUserInteraction],
                animations: apply, completion: { [weak self] _ in self?.isIndicatorSliding = false })
        } else {
            apply()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutReaderChromeRow()
        // Rotation (or a Split View resize) moves the column with the card it
        // sits beside; a container that has stopped being wide enough for two
        // columns closes it rather than leaving it half off screen.
        if let inlineColumn {
            if let frame = inlineColumnFrame {
                inlineColumn.view.frame = frame
            } else {
                closeInlineColumn(inlineColumn)
            }
        }
        if !isIndicatorSliding { layoutCardScrollIndicator(animated: false) }
        if !isAudioToggleSliding { layoutReaderAudioToggle(animated: false) }
        let fadeStart = settingsButton.frame.minY - Self.contentEdgeFade
        footerContentFade.frame = CGRect(
            x: 0, y: fadeStart, width: view.bounds.width,
            height: max(view.bounds.maxY - fadeStart, 0))
        footerContentFade.setFadeHeight(Self.contentEdgeFade)
    }

    /// The centered card's URL when that card is a LOCKED save — the one case
    /// where the deck's Share pill has something to offer with no reader behind
    /// it. Derived rather than stored: `readerForChrome` is assigned from six
    /// places, and a stored twin would only have to be remembered at each of
    /// them. Nil for every other card, which is also what hides the pill.
    private var lockedShareURLString: String? {
        guard let item = centeredItem, item.state == .needsCaptcha else { return nil }
        // An ARTICLE that is locked. The kind test is the registry's, not a
        // hand-written one: a media or product save can also be `.needsCaptcha`
        // and neither wants the reader's link pill.
        guard CardKindPresenters.presenter(for: item) === CardKindPresenters.article
        else { return nil }
        return item.urlString
    }

    private func updateReaderChrome() {
        let state = readerForChrome?.chromeState
        readerChromeRow.isHidden = state == nil
        readerBackButton.isHidden = state?.showsBack != true
        syncAdoptedEyeTrackingToggle()
        guard let state else {
            readerAudioButton.isHidden = true
            readerModeControl.isHidden = true
            // No reader behind the card, but the pill can still have something
            // to offer: a locked save's URL, or a media save's ladder from its
            // own kind's provider (Copy link / Share link / Share video…).
            readerShareButton.isHidden = lockedShareURLString == nil
                && providerShareMenu(from: readerShareButton) == nil
            return
        }
        readerAudioButton.setImage(
            UIImage(systemName: state.isAudioOn ? "speaker.wave.2" : "speaker.slash"), for: .normal)
        readerAudioButton.accessibilityValue = state.isAudioOn
            ? L10n.string("Reader_audioOnAccessibilityValue") : L10n.string("Reader_audioOffAccessibilityValue")

        if chromeModes != state.modes {
            chromeModes = state.modes
            readerModeControl.removeAllSegments()
            for (index, mode) in state.modes.enumerated() {
                readerModeControl.insertSegment(
                    with: ReaderModeIcons.image(for: mode), at: index, animated: false)
            }
        }
        readerModeControl.selectedSegmentIndex = state.modes.firstIndex(of: state.selectedMode) ?? 0
        readerModeControl.isHidden = !state.isArticle
        updateBottomModeSwitcher(immersed: carousel.isImmersed, animated: false)
        readerAudioButton.isHidden = !state.isArticle
        readerShareButton.isHidden = !state.offersSaveShare
    }

    /// The centered card's share menu as its own KIND offers it — a downloaded
    /// media save's Copy link / Share link / Share video ladder. No kind test is
    /// needed: the article presenter offers no menu of its own (its reader's
    /// richer ladder outranks it in the build chain), so asking every kind the
    /// same question answers nil for articles by itself.
    private func providerShareMenu(from sourceView: UIView) -> UIMenu? {
        guard let item = centeredItem else { return nil }
        return presenter(forItem: item)?.shareMenu(
            for: item, host: self, sourceView: sourceView)
    }

    /// The locked card's single share verb. A locked save has no extracted text,
    /// no eBook and no audio, so the reader's richer share ladder has nothing to
    /// offer — the link is the whole of it (the same reasoning as the failed
    /// card's menu in `claudedocs/failed-saves.md`).
    private func lockedShareMenu() -> UIMenu? {
        guard lockedShareURLString != nil else { return nil }
        return UIMenu(children: [
            UIAction(
                title: L10n.string("Common_shareLinkEllipsis"),
                image: UIImage(systemName: "square.and.arrow.up")
            ) { [weak self] _ in self?.shareLockedCardLink() },
        ])
    }

    private func shareLockedCardLink() {
        guard let urlString = lockedShareURLString else { return }
        // Straight to the SYSTEM sheet, not `AppReaderShareProvider`'s ladder: a
        // locked save has no extracted text, so that ladder's "Send as email" row
        // would offer to send nothing (and it drops "Export as…" for exactly the
        // same reason). Same reasoning, same call, as the failed card
        // (`FailedSaveCardFactory`).
        SendToFriendSheet.shareLink(
            urlString: urlString, from: self, sourceView: readerShareButton)
    }

    @objc private func readerBackTapped() { readerForChrome?.chromeBack(); updateReaderChrome() }
    @objc private func readerAudioTapped() { readerForChrome?.chromeToggleAudio(); updateReaderChrome() }
    @objc private func readerModeChanged() {
        guard chromeModes.indices.contains(readerModeControl.selectedSegmentIndex) else { return }
        readerForChrome?.chromeSetMode(chromeModes[readerModeControl.selectedSegmentIndex])
        updateReaderChrome()
    }

    /// The reader's share pill takes the deck's trailing circle. It is a MENU
    /// rather than a tap handler — and it is retargeted as the focused reader
    /// changes, so the menu is built fresh on each press against whatever
    /// `readerForChrome` points at now.
    override func configureTrailingBottomButton(_ button: UIButton) {
        configureBottomButton(
            button, symbol: "square.and.arrow.up", action: nil,
            accessibilityLabel: L10n.string("Common_share"))
        ShareButtonMenu.install(
            on: button,
            providesMenu: true,
            build: { [weak self] in
                guard let self else { return nil }
                if let menu = self.readerForChrome?.chromeShareMenu(from: button) {
                    return menu
                }
                // No reader: the pill belongs to a media save's own ladder, or
                // failing that to a locked save's single link.
                if let menu = self.providerShareMenu(from: button) {
                    return menu
                }
                return self.lockedShareMenu()
            },
            fallback: { [weak self] in
                guard let self else { return }
                guard self.readerForChrome != nil else {
                    self.shareLockedCardLink()
                    return
                }
                self.readerForChrome?.chromeShare(from: button)
            })
    }

    /// The pill's availability is not a share POLICY here — it is whatever the
    /// focused reader can offer, which `updateReaderChrome` already resolves
    /// alongside the rest of the row.
    override func refreshTrailingBottomButton() {
        updateReaderChrome()
    }

    /// The mode switcher owns the mini carousel's bottom-center lane only while
    /// the surrounding card chrome is dismissed. It begins just below its resting
    /// position so the first reveal can translate and fade in.
    private func mountModeSwitcher() {
        readerModeControl.addTarget(self, action: #selector(readerModeChanged), for: .valueChanged)
        readerModeControl.translatesAutoresizingMaskIntoConstraints = false
        readerModeControl.alpha = 0
        readerModeControl.transform = Self.dismissedBottomControlTransform
        readerModeControl.isUserInteractionEnabled = false
        readerModeControl.accessibilityElementsHidden = true
        view.addSubview(readerModeControl)
        NSLayoutConstraint.activate([
            readerModeControl.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            readerModeControl.centerYAnchor.constraint(
                equalTo: readerShareButton.centerYAnchor),
            readerModeControl.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    private static let dismissedBottomControlTransform = CGAffineTransform(
        translationX: 0, y: 8)

    /// Crossfades the bottom-center lane between the mini carousel and the
    /// reader modes. The carousel owns its matching scrubber animation; this
    /// half keeps the replacement control in exact visual lockstep.
    private func updateBottomModeSwitcher(immersed: Bool, animated: Bool) {
        let visible = immersed && !readerModeControl.isHidden
        readerModeControl.isUserInteractionEnabled = visible
        readerModeControl.accessibilityElementsHidden = !visible
        let changes = {
            self.readerModeControl.alpha = visible ? 1 : 0
            self.readerModeControl.transform = visible
                ? .identity
                : Self.dismissedBottomControlTransform
        }
        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            changes()
            return
        }
        UIView.animate(
            withDuration: 0.24, delay: visible ? 0.06 : 0,
            options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState],
            animations: changes)
    }

    // MARK: - Screen-level reader chrome the deck's own cards drive

    /// The card that just centered is a live reader, so the deck's header row,
    /// share pill, and hosted scroll indicator all retarget onto it.
    override func deckDidCenterCard(at index: Int) {
        guard slotIndex(forCarouselIndex: index) != nil else {
            readerForChrome = nil
            updateReaderChrome()
            layoutCardScrollIndicator(animated: false)
            return
        }
        let card = carousel.contentController(at: index) as? ReaderCardContentViewController
        card?.setCardChromeVisible(!carousel.isImmersed, animated: false)
        readerForChrome = card?.rabbitHoleReader
        updateExternalReaderInsets()
        updateReaderChrome()
        layoutCardScrollIndicator(animated: false)
    }

    /// The carousel has already restored its card geometry so this same pan can
    /// page. Keep the screen-level footer veil and indicator in lockstep.
    override func deckDidSurfaceForEdgePaging() {
        footerContentFade.alpha = 0
        (carousel.contentController(at: carousel.currentIndex) as? ReaderCardContentViewController)?
            .setCardChromeVisible(true, animated: false)
        archiveTray?.setChromeHidden(false, animated: false)
        updateBottomModeSwitcher(immersed: false, animated: false)
        layoutCardScrollIndicator(animated: false)
        layoutReaderAudioToggle(animated: false)
    }

    // MARK: - Data

    /// A real reload unmounts every slot, and with it the card that owns the open
    /// column's coordinator. Left standing, the column would keep drawing beside a
    /// card that no longer exists and its own close button — routed through that
    /// dead (weak) coordinator — would do nothing. Send it away first, while there
    /// is still something to send it back to.
    override func deckWillApplyReload() {
        if let inlineColumn { closeInlineColumn(inlineColumn) }
    }

    override func deckWillReload() {
        reconcileFooterContentFade()
    }

    // MARK: - Archive transitions

    /// The archive choreography. WHAT gets written is the kind's — the provider
    /// hands it in as `commit` — and this only says how the deck moves while it
    /// happens: the outgoing card drifts up and fades, then its neighbour
    /// springs into the centre.
    override func performArchive(ofItemID id: UUID, commit: @escaping () -> Void) {
        guard let slot = slots.firstIndex(where: { $0.id == id }) else {
            super.performArchive(ofItemID: id, commit: commit)
            return
        }
        let carouselIndex = self.carouselIndex(forSlot: slot)
        let isCentered = carousel.currentIndex == carouselIndex
        // The provider has already nominated the successor through
        // `pendingTransitionCenteredID`; the direction it arrives from is the
        // only part that is this deck's business.
        let incomingDirection: CGFloat = slot + 1 < slots.count ? 1 : (slot > 0 ? -1 : 0)

        let sourceCard = carousel.cardView(at: carouselIndex)
        let snapshot = sourceCard.flatMap(makeTransitionSnapshot(of:))

        commit()
        reload()

        guard isCentered, !UIAccessibility.isReduceMotionEnabled,
              UIView.areAnimationsEnabled else {
            snapshot?.removeFromSuperview()
            return
        }

        let incoming = carousel.cardView(at: carousel.currentIndex)
        incoming?.alpha = 0
        carousel.view.isUserInteractionEnabled = false

        let revealIncoming = { [weak self, weak incoming] in
            guard let self else { return }
            incoming?.transform = CGAffineTransform(
                translationX: incomingDirection * 28, y: 0).scaledBy(x: 0.985, y: 0.985)
            UIView.animate(
                withDuration: 0.42, delay: 0,
                usingSpringWithDamping: 0.88, initialSpringVelocity: 0.15,
                options: [.beginFromCurrentState, .allowUserInteraction]
            ) {
                incoming?.alpha = 1
                incoming?.transform = .identity
            } completion: { _ in
                incoming?.alpha = 1
                incoming?.transform = .identity
                self.carousel.view.isUserInteractionEnabled = true
            }
        }

        guard let snapshot else {
            revealIncoming()
            return
        }
        UIView.animate(
            withDuration: 0.24, delay: 0,
            options: [.curveEaseIn, .beginFromCurrentState, .allowUserInteraction]
        ) {
            snapshot.alpha = 0
            snapshot.transform = CGAffineTransform(translationX: 0, y: -20)
        } completion: { _ in
            snapshot.removeFromSuperview()
            revealIncoming()
        }
    }

    /// The unarchive choreography. As with `performArchive`, the store write is
    /// the kind's (`commit`) — every kind's unarchive stamps the row's bump date
    /// so it comes back at the front — and this is only the travel: the pressed
    /// tray cell dissolves into the destination card while the tray dismisses.
    override func performUnarchive(
        ofItemID id: UUID, from sourceView: UIView?, commit: @escaping () -> Void
    ) {
        guard let sourceView else {
            super.performUnarchive(ofItemID: id, from: nil, commit: commit)
            return
        }
        let snapshot = makeTransitionSnapshot(of: sourceView)
        isAnimatingFromArchiveTray = true
        pendingTransitionCenteredID = id

        // Reload synchronously so the destination exists before the tray and the
        // traveling snapshot begin their coordinated animation.
        commit()
        reload()
        view.layoutIfNeeded()

        let destination = carousel.cardView(at: carousel.currentIndex)
        destination?.alpha = 0
        let shouldAnimate = !UIAccessibility.isReduceMotionEnabled
            && UIView.areAnimationsEnabled && snapshot != nil && destination != nil

        archiveTray?.dismiss(animated: shouldAnimate)

        guard shouldAnimate, let snapshot, let destination else {
            snapshot?.removeFromSuperview()
            destination?.alpha = 1
            finishUnarchiveTransition()
            return
        }

        // The tray cell and reader card have intentionally different aspect
        // ratios. Morphing one snapshot frame into the other visibly stretches
        // the archived artwork, so keep the source geometry intact and dissolve
        // it into the already-final destination content instead.
        carousel.view.isUserInteractionEnabled = false
        destination.transform = CGAffineTransform(scaleX: 0.985, y: 0.985)
        UIView.animate(
            withDuration: 0.34, delay: 0,
            options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]
        ) {
            snapshot.alpha = 0
            destination.alpha = 1
            destination.transform = .identity
        } completion: { [weak self, weak destination] _ in
            snapshot.removeFromSuperview()
            destination?.alpha = 1
            destination?.transform = .identity
            self?.finishUnarchiveTransition()
        }
    }

    private func finishUnarchiveTransition() {
        isAnimatingFromArchiveTray = false
        carousel.view.isUserInteractionEnabled = true
        refreshArchivePullAvailability(animated: false)
    }

    private func makeTransitionSnapshot(of sourceView: UIView) -> UIView? {
        CardTransitionSnapshot.make(of: sourceView, in: view)
    }

    // MARK: - Opening / immersion

    private func makeReader(for item: SavedItem) -> UIViewController? {
        guard let content = store.content(for: item) else { return nil }
        return ReaderHostFactory.make(
            item: item, content: content,
            shareProvider: AppReaderShareProvider.shared)
    }

}

// MARK: - What an article card asks of the screen around it

/// The article kind's per-save answers live in `ArticleCardPresenter`; the
/// chrome those answers need lives here. This protocol is the entire contact
/// surface between them, which is why this class holds no slot arrays and
/// never asks what kind a save is.
extension ArticleCardsViewController: ArticleDeckChromeHosting {

    var readerCardDelegate: ReaderCardContentDelegate? { self }

    var readerCardTopContentInset: CGFloat { Self.contentEdgeFade }

    /// Brings the card for `id` to the centre, false when it has none here —
    /// the article chrome's name for the deck host's own `centerCard(onItemID:)`,
    /// which every deck (and the Live Activity's share route) shares.
    func centerCard(forItemID id: UUID) -> Bool {
        centerCard(onItemID: id)
    }

    /// The archive.today CAPTCHA unlock flow: on successful extraction, reopen
    /// the now-`.ready` item.
    func presentUnlockFlow(for item: SavedItem, articleURL: URL) {
        ArchiveUnlockFlow.present(
            item: item, articleURL: articleURL, store: store, from: self
        ) { [weak self] fresh in
            guard let self else { return }
            SavesIngestor.shared.backfillMissingThumbnails()
            self.openExternally(fresh)
        }
    }

    /// The fallback for a save with no card here — an archived one, which is
    /// also how the archive tray's own tap opens.
    func pushReader(for item: SavedItem) {
        guard let reader = makeReader(for: item) else { return }
        navigationController?.pushViewController(reader, animated: true)
    }

    func toggleImmersion(for card: ReaderCardContentViewController) {
        readerCard(
            card, didChangeImmersion: !carousel.isImmersed,
            extendsCard: card.rabbitHoleReader?.focusedContentScrollView != nil)
    }

    /// The link-style card for a save whose kind has nothing to draw yet, and
    /// the reader card for every article. Reached through
    /// `CardDeckFallbackContentProviding` so this class builds no card on its
    /// own account.
    func fallbackCardContent(for item: SavedItem) -> CardContentViewController {
        makeReaderCard(for: item)
    }

    func makeReaderCard(for item: SavedItem) -> CardContentViewController {
        let content = ReaderCardContentViewController(
            item: item, senderName: ArticleCardPresenter.senderName(for: item))
        content.setTopContentInset(Self.contentEdgeFade)
        content.delegate = self
        return content
    }
}

// MARK: - Reader card content delegate

extension ArticleCardsViewController: ReaderCardContentDelegate {

    func readerCard(
        _ card: ReaderCardContentViewController, didChangeImmersion immersed: Bool, extendsCard: Bool
    ) {
        // A paired layout IS the surfaced state: the left card keeps its chrome
        // and its resting footprint for as long as the column beside it is open,
        // so reading it must not fade the deck away or grow the card downward
        // over the column's own controls.
        guard inlineColumn == nil, card.isCentered else { return }
        // The deck answers first, and it refuses while a page turn owns it: a
        // reader still decelerating from a flick keeps reporting its travel
        // through the swipe that pages it away. Raising this screen's own
        // immersion chrome on a refusal is what stranded the footer veil — a
        // black band over the scrub strip of a deck that is not immersed.
        guard carousel.setImmersed(
            immersed,
            extendsCard: extendsCard,
            horizontalInset: expandedReaderInset(for: card, immersed: immersed),
            animated: true)
        else { return }
        card.setCardChromeVisible(!immersed, animated: true)
        // The archive peek is card chrome too: it fades away with the
        // side-card peeks and returns with them.
        archiveTray?.setChromeHidden(immersed, animated: true)
        updateBottomModeSwitcher(immersed: immersed, animated: true)
        UIView.animate(
            withDuration: 0.32, delay: 0,
            options: [.curveEaseInOut, .allowUserInteraction]
        ) {
            self.footerContentFade.alpha = immersed && extendsCard ? 1 : 0
        }
        // Slide the scroll indicator and the read-aloud circle between the
        // card edge and the screen edge in step with the immersion
        // (setImmersed's 0.32s ease-in-out).
        layoutCardScrollIndicator(animated: true)
        layoutReaderAudioToggle(animated: true)
    }

    /// A mode switch under a dismissed chrome swaps the reader's content without
    /// touching the immersion state, so the card would keep whichever extension
    /// the PREVIOUS mode asked for — RSVP inheriting the scroll reader's
    /// bottom-extended card lays its fixed column out over the mode switcher.
    /// Re-apply the extension for the mode that is now live.
    func readerCard(
        _ card: ReaderCardContentViewController, didChangeCardExtension extendsCard: Bool
    ) {
        guard card.isCentered, carousel.isImmersed, inlineColumn == nil else { return }
        guard carousel.setImmersed(
            true,
            extendsCard: extendsCard,
            horizontalInset: expandedReaderInset(for: card, immersed: true),
            animated: true)
        else { return }
        UIView.animate(
            withDuration: 0.32, delay: 0,
            options: [.curveEaseInOut, .allowUserInteraction]
        ) {
            self.footerContentFade.alpha = extendsCard ? 1 : 0
        }
        layoutCardScrollIndicator(animated: true)
    }

    func readerCard(
        _ card: ReaderCardContentViewController, didBecomeReady reader: RabbitHoleReaderViewController
    ) {
        guard card.isCentered else { return }
        readerForChrome = reader
        updateExternalReaderInsets()
        updateReaderChrome()
        layoutCardScrollIndicator(animated: false)
    }

    func readerCard(
        _ card: ReaderCardContentViewController, inlineReaderDidChange reader: ReaderChromeControlling?
    ) {
        guard card.isCentered else { return }
        readerForChrome = reader ?? card.rabbitHoleReader
        updateReaderChrome()
        // Step the host indicator aside for an inline reader (it keeps its
        // own), and take back over when it dismisses.
        layoutCardScrollIndicator(animated: false)
    }

    func readerCardRestingFrameInWindow(
        _ card: ReaderCardContentViewController
    ) -> CGRect? {
        guard let restingFrame = carousel.restingCenteredCardFrame(in: view) else { return nil }
        return view.convert(restingFrame, to: nil)
    }

    func readerCardUsesTapOnlyScrollChrome(
        _ card: ReaderCardContentViewController
    ) -> Bool {
        ReaderCardViewportPolicy.usesTapOnlyScrollChrome(
            userInterfaceIdiom: traitCollection.userInterfaceIdiom,
            viewportSize: view.bounds.size)
    }

    private func expandedReaderInset(
        for card: ReaderCardContentViewController,
        immersed: Bool
    ) -> CGFloat? {
        guard immersed,
              card.rabbitHoleReader?.focusedScrollReader != nil
        else { return nil }
        return LunaLayout.isWide(containerWidth: view.bounds.width)
            ? Self.expandedReaderHorizontalInset : 0
    }

    // MARK: - The second column (wide screens)

    /// How far left the deck steps to make room for a second column. Negative;
    /// zero when the screen has no room for one.
    private var columnAsideShift: CGFloat {
        guard let cardFrame = carousel.restingCenteredCardFrame(in: view),
              canFitInlineReaderColumns(cardWidth: cardFrame.width)
        else { return 0 }
        return -(cardFrame.width + LunaLayout.columnGap) / 2
    }

    /// Whether this screen can hold a second reader column beside the card.
    /// Internal rather than private: it is the one bit of state that decides
    /// between the two nested-reader behaviours, and the tests assert on it.
    var hasRoomForColumn: Bool { columnAsideShift < 0 }

    /// Root cards aspect-fit their whole usable height, so an iPad in portrait
    /// may deliberately be too tall to accommodate a second full-size column.
    /// Keep the paired reader only where both cards fit with the normal outer
    /// padding instead of shrinking the root card merely to reserve a column
    /// the user has not opened.
    private func canFitInlineReaderColumns(cardWidth: CGFloat) -> Bool {
        guard LunaLayout.isWide(containerWidth: view.bounds.width) else { return false }
        return cardWidth * 2 + LunaLayout.columnGap
            <= view.bounds.width - LunaLayout.wideEdgePadding * 2
    }

    /// The right column's frame in this view's space — the card's own footprint,
    /// one full column over.
    ///
    /// Derived from the LEFT card rather than measured on its own, so the two
    /// cards are the same size by construction. This layout is offered only
    /// when two aspect-fit root cards already fit side by side.
    ///
    /// `restingCenteredCardFrame` already includes whatever shift the deck has
    /// taken, so the offset backs that out and then steps one column right —
    /// giving the same answer before the deck moves and after.
    private var inlineColumnFrame: CGRect? {
        guard hasRoomForColumn,
              let resting = carousel.restingCenteredCardFrame(in: view)
        else { return nil }
        return resting.offsetBy(dx: -columnAsideShift - carousel.columnAsideShift, dy: 0)
    }

    func readerCardInlineReaderPlacement(
        _ card: ReaderCardContentViewController
    ) -> InlineReaderPlacement {
        hasRoomForColumn ? .column : .overlay
    }

    func readerCardInlineReaderFrameInWindow(
        _ card: ReaderCardContentViewController
    ) -> CGRect? {
        guard hasRoomForColumn else { return readerCardRestingFrameInWindow(card) }
        guard let frame = inlineColumnFrame else { return nil }
        return view.convert(frame, to: nil)
    }

    func readerCard(
        _ card: ReaderCardContentViewController,
        presentInlineColumn column: SplitWebOverlayViewController,
        fromSourcePointInWindow point: CGPoint
    ) {
        guard card.isCentered, inlineColumn == nil, hasRoomForColumn else { return }
        inlineColumn = column
        // Two readers now share the screen: only one of them may voice or march
        // a word at a time (`ReaderPlaybackArbiter`).
        ReaderPlaybackArbiter.isPaired = true

        // Reading dismissed the deck's chrome; a paired layout brings it back.
        // The card becomes a card again BEFORE it travels, so what slides left is
        // the resting footprint the right column is sized against.
        carousel.setImmersed(false, extendsCard: true, animated: true)
        layoutReaderAudioToggle(animated: true)
        UIView.animate(
            withDuration: 0.32, delay: 0,
            options: [.curveEaseInOut, .allowUserInteraction]
        ) {
            self.footerContentFade.alpha = 0
        }
        updateReaderChrome()

        addChild(column)
        view.insertSubview(column.view, belowSubview: readerChromeRow)
        column.didMove(toParent: self)
        column.view.frame = inlineColumnFrame ?? .zero
        column.view.layoutIfNeeded()

        // The deck's chrome is anchored to the card's frame, so laying the screen
        // out INSIDE the carousel's own shift animation carries the chrome row,
        // the flanking circles, and the scroll indicator along with the card.
        carousel.setColumnAside(shift: columnAsideShift, animated: true)
        UIView.animate(
            withDuration: 0.36, delay: 0,
            usingSpringWithDamping: 0.88, initialSpringVelocity: 0,
            options: [.allowUserInteraction, .beginFromCurrentState]
        ) {
            self.view.setNeedsLayout()
            self.view.layoutIfNeeded()
        }
        refreshArchivePullAvailability(animated: true)
        column.animateColumnAppearance()
    }

    func readerCard(
        _ card: ReaderCardContentViewController,
        closeInlineColumn column: SplitWebOverlayViewController
    ) {
        closeInlineColumn(column)
    }

    /// Sends the column away and returns the left card to center. Internal so
    /// the tests can close one without synthesising a tab tap.
    func closeInlineColumn(_ column: SplitWebOverlayViewController) {
        guard inlineColumn === column else { return }
        inlineColumn = nil
        ReaderPlaybackArbiter.isPaired = false
        carousel.setColumnAside(shift: 0, animated: true)
        UIView.animate(
            withDuration: 0.36, delay: 0,
            usingSpringWithDamping: 0.88, initialSpringVelocity: 0,
            options: [.allowUserInteraction, .beginFromCurrentState]
        ) {
            self.view.setNeedsLayout()
            self.view.layoutIfNeeded()
        }
        column.animateColumnDismissal { [weak self, weak column] in
            guard let column else { return }
            column.willMove(toParent: nil)
            column.view.removeFromSuperview()
            column.removeFromParent()
            guard let self else { return }
            self.refreshArchivePullAvailability(animated: true)
            self.updateReaderChrome()
            self.layoutCardScrollIndicator(animated: false)
        }
    }

    func readerCard(
        _ card: ReaderCardContentViewController,
        pushIntoOpenColumn url: URL,
        sourcePointInWindow point: CGPoint
    ) -> Bool {
        guard let column = inlineColumn, column.acceptsPushedLink else { return false }
        column.pushLink(url: url, sourcePointInWindow: point)
        return true
    }

    /// The column currently open beside the centered card, if any.
    var openInlineColumn: SplitWebOverlayViewController? { inlineColumn }

    /// Test seam: opens a nested reader from the centered card down the SAME path
    /// a link tap takes, so the paired-column layout can be asserted without
    /// landing a real hit on a link inside TextKit or WebKit.
    @discardableResult
    func openNestedReaderForTesting(
        url: URL, sourcePointInWindow point: CGPoint
    ) -> SplitWebOverlayViewController? {
        guard let card = carousel.contentController(at: carousel.currentIndex)
            as? ReaderCardContentViewController,
            let reader = card.rabbitHoleReader
        else { return nil }
        return InlineReaderOpener.open(
            url: url,
            from: reader,
            coordinator: card,
            shareProvider: nil,
            sourcePointInWindow: point,
            outerURL: url,
            outerTitle: nil)
    }
}

// MARK: - Card content

/// The push/pull contract between a `ReaderCardContentViewController` and its
/// host: pushes for immersion changes, the reader becoming ready, and an inline
/// reader presenting/dismissing; pulls for the card's resting frame, where a
/// nested reader belongs, and whether there is room to put it beside this card
/// instead of over it. Sole conformer: `ArticleCardsViewController`.
protocol ReaderCardContentDelegate: AnyObject {
    /// The reader wants the carousel chrome faded away (true — reading is
    /// under way) or back in (false — the user is surfacing). `extendsCard`
    /// says whether the immersed card's bottom should extend into the strip's
    /// room: true for the scroll reader (more content shows), false for RSVP,
    /// whose fixed layout must not move when playback starts — only the chrome
    /// fades.
    func readerCard(
        _ card: ReaderCardContentViewController, didChangeImmersion immersed: Bool, extendsCard: Bool)
    /// Whether the host viewport reserves scroll-reader chrome changes for taps.
    func readerCardUsesTapOnlyScrollChrome(_ card: ReaderCardContentViewController) -> Bool
    /// The card's live content changed what an immersed layout should do with
    /// the room the faded strip frees — a scroll→RSVP switch trades a scrolling
    /// surface for a fixed one. Applied only while ALREADY immersed; it never
    /// changes the immersion state itself.
    func readerCard(
        _ card: ReaderCardContentViewController, didChangeCardExtension extendsCard: Bool)
    func readerCard(
        _ card: ReaderCardContentViewController, didBecomeReady reader: RabbitHoleReaderViewController)
    func readerCard(
        _ card: ReaderCardContentViewController, inlineReaderDidChange reader: ReaderChromeControlling?)
    /// This card's own resting footprint in window coordinates — what the live
    /// card measures its immersion bottom-extension against.
    func readerCardRestingFrameInWindow(_ card: ReaderCardContentViewController) -> CGRect?
    /// Where a nested reader opened from this card belongs: this card's footprint
    /// on a phone, the column beside it on a wide screen.
    func readerCardInlineReaderFrameInWindow(_ card: ReaderCardContentViewController) -> CGRect?
    func readerCardInlineReaderPlacement(
        _ card: ReaderCardContentViewController) -> InlineReaderPlacement
    /// Install `column` beside this card and step this card aside for it.
    func readerCard(
        _ card: ReaderCardContentViewController,
        presentInlineColumn column: SplitWebOverlayViewController,
        fromSourcePointInWindow point: CGPoint)
    func readerCard(
        _ card: ReaderCardContentViewController,
        closeInlineColumn column: SplitWebOverlayViewController)
    /// True when an open column took the link instead of a second one opening.
    func readerCard(
        _ card: ReaderCardContentViewController,
        pushIntoOpenColumn url: URL,
        sourcePointInWindow point: CGPoint) -> Bool
}

/// One article card: the FULL live reader, always embedded (side cards too, so
/// paging never shows a placeholder), laid out to the card's bounds — the card
/// view IS the fullscreen reader view, one header and one layout for both
/// states. The card reports reading activity so the host can fade the carousel
/// chrome around it: scroll direction in the scroll reader, play state in RSVP.
final class ReaderCardContentViewController: CardContentViewController,
    InlineReaderPresentationCoordinating, RabbitHoleReaderDelegate,
    ReaderImmersionTrackerDelegate {

    weak var delegate: ReaderCardContentDelegate?

    private let item: SavedItem
    private let statusLabel = UILabel()
    /// The pinned copy shown while card chrome is surfaced and the scrollable
    /// copy that permanently occupies the reader's top content inset. Keeping
    /// both copies laid out identically lets visibility change without changing
    /// the live reader's geometry or content offset.
    private let titleHeader: ReaderCardTitleHeaderView
    private let scrollTitleHeader: ReaderCardTitleHeaderView
    private let knownContent: ArticleContent?
    private var reader: UIViewController?
    private let immersionTracker = ScrollDirectionImmersionTracker()
    private var baseTopContentInset: CGFloat = 0
    private var titleHeaderHeight: CGFloat = 0
    private var cardChromeVisible = true
    private weak var titleScrollView: UIScrollView?
    private var titleScrollObservation: NSKeyValueObservation?
    /// Coalesces UIKit's intermediate programmatic offsets (notably the
    /// prefix-to-full article swap) so the pinned/scrolling title copies never
    /// trade visibility for a single frame after a card transition.
    private var pendingProgrammaticTitleUpdate: DispatchWorkItem?
    /// The title copy mounted inside UITextView is outside TextKit's attributed
    /// string. A flattened copy keeps it visible above the per-glyph body
    /// transition while the live text view is temporarily hidden for reflow.
    private var viewportTitleSnapshot: UIView?
    private var viewportTitleDestinationFrame: CGRect?
    private weak var viewportTransitionScrollReader: ScrollReaderViewController?
    /// Which copy currently owns the title — see `updateTitleHandoffLatch()`.
    private var pinnedTitleHasTakenOver = false
    private(set) var isCentered = false
    var rabbitHoleReader: LunaReaderUI.RabbitHoleReaderViewController? {
        reader as? LunaReaderUI.RabbitHoleReaderViewController
    }

    /// An ARTICLE parked behind a paywall, awaiting the archive unlock flow. A
    /// price tracker or a platform save can also sit in a non-`.ready` state but
    /// has its own card and its own tap, so neither wears the lock. Which kind
    /// this is comes from the registry, the one place that decides.
    var isLockedSave: Bool {
        item.state == .needsCaptcha
            && CardKindPresenters.presenter(for: item) === CardKindPresenters.article
    }

    init(item: SavedItem, senderName: String?, knownContent: ArticleContent? = nil) {
        self.item = item
        self.knownContent = knownContent
        let senderSubtitle = senderName.flatMap { name -> String? in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : L10n.string("Reader_senderFromSubtitle", trimmed)
        }
        self.titleHeader = ReaderCardTitleHeaderView(
            title: item.title ?? L10n.string("Common_untitled"), subtitle: senderSubtitle)
        self.scrollTitleHeader = ReaderCardTitleHeaderView(
            title: item.title ?? L10n.string("Common_untitled"), subtitle: senderSubtitle)
        super.init()
        immersionTracker.delegate = self
    }

    // MARK: - Immersion geometry

    func immersionTracker(
        _ tracker: ScrollDirectionImmersionTracker,
        didChangeImmersion immersed: Bool, extendsCard: Bool
    ) {
        // Sampled before the card resizes: only a restore triggered by
        // reaching the article's end owes the content a compensating slide.
        let restoringAtArticleEnd = !immersed && extendsCard && isFocusedContentAtEnd
        let extensionBeforeRestore = immersionBottomExtension
        delegate?.readerCard(self, didChangeImmersion: immersed, extendsCard: extendsCard)
        if restoringAtArticleEnd {
            keepArticleEndAtReturningCardEdge(by: extensionBeforeRestore)
        }
    }

    func immersionBottomExtension(for tracker: ScrollDirectionImmersionTracker) -> CGFloat {
        immersionBottomExtension
    }

    /// How much taller the live card is than its resting footprint — the
    /// distance the card's bottom edge travels back UP when the chrome returns.
    /// Zero whenever the card is already resting.
    private var immersionBottomExtension: CGFloat {
        guard isViewLoaded, let resting = delegate?.readerCardRestingFrameInWindow(self)
        else { return 0 }
        return max(0, view.bounds.height - resting.height)
    }

    /// Whether the focused reader is sitting on the last of its content. The
    /// tolerance matches the tracker's: a settling scroll stops a point or two
    /// short of the exact maximum.
    private var isFocusedContentAtEnd: Bool {
        guard let scrollView = rabbitHoleReader?.focusedContentScrollView else { return false }
        let maximum = scrollView.contentSize.height + scrollView.adjustedContentInset.bottom
            - scrollView.bounds.height
        let position = scrollView.contentOffset.y
        return maximum > 0 && maximum - position <= 12
    }

    /// The chrome returns by pulling the card's bottom edge back up, which would
    /// otherwise drag the article's end down out of sight behind it. The scroll
    /// range grows by exactly that extension as the card shrinks, so sliding the
    /// content up by the same amount — on the same curve — leaves the end of the
    /// article exactly where the reader last saw it, now resting on the restored
    /// card's bottom edge.
    private func keepArticleEndAtReturningCardEdge(by extensionHeight: CGFloat) {
        guard extensionHeight > 0.5,
              let scrollView = rabbitHoleReader?.focusedContentScrollView
        else { return }
        let target = CGPoint(
            x: scrollView.contentOffset.x, y: scrollView.contentOffset.y + extensionHeight)
        UIView.animate(
            withDuration: 0.32, delay: 0,
            options: [.curveEaseInOut, .allowUserInteraction, .beginFromCurrentState],
            animations: { scrollView.contentOffset = target },
            completion: { _ in
                // The restored card sheds the bottom safe area the immersed one
                // reached into, so the reader's own bottom inset can shrink under
                // the slide. Settle any resulting overshoot rather than leaving a
                // gap below the last line.
                let maximum = scrollView.contentSize.height
                    + scrollView.adjustedContentInset.bottom - scrollView.bounds.height
                guard scrollView.contentOffset.y > maximum + 0.5 else { return }
                scrollView.setContentOffset(
                    CGPoint(x: scrollView.contentOffset.x, y: max(0, maximum)), animated: true)
            })
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        embedReaderIfPossible()
        mountTitleHeader()

        // A locked save wears the lock rather than a line of apology text: the
        // card has no body to show, and "Locked — tap to unlock" on its own read
        // like a failure instead of an invitation. The overlay takes no touches,
        // so the card's tap (unlock flow) and long-press (Archive / Delete) are
        // untouched — see `LockedCardOverlayView`.
        if reader == nil, isLockedSave {
            // A plugin's lock is finished by that plugin's own browser step, so
            // it says so; the archive lock keeps its own line.
            let caption = item.isPluginLocked
                ? L10n.string("PluginLocked_cardCaption")
                : L10n.string("Reader_lockedCardCaption")
            let overlay = LockedCardOverlayView(caption: caption)
            overlay.translatesAutoresizingMaskIntoConstraints = false
            // Below the title header, so the article's title still crowns the card.
            view.insertSubview(overlay, belowSubview: titleHeader)
            NSLayoutConstraint.activate([
                overlay.topAnchor.constraint(equalTo: view.topAnchor),
                overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
        } else if reader == nil {
            statusLabel.font = .preferredFont(forTextStyle: .subheadline)
            statusLabel.textColor = LunaColors.secondaryText
            statusLabel.textAlignment = .center
            statusLabel.numberOfLines = 0
            // A save of ANOTHER kind with nothing of its own to draw yet — a
            // platform link Luna holds no download for. Its card is a link and
            // says so; its tap runs that kind's own open ladder. (A product no
            // longer reaches here at all: its presenter always has the real
            // in-card editor to give, in every app that shows one.)
            if CardKindPresenters.presenter(for: item) !== CardKindPresenters.article {
                statusLabel.text = L10n.string("Reader_cardTapToOpenStatus")
            } else {
                switch item.state {
                case .pending: statusLabel.text = L10n.string("Reader_cardFetchingStatus")
                case .failed: statusLabel.text = L10n.string("Reader_cardCouldntFetchStatus")
                // Unreachable for an article — `isLockedSave` took that above and
                // the card wears `LockedCardOverlayView` instead of a line of text.
                case .needsCaptcha: statusLabel.text = nil
                case .ready: statusLabel.text = nil
                }
            }
            statusLabel.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(statusLabel)
            NSLayoutConstraint.activate([
                statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
                statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
                statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            ])
        }
    }

    private func mountTitleHeader() {
        for header in [titleHeader, scrollTitleHeader] {
            header.isUserInteractionEnabled = false
        }
        view.addSubview(titleHeader)
        guard ArticleSourceBadge.wantsFavicon(item), let url = item.url else { return }
        SiteIconCache.shared.icon(forPageURL: url) { [weak self] image in
            guard let image else { return }
            self?.titleHeader.setIcon(image)
            self?.scrollTitleHeader.setIcon(image)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        immersionTracker.allowsScrollDrivenImmersion =
            !(delegate?.readerCardUsesTapOnlyScrollChrome(self) ?? false)
        // Bake the inline reader's eclipse corona now rather than on the first
        // article open. (The carousel prewarms its own card geometry separately.)
        SplitWebOverlayViewController.prewarmEclipseCorona(
            cardFrameInWindow: inlineReaderCardFrameInWindow)
        // The reader fills the card — the fade-out's bottom extension just
        // grows this frame, revealing more content; nothing inside shifts.
        reader?.view.frame = view.bounds
        let height = titleHeader.heightThatFits(
            width: view.bounds.width, topInset: baseTopContentInset)
        _ = scrollTitleHeader.heightThatFits(
            width: view.bounds.width, topInset: baseTopContentInset)
        // The background begins at the card's top edge while the title/icon keep
        // their normal clearance below the edge dissolve.
        titleHeader.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: height)
        if abs(height - titleHeaderHeight) > 0.5 {
            titleHeaderHeight = height
            applyReaderTopInset()
        }
        synchronizeScrollableTitleHeader()
    }

    // MARK: - Live reader lifecycle

    override func cardDidBecomeCentered() {
        super.cardDidBecomeCentered()
        isCentered = true
        settleTitleHandoffForReveal()
        immersionTracker.allowsScrollDrivenImmersion =
            !(delegate?.readerCardUsesTapOnlyScrollChrome(self) ?? false)
        immersionTracker.isActive = true
        rabbitHoleReader?.activatePrimaryContent()
        if let rabbitHoleReader { delegate?.readerCard(self, didBecomeReady: rabbitHoleReader) }
    }

    override func cardDidLeaveCenter() {
        super.cardDidLeaveCenter()
        isCentered = false
        pendingProgrammaticTitleUpdate?.cancel()
        pendingProgrammaticTitleUpdate = nil
        titleHeader.layer.removeAllAnimations()
        immersionTracker.isActive = false
        setCardChromeVisible(true, animated: false)
    }

    /// A side card can receive provisional reader layout and queued content-
    /// offset corrections while another kind is centered. Resolve both title
    /// copies from the final card bounds before this reader is revealed, and
    /// discard any handoff decision queued for its old state.
    private func settleTitleHandoffForReveal() {
        pendingProgrammaticTitleUpdate?.cancel()
        pendingProgrammaticTitleUpdate = nil
        guard isViewLoaded else { return }
        titleHeader.layer.removeAllAnimations()
        view.setNeedsLayout()
        view.layoutIfNeeded()
        synchronizeScrollableTitleHeader()
        updatePinnedTitleVisibility(animated: false)
    }

    private func embedReaderIfPossible() {
        guard reader == nil, item.state == .ready,
              let content = knownContent ?? SavesStore.shared.content(for: item)
        else { return }
        titleHeader.setTitle(content.title)
        scrollTitleHeader.setTitle(content.title)
        // Render only the initial scroll viewport while this is a side card or
        // scrub preview. Promotion keeps this exact controller and then permits
        // its seamless Phase-2 expansion; offscreen text layout and image work
        // therefore never sits on the scrub interaction's critical path.
        let reader = ReaderHostFactory.make(
            item: item, content: content,
            shareProvider: AppReaderShareProvider.shared,
            fullContentUpFront: false,
            includesArticleTitle: false)
        if let rabbitHole = reader as? LunaReaderUI.RabbitHoleReaderViewController {
            rabbitHole.providesOwnChrome = false
            rabbitHole.presentsLinksAsInlineReaders = true
            rabbitHole.defersFullContentUntilPrimary = true
        }
        addChild(reader)
        reader.view.autoresizingMask = []
        view.insertSubview(reader.view, at: 0)
        reader.didMove(toParent: self)
        if let rabbitHole = reader as? RabbitHoleReaderViewController {
            rabbitHole.delegate = self
        }
        self.reader = reader
        reader.view.frame = view.bounds
        immersionTracker.observe(reader)
        synchronizeScrollableTitleHeader()
        if let rabbitHole = reader as? RabbitHoleReaderViewController {
            delegate?.readerCard(self, didBecomeReady: rabbitHole)
        }

        // Backstop sweeps for content that mounts without a hierarchy
        // callback (a dived-into non-article page installs its web view only
        // after an async probe). KVO only — never triggers layout.
        for delay in [0.7, 2.0, 4.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, let reader = self.reader else { return }
                self.immersionTracker.observe(reader)
            }
        }
    }

    // MARK: - RabbitHoleReaderDelegate

    func readerContentHierarchyDidChange(_ reader: RabbitHoleReaderViewController) {
        // A dive, pop, mode switch, or late article embed swaps the live scroll
        // views / RSVP controllers — re-sweep for new ones to observe (idempotent;
        // next runloop so the new child is mounted).
        // Mode switches mount their child before this callback, so retarget the
        // title synchronously as well; the async pass remains a backstop for a
        // late-loading web/article child.
        synchronizeScrollableTitleHeader()
        // The new mode may want a different immersed card: a scrolling surface
        // extends into the freed strip room, RSVP's fixed column must not.
        if isCentered {
            if let isPlaying = rabbitHoleReader?.focusedRSVPIsPlaying {
                // RSVP's chrome state IS its playback state, so arriving in the
                // speed reader is exactly the paused case: bring the whole card
                // chrome back rather than leaving the dismissed state the
                // outgoing scroll reader put the deck in. Its column is laid out
                // against the card's frame and the room below it, so reading it
                // inside a card still stretched over the footer lane — with the
                // chrome that names the mode faded away — put the controls where
                // nothing could reach them.
                delegate?.readerCard(self, didChangeImmersion: isPlaying, extendsCard: false)
            } else {
                delegate?.readerCard(
                    self, didChangeCardExtension: rabbitHoleReader?.focusedContentScrollView != nil)
            }
        }
        DispatchQueue.main.async {
            if let root = self.reader { self.immersionTracker.observe(root) }
            self.synchronizeScrollableTitleHeader()
        }
        DispatchQueue.main.async {
            guard self.isCentered else { return }
            self.delegate?.readerCard(self, didBecomeReady: reader)
        }
    }

    func readerRequestedRootBack(_ reader: RabbitHoleReaderViewController) {
        // The reader has nowhere to pop to — surface, bringing the carousel
        // chrome back instead.
        guard isCentered else { return }
        delegate?.readerCard(self, didChangeImmersion: false, extendsCard: true)
    }

    func inlineReaderWillPresent(_ reader: ReaderChromeControlling) {
        guard isCentered else { return }
        delegate?.readerCard(
            self, didChangeImmersion: true,
            extendsCard: rabbitHoleReader?.focusedContentScrollView != nil)
        delegate?.readerCard(self, inlineReaderDidChange: reader)
    }

    func inlineReaderDidDismiss(_ reader: ReaderChromeControlling) {
        guard isCentered else { return }
        delegate?.readerCard(self, inlineReaderDidChange: rabbitHoleReader)
        if rabbitHoleReader?.shouldSurfaceAfterInlineReaderDismissal == true {
            delegate?.readerCard(self, didChangeImmersion: false, extendsCard: true)
        }
    }

    func inlineReaderWillDismiss(_ reader: ReaderChromeControlling) {
        guard isCentered,
              rabbitHoleReader?.shouldSurfaceAfterInlineReaderDismissal == true
        else { return }
        // This is visual choreography only. The chrome target remains the inline
        // reader until `inlineReaderDidDismiss` commits the successful dismissal.
        delegate?.readerCard(self, didChangeImmersion: false, extendsCard: true)
    }

    func inlineReaderDismissalDidCancel(_ reader: ReaderChromeControlling) {
        guard isCentered,
              rabbitHoleReader?.shouldSurfaceAfterInlineReaderDismissal == true
        else { return }
        delegate?.readerCard(
            self, didChangeImmersion: true,
            extendsCard: rabbitHoleReader?.focusedContentScrollView != nil)
    }

    var inlineReaderTopEdgeInWindow: CGFloat {
        guard isViewLoaded else { return 0 }
        return view.convert(view.bounds, to: nil).minY
    }

    var inlineReaderCardFrameInWindow: CGRect {
        guard isViewLoaded else { return .zero }
        // Immersion extends this content view to the bottom of the screen. The
        // nested reader must instead occupy the carousel card's stable resting
        // footprint — or, on a wide screen, the column beside it; either way the
        // host owns that rect. Its own metrics reserve the tab strip within it.
        if let frame = delegate?.readerCardInlineReaderFrameInWindow(self) {
            return frame
        }
        return view.convert(view.bounds, to: nil)
    }

    var inlineReaderShowsOuterContentBelow: Bool {
        rabbitHoleReader?.focusedContentScrollView != nil
    }

    var inlineReaderPlacement: InlineReaderPlacement {
        delegate?.readerCardInlineReaderPlacement(self) ?? .overlay
    }

    func inlineReaderPresentAsColumn(
        _ reader: SplitWebOverlayViewController, fromSourcePointInWindow point: CGPoint
    ) {
        delegate?.readerCard(self, presentInlineColumn: reader, fromSourcePointInWindow: point)
    }

    func inlineReaderColumnRequestedClose(_ reader: SplitWebOverlayViewController) {
        delegate?.readerCard(self, closeInlineColumn: reader)
    }

    func inlineReaderPushIntoOpenColumn(url: URL, sourcePointInWindow point: CGPoint) -> Bool {
        delegate?.readerCard(self, pushIntoOpenColumn: url, sourcePointInWindow: point) ?? false
    }

    /// The resting clearance below the card's top edge — enough that an
    /// unscrolled page starts below the card's top-edge dissolve.
    func setTopContentInset(_ inset: CGFloat) {
        baseTopContentInset = max(inset, 0)
        view.setNeedsLayout()
        applyReaderTopInset()
    }

    /// Card immersion changes only the pinned copy's visibility. The scrollable
    /// copy and the reader's top inset never move, so scroll/RSVP/archive layouts
    /// remain stable throughout the transition. RSVP has no scroll surface and
    /// therefore keeps the pinned title visible at all times.
    func setCardChromeVisible(_ visible: Bool, animated: Bool) {
        cardChromeVisible = visible
        updatePinnedTitleVisibility(animated: animated)
    }

    override func prepareForCardViewportTransition(to size: CGSize) {
        viewportTitleSnapshot?.removeFromSuperview()
        viewportTitleSnapshot = nil
        viewportTitleDestinationFrame = nil
        viewportTransitionScrollReader = nil
        let destinationTitleHeight = titleHeader.heightThatFits(
            width: size.width, topInset: baseTopContentInset)
        guard let scrollReader = rabbitHoleReader?.focusedScrollReader,
              scrollReader.prepareForCardViewportTransition(
                to: size,
                destinationTopChromeInset: destinationTitleHeight) == true
        else { return }
        viewportTransitionScrollReader = scrollReader

        let sourceFrame = scrollTitleHeader.convert(scrollTitleHeader.bounds, to: view)
        guard sourceFrame.intersects(view.bounds.insetBy(dx: 0, dy: -4)),
              let snapshot = scrollTitleHeader.snapshotView(afterScreenUpdates: false)
        else { return }
        snapshot.frame = sourceFrame
        snapshot.isUserInteractionEnabled = false
        view.addSubview(snapshot)
        viewportTitleSnapshot = snapshot
        let destinationOffset = scrollReader.preparedCardViewportDestinationOffsetY ?? 0
        let readerOrigin = scrollReader.view.convert(CGPoint.zero, to: view)
        viewportTitleDestinationFrame = CGRect(
            x: readerOrigin.x,
            y: readerOrigin.y - destinationTitleHeight - destinationOffset,
            width: size.width, height: destinationTitleHeight)
    }

    override func animatePreparedCardViewportTransition() {
        viewportTransitionScrollReader?.animatePreparedCardViewportTransition()
        if let destination = viewportTitleDestinationFrame {
            viewportTitleSnapshot?.frame = destination
        }
    }

    override func finishCardViewportTransition(completed: Bool) {
        viewportTransitionScrollReader?.finishCardViewportTransition(completed: completed)
        viewportTransitionScrollReader = nil
        viewportTitleSnapshot?.removeFromSuperview()
        viewportTitleSnapshot = nil
        viewportTitleDestinationFrame = nil
    }

    /// Moves the permanent title copy into whichever scroll surface is focused
    /// (Scroll, Original/web archive, or its local article snapshot). It occupies the
    /// negative content-inset region, so at offset zero it lands pixel-for-pixel
    /// beneath the pinned copy and then naturally scrolls away with the page.
    private func synchronizeScrollableTitleHeader() {
        let focused = rabbitHoleReader?.focusedContentScrollView
        if focused !== titleScrollView {
            pendingProgrammaticTitleUpdate?.cancel()
            pendingProgrammaticTitleUpdate = nil
            titleScrollObservation = nil
            scrollTitleHeader.removeFromSuperview()
            titleScrollView = focused
            if let focused {
                focused.addSubview(scrollTitleHeader)
                focused.bringSubviewToFront(scrollTitleHeader)
                titleScrollObservation = focused.observe(\.contentOffset, options: [.new]) {
                    [weak self, weak focused] _, _ in
                    self?.scrollOffsetDidChange(in: focused)
                }
            }
        }
        guard let focused else {
            updatePinnedTitleVisibility(animated: false)
            return
        }
        // The nested reader lays out after this card. During the first visible
        // parent pass its scroll view can therefore still carry the old,
        // screen-wide bounds, even though the card already has its final width.
        // Size both title copies from the card so the scrolling copy cannot
        // paint wide and then visibly re-wrap on the reader's following pass.
        scrollTitleHeader.frame = CGRect(
            x: 0, y: -titleHeaderHeight,
            width: view.bounds.width, height: titleHeaderHeight)
        focused.bringSubviewToFront(scrollTitleHeader)
        updatePinnedTitleVisibility(animated: false)
    }

    private func scrollOffsetDidChange(in scrollView: UIScrollView?) {
        guard let scrollView, scrollView === titleScrollView else { return }
        guard isCentered else {
            pendingProgrammaticTitleUpdate?.cancel()
            pendingProgrammaticTitleUpdate = nil
            return
        }
        if !ScrollPresentationState.isSuppressed(for: scrollView)
            || scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating {
            pendingProgrammaticTitleUpdate?.cancel()
            pendingProgrammaticTitleUpdate = nil
            updatePinnedTitleVisibility(animated: false)
            return
        }

        // Assigning the full attributed string can briefly clamp the offset
        // before ScrollReader restores it in the same runloop turn. Evaluate
        // only the settled value so the two identical title copies cannot
        // flicker between each other or appear to re-layout.
        pendingProgrammaticTitleUpdate?.cancel()
        let work = DispatchWorkItem { [weak self, weak scrollView] in
            guard let self, let scrollView, scrollView === self.titleScrollView else { return }
            self.pendingProgrammaticTitleUpdate = nil
            self.updatePinnedTitleVisibility(animated: false)
        }
        pendingProgrammaticTitleUpdate = work
        DispatchQueue.main.async(execute: work)
    }

    private func updatePinnedTitleVisibility(animated: Bool) {
        updateTitleHandoffLatch()
        // With no scroll surface the active reader is RSVP (or a non-ready
        // placeholder), whose title is fixed and never follows card chrome.
        let showsPinnedTitle = titleScrollView == nil
            || (cardChromeVisible && pinnedTitleHasTakenOver)
        let changes = {
            self.titleHeader.alpha = showsPinnedTitle ? 1 : 0
        }
        titleHeader.accessibilityElementsHidden = !showsPinnedTitle
        scrollTitleHeader.accessibilityElementsHidden = showsPinnedTitle
        if animated {
            UIView.animate(
                withDuration: 0.32, delay: 0,
                options: [.curveEaseInOut, .allowUserInteraction], animations: changes)
        } else {
            changes()
        }
    }

    /// Advances the latched handoff between the two copies (the rule itself is
    /// `ReaderScrollPosition.pinnedTitleOwnsTitle`). While the pinned copy owns
    /// the title it stays parked over the scrolling copy's approach, and the
    /// swap lands at the one offset where the two are pixel-identical — so a
    /// scroll-driven change of owner is applied without animation.
    private func updateTitleHandoffLatch() {
        guard let scroll = titleScrollView else {
            pinnedTitleHasTakenOver = false
            return
        }
        pinnedTitleHasTakenOver = ReaderScrollPosition.pinnedTitleOwnsTitle(
            wasPinned: pinnedTitleHasTakenOver,
            distanceFromTop: Double(scroll.contentOffset.y + scroll.adjustedContentInset.top),
            titleHeaderHeight: Double(titleHeaderHeight))
    }

    private func applyReaderTopInset() {
        rabbitHoleReader?.externalChromeContentInset = titleHeaderHeight
    }

    override func allowsCardTap(at point: CGPoint) -> Bool {
        !Self.readerControllers(under: reader).contains { controller in
            guard let scrollReader = controller as? ScrollReaderViewController,
                  scrollReader.isViewLoaded,
                  scrollReader.view.window != nil
            else { return false }
            return scrollReader.hasInteractiveContent(
                at: view.convert(point, to: scrollReader.view))
        }
    }

    override func longPressSelectsContent(at point: CGPoint) -> Bool {
        Self.readerControllers(under: reader).contains { controller in
            guard let scrollReader = controller as? ScrollReaderViewController,
                  scrollReader.isViewLoaded,
                  scrollReader.view.window != nil
            else { return false }
            let readerPoint = view.convert(point, to: scrollReader.view)
            // A press on a glyph, a link, or an inline image is the reader's —
            // it selects text or opens the link/image menu. Only bare whitespace
            // falls through to the card's Archive/Delete context menu.
            return scrollReader.pointIsOverText(at: readerPoint)
                || scrollReader.hasInteractiveContent(at: readerPoint)
        }
    }

    private static func readerControllers(under root: UIViewController?) -> [UIViewController] {
        guard let root else { return [] }
        return [root] + root.children.flatMap { readerControllers(under: $0) }
    }

}

/// The title treatment shared by Scroll, RSVP, and Original while an article is
/// shown as a carousel card. It uses the same 30-point reader title typography,
/// now paired with the page's favicon (a globe remains visible while it loads).
private final class ReaderCardTitleHeaderView: UIView {
    /// The title's line cap. A title past it is first set in slightly smaller
    /// type; only what still does not fit moves into `overflowLabel`, rather
    /// than dying in a truncating tail.
    private static let titleLineLimit = 3
    /// A tail long enough to need more than this is not a headline; the cap
    /// keeps a junk extraction from swallowing the card.
    private static let overflowLineLimit = 6
    private static let overflowGap: CGFloat = 6

    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    /// The rest of a title too long for the line cap, shown in smaller type
    /// directly below it and led by an ellipsis. Hidden when the title fits.
    private let overflowLabel = UILabel()
    private let subtitleLabel = UILabel()
    private var topInset: CGFloat = 0
    private var fullTitle: String
    /// The text width the current fit was computed at — the fit is CoreText
    /// work, and layout runs far more often than the width changes.
    private var splitWidth: CGFloat = 0
    /// The nominal title type. `titleLabel`'s own font is this shrunk to fit, so
    /// the sweep must always start from the unshrunken size.
    private let baseTitleFont = ReaderCardTitleHeaderView.readerTitleFont

    init(title: String, subtitle: String?) {
        fullTitle = title
        super.init(frame: .zero)
        backgroundColor = LunaColors.background

        iconView.image = UIImage(systemName: "globe")
        iconView.accessibilityIdentifier = UtilCardSaveTransitionAnchor.thumbnail
        iconView.tintColor = LunaColors.secondaryText
        iconView.contentMode = .scaleAspectFit
        iconView.layer.cornerRadius = 6
        iconView.clipsToBounds = true

        titleLabel.text = title
        titleLabel.accessibilityIdentifier = UtilCardSaveTransitionAnchor.title
        titleLabel.font = baseTitleFont
        titleLabel.textColor = LunaColors.primaryText
        titleLabel.numberOfLines = Self.titleLineLimit
        // The head ends on a wrap point, so it needs no tail of its own; this
        // is a backstop for a head that still overflows by a hair.
        titleLabel.lineBreakMode = .byTruncatingTail

        overflowLabel.font = Self.readerOverflowFont
        overflowLabel.textColor = LunaColors.secondaryText
        overflowLabel.numberOfLines = Self.overflowLineLimit
        overflowLabel.lineBreakMode = .byTruncatingTail
        overflowLabel.isHidden = true

        subtitleLabel.text = subtitle
        subtitleLabel.font = .preferredFont(forTextStyle: .caption1)
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textColor = LunaColors.secondaryText
        subtitleLabel.numberOfLines = 1
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.isHidden = subtitle == nil

        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(overflowLabel)
        addSubview(subtitleLabel)
        isAccessibilityElement = true
        accessibilityLabel = title
        accessibilityValue = subtitle
        accessibilityTraits = .header
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setIcon(_ image: UIImage) {
        iconView.image = image
        iconView.tintColor = nil
    }

    func setTitle(_ title: String) {
        fullTitle = title
        splitWidth = 0
        // VoiceOver reads the headline whole, however it is split visually.
        accessibilityLabel = title
        setNeedsLayout()
        superview?.setNeedsLayout()
    }

    /// Shrinks the title's type as far as the cap needs (and no further), then
    /// moves whatever still does not fit into the overflow label. Both copies of
    /// the header are sized from the same card width, so they fit identically
    /// and stay pixel-identical.
    private func applyTitleSplit(textWidth: CGFloat) {
        guard textWidth > 0, abs(textWidth - splitWidth) > 0.5 else { return }
        splitWidth = textWidth
        let fit = ReaderTitleOverflow.fit(
            fullTitle, font: baseTitleFont, width: textWidth,
            maxLines: Self.titleLineLimit)
        titleLabel.font = fit.font
        titleLabel.text = fit.head
        overflowLabel.text = fit.overflow.map(ReaderTitleOverflow.displayString(forOverflow:))
        overflowLabel.isHidden = fit.overflow == nil
    }

    /// The height of the title stack — title, the overflow tail, then the
    /// sender line — each present only when it has something to say.
    private func textHeight(width: CGFloat) -> CGFloat {
        func height(_ label: UILabel) -> CGFloat {
            label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        }
        var total = height(titleLabel)
        if !overflowLabel.isHidden { total += Self.overflowGap + height(overflowLabel) }
        if !subtitleLabel.isHidden { total += 4 + height(subtitleLabel) }
        return total
    }

    func heightThatFits(width: CGFloat, topInset: CGFloat) -> CGFloat {
        self.topInset = topInset
        let titleWidth = max(width - 20 - 30 - 12 - 20, 0)
        applyTitleSplit(textWidth: titleWidth)
        return topInset + max(30, textHeight(width: titleWidth)) + 20
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let iconSide: CGFloat = 30
        let contentHeight = max(bounds.height - topInset, 0)
        iconView.frame = CGRect(
            x: 20, y: topInset + (contentHeight - iconSide) / 2,
            width: iconSide, height: iconSide)
        let titleX = iconView.frame.maxX + 12
        let textWidth = max(bounds.width - titleX - 20, 0)
        applyTitleSplit(textWidth: textWidth)
        if overflowLabel.isHidden, subtitleLabel.isHidden {
            titleLabel.frame = CGRect(
                x: titleX, y: topInset + 10,
                width: textWidth, height: max(contentHeight - 20, 0))
            iconView.frame.origin.y = titleLabel.frame.midY - iconSide / 2
            overflowLabel.frame = .zero
            subtitleLabel.frame = .zero
            return
        }
        func height(_ label: UILabel) -> CGFloat {
            label.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
        }
        titleLabel.frame = CGRect(
            x: titleX, y: topInset + 10, width: textWidth, height: height(titleLabel))
        var bottom = titleLabel.frame.maxY
        if overflowLabel.isHidden {
            overflowLabel.frame = .zero
        } else {
            overflowLabel.frame = CGRect(
                x: titleX, y: bottom + Self.overflowGap,
                width: textWidth, height: height(overflowLabel))
            bottom = overflowLabel.frame.maxY
        }
        if subtitleLabel.isHidden {
            subtitleLabel.frame = .zero
        } else {
            subtitleLabel.frame = CGRect(
                x: titleX, y: bottom + 4, width: textWidth,
                height: max(0, bounds.maxY - bottom - 14))
        }
        // The favicon identifies the headline, not the headline + secondary
        // metadata stack. Keep it beside the title even when a source/sender
        // line makes the overall header taller.
        iconView.frame.origin.y = titleLabel.frame.midY - iconSide / 2
    }

    private static var readerTitleFont: UIFont {
        // Mirrors the article title in ArticleTextRenderer: same typeface,
        // size, and (clamped) accessibility scaling.
        ReaderSettings.font.font(size: 30 * ReaderSettings.effectiveFontScale, weight: .bold)
    }

    /// The tail's type: the title's typeface, small enough to read as its
    /// continuation rather than a second headline.
    private static var readerOverflowFont: UIFont {
        // Deliberately below semibold: the named reader families map semibold
        // and up onto their bold face, which would read as a second headline.
        ReaderSettings.font.font(size: 17 * ReaderSettings.effectiveFontScale, weight: .medium)
    }
}

/// Screen-level footer veil used only while the scroll reader's card is
/// immersed. It dissolves content over the normal card fade depth, then paints
/// the footer safe area solid so reader content cannot bleed behind controls.
private final class ReaderFooterContentFadeView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    private var gradient: CAGradientLayer { layer as! CAGradientLayer }
    private var fadeHeight: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        updateColors()
        registerForTraitChanges([LunaSkyTrait.self]) {
            (view: ReaderFooterContentFadeView, _: UITraitCollection) in view.updateColors()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.height > 0 else { return }
        gradient.locations = [0, NSNumber(value: min(fadeHeight / bounds.height, 1)), 1]
    }

    func setFadeHeight(_ height: CGFloat) {
        fadeHeight = max(height, 1)
        setNeedsLayout()
    }

    private func updateColors() {
        let background = LunaColors.background.resolvedColor(with: traitCollection)
        gradient.colors = [
            background.withAlphaComponent(0).cgColor,
            background.cgColor,
            background.cgColor,
        ]
    }
}

/// The chrome row's frame hugs the resting card's top corners, but the
/// read-aloud circle rides a transform out to the safe screen corner while the
/// card is immersed (`layoutReaderAudioToggle`). Hit-test where a visible
/// circle actually renders, so the parked circle stays tappable beyond the
/// row's bounds.
private final class ReaderChromeRowView: UIView {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if super.point(inside: point, with: event) { return true }
        return subviews.contains { subview in
            !subview.isHidden && subview.alpha > 0.01
                && subview.isUserInteractionEnabled
                && subview.point(inside: convert(point, to: subview), with: event)
        }
    }
}

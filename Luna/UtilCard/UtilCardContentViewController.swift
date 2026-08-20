//
//  UtilCardContentViewController.swift
//  Luna
//

import LunaDesignSystem
import LunaMailAccount
import LunaModels
import LunaStorage
import LunaURLClassification
import LunaWeekly
import UIKit
import UniformTypeIdentifiers

/// Where the util card's parts sit. The intro headline is the only measurement
/// that is a FRACTION of the card: everything else either hangs off it or is
/// anchored to the paste row at the bottom, so the block resolves downward the
/// way the standalone onboarding root's did.
enum UtilCardLayout {
    static let inset: CGFloat = 20
    /// The headline's top. The standalone onboarding root put its copy at
    /// exactly a third of the surface; the util card lifts it a little to leave
    /// the weekly row its own room below — a little, not up onto the card's
    /// shoulder.
    ///
    /// The completed card has no headline; the weekly row sits at
    /// `weeklyTopRatio`, half this, riding higher than the intro sentence did.
    static let headlineTopRatio: CGFloat = 0.28
    static let headlineToWeekly: CGFloat = 24
    /// The weekly row is deliberately taller than a history row: it carries the
    /// corner flag across its top and the pick's own two lines below it.
    static let weeklyRowHeight: CGFloat = 96
    static let recentRowHeight: CGFloat = 74
    /// The completed card's seat for the weekly row — HALF the headline's
    /// ratio, so the pick rides higher than the intro sentence ever did and the
    /// flag is the first thing the card says.
    static let weeklyTopRatio: CGFloat = 0.14
    /// Where a block of recents starts when there is no weekly row to hang off.
    static let recentsTop: CGFloat = 24
    /// The seam between Luna's own pick and raw Safari history. It is by far
    /// the widest gap on the card — several times `recentRowGap` — so the
    /// weekly row stands alone above the list rather than as the list's first
    /// entry.
    static let weeklyToRecentsGap: CGFloat = 65
    static let recentRowGap: CGFloat = 9
    static let recentsToPasteGap: CGFloat = 12
    static let setupButtonHeight: CGFloat = 54
    static let setupButtonGap: CGFloat = 10
    /// The seam under the "Store downloads …" line. Wider than the gap between
    /// two buttons: the line is prose sitting over the block, not another item
    /// in it.
    static let storageChooserGap: CGFloat = 16
    /// The gap the setup block keeps above the paste field when no “or” stands
    /// between them.
    static let setupToPasteGap: CGFloat = 16
    static let bottomPadding: CGFloat = 20
}

/// Pushes the one email sign-in surface (Settings → Email, whose Sharing
/// Account section IS the form until an account exists). Installed by the
/// article shell of the two apps that do email.
@MainActor
protocol EmailSetupPresenting {
    func presentEmailSetup(from presenter: UIViewController)
}

/// What the util card reads about the app around it. Every answer but
/// `utilCardHasSaves` has a live default over the shared stores, so a deck
/// conforms by answering the one question that is its own; a stage or a test
/// overrides whichever it needs to pin.
@MainActor
protocol UtilCardDataSource: AnyObject {
    /// Whether the deck holds any save of its own. The “or” belongs to a card
    /// that is the only thing in the app.
    var utilCardHasSaves: Bool { get }
    /// Every URL in the shared store, so a weekly row can read as answered.
    var utilCardSavedURLStrings: Set<String> { get }
    /// When every save was made — half of the email nudge's earning rule.
    var utilCardSavedDates: [Date] { get }
    /// Whether an email account is already connected — the other half.
    var utilCardIsEmailConnected: Bool { get }
    /// The Safari-history rows the completed card offers.
    var utilCardRecentMatches: [RecentURLPreview] { get }
}

extension UtilCardDataSource {
    var utilCardSavedURLStrings: Set<String> {
        Set(SavesStore.shared.items().map(\.urlString))
    }

    var utilCardSavedDates: [Date] {
        SavesStore.shared.items().map(\.dateAdded)
    }

    var utilCardIsEmailConnected: Bool {
        EmailAccountStore.shared.isConfigured
    }

    var utilCardRecentMatches: [RecentURLPreview] {
        RecentURLMatcher.shared.matches
    }
}

/// What the util card asks the app around it to do: save a URL the user handed
/// it, and open Luna's own page in system Settings.
@MainActor
protocol UtilCardDelegate: AnyObject {
    /// Saves `urlString`. `sourceView` anchors anything the save presents; the
    /// completion reports whether the card should read as saved or as failed.
    func utilCardSave(
        urlString: String,
        source: CaptureSource,
        sourceView: UIView,
        completion: @escaping (Bool) -> Void)

    /// The only way back to a Photos permission the user has already refused,
    /// since iOS will not prompt twice.
    func utilCardOpenSystemSettings()
}

extension UtilCardDelegate {
    func utilCardOpenSystemSettings() {
        guard let settings = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(settings)
    }
}

/// The permanent first card in every Luna deck. It is the first-launch
/// onboarding surface and, on later launches, a compact home for Safari
/// history. Its launch mode is deliberately immutable: finishing setup keeps
/// the onboarding controls in place until the next app launch.
final class UtilCardContentViewController: CardContentViewController {
    /// A brief crossfade makes the onboarding copy yield its place instead of
    /// the weekly recommendation seeming to pop into existence.
    private static let introToWeeklyFadeDuration: TimeInterval = 0.24

    /// Pushes the one email sign-in surface (Settings → Email, whose Sharing
    /// Account section IS the form until an account exists). Installed by the
    /// article shell of the two apps that do email — the screen itself isn't
    /// compiled into the other two.
    static var emailSetupLauncher: (any EmailSetupPresenting)?

    /// The deck around the card: it answers what the card shows and performs
    /// what the card asks for. Weak — the conformer owns this controller.
    weak var dataSource: (any UtilCardDataSource)?
    weak var delegate: (any UtilCardDelegate)?

    private let showsOnboarding: Bool
    /// Whether the headline's two-beat sweep belongs to THIS appearance. It is
    /// the launch's animation: a card paged back to shows the finished sentence
    /// instead of saying it again.
    private let animatesIntro: Bool
    private let configuration: OnboardingSurfaceConfiguration
    private let onboardingStore: AppOnboardingStore
    /// The app this card belongs to: it decides the weekly row's noun and
    /// whether email is a capability here at all (`LunaApp.sharesByEmail`).
    private let app: LunaApp
    private let now: () -> Date
    /// Where finished downloads go, in the two apps that download them. Nil
    /// everywhere else: Reader and Price Tracker do not link the media module,
    /// so nothing installs one (`DownloadStorageChoice`).
    private let storageChoice: (any DownloadStorageChoosing)?

    private let headline: OnboardingIntroHeadlineView?
    private let weeklyHost: WeeklySaveRowHost
    private let safariButton = UtilCardSetupActionButton(type: .system)
    private let saveSetupButton = UtilCardSetupActionButton(type: .system)
    private let emailButton = UtilCardSetupActionButton(type: .system)
    private let orLabel = UILabel()
    private let pasteRow = OnboardingPasteRow()
    /// The inline "Store downloads …" line, present only while the download
    /// destination is still Luna's own default rather than the user's answer.
    /// Captured once per card, like the onboarding variant: answering it here
    /// (or in Settings) takes it off the NEXT launch's card, not this one's.
    private var storageChooser: UtilCardStorageChooserView?
    /// The setup lessons this card is currently offering, top to bottom. It is
    /// a LIST rather than a fixed pair: a device with no Action Button has no
    /// save lesson, and the block stacks up from the paste row, so whatever is
    /// present simply fills the bottom slots.
    private var setupOffers: [UtilCardSetupButton] = []
    private var setupTextCycler: UtilCardSetupTextCycler?
    private var recentRows: [UtilURLRow] = []
    private var didSettleHeadline = false
    /// On the launch that owns the headline sweep, everything below the
    /// headline waits invisible until the sweep's bloom has finished, then
    /// fades in together. Never true on any other appearance.
    private var awaitingIntroReveal = false
    /// The first-run copy gets a short moment on its own. It then fades out as
    /// the weekly slot moves into the completed-card position.
    private var weeklyAppearanceDeferred = false
    /// The three-second headline hold has elapsed. Central Luna still waits
    /// for the next setup-label cycle boundary before showing the weekly row.
    private var weeklyAppearanceReady = false
    private var introHeadlineHasYieldedToWeekly = false
    /// Whether the card is the one in front of the user. The setup labels only
    /// keep a clock of their own while it is — the weekly row's own pacer
    /// answers this separately for the row.
    private var isCardCentered = false
    private var weeklyRevealWorkItem: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []

    init(
        showsOnboarding: Bool,
        animatesIntro: Bool = false,
        configuration: OnboardingSurfaceConfiguration = .current,
        onboardingStore: AppOnboardingStore = .shared,
        weeklyStore: WeeklySaveStore = .shared,
        app: LunaApp = .current,
        now: @escaping () -> Date = Date.init,
        // No default: `DownloadStorageChoice.installed` is main-actor state and
        // a default argument is evaluated outside the actor. The deck passes it;
        // a test that says nothing gets no row, which is the quiet case.
        storageChoice: (any DownloadStorageChoosing)? = nil
    ) {
        self.showsOnboarding = showsOnboarding
        self.animatesIntro = showsOnboarding && animatesIntro
        self.configuration = configuration
        self.onboardingStore = onboardingStore
        self.app = app
        self.now = now
        self.storageChoice = storageChoice
        weeklyHost = WeeklySaveRowHost(store: weeklyStore, app: app)
        headline = showsOnboarding
            ? OnboardingIntroHeadlineView(copy: configuration.introCopy)
            : nil
        super.init()
        pasteConfiguration = UIPasteConfiguration(
            acceptableTypeIdentifiers: [
                UTType.url.identifier,
                UTType.plainText.identifier,
            ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        weeklyRevealWorkItem?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.accessibilityIdentifier = "utilCard"

        if let headline {
            view.addSubview(headline)
            // The sweep is the launch's. Anywhere else the sentence is simply
            // already finished — including while this card is still a side peek,
            // so paging to it never pops the copy into place.
            if !animatesIntro {
                headline.showFinishedState()
                didSettleHeadline = true
                // A reload (e.g. from a save elsewhere in the deck) rebuilds this
                // controller from scratch, so `introHeadlineHasYieldedToWeekly`
                // starts back at its default. A live weekly pick already claims
                // the seat regardless of onboarding, so settle straight into the
                // yielded state rather than letting the headline reappear above it.
                if !weeklyHost.isEmpty {
                    headline.isHidden = true
                    introHeadlineHasYieldedToWeekly = true
                }
            }
        }
        view.addSubview(weeklyHost)
        view.addSubview(pasteRow)

        weeklyHost.delegate = self
        weeklyAppearanceDeferred = animatesIntro
        weeklyHost.setCycleVisible(!weeklyAppearanceDeferred)
        weeklyHost.isHidden = weeklyHost.isEmpty || weeklyAppearanceDeferred

        // The setup block belongs to BOTH variants: the two system lessons are
        // first-run business, but the email nudge only becomes due once there
        // are saves — by which time this is the completed card.
        configureSetupButtons()
        // Above the lessons, and outside their two-button budget: where saved
        // media lands is a question about the app's own default, not a setup
        // errand, so it belongs to BOTH variants and to neither's priority list.
        installStorageChooserIfOffered()
        if showsOnboarding {
            configureOrLabel()
            view.addSubview(orLabel)
        } else {
            rebuildRecentRows()
        }
        rebuildSetupBlock()

        observers.append(NotificationCenter.default.addObserver(
            forName: RecentURLMatcher.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            guard self?.showsOnboarding == false else { return }
            self?.rebuildRecentRows()
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: AppOnboardingStore.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.rebuildSetupBlock()
            self?.updateOrVisibility()
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .savesChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.updateWeeklySavedState()
            self?.updateOrVisibility()
            // A save can be the third one, or the first one the clock runs on.
            self?.rebuildSetupBlock()
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: EmailAccountStore.accountChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.rebuildSetupBlock()
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in RecentURLMatcher.shared.refresh() }
            // Two days can pass while the app is away, and the retirement that
            // frees a slot for email is written on the way out.
            self?.rebuildSetupBlock()
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: WeeklySaveStore.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.weeklySaveDidChange()
        })

        // The launch's own sweep speaks first: everything else on the card
        // holds back until the headline has finished saying itself.
        if animatesIntro {
            awaitingIntroReveal = true
            for element in introRevealElements { element.alpha = 0 }
        }

        RecentURLMatcher.shared.refresh()
    }

    /// What waits behind the headline on the launch that animates it. The
    /// headline itself is not here — it is the thing being waited on.
    private var introRevealElements: [UIView] {
        [safariButton, saveSetupButton, orLabel, pasteRow]
            + (storageChooser.map { [$0] } ?? [])
    }

    /// The headline's bloom has finished: the rest of the card fades in, in
    /// place — the same beat the standalone intro card gave its actions.
    private func revealIntroElements() {
        guard awaitingIntroReveal else { return }
        awaitingIntroReveal = false
        if UIAccessibility.isReduceMotionEnabled {
            for element in introRevealElements { element.alpha = 1 }
            scheduleWeeklyAppearance()
            return
        }
        UIView.animate(
            withDuration: 0.38,
            delay: 0.16,
            options: [.curveEaseOut, .beginFromCurrentState]
        ) {
            for element in self.introRevealElements { element.alpha = 1 }
        } completion: { _ in
            self.scheduleWeeklyAppearance()
        }
        beginSetupTextCycling()
    }

    /// The headline has landed. After its three-second hold, the weekly row
    /// yields at the next setup-label cycle boundary in central Luna. Other
    /// apps have no cycling labels, so they reveal immediately at that point.
    private func scheduleWeeklyAppearance() {
        guard weeklyAppearanceDeferred, weeklyRevealWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            self?.weeklyAppearanceReady = true
            self?.revealWeeklyAtCycleBoundaryIfReady()
        }
        weeklyRevealWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + OnboardingAnimationClock.delay(3), execute: workItem)
    }

    /// Starts the central app's label clock as the controls arrive instead of
    /// holding it behind the Luna team pick. The first tick names Reader,
    /// matching the weekly row's initial article slot.
    private func beginSetupTextCycling() {
        guard app == .luna, weeklyAppearanceDeferred else { return }
        updateSetupLabelClock()
    }

    /// Which clock advances the central card's setup labels. Exactly one ever
    /// runs, and the weekly row is the preferred one: its turn and the labels
    /// are then the same app's by construction, whether an auto-advance or a
    /// swipe moved it.
    ///
    /// A card with no live pick has no row to hand the job to, though — the row
    /// is not on screen at all — so the cycler keeps its own clock in that
    /// case. It is also the whole answer on the completed card, which keeps
    /// these buttons (and, in central Luna, keeps them stretched edge to edge
    /// for exactly this cycling) long after the first run is answered.
    private func updateSetupLabelClock() {
        guard let setupTextCycler else { return }
        let rowWillCycle = !weeklyHost.isEmpty && !weeklyHost.isHidden
        // Nothing to carry the labels, or nobody looking at them.
        let hasCyclingButton =
            safariButton.superview != nil || saveSetupButton.superview != nil
        let canKeepOwnClock = isCardCentered && !awaitingIntroReveal && hasCyclingButton
        if rowWillCycle || !canKeepOwnClock {
            setupTextCycler.stopCycling()
        } else {
            setupTextCycler.startCycling()
        }
    }

    private func revealWeeklyAtCycleBoundaryIfReady() {
        guard weeklyAppearanceReady else { return }
        if app == .luna, !UIAccessibility.isReduceMotionEnabled {
            // `onCycleStart` calls us at the next title transition. The weekly
            // row must not arrive midway through that slide.
            return
        }
        revealWeeklyAfterIntro()
    }

    private func setupTextCycleDidStart() {
        guard weeklyAppearanceReady else { return }
        revealWeeklyAfterIntro()
    }

    private func revealWeeklyAfterIntro() {
        guard weeklyAppearanceDeferred else { return }
        weeklyRevealWorkItem = nil
        weeklyAppearanceDeferred = false
        weeklyAppearanceReady = false
        introHeadlineHasYieldedToWeekly = true
        let hasWeekly = !weeklyHost.isEmpty
        weeklyHost.isHidden = !hasWeekly
        weeklyHost.alpha = hasWeekly ? 0 : 1
        // The just-started label transition is the hand-off point: from here the
        // weekly row's cycle is the single source of future label changes —
        // when there IS a row. With no live pick the labels keep their own clock
        // rather than standing on the one turn this hand-off gave them.
        updateSetupLabelClock()
        view.setNeedsLayout()
        // Put the invisible row in its finished-card seat before the fade
        // begins. Animating this layout change would make its first appearance
        // slide upward from the headline's old slot.
        view.layoutIfNeeded()
        guard let headline else {
            weeklyHost.setCycleVisible(true)
            return
        }
        guard !UIAccessibility.isReduceMotionEnabled else {
            headline.isHidden = true
            view.layoutIfNeeded()
            weeklyHost.alpha = 1
            weeklyHost.setCycleVisible(true)
            return
        }
        UIView.animate(
            withDuration: Self.introToWeeklyFadeDuration,
            delay: 0,
            options: [.curveEaseInOut, .beginFromCurrentState]
        ) {
            headline.alpha = 0
            self.view.layoutIfNeeded()
            self.weeklyHost.alpha = 1
        } completion: { _ in
            headline.isHidden = true
            headline.alpha = 1
            self.weeklyHost.setCycleVisible(true)
        }
    }

    /// The store gained, replaced, or lost a value. Presence changes reflow the
    /// card; a same-slot replacement is the host's own business.
    private func weeklySaveDidChange() {
        let wasHidden = weeklyHost.isHidden
        weeklyHost.reload(animated: !UIAccessibility.isReduceMotionEnabled)
        let shouldHide = weeklyHost.isEmpty
        // A pick arriving hands the labels to the row; the last one expiring
        // hands them back. Every path below is one of those two, or neither.
        defer { updateSetupLabelClock() }
        guard wasHidden != shouldHide else { return }
        if awaitingIntroReveal || weeklyAppearanceDeferred {
            // The headline is still speaking. Take the slot (or give it up)
            // silently — the row's alpha belongs to the intro reveal.
            weeklyHost.isHidden = weeklyAppearanceDeferred || shouldHide
            view.setNeedsLayout()
            return
        }
        if UIAccessibility.isReduceMotionEnabled {
            weeklyHost.isHidden = shouldHide
            weeklyHost.alpha = 1
            view.setNeedsLayout()
            view.layoutIfNeeded()
            return
        }
        if shouldHide {
            UIView.animate(withDuration: 0.24, delay: 0, options: [.curveEaseOut]) {
                self.weeklyHost.alpha = 0
            } completion: { _ in
                self.weeklyHost.isHidden = true
                self.weeklyHost.alpha = 1
                self.view.setNeedsLayout()
                UIView.animate(withDuration: 0.24, delay: 0, options: [.curveEaseOut]) {
                    self.view.layoutIfNeeded()
                }
            }
            return
        }
        weeklyHost.isHidden = false
        weeklyHost.alpha = 0
        view.setNeedsLayout()
        // The freshly built row is sized OUTSIDE the animation — its frame in
        // the card doesn't depend on the slot's presence, so only the card's
        // other elements animate their reflow while the row itself fades in
        // already in place, rather than growing into it from zero.
        weeklyHost.layoutIfNeeded()
        UIView.animate(withDuration: 0.24, delay: 0, options: [.curveEaseOut]) {
            self.view.layoutIfNeeded()
            self.weeklyHost.alpha = 1
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let inset = UtilCardLayout.inset
        let width = max(0, view.bounds.width - inset * 2)
        let pasteHeight = OnboardingIntroActionMetrics.pasteRowHeight
        pasteRow.frame = CGRect(
            x: inset,
            y: view.bounds.height - pasteHeight - UtilCardLayout.bottomPadding,
            width: width,
            height: pasteHeight)

        // No live entry means no slot: the setup buttons (or the recent rows)
        // move up into the space the row would have taken.
        let weeklyVisible = !weeklyHost.isEmpty

        // The setup actions keep the seat they had on the standalone intro:
        // stacked upward from the paste field, with the “or” — when the card is
        // the whole app — in the seam between them.
        var actionsBottom = pasteRow.frame.minY - UtilCardLayout.setupToPasteGap
        if showsOnboarding, !orLabel.isHidden {
            let orHeight = OnboardingIntroActionMetrics.orHeight
            let gap = OnboardingIntroActionMetrics.orSpacing
            orLabel.frame = CGRect(
                x: inset,
                y: pasteRow.frame.minY - gap - orHeight,
                width: width,
                height: orHeight)
            actionsBottom = orLabel.frame.minY - gap
        }
        // Bottom-up in reverse offer order, so the block's TOP is the highest
        // priority and losing one moves the rest down into its slot.
        let buttonHeight = UtilCardLayout.setupButtonHeight
        var nextBottom = actionsBottom
        for offer in setupOffers.reversed() {
            let button = button(for: offer)
            let buttonWidth = compactSetupButtonWidth(for: offer, containerWidth: width)
            let buttonX = inset + (width - buttonWidth) / 2
            button.frame = CGRect(
                x: buttonX,
                y: nextBottom - buttonHeight,
                width: buttonWidth,
                height: buttonHeight)
            nextBottom = button.frame.minY - UtilCardLayout.setupButtonGap
        }
        // The storage line always tops the block, whatever is (or isn't) under
        // it — it is the one control here that is about the app rather than
        // about setting the app up.
        var setupBlockTop: CGFloat? = setupOffers.isEmpty
            ? nil
            : nextBottom + UtilCardLayout.setupButtonGap
        if let storageChooser {
            let top = (setupBlockTop ?? actionsBottom)
                - (setupOffers.isEmpty ? 0 : UtilCardLayout.storageChooserGap)
                - UtilCardStorageChooserView.height
            storageChooser.frame = CGRect(
                x: inset,
                y: top,
                width: width,
                height: UtilCardStorageChooserView.height)
            setupBlockTop = top
        }

        if let headline, !introHeadlineHasYieldedToWeekly {
            headline.frame = CGRect(
                x: inset,
                y: (view.bounds.height * UtilCardLayout.headlineTopRatio).rounded(),
                width: width,
                height: headline.height)
            let weeklyHeight = UtilCardLayout.weeklyRowHeight
            weeklyHost.frame = CGRect(
                x: inset,
                y: min(
                    headline.frame.maxY + UtilCardLayout.headlineToWeekly,
                    max(
                        headline.frame.maxY,
                        (setupBlockTop ?? actionsBottom) - 18 - weeklyHeight)),
                width: width,
                height: weeklyHeight)
            return
        }

        // With the headline gone the weekly row takes its own seat — a fraction
        // of the card half the headline's, not the top edge — and the recents
        // hang below it across a seam far wider than the one between two
        // recents. Without a live pick there is no seat to keep: the history
        // block reclaims the whole card.
        weeklyHost.frame = CGRect(
            x: inset,
            y: weeklyVisible
                ? (view.bounds.height * UtilCardLayout.weeklyTopRatio).rounded()
                : UtilCardLayout.recentsTop,
            width: width,
            height: UtilCardLayout.weeklyRowHeight)
        var nextY = weeklyVisible
            ? weeklyHost.frame.maxY + UtilCardLayout.weeklyToRecentsGap
            : UtilCardLayout.recentsTop
        // The completed card can still carry a setup button — the email nudge
        // becomes due only once there are saves — so the recents stop above
        // whichever comes first, the block or the paste row.
        let availableBottom = (setupBlockTop ?? pasteRow.frame.minY)
            - UtilCardLayout.recentsToPasteGap
        for row in recentRows {
            // The storage line's options open over whatever is above it, so the
            // card gives it that room outright rather than letting a stack of
            // history rows sit under a panel.
            let fits = storageChooser == nil
                && nextY + UtilCardLayout.recentRowHeight <= availableBottom
            row.isHidden = !fits
            if fits {
                row.frame = CGRect(
                    x: inset, y: nextY,
                    width: width, height: UtilCardLayout.recentRowHeight)
                nextY = row.frame.maxY + UtilCardLayout.recentRowGap
            }
        }
    }

    override func cardDidBecomeCentered() {
        super.cardDidBecomeCentered()
        isCardCentered = true
        weeklyHost.cardDidBecomeCentered()
        updateSetupLabelClock()
        guard let headline, !didSettleHeadline else { return }
        didSettleHeadline = true
        view.layoutIfNeeded()
        DispatchQueue.main.asyncAfter(
            deadline: .now() + OnboardingAnimationClock.delay(
                OnboardingIntroTiming.firstLineDelay)
        ) { [weak self, weak headline] in
            guard let headline else { return }
            headline.revealFirstBeat(
                duration: OnboardingIntroTiming.lineRevealDuration
            ) {
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + OnboardingAnimationClock.delay(
                        OnboardingIntroTiming.interLineDelay)
                ) {
                    headline.revealSecondBeat(
                        duration: OnboardingIntroTiming.lineRevealDuration
                    ) {
                        self?.revealIntroElements()
                    }
                }
            }
        }
    }

    override func cardDidLeaveCenter() {
        super.cardDidLeaveCenter()
        isCardCentered = false
        weeklyHost.cardDidLeaveCenter()
        // Also stops the clock, whichever one was running.
        setupTextCycler?.reset()
    }

    override func paste(itemProviders: [NSItemProvider]) {
        if let provider = itemProviders.first(where: {
            $0.canLoadObject(ofClass: URL.self)
        }) {
            _ = provider.loadObject(ofClass: URL.self) { [weak self] url, _ in
                guard let url else { return }
                DispatchQueue.main.async { self?.handlePastedValue(url.absoluteString) }
            }
            return
        }
        guard let provider = itemProviders.first(where: {
            $0.canLoadObject(ofClass: NSString.self)
        }) else {
            pasteRow.setState(.failure(L10n.string("Onboarding_Util_invalidURL")))
            return
        }
        _ = provider.loadObject(ofClass: NSString.self) { [weak self] value, _ in
            guard let value = value as? NSString else { return }
            DispatchQueue.main.async { self?.handlePastedValue(value as String) }
        }
    }

    private func handlePastedValue(_ value: String) {
        pasteRow.showPastedValue(value)
        guard let url = URLUnwrapper.ingestURL(from: value, allowBareHost: true) else {
            pasteRow.setState(.failure(L10n.string("Onboarding_Util_invalidURL")))
            return
        }
        pasteRow.setState(.loading)
        delegate?.utilCardSave(
            urlString: url.absoluteString, source: .paste, sourceView: pasteRow
        ) { [weak self] succeeded in
            self?.pasteRow.setState(
                succeeded ? .success : .failure(L10n.string("Onboarding_Util_unableToSaveURL")))
        }
    }

    private func save(_ urlString: String, source: CaptureSource, sourceView: UIView) {
        delegate?.utilCardSave(
            urlString: urlString, source: source, sourceView: sourceView) { _ in }
    }

    // MARK: - Save of the week

    /// The weekly recommendation may already be in the deck. Then its row is
    /// shown as answered rather than offered.
    private func updateWeeklySavedState() {
        weeklyHost.updateSavedStates()
    }

    // MARK: - Setup actions

    private func configureSetupButtons() {
        configure(
            safariButton,
            title: OnboardingStrings.Intro.safariAction.value(),
            symbol: "safari.fill",
            action: #selector(safariTapped))
        configure(
            saveSetupButton,
            title: OnboardingStrings.Intro.shortcutAction.value(),
            symbol: "square.and.arrow.up",
            image: saveSetupIcon(),
            action: #selector(saveSetupTapped))
        configure(
            emailButton,
            title: OnboardingStrings.Intro.emailAction.value(),
            symbol: "envelope.fill",
            action: #selector(emailSetupTapped))

        // Central Luna only — and in BOTH states. The cycling is what earns
        // these two buttons their full width (`compactSetupButtonWidth`), which
        // the completed card keeps; gating the cycler on the first run left that
        // card holding edge-to-edge buttons for phrasing that never arrived.
        if app == .luna {
            setupTextCycler = UtilCardSetupTextCycler(
                safariButton: safariButton,
                shortcutButton: saveSetupButton)
            setupTextCycler?.delegate = self
        }
    }

    private func configureOrLabel() {
        orLabel.text = OnboardingStrings.Intro.orSeparator.value()
        orLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        orLabel.textColor = LunaColors.quaternaryText
        orLabel.textAlignment = .center
        orLabel.accessibilityIdentifier =
            OnboardingStrings.Accessibility.introOr.value()
        orLabel.isAccessibilityElement = false
        updateOrVisibility()
    }

    /// The “or” is the seam between "set Luna up" and "or just paste something".
    /// It reads as that choice only while the setup legs are still open AND the
    /// deck holds nothing else — once either is untrue the card is no longer an
    /// either/or.
    private func updateOrVisibility() {
        guard showsOnboarding else { return }
        let setupOutstanding = !(onboardingStore.hasFinishedSafariSetup
            && onboardingStore.hasFinishedSaveSetup)
        let shouldShow = setupOutstanding && !(dataSource?.utilCardHasSaves ?? false)
        guard orLabel.isHidden == shouldShow else { return }
        orLabel.isHidden = !shouldShow
        view.setNeedsLayout()
    }

    /// The save lesson's own artwork: the real Shortcuts app icon, the same the
    /// standalone intro card used. A generic bolt reads as some other feature
    /// entirely. nil falls back to the button's symbol.
    private func saveSetupIcon() -> UIImage? {
        guard let artwork = Bundle.main
            .path(forResource: "ShortcutsAppIcon", ofType: "png")
            .flatMap(UIImage.init(contentsOfFile:))
        else { return nil }
        let size = CGSize(width: 22, height: 22)
        return UIGraphicsImageRenderer(size: size).image { _ in
            artwork.draw(in: CGRect(origin: .zero, size: size))
        }.withRenderingMode(.alwaysOriginal)
    }

    private func configure(
        _ button: UIButton,
        title: String,
        symbol: String,
        image: UIImage? = nil,
        action: Selector
    ) {
        button.configuration = GlassStyle.actionButtonConfiguration(
            title: title,
            symbol: symbol,
            prominent: true,
            tint: LunaSurfacePalette.baseColor)
        if let image { button.configuration?.image = image }
        button.configuration?.baseBackgroundColor =
            LunaSurfacePalette.baseColor.withAlphaComponent(0.24)
        button.configuration?.titleLineBreakMode = .byTruncatingTail
        button.configuration?.titleAlignment = .leading
        button.configuration?.imagePlacement = .leading
        button.configuration?.imagePadding = 10
        button.configuration?.contentInsets = NSDirectionalEdgeInsets(
            top: 13, leading: 20, bottom: 13, trailing: 20)
        var attributes = AttributeContainer()
        attributes.font = .systemFont(ofSize: 13, weight: .semibold)
        button.configuration?.attributedTitle = AttributedString(title, attributes: attributes)
        button.contentHorizontalAlignment = .leading
        button.titleLabel?.numberOfLines = 1
        button.accessibilityLabel = title
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    /// Which lessons the card offers right now, and their finished artwork.
    /// Buttons come and go rather than hiding in place: a card that offers
    /// nothing has no buttons in it at all.
    private func rebuildSetupBlock() {
        let offers = UtilCardSetupOffer.buttons(
            safari: !onboardingStore.isSafariSetupButtonRetired,
            save: configuration.saveSetupMode == .actionButtonShortcut
                && !onboardingStore.isSaveSetupButtonRetired,
            email: offersEmailSetup)
        for offer in UtilCardSetupButton.allCases {
            let button = button(for: offer)
            guard offers.contains(offer) else {
                button.removeFromSuperview()
                continue
            }
            if button.superview == nil { view.addSubview(button) }
            applyFinished(isFinished(offer), to: button, offer: offer)
        }
        guard offers != setupOffers else { return }
        setupOffers = offers
        // A retirement can take the last cycling button off the card, and the
        // email nudge that replaces it never cycles.
        updateSetupLabelClock()
        view.setNeedsLayout()
    }

    /// Email is offered only where it is a capability, only while no account is
    /// connected, and only once Luna has earned the ask.
    private var offersEmailSetup: Bool {
        guard app.sharesByEmail,
              let dataSource, !dataSource.utilCardIsEmailConnected else { return false }
        return UtilCardSetupOffer.emailIsEarned(
            saveDates: dataSource.utilCardSavedDates, now: now())
    }

    private func button(for offer: UtilCardSetupButton) -> UIButton {
        switch offer {
        case .safari: return safariButton
        case .save: return saveSetupButton
        case .email: return emailButton
        }
    }

    /// The Safari and shortcut buttons are full-width ONLY in central Luna,
    /// where the label itself cycles between the other apps' kinds
    /// (`UtilCardSetupTextCycler`) and needs the room to grow into. Every
    /// other app never changes that label, so a fixed short phrase stretched
    /// edge to edge just looks too wide — those buttons hug their own content
    /// and center in the block instead. Email keeps the full-width treatment
    /// everywhere: it never cycles, in central Luna or anywhere else.
    private func compactSetupButtonWidth(
        for offer: UtilCardSetupButton,
        containerWidth: CGFloat
    ) -> CGFloat {
        let hugsContent: Bool
        switch offer {
        case .safari, .save: hugsContent = app != .luna
        case .email: hugsContent = false
        }
        guard hugsContent else { return containerWidth }
        let fitted = button(for: offer).intrinsicContentSize.width
        return min(containerWidth, max(0, fitted))
    }

    /// Whether this button wears its checkmark. Email has no finished state on
    /// the card: connecting an account takes the button away entirely.
    private func isFinished(_ offer: UtilCardSetupButton) -> Bool {
        switch offer {
        case .safari: return onboardingStore.hasFinishedSafariSetup
        case .save: return onboardingStore.hasFinishedSaveSetup
        case .email: return false
        }
    }

    private func applyFinished(
        _ finished: Bool,
        to button: UIButton,
        offer: UtilCardSetupButton
    ) {
        button.isEnabled = !finished
        button.accessibilityValue = finished
            ? OnboardingStrings.Intro.completed.value()
            : nil
        // Disabling the button (the finished state) makes UIButton.Configuration
        // re-derive its colors for `.disabled` afterward, which washes the custom
        // green back toward white — reasserting it from a configurationUpdateHandler
        // runs last and wins.
        let applyStyle: (UIButton) -> Void = { [weak self] button in
            if finished {
                button.configuration?.image = UIImage(systemName: "checkmark.circle.fill")
            } else {
                switch offer {
                case .safari:
                    button.configuration?.image = UIImage(systemName: "safari.fill")
                case .save:
                    button.configuration?.image = self?.saveSetupIcon()
                        ?? UIImage(systemName: "square.and.arrow.up")
                case .email:
                    button.configuration?.image = UIImage(systemName: "envelope.fill")
                }
            }
            button.configuration?.baseForegroundColor = finished
                ? UIColor.systemGreen.withAlphaComponent(0.42)
                : LunaColors.primaryText
            button.configuration?.baseBackgroundColor = finished
                ? UIColor.white.withAlphaComponent(0.08)
                : LunaSurfacePalette.baseColor.withAlphaComponent(0.24)
        }
        button.configurationUpdateHandler = applyStyle
        applyStyle(button)
    }

    @objc private func safariTapped() {
        presentSetupReplay(.safari)
    }

    @objc private func saveSetupTapped() {
        presentSetupReplay(.messages)
    }

    /// Replays one setup lesson over the deck, returning to this app's own root
    /// when it finishes. Every app compiles both ends, so the card names them.
    private func presentSetupReplay(_ source: OnboardingDemoSource) {
        AppOnboardingViewController.presentSetupReplay(
            source, from: self, root: KindWiringOnboardingRoot())
    }

    @objc private func emailSetupTapped() {
        Self.emailSetupLauncher?.presentEmailSetup(from: self)
    }

    // MARK: - Where downloads are stored

    /// Puts the "Store downloads …" line on the card if this app downloads at
    /// all, and either the user has never answered the question here or in
    /// Settings, or the answer standing is Photos from the SIBLING app that
    /// downloads (the choice lives in the shared App Group; Photos permission
    /// does not) and this process has never itself been asked for it. Read
    /// once, at construction: answering it — or resolving the permission
    /// relay — retires the row from the next launch's card rather than
    /// pulling it out from under the tap that answered it.
    private func installStorageChooserIfOffered() {
        guard let storageChoice else { return }
        let needsPermissionRelay = storageChoice.needsPhotosPermissionInThisApp
        guard storageChoice.isUnanswered || needsPermissionRelay else { return }
        let chooser = UtilCardStorageChooserView()
        chooser.setSelection(storageChoice.usesPhotos ? .photos : .luna)
        chooser.setPermissionError(needsPermissionRelay)
        chooser.delegate = self
        view.addSubview(chooser)
        storageChooser = chooser
        // Fires the instant the row appears — the same system prompt a manual
        // "Photos" tap would produce, just relayed on the sibling app's behalf
        // rather than waiting for this app's user to tap anything.
        if needsPermissionRelay {
            storageChoice.requestPhotosPermissionRelay { [weak self] outcome in
                guard let self else { return }
                switch outcome {
                case .granted:
                    storageChooser?.setPermissionError(false)
                case .refused, .refusedBefore:
                    storageChooser?.setPermissionError(true)
                }
            }
        }
    }

    /// Directs the user to this app's own page in system Settings — the only
    /// place a denied Photos permission can now be granted.
    private func presentPhotosPermissionAlert() {
        PhotosPermissionAlert.present(from: self) { [weak self] in
            self?.delegate?.utilCardOpenSystemSettings()
        }
    }

    /// Applies a tap on the storage line. "In Luna" is immediate; "in Photos"
    /// is a REQUEST — the setting follows the system's answer, never leads it,
    /// so a refusal leaves the line reading "in Luna" rather than promising a
    /// destination Luna cannot write to.
    private func applyStorageChoice(_ option: UtilCardStorageChooserView.Option) {
        guard let storageChoice else { return }
        switch option {
        case .luna:
            storageChoice.chooseInLuna()
            storageChooser?.setSelection(.luna)
            storageChooser?.setPermissionError(false)
        case .photos:
            storageChoice.choosePhotos { [weak self] outcome in
                guard let self else { return }
                switch outcome {
                case .granted:
                    storageChooser?.setSelection(.photos)
                    storageChooser?.setPermissionError(false)
                case .refused:
                    storageChooser?.setSelection(.luna)
                    storageChooser?.setPermissionError(false)
                case .refusedBefore:
                    // iOS will not ask again in-process; Luna's own page in
                    // Settings is the only place this can now be granted.
                    storageChooser?.setSelection(.luna)
                    storageChooser?.setPermissionError(storageChoice.needsPhotosPermissionInThisApp)
                    delegate?.utilCardOpenSystemSettings()
                }
            }
        }
    }

    private func rebuildRecentRows() {
        for row in recentRows { row.removeFromSuperview() }
        recentRows = (dataSource?.utilCardRecentMatches ?? []).map { preview in
            let row = UtilURLRow(style: .recent)
            row.configure(preview)
            row.delegate = self
            view.addSubview(row)
            return row
        }
        view.setNeedsLayout()
    }
}

// MARK: - The Save of the Week slot's delegate

extension UtilCardContentViewController: WeeklySaveRowHostDelegate {
    func weeklySaveRowHost(
        _ host: WeeklySaveRowHost, didChooseURLString urlString: String,
        from sourceView: UIView
    ) {
        save(urlString, source: .manual, sourceView: sourceView)
    }

    func weeklySaveRowHostPresenceDidChange(_ host: WeeklySaveRowHost) {
        view.setNeedsLayout()
    }

    /// The row names which app is due; the labels never count for themselves, so
    /// the phrasing and the pick are always the same app's. Only central Luna
    /// builds a cycler, so everywhere else this is a no-op.
    func weeklySaveRowHost(_ host: WeeklySaveRowHost, didCycleTo kind: WeeklySaveKind) {
        setupTextCycler?.show(kind.owningApp)
    }

    func weeklySaveRowHost(
        _ host: WeeklySaveRowHost, isSavedURLString urlString: String
    ) -> Bool {
        dataSource?.utilCardSavedURLStrings.contains(urlString) ?? false
    }
}

// MARK: - The recent-history rows' delegate

extension UtilCardContentViewController: UtilURLRowDelegate {
    func utilURLRowWasTapped(_ row: UtilURLRow) {
        guard let urlString = row.urlString else { return }
        save(urlString, source: .manual, sourceView: row)
    }
}

// MARK: - The download-storage row's delegate

extension UtilCardContentViewController: UtilCardStorageChooserDelegate {
    func storageChooser(
        _ chooser: UtilCardStorageChooserView,
        didChoose option: UtilCardStorageChooserView.Option
    ) {
        applyStorageChoice(option)
    }

    func storageChooserDidTapPermissionError(_ chooser: UtilCardStorageChooserView) {
        presentPhotosPermissionAlert()
    }
}

// MARK: - The setup labels' cycler delegate

extension UtilCardContentViewController: UtilCardSetupTextCyclerDelegate {
    func setupTextCycler(
        _ cycler: UtilCardSetupTextCycler, willBeginCycleTo app: LunaApp
    ) {
        setupTextCycleDidStart()
    }
}

/// A tapped URL row, reported to whichever list built it. The link is the row's
/// own `urlString`.
@MainActor
protocol UtilURLRowDelegate: AnyObject {
    func utilURLRowWasTapped(_ row: UtilURLRow)
}

/// A black URL row with a narrow Liquid Glass rim — the same rim the deck's own
/// cards wear, so a row reads as a card in waiting rather than as a tinted
/// banner.
///
/// The two styles are deliberately NOT interchangeable dressings of one row.
/// A recent is raw Safari history and stays neutral; the Luna team pick carries
/// the app's colour — a wash over the same black, a palette-tinted rim, and its
/// attribution line in the accent — so the two
/// never read as one list of equals.
final class UtilURLRow: UIControl {
    enum Style: Equatable { case saveOfTheWeek, recent }

    /// Shared by the row, its glass rim, and the slot that clips a replacement
    /// slide, so all three round by the same amount.
    static let cornerRadius: CGFloat = 16

    /// The black both styles share. Also the colour the weekly flag dims its
    /// palette into (`WeeklyRibbonView.fillColor`), so the two never drift.
    static let rowBackground = UIColor(white: 0.025, alpha: 1)

    /// The wash the weekly row wears over the shared black. Low enough that the
    /// row is still a black card in waiting, high enough to separate it from the
    /// history rows beneath at a glance.
    static let weeklyWashAlpha: CGFloat = 0.10
    /// The weekly rim's tint. The neutral rim is white at 0.14, so the palette
    /// goes on at a comparable weight rather than as a saturated outline.
    static let weeklyRimAlpha: CGFloat = 0.30

    private let style: Style
    /// Present on the weekly row only, beneath every other subview.
    private let wash = UIView()
    private let thumbnail = UIImageView()
    private let savedOverlay = UIView()
    private let savedCheckmark = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    /// The Luna team attribution, on the curated row only: a tinted corner flag
    /// instead of a phrase competing with the host for the subtitle's width.
    private let weeklyRibbon: WeeklyRibbonView?
    private let border = UtilURLRowGlassBorder()
    private var previewKind: RecentURLPreview.Kind?
    private var weeklyTint = LunaSurfacePalette.baseColor
    private(set) var isShownAsSaved = false
    /// Whichever list built this row — hence weak.
    weak var delegate: (any UtilURLRowDelegate)?

    /// The link this row currently shows, so a tap reports what was tapped
    /// without its owner keeping a parallel model array. Set by `configure`.
    private(set) var urlString: String?

    init(style: Style) {
        self.style = style
        weeklyRibbon = style == .saveOfTheWeek ? WeeklyRibbonView() : nil
        super.init(frame: .zero)
        accessibilityIdentifier = style == .saveOfTheWeek
            ? "utilCard.saveOfTheWeek"
            : "utilCard.recent"
        isAccessibilityElement = true
        backgroundColor = Self.rowBackground
        layer.cornerRadius = Self.cornerRadius
        layer.cornerCurve = .continuous
        clipsToBounds = true

        thumbnail.contentMode = .scaleAspectFill
        thumbnail.clipsToBounds = true
        thumbnail.layer.cornerRadius = 11
        thumbnail.layer.cornerCurve = .continuous
        thumbnail.tintColor = LunaColors.secondaryText
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = LunaColors.primaryText
        titleLabel.numberOfLines = 2
        subtitleLabel.font = .systemFont(
            ofSize: 12, weight: style == .saveOfTheWeek ? .semibold : .regular)
        subtitleLabel.textColor = style == .saveOfTheWeek
            ? LunaSurfacePalette.progressAccent
            : LunaColors.secondaryText
        subtitleLabel.lineBreakMode = .byTruncatingMiddle

        // Already saved: the artwork stays legible under a thin scrim and the
        // deck's own answer sits on top of it.
        savedOverlay.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        savedOverlay.layer.cornerRadius = thumbnail.layer.cornerRadius
        savedOverlay.layer.cornerCurve = .continuous
        savedOverlay.isUserInteractionEnabled = false
        savedOverlay.isHidden = true
        savedCheckmark.image = UIImage(systemName: "checkmark.circle.fill")
        savedCheckmark.tintColor = UIColor.white.withAlphaComponent(0.9)
        savedCheckmark.contentMode = .scaleAspectFit
        savedOverlay.addSubview(savedCheckmark)

        if style == .saveOfTheWeek {
            applyWeeklyTint(weeklyTint)
            wash.isUserInteractionEnabled = false
            addSubview(wash)
        }
        addSubview(thumbnail)
        addSubview(savedOverlay)
        addSubview(titleLabel)
        addSubview(subtitleLabel)
        // Last of the content, so the rim is still the only thing over it — the
        // flag clears the artwork rather than sitting on it, so the order is
        // only about the glass.
        if let weeklyRibbon { addSubview(weeklyRibbon) }
        addSubview(border)
        thumbnail.isAccessibilityElement = false
        titleLabel.isAccessibilityElement = false
        subtitleLabel.isAccessibilityElement = false
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
        accessibilityTraits = .button
        accessibilityHint = L10n.string("Onboarding_Util_recentRowAccessibilityHint")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// - Parameter weeklyLabel: The "From the Luna team" attribution. It goes
    ///   in the corner flag, which is why the subtitle is the host and nothing
    ///   else. Ignored by history rows.
    func configure(
        _ preview: RecentURLPreview,
        weeklyLabel: String? = nil,
        weeklyTint: UIColor? = nil
    ) {
        if let weeklyTint { applyWeeklyTint(weeklyTint) }
        urlString = preview.urlString
        previewKind = preview.kind
        let artwork = preview.image
        thumbnail.image = artwork ?? UIImage(
            systemName: preview.kind == .media ? "play.rectangle.fill"
                : preview.kind == .product ? "bag.fill" : "safari.fill")
        applyThumbnailPresentation(for: artwork)
        titleLabel.text = preview.title
        let host = URL(string: preview.urlString)?.host ?? preview.subtitle ?? preview.urlString
        subtitleLabel.text = host
        weeklyRibbon?.text = weeklyLabel ?? WeeklySaveLabels.subtitle()
        setNeedsLayout()
        // The flag carries the noun now, so VoiceOver reads it first — the row
        // still announces everything it shows.
        accessibilityLabel = [weeklyRibbon?.text, titleLabel.text, subtitleLabel.text]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    /// A photograph fills the square; a site's own mark is FITTED into it.
    ///
    /// Both arrive here as "the preview's image", but a wordmark logo (the
    /// widest thing `FaviconFetcher` can hand back — 700×197 is a real one) put
    /// through `.scaleAspectFill` shows three cropped letters. A fitted mark
    /// needs the subtle fill behind it that `CarouselSourceBadgeView` gives
    /// transparent favicons, since plenty of them are dark artwork on nothing at
    /// all and the row is near-black.
    private func applyThumbnailPresentation(for artwork: UIImage?) {
        guard let artwork, artwork.size.width > 0, artwork.size.height > 0 else {
            thumbnail.contentMode = .scaleAspectFill
            thumbnail.backgroundColor = .clear
            return
        }
        let ratio = artwork.size.width / artwork.size.height
        let isMark = ratio > 1.3 || ratio < 1 / 1.3
        thumbnail.contentMode = isMark ? .scaleAspectFit : .scaleAspectFill
        thumbnail.backgroundColor = isMark ? LunaColors.tertiaryFill : .clear
    }

    private func applyWeeklyTint(_ tint: UIColor) {
        weeklyTint = tint
        wash.backgroundColor = tint.withAlphaComponent(Self.weeklyWashAlpha)
        border.rimTint = tint.withAlphaComponent(Self.weeklyRimAlpha)
        weeklyRibbon?.setTint(tint)
    }

    /// How far the row's CONTENT trails its shell during a cycle slide. The
    /// shell travels a full row width; the thumbnail and labels lag behind it
    /// by this much, which is what gives the swap depth instead of reading as
    /// one flat rectangle sliding.
    func setContentParallax(_ translationX: CGFloat) {
        let transform = CGAffineTransform(translationX: translationX, y: 0)
        thumbnail.transform = transform
        savedOverlay.transform = transform
        titleLabel.transform = transform
        subtitleLabel.transform = transform
        // The flag names the PICK, not the slot, so it travels with the content.
        weeklyRibbon?.transform = transform
    }

    /// The row's fill as ONE flat colour, with the weekly wash already
    /// composited into the black base. The save transition's shell is a single
    /// view, so it takes this rather than the base plus a wash it cannot layer.
    private var compositedFill: UIColor {
        let base = backgroundColor ?? .black
        guard style == .saveOfTheWeek else { return base }
        var baseRGBA = (r: CGFloat(0), g: CGFloat(0), b: CGFloat(0), a: CGFloat(0))
        var washRGBA = (r: CGFloat(0), g: CGFloat(0), b: CGFloat(0), a: CGFloat(0))
        guard base.getRed(&baseRGBA.r, green: &baseRGBA.g, blue: &baseRGBA.b, alpha: &baseRGBA.a),
              weeklyTint.getRed(
                &washRGBA.r, green: &washRGBA.g, blue: &washRGBA.b, alpha: &washRGBA.a)
        else { return base }
        let wash = Self.weeklyWashAlpha
        return UIColor(
            red: washRGBA.r * wash + baseRGBA.r * (1 - wash),
            green: washRGBA.g * wash + baseRGBA.g * (1 - wash),
            blue: washRGBA.b * wash + baseRGBA.b * (1 - wash),
            alpha: 1)
    }

    /// This URL is already in the deck: the row dims and its artwork carries a
    /// checkmark, through which the favicon or thumbnail still reads.
    func setSaved(_ saved: Bool) {
        isShownAsSaved = saved
        savedOverlay.isHidden = !saved
        alpha = saved ? 0.55 : 1
        accessibilityValue = saved ? L10n.string("Common_saved") : nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Frames are meaningless under a transform, so the parallax offset is
        // lifted off, the real geometry applied, and the offset put back.
        let parallax = thumbnail.transform
        thumbnail.transform = .identity
        savedOverlay.transform = .identity
        titleLabel.transform = .identity
        subtitleLabel.transform = .identity
        weeklyRibbon?.transform = .identity
        defer {
            thumbnail.transform = parallax
            savedOverlay.transform = parallax
            titleLabel.transform = parallax
            subtitleLabel.transform = parallax
            weeklyRibbon?.transform = parallax
        }
        wash.frame = bounds
        let imageSide = min(52, max(42, bounds.height - 22))
        // The flag is a band across the row's top, and the artwork stays clear of
        // it: centred as ever, unless the row is short enough that centring would
        // put it under the flag, in which case it sits just below instead. At the
        // weekly row's own 96pt the two agree to the point, so nothing moves.
        let flagFloor: CGFloat = weeklyRibbon == nil ? 0 : WeeklyRibbonView.height + 2
        thumbnail.frame = CGRect(
            x: 11,
            y: max(flagFloor, (bounds.height - imageSide) / 2),
            width: imageSide,
            height: imageSide)
        savedOverlay.frame = thumbnail.frame
        let checkSide = (imageSide * 0.52).rounded()
        savedCheckmark.frame = CGRect(
            x: ((imageSide - checkSide) / 2).rounded(),
            y: ((imageSide - checkSide) / 2).rounded(),
            width: checkSide,
            height: checkSide)
        let labelX = thumbnail.frame.maxX + 11
        let labelWidth = max(0, bounds.width - labelX - 12)
        // The flag occupies the row's top-left corner, so the title starts BELOW
        // it; a history row has no flag and keeps its old 13pt top exactly.
        let titleTop: CGFloat = weeklyRibbon == nil ? 13 : WeeklyRibbonView.height + 6
        titleLabel.frame = CGRect(
            x: labelX,
            y: titleTop,
            width: labelWidth,
            height: weeklyRibbon == nil
                ? max(22, bounds.height - 40)
                : max(22, bounds.height - titleTop - 28))
        subtitleLabel.frame = CGRect(
            x: labelX,
            y: bounds.height - 27,
            width: labelWidth,
            height: 16)
        if let weeklyRibbon {
            weeklyRibbon.frame = CGRect(
                x: 0,
                y: 0,
                // Never more than the row's leading half: a long localisation
                // must not sail across the title.
                width: min(weeklyRibbon.fittingWidth, (bounds.width * 0.55).rounded()),
                height: WeeklyRibbonView.height)
        }
        border.frame = bounds
    }

    @objc private func tapped() { delegate?.utilURLRowWasTapped(self) }
}

@MainActor
extension UtilURLRow: UtilCardSaveTransitionArtworkProviding {
    func makeUtilCardSaveTransitionArtwork(
        in coordinateView: UIView
    ) -> UtilCardSaveTransitionArtwork? {
        guard let previewKind, let title = titleLabel.text else { return nil }
        layoutIfNeeded()

        let thumbnailCopy = UIImageView(image: thumbnail.image)
        thumbnailCopy.frame = thumbnail.convert(thumbnail.bounds, to: coordinateView)
        thumbnailCopy.contentMode = thumbnail.contentMode
        thumbnailCopy.tintColor = thumbnail.tintColor
        thumbnailCopy.backgroundColor = thumbnail.backgroundColor
        thumbnailCopy.clipsToBounds = true
        thumbnailCopy.layer.cornerRadius = thumbnail.layer.cornerRadius
        thumbnailCopy.layer.cornerCurve = .continuous

        let titleCopy = UILabel()
        titleCopy.text = title
        titleCopy.frame = titleLabel.convert(titleLabel.bounds, to: coordinateView)
        titleCopy.font = titleLabel.font
        titleCopy.textColor = titleLabel.textColor
        titleCopy.numberOfLines = titleLabel.numberOfLines

        let subtitleCopy = UILabel()
        subtitleCopy.text = subtitleLabel.text
        subtitleCopy.frame = subtitleLabel.convert(subtitleLabel.bounds, to: coordinateView)
        subtitleCopy.font = subtitleLabel.font
        subtitleCopy.textColor = subtitleLabel.textColor

        return UtilCardSaveTransitionArtwork(
            kind: previewKind,
            sourceFrame: convert(bounds, to: coordinateView),
            backgroundColor: compositedFill,
            rimTint: border.rimTint,
            cornerRadius: layer.cornerRadius,
            thumbnail: thumbnailCopy,
            title: titleCopy,
            subtitle: subtitleCopy)
    }
}

/// The rim a util row wears, and the same rim the save transition's growing
/// shell wears: `CardSurfaceView`'s recipe — plain Liquid Glass under
/// `GlassStyle.glassBorderColor` — at whatever corner radius its owner is
/// currently drawn with. Nothing is tinted with the app's palette here: a row
/// is a card in waiting, and the deck's cards carry no tint.
final class UtilURLRowGlassBorder: UIVisualEffectView {
    static let cornerRadius: CGFloat = 16

    private let rimMaskView = UIView()
    private let maskLayer = CAShapeLayer()
    private let highlight = CAShapeLayer()

    /// Follows the owner's corner radius. Assigning it inside a UIView
    /// animation block carries the rim along with an animating card radius,
    /// since both shape layers pick up the transaction's implicit animation.
    var cornerRadius: CGFloat = UtilURLRowGlassBorder.cornerRadius {
        didSet {
            guard cornerRadius != oldValue else { return }
            applyGeometry()
        }
    }

    /// Replaces the neutral glass rim. The Luna team row is the one
    /// caller: everything else — the history rows, the save transition's growing
    /// shell — is a card in waiting and stays untinted.
    var rimTint: UIColor? {
        didSet {
            guard rimTint != oldValue else { return }
            applyGeometry()
        }
    }

    init() {
        super.init(effect: GlassStyle.barEffect())
        isUserInteractionEnabled = false
        maskLayer.fillColor = UIColor.white.cgColor
        maskLayer.fillRule = .evenOdd
        rimMaskView.layer.addSublayer(maskLayer)
        mask = rimMaskView
        highlight.fillColor = UIColor.clear.cgColor
        highlight.lineWidth = 0.5
        contentView.layer.addSublayer(highlight)
        registerForTraitChanges([LunaSkyTrait.self]) {
            (rim: UtilURLRowGlassBorder, _: UITraitCollection) in
            rim.applyGeometry()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyGeometry()
    }

    private func applyGeometry() {
        let corner = cornerRadius
        let rim: CGFloat = 1.5
        let path = UIBezierPath(roundedRect: bounds, cornerRadius: corner)
        path.append(UIBezierPath(
            roundedRect: bounds.insetBy(dx: rim, dy: rim),
            cornerRadius: max(0, corner - rim)))
        rimMaskView.frame = bounds
        maskLayer.frame = bounds
        maskLayer.path = path.cgPath
        highlight.frame = bounds
        highlight.path = UIBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            cornerRadius: max(0, corner - 0.5)).cgPath
        highlight.strokeColor = (rimTint ?? GlassStyle.glassBorderColor)
            .resolvedColor(with: traitCollection).cgColor
    }
}

//
//  AppOnboardingViewController.swift
//  Luna
//

import LunaDesignSystem
import LunaIngest
import LunaModels
import LunaReadingList
import LunaStorage
import LunaURLClassification
import UIKit

enum OnboardingDemoLoopTiming {
    static let geometryDuration: TimeInterval = 0.58
    static let savedCardHoldDuration: TimeInterval = 0.95
    /// Each completed source remains unobscured long enough to register before
    /// its corresponding setup instructions fade in.
    static let setupPromptSavedCardHoldDuration: TimeInterval = 1.35
    /// A brief clean source beat before the next save gesture begins.
    static let sourceHoldDuration: TimeInterval = 0.38
    /// The freeze every Safari lesson holds, in all four apps, the instant it
    /// reaches its own setup offer: the shared popup and its scrim come up,
    /// and the lesson underneath stays exactly as it stands for this long
    /// before it resets and replays — a faceted app's one lesson replaying
    /// itself, or central Luna's cycle crossing to the next sibling. Longer
    /// than a card hold: what it is holding is the point the lesson just
    /// made.
    static let siblingLessonHoldDuration: TimeInterval = 2.0
}

enum OnboardingDemoSource: CaseIterable, Equatable {
    case safari
    case messages

    var next: Self {
        switch self {
        case .safari: return .messages
        case .messages: return .safari
        }
    }
}

enum OnboardingSetupPrompt: Equatable {
    case safari
    case actionButton
}

enum OnboardingSetupOutcome {
    case completed
    case skipped
}

/// Each intro button's artwork: untouched, genuinely finished (checkmark,
/// disabled), or skipped (a distinct icon, but still enabled so the lesson
/// can be tried again).
enum OnboardingSetupButtonState: Equatable {
    case pending
    case completed
    case skipped

    var isFinished: Bool { self != .pending }
}

/// Each independently launched mock source tracks its corresponding setup
/// prompt while it is active.
enum OnboardingJourneyStage: Equatable {
    case safariDemonstration
    case safariSetup
    case messagesDemonstration
    case actionButtonSetup

    mutating func completedSave(
        from source: OnboardingDemoSource
    ) -> OnboardingSetupPrompt? {
        switch (self, source) {
        case (.safariDemonstration, .safari):
            self = .safariSetup
            return .safari
        case (.messagesDemonstration, .messages):
            self = .actionButtonSetup
            return .actionButton
        default:
            return nil
        }
    }

}

/// The hosted setup site's canonical per-app slug (`site/README.md`'s
/// `/setup/<slug>` list) — the same four pages the site generator builds.
private extension LunaApp {
    var safariSetupPageSlug: String {
        switch self {
        case .luna: return "luna"
        case .reader: return "reader"
        case .downloader: return "downloader"
        case .priceTracker: return "price-tracker"
        }
    }
}

/// The shared guided first-run deck. It intentionally uses the production
/// CardCarousel rather than a look-alike. Safari and Shortcut actions enter
/// their respective facsimiles independently and return through the mock app
/// switcher. A pasted article eclipses into the real saved card and production
/// root, including its ordinary card chrome and carousel.
final class AppOnboardingViewController: UIViewController {
    private enum ExternalReturn: Equatable {
        case none
        case safari
        case shortcut
        case actionButton
    }

    private enum DemoPresentation {
        case fullScreen
        case card
    }

    private let configuration: OnboardingSurfaceConfiguration
    private let onboardingStore: AppOnboardingStore
    private let completion: AppOnboardingCompletion
    private let setupReplaySource: OnboardingDemoSource?
    private let setupReplayOriginSnapshot: UIImage?
    private let carousel = CardCarouselViewController()
    private let intro: OnboardingIntroCardContentViewController
    private let actionGuide = SetupGuideVideo()
    private var safariReplica: SafariReplicaViewController?
    /// One mounted replica per lesson the app's Safari journey plays. A faceted
    /// app has exactly one; central Luna has its three siblings', which it
    /// cycles through in rank order.
    private var safariReplicas: [LunaApp: SafariReplicaViewController] = [:]
    /// Which of `configuration.safariDemonstrationApps` is on screen.
    private var safariCycleIndex = 0
    /// The sibling cycle is running: from the first lesson's start until an
    /// external hop or the end of onboarding stops it.
    private var isCyclingSafariLessons = false
    /// The Safari ask is up. It is raised by the pass that completes the first
    /// full cycle and stays for the rest of the lesson, so later passes must not
    /// raise or reconfigure it.
    private var didRaiseSafariSetupPopover = false
    /// The ONE popup every Safari lesson's own setup offer ends on, in every
    /// app. Owned directly by this controller rather than by whichever
    /// `SafariReplicaViewController` happened to be on screen when the lesson
    /// reached its offer — central Luna's cycle keeps swapping which sibling
    /// that is underneath the popup, so an object that gets swapped out is the
    /// wrong owner. See `showSafariSetupPopup()`.
    private var safariSetupPopup: OnboardingSafariSetupPopupView?
    /// The popup's full-screen 40% scrim — mounted directly on the window
    /// BELOW the popup and never touched again after it fades in, alongside
    /// (never inside) the popup for the same reason
    /// `OnboardingSafariSetupPopupView`'s own doc comment gives.
    private var safariSetupScrim: SafariSetupScrimView?
    private var messagesReplica: MessagesReplicaViewController?
    /// The save lesson's engine, built the moment the user taps into it: it
    /// resolves the link, starts the real work, and owns the real share surface
    /// the lesson demonstrates with. Nil until then — nothing is fetched, saved
    /// or downloaded on behalf of a lesson nobody entered.
    /// Internal for the lesson tests, which assert the engine runs detached.
    private(set) var saveDemoController: OnboardingSaveDemoController?
    private var savedRootViewController: UIViewController?
    private var savedCardWaveSnapshot: UIImage?
    private var introCorona: UIView?
    private var keepsIntroCorona = true
    private var externalReturn = ExternalReturn.none
    private var didConfigureGuides = false
    private var isDemonstrationPreloaded = false
    private var didExpandSafari = false
    private var demoPresentation = DemoPresentation.fullScreen
    private var activeDemoSource = OnboardingDemoSource.safari
    private var nextDemoSource = OnboardingDemoSource.messages
    private var journeyStage = OnboardingJourneyStage.safariDemonstration
    private var demoTransitionGeneration = 0
    private var demoLoopGeneration = 0
    private var isDemoGeometryTransitioning = false
    private var appSwitcher: OnboardingAppSwitcherView?
    private var setupReplayOriginView: UIImageView?
    private var didStartSetupReplay = false
    private var isFinishing = false
    private var foregroundObserver: NSObjectProtocol?
    private var setupObserver: NSObjectProtocol?
    private var contentObservers: [NSObjectProtocol] = []
    private var knownContentIdentifiers: Set<UUID> = []
    private var savedCardPreviewImage: UIImage?
    private var isHandlingPaste = false
    private var safariSetupState = OnboardingSetupButtonState.pending
    private var shortcutSetupState = OnboardingSetupButtonState.pending
    #if DEBUG
    private var debugSafariStage: String?
    var savedRootViewControllerForTesting: UIViewController? {
        savedRootViewController
    }

    /// The handoff a successful paste runs, without the ingest in front of it.
    func completeOnboardingWithRealSaveForTesting(animated: Bool) {
        completeOnboardingWithRealSave(animated: animated)
    }

    /// Which sibling's lesson the Safari journey is showing.
    var safariDemonstrationAppForTesting: LunaApp? {
        let apps = configuration.safariDemonstrationApps
        guard apps.indices.contains(safariCycleIndex) else { return nil }
        return apps[safariCycleIndex]
    }

    var hasSafariInstructionsForTesting: Bool { hasSafariInstructions }

    /// The ending each lesson reports for itself, without spending the several
    /// seconds of animation that lead up to it.
    func finishSafariLessonForTesting() {
        guard let app = safariDemonstrationAppForTesting else { return }
        safariLessonDidReachSetupOffer(app)
    }

    /// Simulates the return leg from a real hop to Safari that brought back no
    /// extension evidence, without an actual `UIApplication.open` round trip.
    func restoreSharedSafariSetupPopupForTesting() {
        restoreSharedSafariSetupPopupIfNeeded()
    }

    /// The shared popup's scrim, directly — nil whenever no popup is up. Tests
    /// use this (rather than hunting the window for a `SafariSetupScrimView`)
    /// to confirm ownership stays put across a cross-sibling swap.
    var safariSetupScrimForTesting: UIView? { safariSetupScrim }

    /// Enters the Safari lesson the way the util card's button does, for the
    /// staged screen that reviews the whole journey (`claudedocs/staging.md`).
    func startSafariLessonForStaging() {
        showSafariCard()
    }
    #endif

    init(
        configuration: OnboardingSurfaceConfiguration = .current,
        onboardingStore: AppOnboardingStore = .shared,
        setupReplaySource: OnboardingDemoSource? = nil,
        setupReplayOriginSnapshot: UIImage? = nil,
        completion: AppOnboardingCompletion
    ) {
        self.configuration = configuration
        self.onboardingStore = onboardingStore
        self.setupReplaySource = setupReplaySource
        self.setupReplayOriginSnapshot = setupReplayOriginSnapshot
        self.completion = completion
        self.intro = OnboardingIntroCardContentViewController(
            introCopy: configuration.introCopy)
        super.init(nibName: nil, bundle: nil)
    }

    /// Re-enters one of onboarding's production mock lessons from the setup
    /// tray. The presenting app is frozen into the first/last switcher card so
    /// the existing journey can run without replacing the completed app root.
    @MainActor
    static func presentSetupReplay(
        _ source: OnboardingDemoSource,
        from presenter: UIViewController,
        makeCompletedRootViewController: @escaping () -> UIViewController
    ) {
        guard let window = presenter.view.window else { return }
        let snapshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let replay = AppOnboardingViewController(
            setupReplaySource: source,
            setupReplayOriginSnapshot: snapshot,
            completion: AppOnboardingCompletion(
                makeCompletedRootViewController: makeCompletedRootViewController))
        replay.modalPresentationStyle = .fullScreen
        presenter.present(replay, animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var childForStatusBarStyle: UIViewController? {
        // Preloading mounts the replicas and production root while the intro
        // card is still up; none of them own the status bar until then.
        guard didExpandSafari else { return nil }
        return demoPresentation == .fullScreen
            ? sourceController(for: activeDemoSource)
            : savedRootViewController
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    /// The Messages replica hides the status bar around its mock Dynamic
    /// Island treatment; forward the query the same way as the style.
    override var childForStatusBarHidden: UIViewController? {
        childForStatusBarStyle
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        // Only what the first frame needs. The guide players (AVFoundation)
        // and the demonstration preload run staged behind the intro reveal,
        // off the launch frame.
        configureCarousel()
        configureLifecycleObservers()
        installSetupReplayOriginIfNeeded()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        beginSetupReplayIfNeeded()
    }

    deinit {
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
        if let setupObserver { NotificationCenter.default.removeObserver(setupObserver) }
        for observer in contentObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
        applyTopInset()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        applyTopInset()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutIntroCorona()
    }

    private func configureCarousel() {
        let starfield = StarfieldView.install(behindContentsOf: view)
        carousel.chromeBackdrop = starfield
        var style = CardCarouselStyle()
        style.scrubberHorizontalInset = 56
        style.scrubberEdgeFadeWidth = 28
        style.showsCardBorder = true
        carousel.style = style
        carousel.dataSource = self
        carousel.delegate = self

        addChild(carousel)
        carousel.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(carousel.view)
        carousel.didMove(toParent: self)
        NSLayoutConstraint.activate([
            carousel.view.topAnchor.constraint(equalTo: view.topAnchor),
            carousel.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            carousel.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            carousel.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        intro.onSafari = { [weak self] in self?.showSafariCard() }
        intro.onShortcut = { [weak self] in self?.showMessagesCard() }
        intro.onPaste = { [weak self] value in self?.pasteArticleURL(value) }
        intro.onFirstLineRevealed = { [weak self] in
            self?.firstIntroLineDidReveal()
        }
        safariSetupState = LunaSetupStatusStore.shared.safariRunApplies(
            to: configuration.app) ? .completed : .pending
        shortcutSetupState = saveSetupHasRun ? .completed : .pending
        intro.setState(safari: safariSetupState, shortcut: shortcutSetupState)
        carousel.reloadData(centeringAt: 0)
    }

    private func installSetupReplayOriginIfNeeded() {
        guard setupReplaySource != nil,
              let setupReplayOriginSnapshot
        else { return }
        let imageView = UIImageView(image: setupReplayOriginSnapshot)
        imageView.frame = view.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.contentMode = .scaleToFill
        imageView.isAccessibilityElement = false
        view.addSubview(imageView)
        setupReplayOriginView = imageView
    }

    private func beginSetupReplayIfNeeded() {
        guard let setupReplaySource, !didStartSetupReplay else { return }
        didStartSetupReplay = true
        if let setupReplayOriginView {
            view.bringSubviewToFront(setupReplayOriginView)
        }
        switch setupReplaySource {
        case .safari:
            showSafariCard()
        case .messages:
            showMessagesCard()
        }
    }

    private func applyTopInset() {
        carousel.setTopInset(view.safeAreaInsets.top + CardDeckGeometry.topClearance)
    }

    private func layoutIntroCorona() {
        guard keepsIntroCorona else {
            introCorona?.removeFromSuperview()
            introCorona = nil
            return
        }
        carousel.view.layoutIfNeeded()
        guard let cardFrame = carousel.restingCenteredCardFrame(in: view) else {
            return
        }

        if introCorona?.bounds.size != cardFrame.size {
            introCorona?.removeFromSuperview()
            // The same artwork the splash draws, at the same frame, so the
            // launch view is free to fade out and be discarded without anything
            // on screen changing.
            let corona = AppLaunchTransition.makeCoronaCardView(
                cardFrame: cardFrame)
            view.insertSubview(corona, belowSubview: carousel.view)
            introCorona = corona
        } else {
            introCorona?.frame = cardFrame
        }
    }

    private func dismissIntroCorona() {
        keepsIntroCorona = false
        introCorona?.removeFromSuperview()
        introCorona = nil
    }

    private func configureGuidesIfNeeded() {
        guard !didConfigureGuides else { return }
        didConfigureGuides = true
        let player = actionGuide.playerView
        player.frame = CGRect(x: 1, y: 1, width: 2, height: 2)
        player.alpha = 0.01
        view.insertSubview(player, at: 0)
        actionGuide.prepare()
    }

    private func configureLifecycleObservers() {
        knownContentIdentifiers = completion.contentWatch.storedIdentifiers()
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.returnedFromExternalApp() }
        }
        setupObserver = NotificationCenter.default.addObserver(
            forName: LunaSetupStatusStore.didChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.setupStatusChanged() }
        }
        LunaSetupStatusStore.startObservingCrossProcessChanges()
        contentObservers = completion.contentWatch.changeNotifications.map { name in
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.contentStoreDidChange() }
            }
        }
    }

    private func startAfterLaunchTransition() {
        #if DEBUG
        if let stage = Self.requestedDebugStage {
            debugSafariStage = stage
            showSafariCard()
            return
        }
        #endif
        intro.start()
        #if DEBUG
        // Inspection seam: `UIPasteControl` is privacy-gated and cannot be
        // driven by synthetic taps, so the paste handoff is otherwise
        // unreachable from an automated run.
        if let url = Self.requestedDebugPasteURL {
            DispatchQueue.main.asyncAfter(
                deadline: .now() + OnboardingAnimationClock.delay(4.2)
            ) { [weak self] in self?.intro.didPaste(url) }
        }
        #endif
    }

    /// Intro callback (and test seam): the first line has finished its
    /// reveal, so the heavy preparation can begin in the reading pause.
    func firstIntroLineDidReveal() {
        configureGuidesIfNeeded()
        // The replicas are store-free and safe to warm while the user reads.
        // In particular, giving Safari's WKWebView a run-loop turn to load its
        // bundled page keeps a first button tap from synchronously waiting on
        // `drawHierarchy(afterScreenUpdates:)`.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.didExpandSafari else { return }
            self.mountSourceReplicas()
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.didExpandSafari else { return }
                self.mountCompletedRootIfNeeded()
            }
        }
    }

    /// Builds the replica assets behind the intro copy: the setup guide
    /// players, the complete production root, the wave's saved-card raster, and
    /// both source replicas (Safari's WKWebView loads its bundled page
    /// asynchronously). The button then only has to run the expansion
    /// animation. Nothing here touches storage — the mock article, video and
    /// tracker live in the replica views alone.
    ///
    /// One stage per run-loop turn, deliberately: heavy work sharing a turn
    /// with a just-added CAAnimation delays that animation's first commit, and
    /// the render server then starts it partway through its duration — the
    /// intro reveal visibly "jumped ahead" when the whole preload ran in the
    /// reveal's own turn.
    private func runPreloadStage(_ stage: Int) {
        guard !isDemonstrationPreloaded, !didExpandSafari else { return }
        switch stage {
        case 0:
            configureGuidesIfNeeded()
        case 1:
            mountCompletedRootIfNeeded()
        case 2:
            savedCardWaveSnapshot = captureSavedCardWaveSnapshot()
        default:
            mountSourceReplicas()
            isDemonstrationPreloaded = true
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.runPreloadStage(stage + 1)
        }
    }

    /// The synchronous whole-preparation fallback for a press that arrives
    /// before (or without) the staged chain — the expansion path's guard.
    private func preloadDemonstrationIfNeeded() {
        guard !isDemonstrationPreloaded, !didExpandSafari else { return }
        configureGuidesIfNeeded()
        mountCompletedRootIfNeeded()
        isDemonstrationPreloaded = true
        mountSourceReplicas()
    }

    private func mountSourceReplicas() {
        guard safariReplica == nil else { return }
        for (offset, demonstrationApp) in configuration.safariDemonstrationApps.enumerated() {
            let safariConfiguration = OnboardingSurfaceConfiguration.configuration(
                for: configuration.app,
                saveSetupMode: configuration.saveSetupMode,
                demonstrationApp: demonstrationApp)
            let safari = SafariReplicaViewController(configuration: safariConfiguration)
            safari.onSetUpSafari = { [weak self] in self?.openSafariSetup() }
            safari.onSkipSafariSetup = { [weak self] in
                self?.skipSafariSetupAndContinue()
            }
            safari.onInstallShortcut = { [weak self] in self?.installShortcut() }
            safari.onSetActionButton = { [weak self] in self?.openActionButtonSettings() }
            safari.onSetUpLater = { [weak self] in
                self?.completeSetupFlow(.messages, outcome: .skipped)
            }
            safari.makeActionButtonDestinationSnapshot = { [weak self] in
                self?.makeSavedCardSnapshot()
            }
            safari.onActionButtonWaveFinished = { [weak self] in
                self?.actionButtonWaveDidFinish(from: .safari)
            }
            safari.onDidReachSetupOffer = { [weak self] in
                self?.safariLessonDidReachSetupOffer(demonstrationApp)
            }
            safariReplicas[demonstrationApp] = safari
            if offset == 0 {
                safariReplica = safari
            }

            addChild(safari)
            safari.view.frame = view.bounds
            safari.view.layer.cornerRadius = CardSurfaceView.cornerRadius
            safari.view.layer.cornerCurve = .continuous
            safari.view.clipsToBounds = true
            safari.view.alpha = 0
            safari.view.isHidden = true
            view.addSubview(safari.view)
            safari.didMove(toParent: self)
            safari.view.layoutIfNeeded()
        }

        let messages = MessagesReplicaViewController(
            urlString: configuration.practiceURLString,
            app: configuration.app,
            appName: configuration.app.displayName,
            previouslyConfiguredApp: previouslyConfiguredShortcutApp)
        // The Messages demonstration finishes in place: its mock shortcut run
        // ends on the setup messages whose pills carry the setup hops.
        messages.onInstallShortcut = { [weak self] in self?.installShortcut() }
        messages.onOpenLunaAppStore = { [weak self] in self?.openLunaAppStore() }
        messages.onSetActionButton = { [weak self] in
            self?.openActionButtonSettings()
        }
        messages.onShortcutSetupMessagesShown = { [weak self] in
            self?.messagesDemonstrationDidPresentSetup()
        }
        messages.onSkipSetup = { [weak self] in
            self?.completeSetupFlow(.messages, outcome: .skipped)
        }
        messagesReplica = messages
        addChild(messages)
        messages.view.frame = view.bounds
        messages.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        messages.view.isHidden = true
        view.addSubview(messages.view)
        messages.didMove(toParent: self)

        // Every central sibling lesson is mounted hidden so the popup can stay
        // above a live page while the next feature animation starts below it.
    }

    /// Builds the save lesson's engine (once), points the conversation at the
    /// link it resolved, and lets the real surface start working behind the
    /// scenes. Called from BOTH ways into the lesson — the first-run tap and the
    /// settings replay — which is why it is idempotent.
    private func startSaveDemonstration(for messages: MessagesReplicaViewController) {
        let demo = saveDemoController ?? OnboardingSaveDemoController(
            link: OnboardingSaveDemoLink.resolve(
                practiceURLString: configuration.practiceURLString,
                app: configuration.demonstrationApp),
            onboardingStore: onboardingStore)
        saveDemoController = demo
        messages.saveDemoController = demo
        messages.updateURL(demo.link.urlString)
        demo.start(in: messages)
    }

    /// Ends the save lesson for good: releases the downloaded file the demo
    /// replays were reusing and takes its row back out of the store for the last
    /// time. Called from every route out of onboarding — `deinit` cannot, being
    /// nonisolated where the controller is main-actor bound, and a rehearsal
    /// outliving its lesson is exactly what the temporary-save marker exists to
    /// stop.
    private func endSaveDemonstration() {
        saveDemoController?.tearDown()
        saveDemoController = nil
        messagesReplica?.saveDemoController = nil
    }

    /// The link the lesson is rehearsing with, or the app's practice link before
    /// the lesson has been entered.
    private func saveDemonstrationLink() -> OnboardingSaveDemoLink {
        saveDemoController?.link
            ?? OnboardingSaveDemoLink.resolve(
                practiceURLString: configuration.practiceURLString,
                app: configuration.demonstrationApp)
    }

    private func showSafariCard() {
        guard carousel.currentIndex == 0, !didExpandSafari else { return }
        expandSafariCard()
    }

    private func showMessagesCard() {
        guard carousel.currentIndex == 0,
              !didExpandSafari,
              appSwitcher == nil
        else { return }
        preloadDemonstrationIfNeeded()
        guard let messages = messagesReplica else {
            intro.setActionsEnabled(true)
            return
        }
        didExpandSafari = true
        activeDemoSource = .messages
        nextDemoSource = .safari
        journeyStage = .messagesDemonstration
        demoPresentation = .fullScreen

        startSaveDemonstration(for: messages)
        messages.resetConversation()
        let messagesView = messages.view!
        messagesView.isHidden = false
        messagesView.alpha = 1
        messagesView.layer.cornerRadius = 0
        messagesView.frame = view.bounds
        view.insertSubview(messagesView, at: 0)
        messagesView.layoutIfNeeded()

        let outgoing = switcherSnapshot(of: view, afterScreenUpdates: false)
        let incoming = switcherSnapshot(
            of: messagesView, afterScreenUpdates: true)
        let switcher = OnboardingAppSwitcherView(
            frame: view.bounds, from: outgoing, to: incoming)
        appSwitcher = switcher
        view.addSubview(switcher)

        dismissIntroCorona()
        carousel.view.alpha = 0
        savedRootViewController?.view.alpha = 0

        switcher.playForward { [weak self] in
            guard let self else { return }
            self.view.bringSubviewToFront(messagesView)
            self.setupReplayOriginView?.removeFromSuperview()
            self.setupReplayOriginView = nil
            self.carousel.view.isHidden = true
            switcher.removeFromSuperview()
            self.appSwitcher = nil
            self.setNeedsStatusBarAppearanceUpdate()
            guard !self.isFinishing else { return }
            messages.scheduleStagedConversation()
            self.startDemoPresentationLoop()
        }
    }

    /// The Safari action hands off with the same mock app-switcher hop
    /// the Safari-setup return uses: the intro deck slides out as a rounded
    /// card while the browser, snapshotted at rest, slides in and fills the
    /// screen. (It used to grow the intro card itself to the display edges.)
    private func expandSafariCard() {
        guard !didExpandSafari, appSwitcher == nil else { return }
        preloadDemonstrationIfNeeded()
        rewindSafariLessonCycle()
        guard let safari = safariReplica else {
            intro.setActionsEnabled(true)
            return
        }
        didExpandSafari = true

        activeDemoSource = .safari
        nextDemoSource = .messages
        journeyStage = .safariDemonstration
        demoPresentation = .fullScreen

        // The lesson is re-enterable — skipping leaves its intro button live —
        // so every entry starts from the buried page, exactly as the Messages
        // lesson rewinds its conversation.
        safari.resetDemonstration()

        // Stage the browser at rest, laid out full screen underneath
        // everything, so it can be snapshotted as the incoming card.
        let safariView = safari.view!
        safariView.isHidden = false
        safariView.alpha = 1
        safariView.layer.cornerRadius = 0
        safariView.frame = view.bounds
        view.insertSubview(safariView, at: 0)
        safariView.layoutIfNeeded()

        let outgoing = switcherSnapshot(of: view, afterScreenUpdates: false)
        let incoming = switcherSnapshot(of: safariView, afterScreenUpdates: true)
        let switcher = OnboardingAppSwitcherView(
            frame: view.bounds, from: outgoing, to: incoming)
        appSwitcher = switcher
        view.addSubview(switcher)

        // The hop's own black backdrop covers the deck from its first frame.
        dismissIntroCorona()
        carousel.view.alpha = 0
        savedRootViewController?.view.alpha = 0

        switcher.playForward { [weak self] in
            guard let self else { return }
            self.view.bringSubviewToFront(safariView)
            self.setupReplayOriginView?.removeFromSuperview()
            self.setupReplayOriginView = nil
            self.carousel.view.isHidden = true
            switcher.removeFromSuperview()
            self.appSwitcher = nil
            self.setNeedsStatusBarAppearanceUpdate()
            guard !self.isFinishing else { return }
            #if DEBUG
            switch self.debugSafariStage {
            case "prompt":
                self.journeyStage = .safariSetup
                self.presentInstructionsAfterShrinking {
                    safari.showSafariPrompt()
                }
            case "setup":
                self.journeyStage = .actionButtonSetup
                self.presentInstructionsAfterShrinking {
                    safari.showShortcutAndActionSetup()
                }
            case "waiting":
                self.journeyStage = .actionButtonSetup
                self.presentInstructionsAfterShrinking {
                    safari.showWaitingForActionButton()
                }
            case "messages":
                self.journeyStage = .messagesDemonstration
                self.showDebugMessagesSource()
                self.startDemoPresentationLoop()
            default:
                safari.beginDemonstration()
            }
            #else
            safari.beginDemonstration()
            #endif
        }
    }

    /// Puts the sibling cycle back on its first lesson. The Safari lesson is
    /// re-enterable — skipping leaves its intro button live — and a second entry
    /// that opened on whichever sibling the last one wandered to would neither
    /// match the ranking nor its own first frame.
    private func rewindSafariLessonCycle() {
        let apps = configuration.safariDemonstrationApps
        didRaiseSafariSetupPopover = false
        isCyclingSafariLessons = apps.count > 1
        safariCycleIndex = 0
        guard let first = apps.first,
              let opening = safariReplicas[first],
              opening !== safariReplica
        else { return }
        for (app, replica) in safariReplicas where app != first {
            replica.resetDemonstration()
            replica.view.isHidden = true
            replica.view.alpha = 0
        }
        safariReplica = opening
    }

    private func actionButtonWaveDidFinish(from source: OnboardingDemoSource) {
        guard source == activeDemoSource else { return }

        // Central Luna keeps the Safari instructions above the lesson and
        // continues the lesson underneath them. Subsequent sibling waves are
        // just the loop's next beat; they must not replace or reconfigure the
        // active popup.
        if source == .safari, isCyclingSafariLessons {
            scheduleSafariInstructionReplay()
            return
        }

        commitWaveDrivenCardPresentation()
        nextDemoSource = source.next

        guard let prompt = journeyStage.completedSave(from: source) else {
            return
        }
        stopDemoPresentationLoop()
        if configuration.isCentralApp, prompt == .safari {
            presentSafariInstructionsAndLoop()
            return
        }
        presentInstructionsAfterShrinking(
            instructionDelay:
                OnboardingDemoLoopTiming.setupPromptSavedCardHoldDuration
        ) { [weak self] in
            guard let self, !self.hasSafariInstructions else { return }
            switch prompt {
            case .safari:
                self.safariReplica?.showSafariPrompt()
            case .actionButton:
                self.safariReplica?.showShortcutAndActionSetup()
            }
        }
    }

    /// A Safari lesson has finished saying its piece: the explainer page is
    /// clean, the video panel has arrived playing, or the price comparison is
    /// on the page. Every app's lesson ends the same way now — the shared
    /// popup comes up, frozen over the lesson for
    /// `OnboardingDemoLoopTiming.siblingLessonHoldDuration`, and then the
    /// lesson resets and replays underneath it, forever, until the user
    /// answers.
    ///
    /// Central Luna is the app whose surfaces take EVERY kind, so its Safari
    /// lesson is all three siblings' lessons in rank order rather than one:
    /// each ending hands over to the next, the pass that finishes the FIRST
    /// full cycle is what raises the popup, and the cycling goes on
    /// underneath it. A faceted app has exactly one lesson, so it IS the
    /// "last lesson of the first cycle" the moment it ends — the same check
    /// below fires on its very first ending.
    private func safariLessonDidReachSetupOffer(_ demonstrationApp: LunaApp) {
        let apps = configuration.safariDemonstrationApps
        guard !isFinishing,
              externalReturn == .none,
              didExpandSafari,
              activeDemoSource == .safari,
              appSwitcher == nil,
              // The lesson that just ended is the one on screen: a stale
              // callback from a replica the cycle has already left behind must
              // not advance it a second time.
              apps.indices.contains(safariCycleIndex),
              apps[safariCycleIndex] == demonstrationApp
        else { return }

        // The last lesson of the first cycle is where the ask comes up. Every
        // other ending — and every later cycle — is just the next beat.
        if !didRaiseSafariSetupPopover, safariCycleIndex == apps.count - 1 {
            presentSafariInstructionsAndLoop()
            return
        }
        scheduleSafariInstructionReplay()
    }

    /// Raises the shared setup popup over the running demonstration and keeps
    /// the lesson(s) cycling beneath it. The popup's own scrim is light,
    /// precisely because there is something behind it worth seeing: a
    /// faceted app's one lesson, or central Luna's three siblings, replay
    /// under it until the user answers.
    private func presentSafariInstructionsAndLoop() {
        didRaiseSafariSetupPopover = true
        isCyclingSafariLessons = true
        stopDemoPresentationLoop()
        // The journey moves on with the ask, exactly as a wave-driven prompt
        // moves it: from here the Safari return legs, the skip and the
        // completion handoff all read `.safariSetup`.
        _ = journeyStage.completedSave(from: .safari)
        transitionDemo(to: .fullScreen, source: .safari) { [weak self] in
            guard let self, !self.isFinishing else { return }
            self.showSafariSetupPopup()
            self.scheduleSafariInstructionReplay()
        }
    }

    /// The ONE ending every Safari lesson shares, in every app: raised the
    /// instant the lesson underneath — the explainer page's clean-up, the
    /// video panel's arrival, or the price comparison landing — reports
    /// `onDidReachSetupOffer`. Mounted directly on the window by THIS
    /// controller rather than by whichever `SafariReplicaViewController`
    /// happens to be running the lesson: central Luna's cycle swaps which
    /// sibling that is while the popup stays up, so the popup (and its scrim)
    /// need an owner that outlives every one of those swaps. This controller
    /// is that owner — it is what runs the swap in the first place.
    private func showSafariSetupPopup() {
        guard safariSetupPopup == nil else { return }
        guard let host = view.window ?? view else { return }

        // The scrim first, as its own view, so nothing about the popup's own
        // layout (its card, its border corona) can ever disturb it.
        let scrim = SafariSetupScrimView(frame: host.bounds)
        scrim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrim.backgroundColor = UIColor.black.withAlphaComponent(
            OnboardingSafariSetupPopupView.scrimAlpha)
        scrim.isUserInteractionEnabled = false
        scrim.alpha = 0
        safariSetupScrim = scrim
        host.addSubview(scrim)

        let popup = OnboardingSafariSetupPopupView(frame: host.bounds)
        popup.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        popup.onActivate = { [weak self] in self?.openSafariSetup() }
        popup.onSkip = { [weak self] in self?.skipSafariSetupAndContinue() }
        safariSetupPopup = popup
        host.addSubview(popup)
        popup.layoutIfNeeded()
        popup.present(fadingInAlongside: scrim)
    }

    /// Tears down the shared popup and its scrim TOGETHER, as one unit, and
    /// only when there is actually a popup up — the guard that keeps a
    /// cross-sibling swap (which never calls this) from being able to remove
    /// either half on its own.
    private func dismissSharedSafariSetupPopup(
        animated: Bool, completion: @escaping () -> Void
    ) {
        guard let popup = safariSetupPopup else {
            completion()
            return
        }
        let scrim = safariSetupScrim
        safariSetupPopup = nil
        safariSetupScrim = nil
        let changes = {
            popup.alpha = 0
            scrim?.alpha = 0
        }
        if animated, !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(
                withDuration: 0.28, delay: 0,
                options: [.curveEaseInOut],
                animations: changes,
                completion: { _ in
                    popup.removeFromSuperview()
                    scrim?.removeFromSuperview()
                    completion()
                })
        } else {
            changes()
            popup.removeFromSuperview()
            scrim?.removeFromSuperview()
            completion()
        }
    }

    /// After a hop to real Safari that brought back no extension evidence,
    /// the popup's buttons come back live and its plea starts breathing again.
    /// A no-op when this controller isn't the popup's owner — which, now that
    /// there is only ever one owner, is simply whenever no popup is up.
    private func restoreSharedSafariSetupPopupIfNeeded() {
        safariSetupPopup?.reactivate()
    }

    /// Puts the loop back after a hop to real Safari that brought no extension
    /// evidence home: the ask is still standing, so the lesson(s) behind it go
    /// on rather than leaving one frozen frame under a live popup.
    private func resumeSafariLessonLoopIfNeeded() {
        guard hasSafariInstructions,
              !isCyclingSafariLessons,
              !isFinishing,
              didExpandSafari,
              activeDemoSource == .safari
        else { return }
        isCyclingSafariLessons = true
        scheduleSafariInstructionReplay()
    }

    /// Whether the shared setup popup is up, or any mounted sibling replica is
    /// showing one of its OWN instruction overlays (the Safari prompt, the
    /// shortcut/Action Button ask, the external-open failure — asks that
    /// belong to a single lesson rather than to the cycle as a whole). The
    /// popup itself is this controller's own state now, not any replica's, so
    /// it no longer matters which replica is currently on screen.
    private var hasSafariInstructions: Bool {
        safariSetupPopup != nil
            || safariReplicas.values.contains { $0.hasInstructions }
    }

    /// Replays the next sibling lesson below the window-hosted popup. The
    /// first lesson is already the highest-ranked missing sibling; later
    /// passes wrap through Reader → Downloader → Price Tracker. A faceted app
    /// has exactly one sibling, so this just resets and replays it in place
    /// (see `cycleSafariInstructionLesson`'s own fallback).
    private func scheduleSafariInstructionReplay() {
        guard isCyclingSafariLessons, !isFinishing else { return }
        demoLoopGeneration += 1
        let generation = demoLoopGeneration
        DispatchQueue.main.asyncAfter(
            deadline: .now() + OnboardingAnimationClock.delay(
                OnboardingDemoLoopTiming.siblingLessonHoldDuration)
        ) { [weak self] in
            guard let self,
                  self.isCyclingSafariLessons,
                  !self.isFinishing,
                  generation == self.demoLoopGeneration
            else { return }
            self.cycleSafariInstructionLesson()
        }
    }

    private func cycleSafariInstructionLesson() {
        let apps = configuration.safariDemonstrationApps
        guard apps.count > 1,
              let outgoing = safariReplica,
              !isFinishing
        else {
            safariReplica?.resetDemonstration()
            safariReplica?.beginDemonstration()
            return
        }
        safariCycleIndex = (safariCycleIndex + 1) % apps.count
        guard let incoming = safariReplicas[apps[safariCycleIndex]] else { return }

        incoming.resetDemonstration()
        incoming.view.frame = view.bounds
        incoming.view.layer.cornerRadius = 0
        incoming.view.isHidden = false
        incoming.view.alpha = 0
        view.bringSubviewToFront(incoming.view)
        let duration: TimeInterval = UIAccessibility.isReduceMotionEnabled ? 0.2 : 0.28
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: [.curveEaseInOut, .beginFromCurrentState]
        ) {
            outgoing.view.alpha = 0
            incoming.view.alpha = 1
        } completion: { [weak self] _ in
            guard let self, self.isCyclingSafariLessons else { return }
            outgoing.view.isHidden = true
            outgoing.view.alpha = 0
            self.safariReplica = incoming
            self.setNeedsStatusBarAppearanceUpdate()
            incoming.prepareForPresentation()
            incoming.beginDemonstration()
        }
    }

    /// The Messages demonstration ended on its in-conversation setup pills
    /// (its save never crosses into the saved card, so there is no wave-driven
    /// commit): the demonstration loop is over and the pills own what's next.
    private func messagesDemonstrationDidPresentSetup() {
        guard journeyStage.completedSave(from: .messages) == .actionButton else {
            return
        }
        nextDemoSource = OnboardingDemoSource.messages.next
        stopDemoPresentationLoop()
    }

    /// The wave's final rendered frame is already the saved-card screen. Commit
    /// the matching live hierarchy before its overlay is removed, avoiding a
    /// flash or a second, disconnected geometry animation.
    private func commitWaveDrivenCardPresentation() {
        guard let source = sourceController(for: activeDemoSource) else { return }
        demoTransitionGeneration += 1
        isDemoGeometryTransitioning = false
        demoPresentation = .card
        applyDemoPresentation(.card, source: source)
        source.view.isHidden = true
        setNeedsStatusBarAppearanceUpdate()
    }

    /// Returns the production saved-card snapshot captured before the Safari
    /// replica was mounted. Avoiding a live hierarchy swap here keeps the press
    /// animation responsive even when the Safari WKWebView is active.
    private func makeSavedCardSnapshot() -> UIImage? {
        if let savedCardWaveSnapshot { return savedCardWaveSnapshot }
        let snapshot = captureSavedCardWaveSnapshot()
        savedCardWaveSnapshot = snapshot
        return snapshot
    }

    private func captureSavedCardWaveSnapshot() -> UIImage? {
        guard let savedRootViewController else { return nil }
        let carouselAlpha = carousel.view.alpha
        let rootAlpha = savedRootViewController.view.alpha
        // Preloading captures this while the intro card — and its corona —
        // are still on screen; neither belongs in the saved-card raster.
        let coronaIsHidden = introCorona?.isHidden ?? true
        var snapshot: UIImage?
        UIView.performWithoutAnimation {
            carousel.view.alpha = 0
            introCorona?.isHidden = true
            savedRootViewController.view.alpha = 1
            view.layoutIfNeeded()
            snapshot = renderSnapshot(of: view)
            carousel.view.alpha = carouselAlpha
            introCorona?.isHidden = coronaIsHidden
            savedRootViewController.view.alpha = rootAlpha
        }
        return snapshot
    }

    private func renderSnapshot(of targetView: UIView) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = OnboardingActionButtonTiming.waveRasterScale
        format.opaque = true
        return UIGraphicsImageRenderer(
            bounds: targetView.bounds,
            format: format
        ).image { rendererContext in
            targetView.layer.render(in: rendererContext.cgContext)
        }
    }

    private func presentInstructionsAfterShrinking(
        instructionDelay: TimeInterval = 0,
        _ presentInstructions: @escaping () -> Void
    ) {
        transitionDemo(to: .card, source: activeDemoSource) { [weak self] in
            guard let self, !self.isFinishing else { return }
            DispatchQueue.main.asyncAfter(
                deadline: .now() + OnboardingAnimationClock.delay(
                    instructionDelay)
            ) { [weak self] in
                guard let self, !self.isFinishing else { return }
                presentInstructions()
            }
        }
    }

    private func transitionDemo(
        to target: DemoPresentation,
        source sourceKind: OnboardingDemoSource,
        completion: @escaping () -> Void
    ) {
        guard let source = sourceController(for: sourceKind) else {
            completion()
            return
        }
        if demoPresentation == target,
           activeDemoSource == sourceKind,
           !isDemoGeometryTransitioning
        {
            applyDemoPresentation(target, source: source)
            completion()
            return
        }

        demoTransitionGeneration += 1
        let generation = demoTransitionGeneration
        isDemoGeometryTransitioning = true
        demoPresentation = target

        if target == .fullScreen {
            prepareSourceForPresentation(sourceKind)
            activeDemoSource = sourceKind
            source.view.isHidden = false
        }
        view.bringSubviewToFront(source.view)
        setNeedsStatusBarAppearanceUpdate()

        let duration: TimeInterval = UIAccessibility.isReduceMotionEnabled
            ? 0.20
            : OnboardingDemoLoopTiming.geometryDuration
        UIView.animate(
            withDuration: duration,
            delay: 0,
            usingSpringWithDamping: 0.96,
            initialSpringVelocity: 0,
            options: [.curveEaseInOut, .beginFromCurrentState]
        ) {
            self.applyDemoPresentation(target, source: source)
        } completion: { [weak self] _ in
            guard let self,
                  generation == self.demoTransitionGeneration
            else { return }
            self.isDemoGeometryTransitioning = false
            self.applyDemoPresentation(target, source: source)
            source.view.isHidden = target == .card
            self.setNeedsStatusBarAppearanceUpdate()
            completion()
        }
    }

    private func applyDemoPresentation(
        _ presentation: DemoPresentation,
        source: OnboardingSaveSourceViewController
    ) {
        switch presentation {
        case .fullScreen:
            source.view.frame = view.bounds
            // The card branch below forces layout; the full-screen branch must
            // too, or a source shown straight after mounting keeps its
            // preload-size internal layout until the next display pass.
            source.view.layoutIfNeeded()
            source.view.layer.cornerRadius = 0
            source.view.alpha = 1
            carousel.view.alpha = 0
            savedRootViewController?.view.alpha = 0
        case .card:
            view.layoutIfNeeded()
            savedRootViewController?.view.layoutIfNeeded()
            source.view.frame = savedCardFrame()
            source.view.layer.cornerRadius = CardSurfaceView.cornerRadius
            source.view.alpha = 0
            carousel.view.alpha = 0
            savedRootViewController?.view.alpha = 1
        }
        source.view.layer.cornerCurve = .continuous
        source.view.clipsToBounds = true
    }

    private func prepareSourceForPresentation(_ source: OnboardingDemoSource) {
        if source == .messages, let messages = messagesReplica {
            messages.updateURL(saveDemonstrationLink().urlString)
        }
        sourceController(for: source)?.prepareForPresentation()
        for otherSource in OnboardingDemoSource.allCases where otherSource != source {
            sourceController(for: otherSource)?.view.isHidden = true
        }
        guard let sourceView = sourceController(for: source)?.view else { return }
        sourceView.frame = savedCardFrame()
        sourceView.layer.cornerRadius = CardSurfaceView.cornerRadius
        sourceView.layer.cornerCurve = .continuous
        sourceView.clipsToBounds = true
        sourceView.alpha = 0
    }

    /// Takes both mock lessons off screen for good — the last thing any ending
    /// does before the screen changes hands.
    ///
    /// A demonstration is mounted full screen at the SIZE of the screen, so
    /// while it is attached it is the topmost thing in the window under the
    /// app-switcher hop. Every ending used to leave it there: the hop came down,
    /// or the window's root was swapped, or the replay was dismissed, with the
    /// mock still live underneath — and whichever of those needed a frame of its
    /// own showed the lesson flashing back over the card deck it had just handed
    /// off to. Nothing may outlive the hop that covered it.
    private func hideDemonstrationSources() {
        for kind in OnboardingDemoSource.allCases {
            guard let sourceView = sourceController(for: kind)?.view else { continue }
            sourceView.layer.removeAllAnimations()
            sourceView.isHidden = true
            sourceView.alpha = 0
        }
    }

    private func sourceController(
        for source: OnboardingDemoSource
    ) -> OnboardingSaveSourceViewController? {
        switch source {
        case .safari: return safariReplica
        case .messages: return messagesReplica
        }
    }

    private func dismissSafariInstructions() {
        for safari in safariReplicas.values {
            safari.dismissInstructions(animated: false) {}
        }
        dismissSharedSafariSetupPopup(animated: false) {}
    }

    #if DEBUG
    private func showDebugMessagesSource() {
        prepareSourceForPresentation(.messages)
        activeDemoSource = .messages
        nextDemoSource = .safari
        demoPresentation = .fullScreen
        guard let messages = messagesReplica else { return }
        messages.view.isHidden = false
        applyDemoPresentation(.fullScreen, source: messages)
        view.bringSubviewToFront(messages.view)
        setNeedsStatusBarAppearanceUpdate()
    }
    #endif

    private func startDemoPresentationLoop() {
        demoLoopGeneration += 1
        scheduleNextDemoPresentation(loopGeneration: demoLoopGeneration)
    }

    private func stopDemoPresentationLoop() {
        demoLoopGeneration += 1
    }

    /// Freezes the current demonstration at its model-layer state. Cancelling
    /// both geometry and save-wave work before an external hop prevents a
    /// foreground return from resuming stale callbacks over the next stage.
    private func pauseDemoPresentationPlayback() {
        stopDemoPresentationLoop()
        isCyclingSafariLessons = false
        appSwitcher?.removeFromSuperview()
        appSwitcher = nil
        for source in OnboardingDemoSource.allCases {
            sourceController(for: source)?.cancelSaveDemonstration()
        }

        // Only a demonstration that is actually on screen has a presentation to
        // freeze. Re-applying one from the intro card would stage the source
        // replica full screen (`.fullScreen` is the resting default) and blank
        // the carousel — the paste handoff, which pauses playback on its way
        // out, then flashed the mock browser over its own card eclipse.
        guard didExpandSafari,
              let source = sourceController(for: activeDemoSource)
        else { return }
        demoTransitionGeneration += 1
        isDemoGeometryTransitioning = false
        source.view.layer.removeAllAnimations()
        carousel.view.layer.removeAllAnimations()
        savedRootViewController?.view.layer.removeAllAnimations()
        applyDemoPresentation(demoPresentation, source: source)
        source.view.isHidden = demoPresentation == .card
    }

    private func scheduleNextDemoPresentation(loopGeneration: Int) {
        guard !isFinishing,
              loopGeneration == demoLoopGeneration,
              externalReturn == .none
        else { return }

        if demoPresentation == .fullScreen {
            scheduleActionButtonReplay(loopGeneration: loopGeneration)
            return
        }

        DispatchQueue.main.asyncAfter(
            deadline: .now() + OnboardingAnimationClock.delay(
                OnboardingDemoLoopTiming.savedCardHoldDuration)
        ) { [weak self] in
            guard let self,
                  !self.isFinishing,
                  loopGeneration == self.demoLoopGeneration,
                  self.externalReturn == .none
            else { return }
            let source = self.nextDemoSource
            self.transitionDemo(to: .fullScreen, source: source) { [weak self] in
                self?.scheduleActionButtonReplay(
                    loopGeneration: loopGeneration)
            }
        }
    }

    private func scheduleActionButtonReplay(loopGeneration: Int) {
        DispatchQueue.main.asyncAfter(
            deadline: .now() + OnboardingAnimationClock.delay(
                self.sourceController(
                    for: self.activeDemoSource)?.actionButtonReplayDelay
                    ?? OnboardingDemoLoopTiming.sourceHoldDuration)
        ) { [weak self] in
            guard let self,
                  !self.isFinishing,
                  loopGeneration == self.demoLoopGeneration,
                  self.externalReturn == .none,
                  self.demoPresentation == .fullScreen
            else { return }
            self.sourceController(
                for: self.activeDemoSource)?.replaySaveDemonstration()
        }
    }

    /// Opens the RUNNING app's own setup page (`site/README.md`'s canonical
    /// slugs — the site is generated from the same `Localizable.strings` the
    /// in-app popup reads, so the two never drift in wording).
    private func openSafariSetup() {
        guard externalReturn == .none else { return }
        pauseDemoPresentationPlayback()
        journeyStage = .safariSetup
        externalReturn = .safari
        // Stamped before the hop, not after a successful open: the extension's
        // in-page confirmation pairs this with its own first run, and both halves
        // have to be on disk before Safari is anywhere near the foreground.
        LunaSetupStatusStore.shared.recordSafariSetupTap(for: configuration.app)
        // The page IS the instructions now: the enabling steps that used to be
        // narrated in-app live on the RUNNING app's own hosted setup page, so
        // the hop lands the user on the very page that tells them what to tap
        // next. `configuration.app` (not the sibling the cycle happens to be
        // showing) matches `recordSafariSetupTap(for:)` above — in central Luna
        // the cycle walks through sibling lessons, but the extension being
        // enabled is always central Luna's own.
        guard let url = URL(
            string: "https://luna-site-bm6.pages.dev/setup/\(configuration.app.safariSetupPageSlug)")
        else {
            externalOpenFailed(.safari)
            return
        }
        UIApplication.shared.open(url, options: [:]) { [weak self] opened in
            guard !opened else { return }
            Task { @MainActor in self?.externalOpenFailed(.safari) }
        }
    }

    /// Skipping finishes this optional setup lesson. The user returns to the
    /// intro card, where the independent Shortcut lesson and paste action stay
    /// available.
    ///
    /// `.safariSetup` counts as well as `.safariDemonstration`: a hop to real
    /// Safari that brought back no extension evidence puts both of the page's
    /// actions back (`restoreSharedSafariSetupPopupIfNeeded`), and the skip
    /// has to be one of them. What the stage guard is really for is the OTHER
    /// lesson — plus the app-switcher hops, named outright rather than left to
    /// the stage.
    private func skipSafariSetupAndContinue() {
        guard externalReturn == .none,
              !isFinishing,
              appSwitcher == nil,
              journeyStage == .safariDemonstration
                  || journeyStage == .safariSetup
        else { return }
        journeyStage = .safariSetup
        completeSetupFlow(.safari, outcome: .skipped)
    }

    private func switcherSnapshot(
        of target: UIView,
        afterScreenUpdates: Bool
    ) -> UIImage {
        UIGraphicsImageRenderer(bounds: target.bounds).image { _ in
            target.drawHierarchy(
                in: target.bounds,
                afterScreenUpdates: afterScreenUpdates)
        }
    }

    private func installShortcut() {
        guard externalReturn == .none else { return }
        pauseDemoPresentationPlayback()
        externalReturn = .shortcut
        BundledShortcut.presentInstaller(
            from: self,
            sourceView: sourceController(for: activeDemoSource)?.view
                ?? safariReplica?.view
        ) { [weak self] opened in
            guard !opened else { return }
            Task { @MainActor in self?.externalOpenFailed(.shortcut) }
        }
    }

    private func openLunaAppStore() {
        guard let url = LunaCoreAppStoreLink.url else { return }
        UIApplication.shared.open(url)
    }

    private func openActionButtonSettings() {
        guard externalReturn == .none else { return }
        pauseDemoPresentationPlayback()
        externalReturn = .actionButton
        actionGuide.startPictureInPicture()
        SystemSettingsLink.openActionButton { [weak self] opened in
            guard !opened else { return }
            Task { @MainActor in self?.externalOpenFailed(.actionButton) }
        }
    }

    /// The one save lesson is the Action Button shortcut, so its run evidence is
    /// the only kind there is.
    private var saveSetupHasRun: Bool {
        LunaSetupStatusStore.shared.shortcutRunApplies(to: configuration.app)
    }

    private func externalOpenFailed(_ expectedReturn: ExternalReturn) {
        guard externalReturn == expectedReturn else { return }
        externalReturn = .none
        actionGuide.stopPictureInPicture()
        switch expectedReturn {
        case .none:
            break
        case .safari:
            safariReplica?.showExternalOpenFailure(destination: .safari)
        case .shortcut:
            safariReplica?.showExternalOpenFailure(destination: .shortcuts)
        case .actionButton:
            safariReplica?.showExternalOpenFailure(destination: .settings)
        }
    }

    private func returnedFromExternalApp() {
        let returned = externalReturn
        externalReturn = .none
        switch returned {
        case .none:
            contentStoreDidChange()
        case .safari:
            guard LunaSetupStatusStore.shared.safariRunApplies(
                to: configuration.app)
            else {
                // The shared popup is this controller's own state, so there is
                // exactly one place to restore it. Each replica's own video
                // lesson (if it has one) still resumes independently — it
                // isn't necessarily the one currently on screen either.
                restoreSharedSafariSetupPopupIfNeeded()
                for replica in safariReplicas.values {
                    replica.resumeVideoLessonAfterExternalReturn()
                }
                resumeSafariLessonLoopIfNeeded()
                return
            }
            completeSetupFlow(.safari, outcome: .completed)
        case .shortcut:
            // Importing the signed file is an external Shortcuts hop, but the
            // setup isn't complete until the hardware Action Button is
            // assigned: coming back from the install, the conversation now
            // walks through that with its Settings message. Only a recovery
            // overlay (an earlier open failure) still uses the overlay path.
            if messagesReplica?.isShowingSetupMessages == true,
               !hasSafariInstructions
            {
                messagesReplica?.revealSettingsSetupMessage()
            } else {
                safariReplica?.showShortcutAndActionSetup()
            }
        case .actionButton:
            actionGuide.stopPictureInPicture()
            safariReplica?.showWaitingForActionButton()
            setupStatusChanged()
        }
    }

    private func setupStatusChanged() {
        guard didExpandSafari,
              externalReturn == .none,
              activeDemoSource == .messages,
              saveSetupHasRun
        else { return }
        completeSetupFlow(.messages, outcome: .completed)
    }

    private func pasteArticleURL(_ value: String) {
        guard !isHandlingPaste, !isFinishing else { return }
        guard let url = URLUnwrapper.ingestURL(from: value) else {
            intro.setPasteError(OnboardingStrings.Intro.articleURLsOnly.value())
            return
        }
        isHandlingPaste = true
        intro.setPasteLoading()

        Task { [weak self] in
            let result = await IngestPipeline.processResolved(
                IngestInput(url: url, source: .paste))
            guard let self else { return }
            switch result.outcome {
            case .article(let content, _):
                let saved = await ReadingListIngestor.shared.saveNewWithContent(
                    urlString: result.url.absoluteString,
                    content: content,
                    source: .paste)
                await MainActor.run {
                    guard let saved,
                          let current = ReadingListStore.shared.item(
                            withID: saved.id),
                          current.state == .ready
                    else {
                        self.isHandlingPaste = false
                        self.intro.setPasteError(
                            OnboardingStrings.Intro.unableToLoadPage.value())
                        return
                    }
                    // The spinner answers before the deck arrives: the
                    // checkmark IS the save, and the eclipse follows it. The
                    // paste stays "in flight" across that beat — our own save
                    // reaches the store during it, and `contentStoreDidChange`
                    // would otherwise read it as an external one and finish
                    // onboarding without the transition.
                    self.intro.setPasteSucceeded { [weak self] in
                        guard let self else { return }
                        self.isHandlingPaste = false
                        self.completeOnboardingWithRealSave(animated: true)
                    }
                }
            case .failed, .needsArchive:
                await MainActor.run {
                    self.isHandlingPaste = false
                    self.intro.setPasteError(
                        OnboardingStrings.Intro.unableToLoadPage.value())
                }
            case .product, .social, .video, .document, .unsupported:
                await MainActor.run {
                    self.isHandlingPaste = false
                    self.intro.setPasteError(
                        OnboardingStrings.Intro.articleURLsOnly.value())
                }
            }
        }
    }

    private func contentStoreDidChange() {
        guard setupReplaySource == nil,
              !didExpandSafari,
              appSwitcher == nil,
              !isHandlingPaste,
              !isFinishing,
              savedCardPreviewImage == nil
        else { return }
        // Onboarding never writes, so every unseen id here is a save the user
        // really made — through a share/action extension or an App Intent.
        let current = completion.contentWatch.storedIdentifiers()
        guard !current.subtracting(knownContentIdentifiers).isEmpty else { return }
        completeOnboardingWithRealSave(animated: false)
    }

    private func completeOnboardingWithRealSave(animated: Bool) {
        guard !isFinishing else { return }
        isFinishing = true
        endSaveDemonstration()
        pauseDemoPresentationPlayback()
        // The same rule the app-switcher endings follow: no mock lesson may be
        // attached when the window changes hands.
        hideDemonstrationSources()
        replaceSavedRootWithCurrentContent()
        guard let window = view.window,
              let root = savedRootViewController
        else {
            isFinishing = false
            intro.setPasteError(OnboardingStrings.Intro.unableToLoadPage.value())
            return
        }

        onboardingStore.markCompleted()
        guard animated,
              let preview = captureCurrentSavedCardPreview()
        else {
            AppOnboardingCompletionTransition.run(in: window, to: root)
            return
        }

        savedCardPreviewImage = preview
        carousel.reloadData(centeringAt: 0)
        carousel.page(by: 1) { [weak self, weak window, weak root] in
            guard let self, let window, let root else { return }
            AppOnboardingCompletionTransition.run(in: window, to: root)
            self.savedCardPreviewImage = nil
        }
    }

    private func replaceSavedRootWithCurrentContent() {
        if let oldRoot = savedRootViewController {
            oldRoot.willMove(toParent: nil)
            oldRoot.view.removeFromSuperview()
            oldRoot.removeFromParent()
        }
        savedCardWaveSnapshot = nil
        let root = completion.makeCompletedRootViewController()
        savedRootViewController = root
        addChild(root)
        root.view.frame = view.bounds
        root.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        root.view.alpha = 0
        view.addSubview(root.view)
        root.didMove(toParent: self)
        root.view.layoutIfNeeded()
    }

    private func captureCurrentSavedCardPreview() -> UIImage? {
        guard let root = savedRootViewController else { return nil }
        root.view.layoutIfNeeded()
        let frame = savedCardFrame()
        guard frame.width > 0, frame.height > 0 else { return nil }
        let alpha = root.view.alpha
        root.view.alpha = 1
        defer { root.view.alpha = alpha }
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        return UIGraphicsImageRenderer(
            bounds: CGRect(origin: .zero, size: frame.size),
            format: format
        ).image { context in
            context.cgContext.translateBy(x: -frame.minX, y: -frame.minY)
            root.view.layer.render(in: context.cgContext)
        }
    }

    private func completeSetupFlow(
        _ source: OnboardingDemoSource,
        outcome: OnboardingSetupOutcome
    ) {
        guard didExpandSafari, !isFinishing else { return }
        switch source {
        case .safari:
            onboardingStore.markSafariSetupHandled(outcome: outcome)
        case .messages:
            // The lesson is answered either way, so its rehearsal has nothing
            // left to demonstrate.
            endSaveDemonstration()
            onboardingStore.markSaveSetupHandled(outcome: outcome)
        }
        if setupReplaySource != nil {
            if onboardingStore.hasFinishedSafariSetup,
               onboardingStore.hasFinishedSaveSetup {
                onboardingStore.markCompleted()
            }
            finishSetupReplayViaAppSwitcher()
            return
        }
        let state: OnboardingSetupButtonState =
            outcome == .completed ? .completed : .skipped
        switch source {
        case .safari:
            safariSetupState = state
        case .messages:
            shortcutSetupState = state
        }
        intro.setState(safari: safariSetupState, shortcut: shortcutSetupState)
        if safariSetupState.isFinished, shortcutSetupState.isFinished {
            finishOnboardingViaAppSwitcher()
        } else {
            returnToIntroViaAppSwitcher()
        }
    }

    private func finishSetupReplayViaAppSwitcher() {
        guard appSwitcher == nil,
              let source = sourceController(for: activeDemoSource),
              let setupReplayOriginSnapshot
        else { return }
        isFinishing = true
        endSaveDemonstration()
        pauseDemoPresentationPlayback()
        actionGuide.stopPictureInPicture()
        dismissSafariInstructions()

        let outgoing = switcherSnapshot(of: source.view, afterScreenUpdates: false)
        let switcher = OnboardingAppSwitcherView(
            frame: view.bounds,
            from: outgoing,
            to: setupReplayOriginSnapshot)
        appSwitcher = switcher
        view.addSubview(switcher)
        switcher.playForward { [weak self] in
            guard let self else { return }
            // The mock goes first and the dismissal second, both under the
            // hop's own last frame. Taking the hop down first uncovered the
            // full-screen lesson for however long the dismissal took.
            self.hideDemonstrationSources()
            self.dismiss(animated: false)
            switcher.removeFromSuperview()
            self.appSwitcher = nil
        }
    }

    private func returnToIntroViaAppSwitcher() {
        guard appSwitcher == nil,
              let source = sourceController(for: activeDemoSource)
        else { return }
        pauseDemoPresentationPlayback()
        actionGuide.stopPictureInPicture()
        dismissSafariInstructions()

        let outgoing = switcherSnapshot(
            of: source.view, afterScreenUpdates: false)
        let incoming = introScreenSnapshot()

        carousel.view.isHidden = false
        carousel.view.alpha = 1
        savedRootViewController?.view.alpha = 0
        keepsIntroCorona = true
        layoutIntroCorona()

        let switcher = OnboardingAppSwitcherView(
            frame: view.bounds, from: outgoing, to: incoming)
        appSwitcher = switcher
        view.addSubview(switcher)
        switcher.playForward { [weak self] in
            guard let self else { return }
            self.hideDemonstrationSources()
            self.carousel.view.isHidden = false
            self.carousel.view.alpha = 1
            self.savedRootViewController?.view.alpha = 0
            self.didExpandSafari = false
            self.demoPresentation = .fullScreen
            self.externalReturn = .none
            self.intro.setActionsEnabled(true)
            self.knownContentIdentifiers =
                self.completion.contentWatch.storedIdentifiers()
            switcher.removeFromSuperview()
            self.appSwitcher = nil
            self.setNeedsStatusBarAppearanceUpdate()
            UIAccessibility.post(
                notification: .layoutChanged,
                argument: self.intro.view)
        }
    }

    /// Both setup lessons are finished (skipped or completed): the same
    /// app-switcher hop other returns use lands on the real production root
    /// instead of looping back to the intro card, and onboarding ends for
    /// good. The hop's frozen final frame is pixel-identical to the root it
    /// snapshotted, so handing off to it as the window's actual root is
    /// seamless.
    private func finishOnboardingViaAppSwitcher() {
        guard appSwitcher == nil,
              let source = sourceController(for: activeDemoSource),
              let window = view.window,
              let root = savedRootViewController
        else { return }
        isFinishing = true
        endSaveDemonstration()
        pauseDemoPresentationPlayback()
        actionGuide.stopPictureInPicture()
        dismissSafariInstructions()

        root.view.alpha = 1
        root.view.layoutIfNeeded()
        let outgoing = switcherSnapshot(of: source.view, afterScreenUpdates: false)
        let incoming = switcherSnapshot(of: root.view, afterScreenUpdates: true)
        root.view.alpha = 0

        carousel.view.isHidden = true
        carousel.view.alpha = 0
        dismissIntroCorona()

        let switcher = OnboardingAppSwitcherView(
            frame: view.bounds, from: outgoing, to: incoming)
        appSwitcher = switcher
        view.addSubview(switcher)
        switcher.playForward { [weak self, weak window, weak root] in
            guard let self, let window, let root else { return }
            self.onboardingStore.markCompleted()
            // The handoff snapshots the window and reparents the root out of
            // this controller, and for that one frame the outgoing tree still
            // owns the screen. So the lesson comes down and the live root comes
            // up FIRST, under the hop's frozen last frame — which is a raster of
            // that same root, so nothing moves — and only then does the window
            // change hands and the hop come down.
            self.hideDemonstrationSources()
            root.view.alpha = 1
            root.view.layoutIfNeeded()
            AppOnboardingCompletionTransition.run(in: window, to: root)
            switcher.removeFromSuperview()
            self.appSwitcher = nil
        }
    }

    private func introScreenSnapshot() -> UIImage {
        let sourceStates = OnboardingDemoSource.allCases.compactMap { kind in
            sourceController(for: kind).map { ($0, $0.view.isHidden) }
        }
        let carouselWasHidden = carousel.view.isHidden
        let carouselAlpha = carousel.view.alpha
        let rootAlpha = savedRootViewController?.view.alpha
        var snapshot: UIImage!
        UIView.performWithoutAnimation {
            for (controller, _) in sourceStates {
                controller.view.isHidden = true
            }
            carousel.view.isHidden = false
            carousel.view.alpha = 1
            savedRootViewController?.view.alpha = 0
            keepsIntroCorona = true
            layoutIntroCorona()
            view.layoutIfNeeded()
            snapshot = switcherSnapshot(of: view, afterScreenUpdates: true)
            for (controller, wasHidden) in sourceStates {
                controller.view.isHidden = wasHidden
            }
            carousel.view.isHidden = carouselWasHidden
            carousel.view.alpha = carouselAlpha
            savedRootViewController?.view.alpha = rootAlpha ?? 0
        }
        return snapshot
    }

    private func mountCompletedRootIfNeeded() {
        guard savedRootViewController == nil else { return }
        let root = completion.makeCompletedRootViewController()
        savedRootViewController = root
        addChild(root)
        root.view.frame = view.bounds
        root.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        root.view.alpha = 0
        view.addSubview(root.view)
        root.didMove(toParent: self)
        root.view.layoutIfNeeded()
    }

    private func savedCardFrame() -> CGRect {
        guard let window = view.window,
              let target = savedRootViewController?.appLaunchTransitionTarget(),
              let frame = target.appLaunchTargetFrame(in: window)
        else {
            return CardDeckGeometry.cardFrame(
                inScreenSize: view.bounds.size,
                safeAreaInsets: view.safeAreaInsets)
        }
        return view.convert(frame, from: window)
    }

    private var previouslyConfiguredShortcutApp: LunaApp? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "-onboardingPreviousShortcutApp"),
           arguments.indices.contains(flag + 1)
        {
            let identifier = arguments[flag + 1].lowercased()
            if let requested = LunaApp.allCases.first(where: {
                $0.storageIdentifier == identifier && $0 != configuration.app
            }) {
                return requested
            }
        }
        #endif
        return LunaSetupStatusStore.shared.previouslyConfiguredShortcutApp(
            excluding: configuration.app)
    }

    #if DEBUG
    private static var requestedDebugStage: String? {
        let arguments = ProcessInfo.processInfo.arguments
        let flag = arguments.firstIndex(of: "-onboardingStage")
            ?? arguments.firstIndex(of: "-readerOnboardingStage")
        guard let flag,
              arguments.indices.contains(flag + 1)
        else { return nil }
        return arguments[flag + 1]
    }

    private static var requestedDebugPasteURL: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-onboardingPasteURL"),
              arguments.indices.contains(flag + 1)
        else { return nil }
        return arguments[flag + 1]
    }
    #endif

}

// MARK: - Card carousel

extension AppOnboardingViewController: CardCarouselDataSource {
    func numberOfCards(in carousel: CardCarouselViewController) -> Int {
        savedCardPreviewImage == nil ? 1 : 2
    }

    func carousel(
        _ carousel: CardCarouselViewController,
        contentControllerForCardAt index: Int
    ) -> CardContentViewController {
        if index == 1, let savedCardPreviewImage {
            return OnboardingSavedCardPreviewViewController(
                image: savedCardPreviewImage)
        }
        return intro
    }

    func carousel(
        _ carousel: CardCarouselViewController,
        loadThumbnailForCardAt index: Int,
        completion: @escaping (UIImage?) -> Void
    ) {
        completion(nil)
    }

    func carousel(
        _ carousel: CardCarouselViewController,
        titleForCardAt index: Int
    ) -> String? {
        index == 0
            ? LunaApp.luna.displayName
            : OnboardingStrings.Card.saved.value()
    }

    func carousel(
        _ carousel: CardCarouselViewController,
        loadSourceBadgeForCardAt index: Int,
        completion: @escaping (CarouselSourceBadge?) -> Void
    ) {
        completion(.symbol("moon.stars.fill"))
    }
}

private final class OnboardingSavedCardPreviewViewController:
    CardContentViewController
{
    private let image: UIImage

    init(image: UIImage) {
        self.image = image
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let imageView = UIImageView(image: image)
        imageView.frame = view.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.contentMode = .scaleToFill
        imageView.isAccessibilityElement = false
        view.addSubview(imageView)
        view.accessibilityLabel = OnboardingStrings.Card.savedArticle.value()
        view.isAccessibilityElement = true
    }
}

extension AppOnboardingViewController: CardCarouselDelegate {
    func carousel(
        _ carousel: CardCarouselViewController,
        navigationTargetDidChangeTo index: Int
    ) {}
}

extension AppOnboardingViewController: AppLaunchTransitionTarget {
    var keepsOnboardingSlowMotionAfterLaunch: Bool { true }

    /// The splash is pixel-identical to this screen (starfield, corona, blank
    /// black card), so the launch crossfade collapses to its quickest form.
    var prefersInstantLaunchReveal: Bool { true }

    func appLaunchTargetFrame(in window: UIWindow) -> CGRect? {
        view.layoutIfNeeded()
        guard let frame = carousel.restingCenteredCardFrame(in: view) else { return nil }
        return view.convert(frame, to: window)
    }

    /// Fired as the launch splash BEGINS its fade: the splash and this card
    /// are pixel-identical, so the first line's reveal reads as starting the
    /// instant the app is up instead of waiting out the crossfade.
    func appLaunchTransitionWillReveal() {
        startAfterLaunchTransition()
    }
}

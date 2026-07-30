//
//  AppOnboardingViewController.swift
//  Luna
//

import LunaDesignSystem
import LunaStorage
import UIKit

enum OnboardingDemoLoopTiming {
    static let geometryDuration: TimeInterval = 0.58
    static let savedCardHoldDuration: TimeInterval = 0.95
    /// Each completed source remains unobscured long enough to register before
    /// its corresponding setup instructions fade in.
    static let setupPromptSavedCardHoldDuration: TimeInterval = 1.35
    /// A brief clean source beat before the next save gesture begins.
    static let sourceHoldDuration: TimeInterval = 0.38
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

/// The first-run teaching sequence deliberately separates the two mock
/// sources with their corresponding setup work.
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

    mutating func completedSafariSetup() -> Bool {
        guard self == .safariSetup else { return false }
        self = .messagesDemonstration
        return true
    }
}

/// The shared guided first-run deck. It intentionally uses the production
/// CardCarousel rather than a look-alike. The intro card expands directly into
/// the Safari facsimile. Its save leads to Safari setup; returning from that
/// setup runs the Messages demonstration, whose save leads to shortcut and
/// Action Button setup. Each wave dissolves into the app's complete production
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
    private let carousel = CardCarouselViewController()
    private let intro: OnboardingIntroCardContentViewController
    private let safariGuide = SetupGuideVideo(guide: .safariExtension)
    private let actionGuide = SetupGuideVideo(guide: .actionButton)
    private var safariReplica: SafariReplicaViewController?
    private var messagesReplica: MessagesReplicaViewController?
    private var savedRootViewController: UIViewController?
    private var savedCardWaveSnapshot: UIImage?
    private var introCorona: EclipseCoronaView?
    private var keepsIntroCorona = true
    private var temporarySaveInstallResult: Bool?
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
    private var continuesToMessagesAfterSafariSave = false
    private var isFinishing = false
    private var foregroundObserver: NSObjectProtocol?
    private var setupObserver: NSObjectProtocol?
    #if DEBUG
    private var debugSafariStage: String?
    var savedRootViewControllerForTesting: UIViewController? {
        savedRootViewController
    }
    #endif

    init(
        configuration: OnboardingSurfaceConfiguration = .current,
        onboardingStore: AppOnboardingStore = .shared,
        completion: AppOnboardingCompletion
    ) {
        self.configuration = configuration
        self.onboardingStore = onboardingStore
        self.completion = completion
        self.intro = OnboardingIntroCardContentViewController(
            firstLine: configuration.firstLine,
            secondLine: configuration.secondLine,
            supportingText: configuration.supportingText)
        super.init(nibName: nil, bundle: nil)
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

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        // Only what the first frame needs. The guide players (AVFoundation)
        // and the demonstration preload run staged behind the intro reveal,
        // off the launch frame.
        configureCarousel()
        configureLifecycleObservers()
    }

    deinit {
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
        if let setupObserver { NotificationCenter.default.removeObserver(setupObserver) }
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
        style.edgeGap = 10
        style.cardFit = .aspectFromBottom
        style.cardTopOverflow = 48
        style.pagesOnInCardSwipes = false
        style.scrubberStyle = .miniCards
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

        intro.onContinue = { [weak self] in self?.showSafariCard() }
        intro.onFirstLineRevealed = { [weak self] in
            self?.firstIntroLineDidReveal()
        }
        carousel.reloadData(centeringAt: 0)
    }

    private func applyTopInset() {
        carousel.setTopInset(view.safeAreaInsets.top + 48)
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
            // This is a fresh UIKit reconstruction of the transition's peak
            // corona. It visually replaces the launch raster; the splash view
            // itself is still free to fade out and be discarded.
            let corona = AppLaunchTransition.makePeakCoronaView(
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
        for guide in [safariGuide, actionGuide] {
            let player = guide.playerView
            player.frame = CGRect(x: 1, y: 1, width: 2, height: 2)
            player.alpha = 0.01
            view.insertSubview(player, at: 0)
            guide.prepare()
        }
    }

    private func configureLifecycleObservers() {
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
    }

    /// Intro callback (and test seam): the first line has finished its
    /// reveal, so the heavy preparation can begin in the reading pause.
    func firstIntroLineDidReveal() {
        runPreloadStage(0)
    }

    /// Builds everything "Show me how" needs behind the intro copy: the setup
    /// guide players, the temporary save (disk + article parse), the complete
    /// production root, the wave's saved-card raster, and both source
    /// replicas (Safari's WKWebView loads its bundled page asynchronously).
    /// The button then only has to run the expansion animation.
    ///
    /// One stage per run-loop turn, deliberately: heavy work sharing a turn
    /// with a just-added CAAnimation delays that animation's first commit, and
    /// the render server then starts it partway through its duration — the
    /// intro reveal visibly "jumped ahead" when the whole preload ran in the
    /// reveal's own turn. A failed temporary-save install stops the chain
    /// silently; the button press retries via `preloadDemonstrationIfNeeded`
    /// and surfaces the failure alert.
    private func runPreloadStage(_ stage: Int) {
        guard !isDemonstrationPreloaded, !didExpandSafari else { return }
        switch stage {
        case 0:
            configureGuidesIfNeeded()
        case 1:
            guard prepareSavedRootIfNeeded() else { return }
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
        guard prepareSavedRootIfNeeded() else { return }
        isDemonstrationPreloaded = true
        savedCardWaveSnapshot = captureSavedCardWaveSnapshot()
        mountSourceReplicas()
    }

    private func mountSourceReplicas() {
        guard safariReplica == nil else { return }
        let safari = SafariReplicaViewController(configuration: configuration)
        safari.onSetUpSafari = { [weak self] in self?.openSafariSetup() }
        safari.onInstallShortcut = { [weak self] in self?.installShortcut() }
        safari.onSetActionButton = { [weak self] in self?.openActionButtonSettings() }
        safari.onSetUpLater = { [weak self] in self?.finishOnboarding() }
        safari.makeActionButtonDestinationSnapshot = { [weak self] in
            self?.makeSavedCardSnapshot()
        }
        safari.onActionButtonWaveFinished = { [weak self] in
            self?.actionButtonWaveDidFinish(from: .safari)
        }
        safariReplica = safari

        let messages = MessagesReplicaViewController(
            urlString: safari.sharedURLString)
        messages.makeActionButtonDestinationSnapshot = { [weak self] in
            self?.makeSavedCardSnapshot()
        }
        messages.onActionButtonWaveFinished = { [weak self] in
            self?.actionButtonWaveDidFinish(from: .messages)
        }
        messagesReplica = messages
        addChild(messages)
        messages.view.frame = view.bounds
        messages.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        messages.view.isHidden = true
        view.addSubview(messages.view)
        messages.didMove(toParent: self)

        // Mounted hidden at full size so the WKWebView spins up and lays out
        // its bundled page long before the expansion needs it.
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

    private func showSafariCard() {
        guard carousel.currentIndex == 0, !didExpandSafari else { return }
        expandSafariCard()
    }

    private func expandSafariCard() {
        guard !didExpandSafari,
              let card = carousel.cardView(at: 0)
        else { return }
        preloadDemonstrationIfNeeded()
        guard isDemonstrationPreloaded, let safari = safariReplica else {
            presentSavePreparationFailure()
            return
        }
        dismissIntroCorona()
        didExpandSafari = true

        let startFrame = card.convert(card.bounds, to: view)
        safari.view.frame = startFrame
        safari.view.layer.cornerRadius = CardSurfaceView.cornerRadius
        safari.view.alpha = 0
        safari.view.isHidden = false
        safari.view.layoutIfNeeded()
        view.bringSubviewToFront(safari.view)

        activeDemoSource = .safari
        nextDemoSource = .messages
        journeyStage = .safariDemonstration
        demoPresentation = .fullScreen
        let duration: TimeInterval = UIAccessibility.isReduceMotionEnabled
            ? 0.20
            : OnboardingDemoLoopTiming.geometryDuration
        UIView.animate(
            withDuration: duration,
            delay: 0,
            usingSpringWithDamping: 0.94,
            initialSpringVelocity: 0,
            options: [.curveEaseInOut, .beginFromCurrentState]
        ) {
            safari.view.frame = self.view.bounds
            safari.view.layer.cornerRadius = 0
            safari.view.alpha = 1
            self.carousel.view.alpha = 0
            self.savedRootViewController?.view.alpha = 0
        } completion: { _ in
            self.carousel.view.isHidden = true
            self.setNeedsStatusBarAppearanceUpdate()
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
            default:
                safari.beginDemonstration()
            }
            #else
            safari.beginDemonstration()
            #endif
        }
    }

    private func actionButtonWaveDidFinish(from source: OnboardingDemoSource) {
        guard source == activeDemoSource else { return }
        commitWaveDrivenCardPresentation()
        nextDemoSource = source.next

        if source == .safari, continuesToMessagesAfterSafariSave {
            continuesToMessagesAfterSafariSave = false
            DispatchQueue.main.asyncAfter(
                deadline: .now() + OnboardingAnimationClock.delay(
                    OnboardingDemoLoopTiming.savedCardHoldDuration)
            ) { [weak self] in
                guard let self, !self.isFinishing else { return }
                self.transitionDemo(to: .fullScreen, source: .messages) { [weak self] in
                    self?.startDemoPresentationLoop()
                }
            }
            return
        }

        guard let prompt = journeyStage.completedSave(from: source) else {
            return
        }
        stopDemoPresentationLoop()
        presentInstructionsAfterShrinking(
            instructionDelay:
                OnboardingDemoLoopTiming.setupPromptSavedCardHoldDuration
        ) { [weak self] in
            guard let self,
                  self.safariReplica?.hasInstructions != true
            else { return }
            switch prompt {
            case .safari:
                self.safariReplica?.showSafariPrompt()
            case .actionButton:
                self.safariReplica?.showShortcutAndActionSetup()
            }
        }
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
        savedCardWaveSnapshot
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
        if source == .messages,
           let urlString = safariReplica?.sharedURLString
        {
            messagesReplica?.updateURL(urlString)
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

    private func sourceController(
        for source: OnboardingDemoSource
    ) -> OnboardingSaveSourceViewController? {
        switch source {
        case .safari: return safariReplica
        case .messages: return messagesReplica
        }
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
        for source in OnboardingDemoSource.allCases {
            sourceController(for: source)?.cancelActionButtonSaveEffect()
        }

        guard let source = sourceController(for: activeDemoSource) else { return }
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
                for: self.activeDemoSource)?.replayActionButtonSaveEffect()
        }
    }

    private func openSafariSetup() {
        guard externalReturn == .none else { return }
        pauseDemoPresentationPlayback()
        journeyStage = .safariSetup
        externalReturn = .safari
        safariGuide.startPictureInPicture()
        guard let url = URL(string: "https://luna.app")
        else {
            externalOpenFailed(.safari)
            return
        }
        UIApplication.shared.open(url, options: [:]) { [weak self] opened in
            guard !opened else { return }
            Task { @MainActor in self?.externalOpenFailed(.safari) }
        }
    }

    private func installShortcut() {
        guard externalReturn == .none else { return }
        pauseDemoPresentationPlayback()
        externalReturn = .shortcut
        BundledShortcut.presentInstaller(
            from: self,
            sourceView: safariReplica?.view
        ) { [weak self] opened in
            guard !opened else { return }
            Task { @MainActor in self?.externalOpenFailed(.shortcut) }
        }
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

    private func externalOpenFailed(_ expectedReturn: ExternalReturn) {
        guard externalReturn == expectedReturn else { return }
        externalReturn = .none
        safariGuide.stopPictureInPicture()
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
            break
        case .safari:
            safariGuide.stopPictureInPicture()
            guard LunaSetupStatusStore.shared.safariHasRun(
                isCentral: configuration.isCentralApp)
            else {
                safariReplica?.restoreInPageSafariSetup()
                return
            }
            guard journeyStage.completedSafariSetup() else {
                return
            }
            continuesToMessagesAfterSafariSave = true
            safariReplica?.playURLBarZoomAndSave()
        case .shortcut:
            // Importing the signed file is an external Shortcuts hop, but the
            // setup isn't complete until the hardware Action Button is assigned.
            safariReplica?.showShortcutAndActionSetup()
        case .actionButton:
            actionGuide.stopPictureInPicture()
            safariReplica?.showWaitingForActionButton()
            setupStatusChanged()
        }
    }

    private func setupStatusChanged() {
        guard didExpandSafari,
              externalReturn == .none,
              LunaSetupStatusStore.shared.shortcutHasRun(
                isCentral: configuration.isCentralApp)
        else { return }
        finishOnboarding()
    }

    private func finishOnboarding() {
        guard !isFinishing else { return }
        isFinishing = true
        pauseDemoPresentationPlayback()
        safariGuide.stopPictureInPicture()
        actionGuide.stopPictureInPicture()
        safariReplica?.dismissInstructions(animated: true) { [weak self] in
            self?.settleOnSavedCardAndFinish()
        }
    }

    private func settleOnSavedCardAndFinish() {
        if demoPresentation == .card, !isDemoGeometryTransitioning {
            commitBundledSaveAndTransition()
            return
        }
        transitionDemo(to: .card, source: activeDemoSource) { [weak self] in
            self?.commitBundledSaveAndTransition()
        }
    }

    private func commitBundledSaveAndTransition() {
        guard let window = view.window else {
            presentCompletionRetry()
            return
        }
        guard temporarySaveInstallResult == true else {
            presentCompletionRetry()
            return
        }
        onboardingStore.markCompleted()
        AppOnboardingCompletionTransition.run(
            in: window,
            to: completion.makeCompletedRootViewController())
    }

    private func prepareSavedRootIfNeeded() -> Bool {
        if let temporarySaveInstallResult {
            return temporarySaveInstallResult
        }

        let installed = completion.temporarySave.install()
        temporarySaveInstallResult = installed
        guard installed else { return false }

        let root = completion.makeCompletedRootViewController()
        savedRootViewController = root
        addChild(root)
        root.view.frame = view.bounds
        root.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        root.view.alpha = 0
        view.addSubview(root.view)
        root.didMove(toParent: self)
        root.view.layoutIfNeeded()
        return true
    }

    private func savedCardFrame() -> CGRect {
        guard let window = view.window,
              let target = savedRootViewController?.appLaunchTransitionTarget(),
              let frame = target.appLaunchTargetFrame(in: window)
        else {
            return AppLaunchGeometry.fallbackRootCardFrame(
                in: view.bounds,
                safeAreaInsets: view.safeAreaInsets)
        }
        return view.convert(frame, from: window)
    }

    private func presentSavePreparationFailure() {
        let alert = UIAlertController(
            title: "Couldn’t create the offline example",
            message: "Try the onboarding demonstration again.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(
            title: "Try again",
            style: .default,
            handler: { [weak self] _ in
                self?.completion.temporarySave.cleanup()
                self?.temporarySaveInstallResult = nil
                self?.showSafariCard()
            }))
        present(alert, animated: true)
    }

    private func presentCompletionRetry() {
        isFinishing = false
        safariReplica?.showSaveFailure { [weak self] in
            self?.finishOnboarding()
        }
        startDemoPresentationLoop()
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
    #endif

}

// MARK: - Card carousel

extension AppOnboardingViewController: CardCarouselDataSource {
    func numberOfCards(in carousel: CardCarouselViewController) -> Int {
        1
    }

    func carousel(
        _ carousel: CardCarouselViewController,
        contentControllerForCardAt index: Int
    ) -> CardContentViewController {
        intro
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
        "Luna"
    }

    func carousel(
        _ carousel: CardCarouselViewController,
        loadSourceBadgeForCardAt index: Int,
        completion: @escaping (CarouselSourceBadge?) -> Void
    ) {
        completion(.symbol("moon.stars.fill"))
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

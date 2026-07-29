//
//  AppOnboardingViewController.swift
//  Luna
//

import LunaDesignSystem
import LunaStorage
import UIKit

enum OnboardingSafariCardTiming {
    static let geometryDuration: TimeInterval = 0.58
    static let cardHoldDuration: TimeInterval = 0.95
    /// The first successful save remains completely unobscured long enough to
    /// register before setup instructions fade over it.
    static let firstSavedCardHoldDuration: TimeInterval = 1.35
    /// A brief clean Safari beat before the next save gesture begins.
    static let browserHoldDuration: TimeInterval = 0.38
}

/// The shared guided first-run deck. It intentionally uses the production
/// CardCarousel rather than a look-alike. The intro card expands directly into
/// the Safari facsimile; after each save wave, Safari dissolves into the app's
/// complete production root, including its ordinary card chrome and carousel.
final class AppOnboardingViewController: UIViewController {
    private enum ExternalReturn {
        case none
        case safari
        case shortcut
        case actionButton
    }

    private enum SafariPresentation {
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
    private var savedRootViewController: UIViewController?
    private var savedCardWaveSnapshot: UIImage?
    private var temporarySaveInstallResult: Bool?
    private var externalReturn = ExternalReturn.none
    private var didExpandSafari = false
    private var safariPresentation = SafariPresentation.fullScreen
    private var safariTransitionGeneration = 0
    private var safariLoopGeneration = 0
    private var isSafariGeometryTransitioning = false
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
        safariPresentation == .fullScreen
            ? safariReplica
            : savedRootViewController
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureCarousel()
        configureGuides()
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
        carousel.reloadData(centeringAt: 0)
    }

    private func applyTopInset() {
        carousel.setTopInset(view.safeAreaInsets.top + 48)
    }

    private func configureGuides() {
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

    private func showSafariCard() {
        guard carousel.currentIndex == 0, !didExpandSafari else { return }
        expandSafariCard()
    }

    private func expandSafariCard() {
        guard !didExpandSafari,
              let card = carousel.cardView(at: 0)
        else { return }
        guard prepareSavedRootIfNeeded() else {
            presentSavePreparationFailure()
            return
        }
        savedCardWaveSnapshot = captureSavedCardWaveSnapshot()
        didExpandSafari = true

        let safari = SafariReplicaViewController(configuration: configuration)
        safari.onSetUpSafari = { [weak self] in self?.openSafariSetup() }
        safari.onInstallShortcut = { [weak self] in self?.installShortcut() }
        safari.onSetActionButton = { [weak self] in self?.openActionButtonSettings() }
        safari.onSetUpLater = { [weak self] in self?.finishOnboarding() }
        safari.makeActionButtonDestinationSnapshot = { [weak self] in
            self?.makeSavedCardSnapshot()
        }
        safari.onActionButtonWaveFinished = { [weak self] in
            self?.actionButtonWaveDidFinish()
        }
        safariReplica = safari

        addChild(safari)
        let startFrame = card.convert(card.bounds, to: view)
        safari.view.frame = startFrame
        safari.view.layer.cornerRadius = CardSurfaceView.cornerRadius
        safari.view.layer.cornerCurve = .continuous
        safari.view.clipsToBounds = true
        safari.view.alpha = 0
        view.addSubview(safari.view)
        safari.didMove(toParent: self)
        safari.view.layoutIfNeeded()
        view.bringSubviewToFront(safari.view)

        safariPresentation = .fullScreen
        let duration: TimeInterval = UIAccessibility.isReduceMotionEnabled
            ? 0.20
            : OnboardingSafariCardTiming.geometryDuration
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
                self.presentInstructionsAfterShrinking {
                    safari.showSafariPrompt()
                }
            case "setup":
                self.presentInstructionsAfterShrinking {
                    safari.showShortcutAndActionSetup()
                }
            case "waiting":
                self.presentInstructionsAfterShrinking {
                    safari.showWaitingForActionButton()
                }
            default:
                safari.beginDemonstration()
            }
            #else
            safari.beginDemonstration()
            #endif
        }
    }

    private func actionButtonWaveDidFinish() {
        commitWaveDrivenCardPresentation()
        let isFirstSave = safariReplica?.hasInstructions != true
        presentInstructionsAfterShrinking(
            instructionDelay: isFirstSave
                ? OnboardingSafariCardTiming.firstSavedCardHoldDuration
                : 0
        ) { [weak self] in
            guard let self else { return }
            if self.safariReplica?.hasInstructions != true {
                self.safariReplica?.showSafariPrompt()
            }
        }
    }

    /// The wave's final rendered frame is already the saved-card screen. Commit
    /// the matching live hierarchy before its overlay is removed, avoiding a
    /// flash or a second, disconnected geometry animation.
    private func commitWaveDrivenCardPresentation() {
        guard let safari = safariReplica else { return }
        safariTransitionGeneration += 1
        isSafariGeometryTransitioning = false
        safariPresentation = .card
        applySafariPresentation(.card, safari: safari)
        safari.view.isHidden = true
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
        var snapshot: UIImage?
        UIView.performWithoutAnimation {
            carousel.view.alpha = 0
            savedRootViewController.view.alpha = 1
            view.layoutIfNeeded()
            snapshot = renderSnapshot(of: view)
            carousel.view.alpha = carouselAlpha
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
        transitionSafari(to: .card) { [weak self] in
            guard let self, !self.isFinishing else { return }
            DispatchQueue.main.asyncAfter(
                deadline: .now() + OnboardingAnimationClock.delay(
                    instructionDelay)
            ) { [weak self] in
                guard let self, !self.isFinishing else { return }
                presentInstructions()
                self.startSafariPresentationLoop()
            }
        }
    }

    private func transitionSafari(
        to target: SafariPresentation,
        completion: @escaping () -> Void
    ) {
        guard let safari = safariReplica else {
            completion()
            return
        }
        if safariPresentation == target, !isSafariGeometryTransitioning {
            applySafariPresentation(target, safari: safari)
            completion()
            return
        }

        safariTransitionGeneration += 1
        let generation = safariTransitionGeneration
        isSafariGeometryTransitioning = true
        safariPresentation = target

        if target == .fullScreen {
            safari.view.isHidden = false
        }
        view.bringSubviewToFront(safari.view)
        setNeedsStatusBarAppearanceUpdate()

        let duration: TimeInterval = UIAccessibility.isReduceMotionEnabled
            ? 0.20
            : OnboardingSafariCardTiming.geometryDuration
        UIView.animate(
            withDuration: duration,
            delay: 0,
            usingSpringWithDamping: 0.96,
            initialSpringVelocity: 0,
            options: [.curveEaseInOut, .beginFromCurrentState]
        ) {
            self.applySafariPresentation(target, safari: safari)
        } completion: { [weak self] _ in
            guard let self,
                  generation == self.safariTransitionGeneration
            else { return }
            self.isSafariGeometryTransitioning = false
            self.applySafariPresentation(target, safari: safari)
            safari.view.isHidden = target == .card
            self.setNeedsStatusBarAppearanceUpdate()
            completion()
        }
    }

    private func applySafariPresentation(
        _ presentation: SafariPresentation,
        safari: SafariReplicaViewController
    ) {
        switch presentation {
        case .fullScreen:
            safari.view.frame = view.bounds
            safari.view.layer.cornerRadius = 0
            safari.view.alpha = 1
            carousel.view.alpha = 0
            savedRootViewController?.view.alpha = 0
        case .card:
            view.layoutIfNeeded()
            savedRootViewController?.view.layoutIfNeeded()
            safari.view.frame = savedCardFrame()
            safari.view.layer.cornerRadius = CardSurfaceView.cornerRadius
            safari.view.alpha = 0
            carousel.view.alpha = 0
            savedRootViewController?.view.alpha = 1
        }
        safari.view.layer.cornerCurve = .continuous
        safari.view.clipsToBounds = true
    }

    private func startSafariPresentationLoop() {
        safariLoopGeneration += 1
        scheduleNextSafariPresentation(loopGeneration: safariLoopGeneration)
    }

    private func stopSafariPresentationLoop() {
        safariLoopGeneration += 1
    }

    private func scheduleNextSafariPresentation(loopGeneration: Int) {
        guard !isFinishing,
              loopGeneration == safariLoopGeneration,
              externalReturn == .none
        else { return }

        if safariPresentation == .fullScreen {
            scheduleActionButtonReplay(loopGeneration: loopGeneration)
            return
        }

        DispatchQueue.main.asyncAfter(
            deadline: .now() + OnboardingAnimationClock.delay(
                OnboardingSafariCardTiming.cardHoldDuration)
        ) { [weak self] in
            guard let self,
                  !self.isFinishing,
                  loopGeneration == self.safariLoopGeneration,
                  self.externalReturn == .none
            else { return }
            self.transitionSafari(to: .fullScreen) { [weak self] in
                self?.scheduleActionButtonReplay(
                    loopGeneration: loopGeneration)
            }
        }
    }

    private func scheduleActionButtonReplay(loopGeneration: Int) {
        DispatchQueue.main.asyncAfter(
            deadline: .now() + OnboardingAnimationClock.delay(
                OnboardingSafariCardTiming.browserHoldDuration)
        ) { [weak self] in
            guard let self,
                  !self.isFinishing,
                  loopGeneration == self.safariLoopGeneration,
                  self.externalReturn == .none,
                  self.safariPresentation == .fullScreen
            else { return }
            // The wave completion drives the saved-card transition and schedules
            // the next cycle. Nothing alternates geometry on its own anymore.
            self.safariReplica?.replayActionButtonSaveEffect()
        }
    }

    private func openSafariSetup() {
        guard externalReturn == .none else { return }
        stopSafariPresentationLoop()
        externalReturn = .safari
        safariGuide.startPictureInPicture()
        if let url = URL(string: "https://en.wikipedia.org/wiki/Wikipedia") {
            UIApplication.shared.open(url)
        }
    }

    private func installShortcut() {
        guard externalReturn == .none else { return }
        stopSafariPresentationLoop()
        externalReturn = .shortcut
        BundledShortcut.presentInstaller(from: self, sourceView: safariReplica?.view)
    }

    private func openActionButtonSettings() {
        guard externalReturn == .none else { return }
        stopSafariPresentationLoop()
        externalReturn = .actionButton
        actionGuide.startPictureInPicture()
        SystemSettingsLink.openActionButton()
    }

    private func returnedFromExternalApp() {
        let returned = externalReturn
        externalReturn = .none
        switch returned {
        case .none:
            break
        case .safari:
            safariGuide.stopPictureInPicture()
            safariReplica?.showShortcutAndActionSetup()
            startSafariPresentationLoop()
        case .shortcut:
            // Importing the signed file is an external Shortcuts hop, but the
            // setup isn't complete until the hardware Action Button is assigned.
            safariReplica?.showShortcutAndActionSetup()
            startSafariPresentationLoop()
        case .actionButton:
            actionGuide.stopPictureInPicture()
            safariReplica?.showWaitingForActionButton()
            setupStatusChanged()
            if !isFinishing {
                startSafariPresentationLoop()
            }
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
        stopSafariPresentationLoop()
        safariGuide.stopPictureInPicture()
        actionGuide.stopPictureInPicture()
        safariReplica?.dismissInstructions(animated: true) { [weak self] in
            self?.settleOnSavedCardAndFinish()
        }
    }

    private func settleOnSavedCardAndFinish() {
        if safariPresentation == .card, !isSafariGeometryTransitioning {
            commitBundledSaveAndTransition()
            return
        }
        transitionSafari(to: .card) { [weak self] in
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
        startSafariPresentationLoop()
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

    func appLaunchTargetFrame(in window: UIWindow) -> CGRect? {
        view.layoutIfNeeded()
        guard let frame = carousel.restingCenteredCardFrame(in: view) else { return nil }
        return view.convert(frame, to: window)
    }

    func appLaunchTransitionDidFinish() {
        startAfterLaunchTransition()
    }
}

//
//  AppOnboardingViewController.swift
//  Luna
//

import LunaDesignSystem
import LunaStorage
import UIKit

/// The shared guided first-run deck. It intentionally uses the production
/// CardCarousel rather than a look-alike: peeks, glass rim, and the transition
/// from the intro card to Safari are the same views and CardEclipseTransition
/// used by the app's normal saved cards.
final class AppOnboardingViewController: UIViewController {
    private enum ExternalReturn {
        case none
        case safari
        case shortcut
        case actionButton
    }

    private let configuration: OnboardingSurfaceConfiguration
    private let onboardingStore: AppOnboardingStore
    private let completion: AppOnboardingCompletion
    private let carousel = CardCarouselViewController()
    private let intro: OnboardingIntroCardContentViewController
    private let safariSeed = OnboardingBrowserSeedCardContentViewController()
    private let safariGuide = SetupGuideVideo(guide: .safariExtension)
    private let actionGuide = SetupGuideVideo(guide: .actionButton)
    private var safariReplica: SafariReplicaViewController?
    private var externalReturn = ExternalReturn.none
    private var didExpandSafari = false
    private var isFinishing = false
    private var foregroundObserver: NSObjectProtocol?
    private var setupObserver: NSObjectProtocol?
    #if DEBUG
    private var debugSafariStage: String?
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
            secondLine: configuration.secondLine)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var childForStatusBarStyle: UIViewController? {
        safariReplica
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
        carousel.page(by: 1)
    }

    private func expandSafariCard() {
        guard !didExpandSafari,
              let card = carousel.cardView(at: 1)
        else { return }
        didExpandSafari = true

        let safari = SafariReplicaViewController(configuration: configuration)
        safari.onSetUpSafari = { [weak self] in self?.openSafariSetup() }
        safari.onInstallShortcut = { [weak self] in self?.installShortcut() }
        safari.onSetActionButton = { [weak self] in self?.openActionButtonSettings() }
        safari.onSetUpLater = { [weak self] in self?.finishOnboarding() }
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

        let duration: TimeInterval = UIAccessibility.isReduceMotionEnabled ? 0.2 : 0.52
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
        } completion: { _ in
            self.carousel.view.isHidden = true
            self.setNeedsStatusBarAppearanceUpdate()
            #if DEBUG
            switch self.debugSafariStage {
            case "prompt":
                safari.showSafariPrompt()
            case "setup":
                safari.showShortcutAndActionSetup()
            case "waiting":
                safari.showWaitingForActionButton()
            default:
                safari.beginDemonstration()
            }
            #else
            safari.beginDemonstration()
            #endif
        }
    }

    private func openSafariSetup() {
        guard externalReturn == .none else { return }
        externalReturn = .safari
        safariGuide.startPictureInPicture()
        if let url = URL(string: "https://en.wikipedia.org/wiki/Wikipedia") {
            UIApplication.shared.open(url)
        }
    }

    private func installShortcut() {
        guard externalReturn == .none else { return }
        externalReturn = .shortcut
        BundledShortcut.presentInstaller(from: self, sourceView: safariReplica?.view)
    }

    private func openActionButtonSettings() {
        guard externalReturn == .none else { return }
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
        safariGuide.stopPictureInPicture()
        actionGuide.stopPictureInPicture()
        safariReplica?.dismissInstructions(animated: true) { [weak self] in
            self?.commitBundledSaveAndTransition()
        }
    }

    private func commitBundledSaveAndTransition() {
        guard let window = view.window else {
            presentCompletionRetry()
            return
        }
        guard completion.temporarySave.install() else {
            presentCompletionRetry()
            return
        }
        onboardingStore.markCompleted()
        AppOnboardingCompletionTransition.run(
            in: window,
            to: completion.makeCompletedRootViewController())
    }

    private func presentCompletionRetry() {
        isFinishing = false
        safariReplica?.showSaveFailure { [weak self] in
            self?.finishOnboarding()
        }
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
    func numberOfCards(in carousel: CardCarouselViewController) -> Int { 2 }

    func carousel(
        _ carousel: CardCarouselViewController,
        contentControllerForCardAt index: Int
    ) -> CardContentViewController {
        index == 0 ? intro : safariSeed
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
        index == 0 ? "Luna" : configuration.seedTitle
    }

    func carousel(
        _ carousel: CardCarouselViewController,
        loadSourceBadgeForCardAt index: Int,
        completion: @escaping (CarouselSourceBadge?) -> Void
    ) {
        completion(index == 1
            ? .symbol(configuration.seedSymbol)
            : .symbol("moon.stars.fill"))
    }
}

extension AppOnboardingViewController: CardCarouselDelegate {
    func carousel(
        _ carousel: CardCarouselViewController,
        navigationTargetDidChangeTo index: Int
    ) {}

    func carousel(_ carousel: CardCarouselViewController, didCenterCardAt index: Int) {
        guard index == 1, !didExpandSafari else { return }
        // didCenter fires at zenith. Let CardEclipseTransition finish its egress
        // before the now-centered card takes over the whole display.
        DispatchQueue.main.asyncAfter(
            deadline: .now() + OnboardingAnimationClock.delay(
                CardEclipseTransition.duration * 0.38)
        ) { [weak self] in
            self?.expandSafariCard()
        }
    }
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

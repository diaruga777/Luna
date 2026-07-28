//
//  ReaderOnboardingViewController.swift
//  Luna
//

import LunaDesignSystem
import LunaStorage
import UIKit

/// Reader's guided first-run deck. It intentionally uses the production
/// CardCarousel rather than a look-alike: peeks, glass rim, and the transition
/// from the intro card to Safari are the same views and CardEclipseTransition
/// used by saved articles.
final class ReaderOnboardingViewController: UIViewController {
    private enum ExternalReturn {
        case none
        case safari
        case shortcut
        case actionButton
    }

    private let carousel = CardCarouselViewController()
    private let intro = ReaderOnboardingIntroCardContentViewController()
    private let safariSeed = ReaderOnboardingSafariSeedCardContentViewController()
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

    func readerLaunchTransitionDidFinish() {
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

        let safari = SafariReplicaViewController()
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
              LunaSetupStatusStore.shared.shortcutHasRun(isCentral: false)
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
        _ = ReaderBundledLunaArticle.install()
        ReaderOnboardingStore.shared.markCompleted()
        guard let window = view.window,
              let root = ReaderOnboardingWiring.makeCompletedRootViewController?()
        else { return }
        ReaderOnboardingCompletionTransition.run(in: window, to: root)
    }

    #if DEBUG
    private static var requestedDebugStage: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-readerOnboardingStage"),
              arguments.indices.contains(flag + 1)
        else { return nil }
        return arguments[flag + 1]
    }
    #endif
}

// MARK: - Card carousel

extension ReaderOnboardingViewController: CardCarouselDataSource {
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
        index == 0 ? "Read more" : "Luna"
    }

    func carousel(
        _ carousel: CardCarouselViewController,
        loadSourceBadgeForCardAt index: Int,
        completion: @escaping (CarouselSourceBadge?) -> Void
    ) {
        completion(index == 1 ? .symbol("safari.fill") : .symbol("book.fill"))
    }
}

extension ReaderOnboardingViewController: CardCarouselDelegate {
    func carousel(
        _ carousel: CardCarouselViewController,
        navigationTargetDidChangeTo index: Int
    ) {}

    func carousel(_ carousel: CardCarouselViewController, didCenterCardAt index: Int) {
        guard index == 1, !didExpandSafari else { return }
        // didCenter fires at zenith. Let CardEclipseTransition finish its egress
        // before the now-centered card takes over the whole display.
        DispatchQueue.main.asyncAfter(
            deadline: .now() + CardEclipseTransition.duration * 0.38
        ) { [weak self] in
            self?.expandSafariCard()
        }
    }
}

extension ReaderOnboardingViewController: ReaderLaunchTransitionTarget {
    func readerLaunchTargetFrame(in window: UIWindow) -> CGRect? {
        view.layoutIfNeeded()
        guard let frame = carousel.restingCenteredCardFrame(in: view) else { return nil }
        return view.convert(frame, to: window)
    }
}

// MARK: - Intro card

private final class ReaderOnboardingIntroCardContentViewController: CardContentViewController {
    var onContinue: (() -> Void)?

    private let firstLine = MoonRevealLineView(text: "You wish you read more.")
    private let secondLine = MoonRevealLineView(text: "Let’s make that happen.")
    private let button = UIButton(type: .system)
    private var didStart = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.addSubview(firstLine)
        view.addSubview(secondLine)

        button.configuration = GlassStyle.actionButtonConfiguration(
            title: "Show me how",
            symbol: "arrow.right",
            prominent: true)
        button.configuration?.imagePlacement = .trailing
        button.accessibilityLabel = "Show me how"
        button.alpha = 0
        button.isUserInteractionEnabled = false
        button.addTarget(self, action: #selector(continueTapped), for: .touchUpInside)
        view.addSubview(button)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let inset: CGFloat = 24
        let lineHeight: CGFloat = 44
        let gap: CGFloat = 3
        let groupHeight = lineHeight * 2 + gap
        let centerY = view.bounds.height * 2 / 3
        firstLine.frame = CGRect(
            x: inset, y: centerY - groupHeight / 2,
            width: view.bounds.width - inset * 2, height: lineHeight)
        secondLine.frame = CGRect(
            x: inset, y: firstLine.frame.maxY + gap,
            width: view.bounds.width - inset * 2, height: lineHeight)
        let buttonSize = button.sizeThatFits(CGSize(
            width: view.bounds.width - 40, height: 60))
        button.frame = CGRect(
            x: (view.bounds.width - max(170, buttonSize.width)) / 2,
            y: view.bounds.height - max(54, buttonSize.height) - 24,
            width: max(170, buttonSize.width),
            height: max(54, buttonSize.height))
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        firstLine.reveal(duration: 0.70) { [weak self] in
            guard let self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) {
                self.secondLine.reveal(duration: 0.82) { [weak self] in
                    guard let self else { return }
                    UIView.animate(
                        withDuration: 0.38,
                        delay: 0.16,
                        options: [.curveEaseOut]
                    ) {
                        self.button.alpha = 1
                    } completion: { _ in
                        self.button.isUserInteractionEnabled = true
                        UIAccessibility.post(
                            notification: .layoutChanged,
                            argument: self.button)
                    }
                }
            }
        }
    }

    @objc private func continueTapped() {
        button.isUserInteractionEnabled = false
        onContinue?()
    }
}

private final class ReaderOnboardingSafariSeedCardContentViewController: CardContentViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
    }
}

/// A black circular occluder moves down over a line. The revealed pixels pass
/// through a narrow white bloom layer before resolving to the ordinary label,
/// so the edge reads as moonlight exposing type rather than a generic fade.
private final class MoonRevealLineView: UIView {
    private let finalLabel = UILabel()
    private let glowLabel = UILabel()
    private let moon = UIView()
    private let glowMask = CAGradientLayer()
    private var didReveal = false

    init(text: String) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        clipsToBounds = false
        for label in [finalLabel, glowLabel] {
            label.text = text
            label.font = .systemFont(ofSize: 25, weight: .semibold)
            label.textColor = .white
            label.textAlignment = .center
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.72
            addSubview(label)
        }
        glowLabel.layer.shadowColor = UIColor.white.cgColor
        glowLabel.layer.shadowRadius = 16
        glowLabel.layer.shadowOpacity = 1
        glowLabel.layer.shadowOffset = .zero
        glowMask.colors = [
            UIColor.clear.cgColor,
            UIColor.white.cgColor,
            UIColor.white.cgColor,
            UIColor.clear.cgColor,
        ]
        glowMask.locations = [0, 0.38, 0.62, 1]
        glowMask.startPoint = CGPoint(x: 0.5, y: 0)
        glowMask.endPoint = CGPoint(x: 0.5, y: 1)
        glowLabel.layer.mask = glowMask

        moon.backgroundColor = .black
        addSubview(moon)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        finalLabel.frame = bounds
        glowLabel.frame = bounds
        glowMask.frame = CGRect(
            x: 0, y: -bounds.height * 0.45,
            width: bounds.width, height: bounds.height * 0.55)
        if !didReveal {
            let diameter = max(bounds.width + 40, 240)
            moon.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            moon.center = CGPoint(x: bounds.midX, y: bounds.midY)
            moon.layer.cornerRadius = diameter / 2
        }
    }

    func reveal(duration: TimeInterval, completion: @escaping () -> Void) {
        guard !didReveal else {
            completion()
            return
        }
        didReveal = true
        layoutIfNeeded()
        let moonTravel = moon.bounds.height / 2 + bounds.height + 12
        let glowTravel = bounds.height * 1.9
        UIView.animate(
            withDuration: UIAccessibility.isReduceMotionEnabled ? 0.18 : duration,
            delay: 0,
            options: [.curveEaseInOut]
        ) {
            self.moon.transform = CGAffineTransform(translationX: 0, y: moonTravel)
        } completion: { _ in
            self.moon.removeFromSuperview()
            self.glowLabel.removeFromSuperview()
            completion()
        }
        let animation = CABasicAnimation(keyPath: "transform.translation.y")
        animation.fromValue = 0
        animation.toValue = glowTravel
        animation.duration = UIAccessibility.isReduceMotionEnabled ? 0.18 : duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glowMask.add(animation, forKey: "revealBand")
    }
}

// MARK: - Final eclipse into the real Reader deck

private enum ReaderOnboardingCompletionTransition {
    static func run(in window: UIWindow, to root: UIViewController) {
        let oldBounds = window.bounds
        guard let snapshot = window.snapshotView(afterScreenUpdates: true) else {
            window.rootViewController = root
            window.makeKeyAndVisible()
            return
        }
        snapshot.frame = oldBounds

        window.rootViewController = root
        window.makeKeyAndVisible()
        root.view.frame = oldBounds
        root.view.layoutIfNeeded()
        root.view.alpha = 0
        root.descendantNavigationController()?.installLunarEclipseTransition()

        let target = root.readerLaunchTransitionTarget()
        let targetFrame = target?.readerLaunchTargetFrame(in: window)
            ?? ReaderLaunchGeometry.totalityCardFrame(in: oldBounds)

        let stage = UIView(frame: oldBounds)
        stage.backgroundColor = .clear
        stage.isUserInteractionEnabled = false
        window.addSubview(stage)
        stage.addSubview(snapshot)

        let dimmer = UIView(frame: stage.bounds)
        dimmer.backgroundColor = .black
        dimmer.alpha = 0
        stage.addSubview(dimmer)

        let startFrame = targetFrame.offsetBy(dx: oldBounds.width + targetFrame.width, dy: 0)
        let corona = EclipseCoronaView(
            bodySize: targetFrame.size,
            cornerRadius: CardSurfaceView.cornerRadius,
            tint: LunaSurfacePalette.atmosphereTint(for: .reader))
        corona.frame = startFrame
        corona.alpha = 0.08
        stage.addSubview(corona)

        let flare = EclipseFlareView(frame: CGRect(
            x: targetFrame.minX - 65,
            y: targetFrame.midY - 65,
            width: 130,
            height: 130))
        flare.alpha = 0
        flare.transform = CGAffineTransform(scaleX: 0.45, y: 0.45)
        stage.addSubview(flare)

        let moon = CardSurfaceView(frame: startFrame)
        moon.backgroundColor = .black
        moon.setBorderEnabled(true)
        let black = UIView(frame: moon.bounds)
        black.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        black.backgroundColor = .black
        moon.installContentView(black)
        moon.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
        stage.addSubview(moon)

        let ingress: TimeInterval = UIAccessibility.isReduceMotionEnabled ? 0.18 : 0.58
        UIView.animateKeyframes(
            withDuration: ingress,
            delay: 0,
            options: [.calculationModeCubic]
        ) {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 1) {
                moon.frame = targetFrame
                moon.transform = CGAffineTransform(
                    scaleX: CardEclipseTransition.zenithScale,
                    y: CardEclipseTransition.zenithScale)
                corona.frame = targetFrame
                corona.alpha = 1
                dimmer.alpha = 0.94
            }
            UIView.addKeyframe(withRelativeStartTime: 0.78, relativeDuration: 0.22) {
                flare.alpha = 1
                flare.transform = .identity
                snapshot.alpha = 0
            }
        } completion: { _ in
            root.view.alpha = 1
            snapshot.removeFromSuperview()
            UIView.animateKeyframes(
                withDuration: UIAccessibility.isReduceMotionEnabled ? 0.16 : 0.34,
                delay: 0,
                options: [.calculationModeCubic]
            ) {
                UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 1) {
                    dimmer.alpha = 0
                    corona.alpha = 0
                    moon.transform = .identity
                    moon.alpha = 0
                }
                UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.34) {
                    flare.alpha = 0
                    flare.transform = CGAffineTransform(scaleX: 1.35, y: 1.35)
                }
            } completion: { _ in
                stage.removeFromSuperview()
                target?.readerLaunchTransitionDidFinish()
            }
        }
    }
}

private extension UIViewController {
    func descendantNavigationController() -> UINavigationController? {
        if let navigation = self as? UINavigationController { return navigation }
        for child in children {
            if let navigation = child.descendantNavigationController() { return navigation }
        }
        return nil
    }
}

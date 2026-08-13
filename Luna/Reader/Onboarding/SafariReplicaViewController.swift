//
//  SafariReplicaViewController.swift
//  Luna
//

import LunaDesignSystem
import LunaModels
import UIKit
import WebKit

enum OnboardingExternalDestination {
    case safari
    case shortcuts
    case settings

    var displayName: String {
        switch self {
        case .safari: return OnboardingStrings.Instruction.setUpSafari.value()
        case .shortcuts: return OnboardingStrings.Instruction.installShortcut.value()
        case .settings: return OnboardingStrings.Instruction.setActionButton.value()
        }
    }
}

/// A deliberately noninteractive Safari facsimile used by each app's
/// onboarding. The page bytes are local; the browser chrome remains native
/// UIKit so it has the current OS's typography, glass, safe-area and status-bar
/// behavior.
@MainActor
final class SafariReplicaViewController:
    OnboardingSaveSourceViewController,
    WKNavigationDelegate
{
    var onSetUpSafari: (() -> Void)?
    var onSkipSafariSetup: (() -> Void)?
    var onInstallShortcut: (() -> Void)?
    var onSetActionButton: (() -> Void)?
    var onSetUpLater: (() -> Void)?
    /// This app's lesson has reached its own setup ask — the explainer's page
    /// clean, the video panel's steps, the product card — whichever of the three
    /// this replica plays. It is the ONE end-of-lesson signal, so a host that
    /// plays several of them in a row does not have to know which is which.
    var onDidReachSetupOffer: (() -> Void)?

    private let onboardingConfiguration: OnboardingSurfaceConfiguration
    private let webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isUserInteractionEnabled = false
        view.scrollView.isScrollEnabled = false
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.backgroundColor = .white
        view.isOpaque = true
        return view
    }()

    private let browserBar = SafariBottomBar()
    /// The native `luna.app` explainer, and nil in an app whose Safari lesson
    /// is not the explainer — an unused copy of it, mounted and hidden, is a
    /// whole page of ads, popups and (identically labelled) setup buttons that
    /// the lesson on screen has nothing to do with.
    private let lunaPage: OnboardingSafariPageView?
    /// The price tracker's lesson, played over the mock product page instead of
    /// the explainer's clutter wipe. Nil in every app whose lesson is the
    /// explainer (`OnboardingSurfaceConfiguration.safariLesson`).
    private var priceLesson: OnboardingPriceComparisonOverlayView?
    /// The Downloader's lesson, played over the mock post instead of the
    /// explainer's clutter wipe. Nil in every app whose lesson is not
    /// `.videoDownload`.
    private var videoLesson: OnboardingVideoDownloadOverlayView?
    private var instructionOverlay: DemoInstructionOverlay?
    private var extensionsSheet: OnboardingManageExtensionsSheetView?
    private var enableDemoGeneration = 0
    private var didBeginDemonstration = false
    /// One report per run of the lesson: the explainer's clean-up completion,
    /// the video panel's steps and the product card each land once, and a rewind
    /// arms the next run.
    private var didReportSetupOffer = false
    private var pageIndex = 0
    private var pageTimer: Timer?
    /// The first lesson demonstrates Safari's extension switch. Replays run
    /// the already-enabled result directly, at a shorter timeline beneath the
    /// persistent setup popup.
    private var animationSpeedMultiplier: TimeInterval = 1

    /// Only this replica's OWN instruction overlay — the shared "Set up in
    /// Safari" / "Skip" popup every lesson ends on now lives one level up, on
    /// `AppOnboardingViewController`, precisely so it is never one of these
    /// per-replica things a cross-sibling swap could disturb (see
    /// `AppOnboardingViewController.showSafariSetupPopup()`).
    var hasInstructions: Bool {
        instructionOverlay != nil
    }
    override var sharedURLString: String {
        let pages = onboardingConfiguration.demoPages
        guard !pages.isEmpty else { return OnboardingDemoPage.lunaPage.sharedURLString }
        return pages[pageIndex % pages.count].sharedURLString
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .darkContent }

    init(configuration: OnboardingSurfaceConfiguration = .current) {
        self.onboardingConfiguration = configuration
        lunaPage = configuration.safariLesson == .extensionExplainer
            ? OnboardingSafariPageView(configuration: configuration)
            : nil
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        pageTimer?.invalidate()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The strip under the status bar, which the page itself starts below:
        // the explainer's own grey, or — for a lesson that only ever loads one
        // bundled page — that page's black.
        view.backgroundColor = onboardingConfiguration.safariLesson == .videoDownload
            ? .black
            : OnboardingSafariPagePalette.background
        configureBrowser()
        webView.navigationDelegate = self
        configurePriceLessonIfNeeded()
        configureVideoLessonIfNeeded()
        loadOfflinePage(at: 0)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startPageRotationIfNeeded()
        videoLesson?.setPlaying(true)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Nothing should be decoding behind a screen nobody is looking at — and
        // the panel keeps its last frame, so coming back finds the video where
        // it was rather than a black rectangle.
        videoLesson?.setPlaying(false)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        pageTimer?.invalidate()
        pageTimer = nil
    }

    private func configureBrowser() {
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        if let lunaPage {
            lunaPage.translatesAutoresizingMaskIntoConstraints = false
            lunaPage.isHidden = true
            view.addSubview(lunaPage)
            NSLayoutConstraint.activate([
                lunaPage.topAnchor.constraint(
                    equalTo: view.safeAreaLayoutGuide.topAnchor),
                lunaPage.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                lunaPage.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                lunaPage.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        }
        browserBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(browserBar)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            browserBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            browserBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            browserBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            browserBar.heightAnchor.constraint(
                equalToConstant: SafariBottomBar.reservedPageHeight),
        ])
    }

    /// The lesson that plays over a real-looking product page rather than over
    /// the explainer. Mounted with the browser rather than at its cue: the card
    /// it ends on wears an eclipse corona, whose raster is worth building while
    /// the replica is still hidden behind the intro card.
    private func configurePriceLessonIfNeeded() {
        guard onboardingConfiguration.safariLesson == .priceComparison else {
            return
        }
        let lesson = OnboardingPriceComparisonOverlayView(
            configuration: onboardingConfiguration)
        lesson.onDidReachSetupOffer = { [weak self] in
            self?.lessonDidReachSetupOffer()
        }
        lesson.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(lesson)
        priceLesson = lesson
        NSLayoutConstraint.activate([
            lesson.topAnchor.constraint(equalTo: view.topAnchor),
            lesson.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            lesson.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            lesson.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// The Downloader's lesson, mounted with the browser for the same reason
    /// the price one is: its first layout — the panel's header, its portrait
    /// stage and the download capsule — is worth paying while the replica is
    /// still hidden behind the intro card. Under the browser bar and over the
    /// page, because Safari's chrome is not part of the page an extension
    /// draws into.
    private func configureVideoLessonIfNeeded() {
        guard onboardingConfiguration.safariLesson == .videoDownload else {
            return
        }
        let lesson = OnboardingVideoDownloadOverlayView(
            configuration: onboardingConfiguration)
        lesson.onDidReachSetupOffer = { [weak self] in
            self?.lessonDidReachSetupOffer()
        }
        lesson.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(lesson, belowSubview: browserBar)
        videoLesson = lesson
        NSLayoutConstraint.activate([
            lesson.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor),
            lesson.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            lesson.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            lesson.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func loadOfflinePage(at index: Int) {
        let pages = onboardingConfiguration.demoPages
        guard !pages.isEmpty else {
            webView.loadHTMLString(Self.fallbackHTML, baseURL: nil)
            return
        }
        pageIndex = index % pages.count
        let page = pages[pageIndex]
        browserBar.setURL(
            page.sharedURLString,
            displayedHost: page.displayedHost)
        if page == .lunaPage, let lunaPage {
            webView.isHidden = true
            lunaPage.isHidden = false
            lunaPage.alpha = 1
            return
        }

        lunaPage?.isHidden = true
        webView.isHidden = false
        guard let resourceName = page.resourceName,
              let url = Bundle.main.url(
                forResource: resourceName, withExtension: "html"),
              let html = OnboardingStrings.Demo.renderedHTML(for: page)
        else {
            webView.loadHTMLString(Self.fallbackHTML, baseURL: nil)
            return
        }
        webView.loadHTMLString(html, baseURL: url.deletingLastPathComponent())
    }

    private func startPageRotationIfNeeded() {
        guard didBeginDemonstration,
              onboardingConfiguration.demoPages.count > 1,
              pageTimer == nil
        else { return }
        pageTimer = Timer.scheduledTimer(
            withTimeInterval: OnboardingAnimationClock.delay(3.4),
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let outgoing = self.visiblePageView
                UIView.animate(
                    withDuration: 0.18,
                    animations: { outgoing.alpha = 0.12 },
                    completion: { _ in
                        self.loadOfflinePage(at: self.pageIndex + 1)
                        let incoming = self.visiblePageView
                        incoming.alpha = 0.12
                        UIView.animate(
                            withDuration: 0.18,
                            animations: { incoming.alpha = 1 })
                    })
            }
        }
    }

    private var visiblePageView: UIView {
        guard let lunaPage, !lunaPage.isHidden else { return webView }
        return lunaPage
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        UIView.animate(
            withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.28
        ) {
            webView.alpha = 1
        }
    }

    /// Rewinds the lesson to its first frame, so a second entry plays the whole
    /// demonstration instead of landing on its finished last one. A no-op
    /// before the first `beginDemonstration`, which keeps the very first entry
    /// from reloading a page it has already laid out — the app-switcher hop
    /// snapshots this view the instant afterwards.
    func resetDemonstration() {
        guard didBeginDemonstration else { return }
        didBeginDemonstration = false
        didReportSetupOffer = false
        cancelActionButtonSaveEffect()
        priceLesson?.reset()
        videoLesson?.reset()
        pageTimer?.invalidate()
        pageTimer = nil
        lunaPage?.restoreBuriedPage()
        // Central Luna's rotation can have left the browser on another page.
        if pageIndex != 0 {
            loadOfflinePage(at: 0)
        }
    }

    /// Starts only after the incoming card has expanded to the screen. Keeping
    /// the timeline explicit prevents the Action Button cue from playing while
    /// the browser is still changing geometry.
    func beginDemonstration(
        showsExtensionSheet: Bool = true,
        animationSpeedMultiplier: TimeInterval = 1
    ) {
        guard !didBeginDemonstration else { return }
        didBeginDemonstration = true
        self.animationSpeedMultiplier = animationSpeedMultiplier
        lunaPage?.animationSpeedMultiplier = animationSpeedMultiplier
        if let priceLesson {
            runPriceComparisonDemonstration(
                priceLesson, showsExtensionSheet: showsExtensionSheet)
            return
        }
        if let videoLesson {
            // First teach the one Safari action the person has to take. The
            // media panel is the proof of what enabling it unlocks, not a
            // detached prelude that appears before the extension is on.
            runExtensionEnableDemonstration(showsExtensionSheet: showsExtensionSheet) {
                [weak self, weak videoLesson] in
                videoLesson?.begin(
                    immediately: true,
                    animationSpeedMultiplier: self?.animationSpeedMultiplier ?? 1)
            }
            return
        }
        if onboardingConfiguration.demoPages[pageIndex] == .lunaPage {
            runExtensionEnableDemonstration(showsExtensionSheet: showsExtensionSheet)
            return
        }
        DispatchQueue.main.asyncAfter(
            deadline: .now() + OnboardingAnimationClock.delay(0.75)
        ) { [weak self] in
            self?.replayActionButtonSaveEffect()
        }
    }

    /// Whichever of the three lessons this replica plays, it ends by asking for
    /// the same thing. Reported once per run, and only for a run that is still
    /// the current one.
    private func lessonDidReachSetupOffer() {
        guard didBeginDemonstration, !didReportSetupOffer else { return }
        didReportSetupOffer = true
        onDidReachSetupOffer?()
    }

    /// Price Tracker starts by showing the same Safari-owned permission
    /// decision as the Reader. Only after its extension is enabled does the
    /// product lesson demonstrate the extension looking for comparable sellers.
    private func runPriceComparisonDemonstration(
        _ lesson: OnboardingPriceComparisonOverlayView,
        showsExtensionSheet: Bool
    ) {
        enableDemoGeneration += 1
        let generation = enableDemoGeneration
        guard showsExtensionSheet else {
            holdOnThePage(generation: generation) {
                lesson.begin(
                    afterEnablingExtension: true,
                    animationSpeedMultiplier: self.animationSpeedMultiplier)
            }
            return
        }
        afterEnableDelay(
            OnboardingExtensionEnableTiming.pageHoldDuration,
            generation: generation
        ) { [weak self] in
            guard let self else { return }
            let sheet = OnboardingManageExtensionsSheetView(
                frame: self.view.bounds, configuration: self.onboardingConfiguration)
            self.extensionsSheet = sheet
            self.view.addSubview(sheet)
            sheet.present { [weak self] in
                guard let self, generation == self.enableDemoGeneration else { return }
                self.afterEnableDelay(
                    OnboardingExtensionEnableTiming.toggleDelay,
                    generation: generation
                ) { [weak self] in
                    guard let self else { return }
                    sheet.turnOnToggle { [weak self] in
                        guard let self,
                              generation == self.enableDemoGeneration
                        else { return }
                        sheet.dismiss { [weak self] in
                            guard let self,
                                  generation == self.enableDemoGeneration
                            else { return }
                            self.extensionsSheet = nil
                            lesson.begin(afterEnablingExtension: true)
                        }
                    }
                }
            }
        }
    }

    // MARK: - The mock extension-enable pass

    /// The buried page's rescue, told through Safari's own UI: the Manage
    /// Extensions sheet slides straight up over the page — no page menu, no
    /// hunt down its list — flips Luna's toggle on, and the wipe sets out on
    /// that flip, playing while the sheet slides back down. The page underneath
    /// spells out those same steps, so the pass is a demonstration of what the
    /// reader is about to read.
    private func runExtensionEnableDemonstration(
        showsExtensionSheet: Bool = true,
        completion: (() -> Void)? = nil
    ) {
        enableDemoGeneration += 1
        let generation = enableDemoGeneration
        guard showsExtensionSheet else {
            holdOnThePage(generation: generation) {
                self.completeExtensionEnableDemonstration(completion: completion)
            }
            return
        }
        afterEnableDelay(
            OnboardingExtensionEnableTiming.pageHoldDuration,
            generation: generation
        ) {
            self.presentExtensionsSheet(
                generation: generation, completion: completion)
        }
    }

    private func presentExtensionsSheet(
        generation: Int,
        completion: (() -> Void)? = nil
    ) {
        let sheet = OnboardingManageExtensionsSheetView(
            frame: view.bounds, configuration: onboardingConfiguration)
        extensionsSheet = sheet
        view.addSubview(sheet)
        sheet.present { [weak self] in
            guard let self, generation == self.enableDemoGeneration else { return }
            self.afterEnableDelay(
                OnboardingExtensionEnableTiming.toggleDelay,
                generation: generation
            ) { [weak self] in
                guard let self else { return }
                sheet.turnOnToggle { [weak self] in
                    guard let self,
                          generation == self.enableDemoGeneration
                    else { return }
                    sheet.dismiss { [weak self] in
                        self?.extensionsSheet = nil
                        self?.completeExtensionEnableDemonstration(
                            completion: completion)
                    }
                }
            }
        }
    }

    /// The result of Safari's toggle flip. A replay already taught the toggle,
    /// so it begins here instead of presenting another copy of that sheet.
    private func completeExtensionEnableDemonstration(
        completion: (() -> Void)?
    ) {
        lunaPage?.prepareCleanUp()
        completion?()
        // Only the Reader's explainer has clutter to shatter. The Downloader
        // keeps its blocked post intact behind the video panel and reports its
        // own end from that panel instead.
        lunaPage?.cleanUpClutter { [weak self] in
            self?.lessonDidReachSetupOffer()
        }
    }

    /// The beat a pass that skips the Manage Extensions sheet would otherwise
    /// not have: the browser standing on its own page, exactly as it loaded,
    /// before the extension's result plays over it. With the sheet, that beat is
    /// the sheet's own — it opens over a page the reader has already had time to
    /// take in. Without it the lesson jumped straight to its answer, which is
    /// what made the Downloader's blocked post — the whole premise of its
    /// lesson — a frame nobody could read.
    ///
    /// Each lesson names its own hold, because each is standing on a different
    /// page: a wall of refusal has to be READ, a product page only has to
    /// register as one. Scaled by `animationSpeedMultiplier` like every other
    /// beat, so the loop's later passes shorten it along with the rest.
    private func holdOnThePage(
        generation: Int, _ work: @escaping () -> Void
    ) {
        afterEnableDelay(
            skippedSheetPageHoldDuration, generation: generation, work)
    }

    private var skippedSheetPageHoldDuration: TimeInterval {
        switch onboardingConfiguration.safariLesson {
        case .videoDownload:
            return OnboardingVideoDownloadTiming.pageHoldDuration
        case .priceComparison:
            return OnboardingPriceComparisonTiming.pageHoldDuration
        case .extensionExplainer:
            return OnboardingExtensionEnableTiming.pageHoldDuration
        }
    }

    private func afterEnableDelay(
        _ delay: TimeInterval,
        generation: Int,
        _ work: @escaping () -> Void
    ) {
        DispatchQueue.main.asyncAfter(
            deadline: .now() + OnboardingAnimationClock.delay(
                delay * animationSpeedMultiplier)
        ) { [weak self] in
            guard let self, generation == self.enableDemoGeneration else { return }
            work()
        }
    }

    override func saveEffectWasCancelled() {
        enableDemoGeneration += 1
        extensionsSheet?.removeFromSuperview()
        extensionsSheet = nil
    }

    override func setURLHighlighted(_ highlighted: Bool) {
        browserBar.setURLHighlighted(highlighted)
    }

    override func prepareForPresentation() {
        super.prepareForPresentation()
        // Keep the preloaded central-app source on luna.app through the initial
        // staged article and save. Its normal multi-page rotation resumes when
        // Safari returns later in the demonstration loop.
        if didBeginDemonstration {
            startPageRotationIfNeeded()
        }
    }

    override var isURLHighlighted: Bool { browserBar.isURLHighlighted }

    override var highlightedLinkRegion: OnboardingHighlightedLinkRegion? {
        // The bar is up for the whole of every lesson now, so the only thing
        // that can be missing is the view itself.
        guard isViewLoaded else { return nil }
        let browserRegion = browserBar.highlightedURLRegion
        return OnboardingHighlightedLinkRegion(
            frame: view.convert(browserRegion.frame, from: browserBar),
            cornerRadius: browserRegion.cornerRadius)
    }

    /// The wave-driven "you should enable Safari" ask — a different moment
    /// from a lesson's own setup offer (`AppOnboardingViewController
    /// .showSafariSetupPopup()`): this one comes up once a save FROM Safari
    /// has been demonstrated, wherever that lands in the journey.
    func showSafariPrompt() {
        setInstruction(
            title: OnboardingStrings.Instruction.safariPrompt(
                saveBenefit: onboardingConfiguration.saveBenefit,
                allApps: onboardingConfiguration.isCentralApp),
            actions: [
                .init(
                    title: OnboardingStrings.Instruction.setUpSafari.value(),
                    image: UIImage(systemName: "safari.fill"),
                    prominent: true,
                    action: { [weak self] in self?.onSetUpSafari?() }),
            ])
    }

    /// After a hop to Safari that returns with no evidence, this replica's
    /// OWN video panel (if it has one) resumes playing. The shared setup
    /// popup's own buttons/pulse are restored by whichever object raised it
    /// now — `AppOnboardingViewController.restoreSharedSafariSetupPopupIfNeeded()`
    /// — not per replica; see that type's doc for why the popup no longer
    /// lives here at all.
    func resumeVideoLessonAfterExternalReturn() {
        videoLesson?.setPlaying(true)
    }

    func showShortcutAndActionSetup() {
        setInstruction(
            title: nil,
            actions: [
                .init(
                    title: OnboardingStrings.Instruction.installShortcut.value(),
                    image: OnboardingSystemIcons.shortcutsAppIcon,
                    prominent: true,
                    action: { [weak self] in self?.onInstallShortcut?() }),
                .init(
                    title: OnboardingStrings.Instruction.setActionButton.value(),
                    image: OnboardingSystemIcons.actionButton,
                    prominent: false,
                    action: { [weak self] in self?.onSetActionButton?() }),
            ])
    }

    func showWaitingForActionButton() {
        setInstruction(
            title: OnboardingStrings.Instruction.actionButtonPrompt.value(),
            actions: [
                .init(
                    title: OnboardingStrings.Instruction.setUpLater.value(),
                    image: UIImage(systemName: "clock"),
                    prominent: false,
                    action: { [weak self] in self?.onSetUpLater?() }),
            ])
    }

    func showExternalOpenFailure(destination: OnboardingExternalDestination) {
        setInstruction(
            title: OnboardingStrings.Instruction.externalOpenFailure(
                destination: destination.displayName),
            actions: [
                .init(
                    title: OnboardingStrings.Instruction.setUpSafari.value(),
                    image: UIImage(systemName: "safari.fill"),
                    prominent: destination == .safari,
                    action: { [weak self] in self?.onSetUpSafari?() }),
                .init(
                    title: OnboardingStrings.Instruction.installShortcut.value(),
                    image: OnboardingSystemIcons.shortcutsAppIcon,
                    prominent: destination == .shortcuts,
                    action: { [weak self] in self?.onInstallShortcut?() }),
                .init(
                    title: OnboardingStrings.Instruction.setActionButton.value(),
                    image: OnboardingSystemIcons.actionButton,
                    prominent: destination == .settings,
                    action: { [weak self] in self?.onSetActionButton?() }),
            ])
    }

    func dismissInstructions(animated: Bool, completion: @escaping () -> Void) {
        guard let overlay = instructionOverlay else {
            completion()
            return
        }
        instructionOverlay = nil
        let changes = { overlay.alpha = 0 }
        if animated, !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(
                withDuration: 0.28, delay: 0,
                options: [.curveEaseInOut],
                animations: changes,
                completion: { _ in
                    overlay.removeFromSuperview()
                    completion()
                })
        } else {
            changes()
            overlay.removeFromSuperview()
            completion()
        }
    }

    private func setInstruction(
        title: String?,
        actions: [DemoInstructionOverlay.Action]
    ) {
        let overlay = instructionOverlay ?? DemoInstructionOverlay()
        overlay.configure(title: title, actions: actions)
        if instructionOverlay == nil {
            guard let host = view.window ?? view else { return }
            instructionOverlay = overlay
            overlay.frame = host.bounds
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            host.addSubview(overlay)
            overlay.animateIn()
        }
    }

    private static let fallbackHTML = """
    <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
    <style>body{font:17px -apple-system;margin:24px;color:#202122}h1{font:36px Georgia}\
    li{margin:0 0 10px}</style>
    \(ShareSetupPractice.fallbackHTMLBody)
    """
}

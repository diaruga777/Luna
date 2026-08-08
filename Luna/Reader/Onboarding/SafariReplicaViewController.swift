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
    /// Mounted only by the apps whose lesson is the explainer page. A page the
    /// browser will never load has no business in the hierarchy: its actions
    /// carry the same labels the video panel's do, and two of each is one for a
    /// test — or for VoiceOver — to find by accident.
    private let lunaPage: OnboardingSafariPageView
    private var videoOverlay: OnboardingSafariVideoOverlayView?
    /// False from the extension's flip until the lesson stages the browser
    /// again: the bar has slid away and the page has taken back its strip.
    private var isBrowserBarVisible = true
    private var instructionOverlay: DemoInstructionOverlay?
    private var extensionsSheet: OnboardingManageExtensionsSheetView?
    private var enableDemoGeneration = 0
    private var didBeginDemonstration = false
    private var pageIndex = 0
    private var pageTimer: Timer?

    var hasInstructions: Bool { instructionOverlay != nil }
    private var usesLunaPage: Bool {
        onboardingConfiguration.demoPages.contains(.lunaPage)
    }
    override var sharedURLString: String {
        let pages = onboardingConfiguration.demoPages
        guard !pages.isEmpty else { return OnboardingDemoPage.lunaPage.sharedURLString }
        return pages[pageIndex % pages.count].sharedURLString
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .darkContent }

    init(configuration: OnboardingSurfaceConfiguration = .current) {
        self.onboardingConfiguration = configuration
        lunaPage = OnboardingSafariPageView(configuration: configuration)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        pageTimer?.invalidate()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // What the strip under the status bar shows, since the page itself
        // starts at the safe area: the explainer page's own grey, or — for a
        // lesson that only ever loads a bundled page — that page's black.
        view.backgroundColor = usesLunaPage ? lunaPage.backgroundColor : .black
        configureBrowser()
        lunaPage.onActivateSafari = { [weak self] in
            self?.onSetUpSafari?()
        }
        lunaPage.onSkipSafariSetup = { [weak self] in
            self?.onSkipSafariSetup?()
        }
        webView.navigationDelegate = self
        loadOfflinePage(at: 0)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startPageRotationIfNeeded()
        videoOverlay?.setPlaying(true)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        pageTimer?.invalidate()
        pageTimer = nil
    }

    private func configureBrowser() {
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        if usesLunaPage {
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

    /// The mock browser bar belongs to the page it floats over. While the page
    /// is buried, the bar is what makes the facsimile read as Safari; the
    /// instant the extension has run there is nothing left in it for the lesson
    /// to point at, and an address field left standing under a finished sweep
    /// reads as a control the user could tap. So it leaves with the Manage
    /// Extensions sheet — sliding out on its own height, over the sheet's own
    /// exit — and the page takes back the strip it was reserving for it.
    ///
    /// The page's reserve changes with the FIRST frame of the slide rather than
    /// over it: the wave's geometry is cut in the same beat (`prepareCleanUp`),
    /// and content still travelling would put the light off its own ink. The
    /// jump lands under the clutter's tiles, which still cover the page's whole
    /// bottom half at that moment.
    private func setBrowserBarVisible(_ visible: Bool, animated: Bool) {
        isBrowserBarVisible = visible
        lunaPage.setReservesBrowserChrome(visible)
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        let changes = {
            self.browserBar.alpha = visible ? 1 : 0
            self.browserBar.transform = visible || reduceMotion
                ? .identity
                : CGAffineTransform(
                    translationX: 0,
                    y: SafariBottomBar.reservedPageHeight)
        }
        guard animated else {
            changes()
            return
        }
        UIView.animate(
            withDuration: reduceMotion
                ? 0.2
                : OnboardingExtensionEnableTiming.sheetDismissDuration,
            delay: 0,
            options: [.curveEaseIn, .beginFromCurrentState],
            animations: changes)
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
        if page == .lunaPage {
            webView.isHidden = true
            lunaPage.isHidden = false
            lunaPage.alpha = 1
            return
        }

        lunaPage.isHidden = true
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
        lunaPage.isHidden ? webView : lunaPage
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
        cancelActionButtonSaveEffect()
        tearDownVideoOverlay()
        pageTimer?.invalidate()
        pageTimer = nil
        // A buried page is a page in a browser: the bar is back before this
        // entry's first frame, and the page reserves its strip again.
        setBrowserBarVisible(true, animated: false)
        lunaPage.restoreBuriedPage()
        // Central Luna's rotation can have left the browser on another page.
        if pageIndex != 0 {
            loadOfflinePage(at: 0)
        }
    }

    /// Starts only after the incoming card has expanded to the screen. Keeping
    /// the timeline explicit prevents the Action Button cue from playing while
    /// the browser is still changing geometry.
    func beginDemonstration() {
        guard !didBeginDemonstration else { return }
        didBeginDemonstration = true
        if onboardingConfiguration.safariLesson == .videoOverlay {
            runVideoOverlayDemonstration()
            return
        }
        if onboardingConfiguration.demoPages[pageIndex] == .lunaPage {
            runExtensionEnableDemonstration()
            return
        }
        DispatchQueue.main.asyncAfter(
            deadline: .now() + OnboardingAnimationClock.delay(0.75)
        ) { [weak self] in
            self?.replayActionButtonSaveEffect()
        }
    }

    // MARK: - The blocked post, answered

    /// The Downloader's lesson. The post loads with its own video walled off
    /// behind a sign-up prompt; a beat later the extension's video panel arrives
    /// over it — the same panel `content.js` builds, playing the post's video —
    /// and once it has plainly played, the download button gives way to the
    /// three steps that switch the extension on, the panel growing downward to
    /// hold them.
    ///
    /// Nothing in it is tappable but those last two buttons: the whole point is
    /// a picture of what happens on a real page, and a picture that answered a
    /// tap would be a route out of the lesson into a page that does not exist.
    private func runVideoOverlayDemonstration() {
        enableDemoGeneration += 1
        let generation = enableDemoGeneration
        let overlay = OnboardingSafariVideoOverlayView(
            configuration: onboardingConfiguration)
        overlay.onActivateSafari = { [weak self] in self?.onSetUpSafari?() }
        overlay.onSkipSafariSetup = { [weak self] in self?.onSkipSafariSetup?() }
        overlay.translatesAutoresizingMaskIntoConstraints = false
        videoOverlay = overlay
        // Under the browser bar, over the page: Safari's chrome is not part of
        // the page an extension draws into.
        view.insertSubview(overlay, belowSubview: browserBar)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        overlay.alpha = 0
        view.layoutIfNeeded()

        afterEnableDelay(
            OnboardingVideoOverlayTiming.pageHoldDuration,
            generation: generation
        ) {
            overlay.present { [weak self] in
                self?.afterEnableDelay(
                    OnboardingVideoOverlayTiming.playbackHoldDuration,
                    generation: generation
                ) {
                    overlay.revealSetupInstructions()
                }
            }
        }
    }

    private func tearDownVideoOverlay() {
        videoOverlay?.stop()
        videoOverlay?.removeFromSuperview()
        videoOverlay = nil
    }

    // MARK: - The mock extension-enable pass

    /// The buried page's rescue, told through Safari's own UI: the Manage
    /// Extensions sheet slides straight up over the page — no page menu, no
    /// hunt down its list — flips Luna's toggle on, and the wipe sets out on
    /// that flip, playing while the sheet slides back down. The page underneath
    /// spells out those same steps, so the pass is a demonstration of what the
    /// reader is about to read.
    private func runExtensionEnableDemonstration() {
        enableDemoGeneration += 1
        let generation = enableDemoGeneration
        afterEnableDelay(
            OnboardingExtensionEnableTiming.pageHoldDuration,
            generation: generation
        ) {
            self.presentExtensionsSheet(generation: generation)
        }
    }

    private func presentExtensionsSheet(generation: Int) {
        let sheet = OnboardingManageExtensionsSheetView(
            frame: view.bounds, configuration: onboardingConfiguration)
        extensionsSheet = sheet
        view.addSubview(sheet)
        sheet.present { [weak self] in
            guard let self, generation == self.enableDemoGeneration else { return }
            self.afterEnableDelay(
                OnboardingExtensionEnableTiming.toggleDelay,
                generation: generation
            ) {
                sheet.turnOnToggle { [weak self] in
                    guard let self,
                          generation == self.enableDemoGeneration
                    else { return }
                    // The switch flipping on IS the wipe's cue: the heavy
                    // preparation (tile swap, light rasters) commits first,
                    // then the sheet starts sliding away and the sweep sets
                    // out with it — `cleanUpClutter` still holds its
                    // animations back one run-loop turn, so the short blooms
                    // at the top of the page keep their shine.
                    // The browser bar leaves on the same cue, before the
                    // page's geometry is measured for the wave.
                    self.setBrowserBarVisible(false, animated: true)
                    self.lunaPage.prepareCleanUp()
                    sheet.dismiss { [weak self] in
                        self?.extensionsSheet = nil
                    }
                    self.lunaPage.cleanUpClutter()
                }
            }
        }
    }

    private func afterEnableDelay(
        _ delay: TimeInterval,
        generation: Int,
        _ work: @escaping () -> Void
    ) {
        DispatchQueue.main.asyncAfter(
            deadline: .now() + OnboardingAnimationClock.delay(delay)
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

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Nothing should be decoding behind a screen nobody is looking at —
        // and the panel keeps its last frame, so coming back finds the video
        // where it was rather than a black rectangle.
        videoOverlay?.setPlaying(false)
    }

    override func setURLHighlighted(_ highlighted: Bool) {
        browserBar.setURLHighlighted(highlighted)
    }

    override func prepareForPresentation() {
        super.prepareForPresentation()
        // A source coming back full screen is a browser again: the save
        // demonstration lights up the address field, so the bar has to be there
        // for it whatever the extension pass did with it.
        setBrowserBarVisible(true, animated: false)
        // Keep the preloaded central-app source on luna.app through the initial
        // staged article and save. Its normal multi-page rotation resumes when
        // Safari returns later in the demonstration loop.
        if didBeginDemonstration {
            startPageRotationIfNeeded()
        }
    }

    override var isURLHighlighted: Bool { browserBar.isURLHighlighted }

    override var highlightedLinkRegion: OnboardingHighlightedLinkRegion? {
        // No bar, no URL to isolate: a save replay that arrived with the bar
        // away would light a region nothing is drawn in, so the shared player
        // is told there is nothing here to save from.
        guard isViewLoaded, isBrowserBarVisible else { return nil }
        let browserRegion = browserBar.highlightedURLRegion
        return OnboardingHighlightedLinkRegion(
            frame: view.convert(browserRegion.frame, from: browserBar),
            cornerRadius: browserRegion.cornerRadius)
    }

    func showSafariPrompt() {
        setInstruction(
            title: OnboardingStrings.Instruction.safariPrompt(
                saveBenefit: onboardingConfiguration.saveBenefit),
            actions: [
                .init(
                    title: OnboardingStrings.Instruction.setUpSafari.value(),
                    image: UIImage(systemName: "safari.fill"),
                    prominent: true,
                    action: { [weak self] in self?.onSetUpSafari?() }),
            ])
    }


    func restoreInPageSafariSetup() {
        lunaPage.reactivateActions()
        videoOverlay?.reactivateActions()
        videoOverlay?.setPlaying(true)
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
        let changes = {
            overlay.alpha = 0
        }
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

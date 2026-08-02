//
//  SafariReplicaViewController.swift
//  Luna
//

import LunaDesignSystem
import UIKit
import WebKit

enum OnboardingExternalDestination: String {
    case safari = "Safari"
    case shortcuts = "Shortcuts"
    case settings = "Settings"
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
    private let lunaPage: OnboardingSafariPageView
    private var instructionOverlay: DemoInstructionOverlay?
    private var extensionsSheet: OnboardingManageExtensionsSheetView?
    private var enableDemoGeneration = 0
    private var didBeginDemonstration = false
    private var pageIndex = 0
    private var pageTimer: Timer?

    var hasInstructions: Bool { instructionOverlay != nil }
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
        view.backgroundColor = lunaPage.backgroundColor
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
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        pageTimer?.invalidate()
        pageTimer = nil
    }

    private func configureBrowser() {
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        lunaPage.translatesAutoresizingMaskIntoConstraints = false
        lunaPage.isHidden = true
        view.addSubview(lunaPage)
        browserBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(browserBar)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            lunaPage.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            lunaPage.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            lunaPage.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            lunaPage.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            browserBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            browserBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            browserBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            browserBar.heightAnchor.constraint(
                equalToConstant: SafariBottomBar.reservedPageHeight),
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
                forResource: resourceName, withExtension: "html")
        else {
            webView.loadHTMLString(Self.fallbackHTML, baseURL: nil)
            return
        }
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
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
        pageTimer?.invalidate()
        pageTimer = nil
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
                    // preparation (tile swap, re-occlusion, light rasters)
                    // commits first, then the sheet starts sliding away and
                    // the sweep sets out with it — `cleanUpClutter` still
                    // holds its animations back one run-loop turn, so the
                    // short reveals at the top of the page keep their shine.
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
        guard isViewLoaded else { return nil }
        let browserRegion = browserBar.highlightedURLRegion
        return OnboardingHighlightedLinkRegion(
            frame: view.convert(browserRegion.frame, from: browserBar),
            cornerRadius: browserRegion.cornerRadius)
    }

    func showSafariPrompt() {
        setInstruction(
            title: "Press the Action Button to save\n\(onboardingConfiguration.saveBenefit)",
            actions: [
                .init(
                    title: "Set up Safari",
                    image: UIImage(systemName: "safari.fill"),
                    prominent: true,
                    action: { [weak self] in self?.onSetUpSafari?() }),
            ])
    }


    func restoreInPageSafariSetup() {
        lunaPage.reactivateActions()
    }

    func showShortcutAndActionSetup() {
        setInstruction(
            title: nil,
            actions: [
                .init(
                    title: "Install Shortcut",
                    image: OnboardingSystemIcons.shortcutsAppIcon,
                    prominent: true,
                    action: { [weak self] in self?.onInstallShortcut?() }),
                .init(
                    title: "Set action button",
                    image: OnboardingSystemIcons.actionButton,
                    prominent: false,
                    action: { [weak self] in self?.onSetActionButton?() }),
            ])
    }

    func showWaitingForActionButton() {
        setInstruction(
            title: "Press the action button to finish",
            actions: [
                .init(
                    title: "Set up later",
                    image: UIImage(systemName: "clock"),
                    prominent: false,
                    action: { [weak self] in self?.onSetUpLater?() }),
            ])
    }

    func showExternalOpenFailure(destination: OnboardingExternalDestination) {
        setInstruction(
            title: "Couldn’t open \(destination.rawValue). Try again.",
            actions: [
                .init(
                    title: "Set up Safari",
                    image: UIImage(systemName: "safari.fill"),
                    prominent: destination == .safari,
                    action: { [weak self] in self?.onSetUpSafari?() }),
                .init(
                    title: "Install Shortcut",
                    image: OnboardingSystemIcons.shortcutsAppIcon,
                    prominent: destination == .shortcuts,
                    action: { [weak self] in self?.onInstallShortcut?() }),
                .init(
                    title: "Set action button",
                    image: OnboardingSystemIcons.actionButton,
                    prominent: destination == .settings,
                    action: { [weak self] in self?.onSetActionButton?() }),
            ])
    }

    func showSaveFailure(retry: @escaping () -> Void) {
        setInstruction(
            title: "Couldn’t create the offline example",
            actions: [
                .init(
                    title: "Try again",
                    image: UIImage(systemName: "arrow.clockwise"),
                    prominent: true,
                    action: retry),
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
    \(OnboardingLunaArticleCopy.fallbackHTMLBody)
    """
}

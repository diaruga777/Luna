//
//  SafariReplicaViewController.swift
//  Luna
//

import LunaDesignSystem
import UIKit
import WebKit

/// A deliberately noninteractive Safari facsimile used by each app's
/// onboarding. The page bytes are local; the browser chrome remains native
/// UIKit so it has the current OS's typography, glass, safe-area and status-bar
/// behavior.
@MainActor
final class SafariReplicaViewController: UIViewController, WKNavigationDelegate {
    var onSetUpSafari: (() -> Void)?
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
    private var instructionOverlay: DemoInstructionOverlay?
    private var actionCue: ActionButtonPressCue?
    private var waveAnimator: LiquidScreenWaveAnimator?
    private var didBeginDemonstration = false
    private var pageIndex = 0
    private var pageTimer: Timer?

    override var preferredStatusBarStyle: UIStatusBarStyle { .darkContent }

    init(configuration: OnboardingSurfaceConfiguration = .current) {
        self.onboardingConfiguration = configuration
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white
        configureBrowser()
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
                equalToConstant: SafariBottomBar.chromeHeight + 34),
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
        browserBar.setHost(page.displayedHost)
        guard let url = Bundle.main.url(
            forResource: page.resourceName, withExtension: "html")
        else {
            webView.loadHTMLString(Self.fallbackHTML, baseURL: nil)
            return
        }
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    private func startPageRotationIfNeeded() {
        guard onboardingConfiguration.demoPages.count > 1, pageTimer == nil else { return }
        pageTimer = Timer.scheduledTimer(
            withTimeInterval: OnboardingAnimationClock.delay(3.4),
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                UIView.animate(
                    withDuration: 0.18,
                    animations: { self.webView.alpha = 0.12 },
                    completion: { _ in
                        self.loadOfflinePage(at: self.pageIndex + 1)
                    })
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        UIView.animate(
            withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.28
        ) {
            webView.alpha = 1
        }
    }

    /// Starts only after the incoming card has expanded to the screen. Keeping
    /// the timeline explicit prevents the Action Button cue from playing while
    /// the browser is still changing geometry.
    func beginDemonstration() {
        guard !didBeginDemonstration else { return }
        didBeginDemonstration = true
        DispatchQueue.main.asyncAfter(
            deadline: .now() + OnboardingAnimationClock.delay(0.75)
        ) { [weak self] in
            self?.playActionButtonCue()
        }
    }

    private func playActionButtonCue() {
        guard let window = view.window else { return }
        let cue = ActionButtonPressCue()
        actionCue = cue
        window.addSubview(cue)
        cue.layout(in: window)
        cue.play { [weak self, weak cue] in
            let origin = cue?.waveOrigin
                ?? CGPoint(x: 0, y: window.safeAreaInsets.top + 107)
            cue?.removeFromSuperview()
            self?.actionCue = nil
            self?.playLiquidWave(origin: origin)
        }
    }

    private func playLiquidWave(origin: CGPoint) {
        guard let window = view.window else {
            showSafariPrompt()
            return
        }
        let animator = LiquidScreenWaveAnimator(window: window)
        waveAnimator = animator
        animator.play(
            origin: origin,
            midpoint: { [weak self] in self?.showSafariPrompt() },
            completion: { [weak self] in self?.waveAnimator = nil })
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

    func showShortcutAndActionSetup() {
        setInstruction(
            title: nil,
            actions: [
                .init(
                    title: "Install Shortcut",
                    image: OnboardingSystemIcons.shortcuts,
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
            overlay.alpha = 0
            UIView.animate(
                withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.34,
                delay: 0,
                options: [.curveEaseOut, .beginFromCurrentState]
            ) {
                overlay.alpha = 1
            }
        }
    }

    private static let fallbackHTML = """
    <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
    <style>body{font:17px -apple-system;margin:24px;color:#202122}h1{font:36px Georgia}</style>
    <h1>Luna</h1><p><b>Luna</b> commonly refers to Earth’s Moon and the ancient
    Roman personification of the Moon.</p><h2>Offline</h2>
    <p>This page is bundled with Luna for its onboarding demonstration.</p>
    """
}

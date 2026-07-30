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
    private let articleView = OnboardingArticleReplicaView()
    private let extensionCallout = OnboardingExtensionCalloutView()
    private let skipPill = UIButton(type: .system)
    private var isCalloutVisible = false
    private var instructionOverlay: DemoInstructionOverlay?
    private var didBeginDemonstration = false
    private var pageIndex = 0
    private var pageTimer: Timer?

    var hasInstructions: Bool { instructionOverlay != nil }
    override var sharedURLString: String {
        let pages = onboardingConfiguration.demoPages
        guard !pages.isEmpty else { return OnboardingDemoPage.lunaArticle.sharedURLString }
        return pages[pageIndex % pages.count].sharedURLString
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .darkContent }

    init(configuration: OnboardingSurfaceConfiguration = .current) {
        self.onboardingConfiguration = configuration
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        pageTimer?.invalidate()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = articleView.backgroundColor
        configureBrowser()
        configureExtensionCallout()
        webView.navigationDelegate = self
        loadOfflinePage(at: 0)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutExtensionCallout()
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
        articleView.translatesAutoresizingMaskIntoConstraints = false
        articleView.isHidden = true
        view.addSubview(articleView)
        browserBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(browserBar)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            articleView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            articleView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            articleView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            articleView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

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
        browserBar.setURL(
            page.sharedURLString,
            displayedHost: page.displayedHost)
        if page == .lunaArticle {
            webView.isHidden = true
            articleView.isHidden = false
            articleView.alpha = 1
            return
        }

        articleView.isHidden = true
        webView.isHidden = false
        dismissExtensionCallout()
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
        articleView.isHidden ? webView : articleView
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
        if onboardingConfiguration.demoPages[pageIndex] == .lunaArticle {
            articleView.start { [weak self] in
                self?.presentExtensionCallout()
            }
            return
        }
        DispatchQueue.main.asyncAfter(
            deadline: .now() + OnboardingAnimationClock.delay(0.75)
        ) { [weak self] in
            self?.replayActionButtonSaveEffect()
        }
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

    // MARK: - Extension callout

    private func configureExtensionCallout() {
        extensionCallout.alpha = 0
        extensionCallout.isHidden = true
        extensionCallout.onActivate = { [weak self] in
            self?.dismissExtensionCallout()
            self?.onSetUpSafari?()
        }
        view.addSubview(extensionCallout)

        var pillConfiguration: UIButton.Configuration
        if #available(iOS 26.0, *) {
            pillConfiguration = .glass()
        } else {
            pillConfiguration = .filled()
            pillConfiguration.baseBackgroundColor = UIColor(white: 0.22, alpha: 0.86)
        }
        pillConfiguration.title = "Skip"
        pillConfiguration.cornerStyle = .capsule
        pillConfiguration.baseForegroundColor = .white
        pillConfiguration.contentInsets = NSDirectionalEdgeInsets(
            top: 11, leading: 20, bottom: 11, trailing: 20)
        pillConfiguration.titleTextAttributesTransformer =
            UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.font = .systemFont(ofSize: 15, weight: .semibold)
                return outgoing
            }
        skipPill.configuration = pillConfiguration
        skipPill.accessibilityLabel = "Skip"
        skipPill.accessibilityIdentifier = "onboarding.safari.skipPill"
        skipPill.alpha = 0
        skipPill.isHidden = true
        skipPill.addTarget(
            self, action: #selector(skipPillTapped), for: .touchUpInside)
        view.addSubview(skipPill)
    }

    private func layoutExtensionCallout() {
        let barTop = view.bounds.height - SafariBottomBar.chromeHeight - 34
        let width = min(310, view.bounds.width - 108)
        let height = OnboardingExtensionCalloutView.preferredHeight
        // The arrow tip rests just above the URL bar's leading page-menu item.
        let frame = CGRect(
            x: 16,
            y: barTop - OnboardingExtensionCalloutView.arrowHeight - 2 - height,
            width: width,
            height: height)
        let anchorX = view.convert(
            browserBar.leadingAddressItemFrame, from: browserBar).midX
        extensionCallout.arrowAnchorX = anchorX - frame.minX
        // Growing out of the arrow tip needs the anchor there, so the frame is
        // expressed as bounds + anchored position.
        let anchor = CGPoint(
            x: extensionCallout.arrowAnchorX / frame.width,
            y: 1)
        extensionCallout.layer.anchorPoint = anchor
        extensionCallout.bounds = CGRect(origin: .zero, size: frame.size)
        extensionCallout.layer.position = CGPoint(
            x: frame.minX + anchor.x * frame.width,
            y: frame.maxY)

        let pillSize = skipPill.sizeThatFits(CGSize(width: 120, height: 44))
        let pillHeight = max(40, pillSize.height)
        skipPill.frame = CGRect(
            x: view.bounds.width - 16 - max(72, pillSize.width),
            y: barTop - 8 - pillHeight,
            width: max(72, pillSize.width),
            height: pillHeight)
    }

    /// The system-style popover grows out of the page-menu item once the
    /// cleanup has re-revealed the article; the Skip pill follows it in.
    func presentExtensionCallout() {
        layoutExtensionCallout()
        extensionCallout.setActionsEnabled(true)
        guard !isCalloutVisible else { return }
        isCalloutVisible = true
        extensionCallout.isHidden = false
        skipPill.isHidden = false
        view.bringSubviewToFront(extensionCallout)
        view.bringSubviewToFront(skipPill)

        if UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.2) {
                self.extensionCallout.alpha = 1
                self.skipPill.alpha = 1
            }
            return
        }
        extensionCallout.transform = CGAffineTransform(scaleX: 0.05, y: 0.05)
        skipPill.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
        UIView.animate(
            withDuration: 0.52,
            delay: 0,
            usingSpringWithDamping: 0.78,
            initialSpringVelocity: 0.3,
            options: [.curveEaseOut, .beginFromCurrentState]
        ) {
            self.extensionCallout.alpha = 1
            self.extensionCallout.transform = .identity
        }
        UIView.animate(
            withDuration: 0.34,
            delay: 0.24,
            usingSpringWithDamping: 0.8,
            initialSpringVelocity: 0.2,
            options: [.curveEaseOut, .beginFromCurrentState]
        ) {
            self.skipPill.alpha = 1
            self.skipPill.transform = .identity
        }
    }

    private func dismissExtensionCallout() {
        guard isCalloutVisible else { return }
        isCalloutVisible = false
        UIView.animate(
            withDuration: UIAccessibility.isReduceMotionEnabled ? 0.2 : 0.26,
            delay: 0,
            options: [.curveEaseIn, .beginFromCurrentState]
        ) {
            self.extensionCallout.alpha = 0
            self.skipPill.alpha = 0
            if !UIAccessibility.isReduceMotionEnabled {
                self.extensionCallout.transform = CGAffineTransform(
                    scaleX: 0.86, y: 0.86)
            }
        } completion: { _ in
            self.extensionCallout.isHidden = true
            self.extensionCallout.transform = .identity
            self.skipPill.isHidden = true
            self.skipPill.transform = .identity
        }
    }

    @objc private func skipPillTapped() {
        dismissExtensionCallout()
        onSetUpLater?()
    }

    /// Returning from a successfully running extension focuses the real item
    /// being saved before handing off to the shared URL-isolation transition.
    func playURLBarZoomAndSave() {
        browserBar.animateURLBarZoom { [weak self] in
            self?.replayActionButtonSaveEffect()
        }
    }

    func restoreInPageSafariSetup() {
        presentExtensionCallout()
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
                    image: OnboardingSystemIcons.shortcuts,
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
    <style>body{font:17px -apple-system;margin:24px;color:#202122}h1{font:36px Georgia}</style>
    <h1>Save anything in Safari</h1>
    <p>Your article, and your browsing history, all stay offline.</p>
    """
}

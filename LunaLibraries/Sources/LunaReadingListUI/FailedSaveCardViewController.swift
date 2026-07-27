//
//  FailedSaveCardViewController.swift
//  LunaReadingListUI
//

import LunaDesignSystem
import LunaModels
import UIKit
import WebKit

/// Everything a failed save's card shows and can do. Assembled by the app shell
/// (which alone can reach the failure sidecar, the rescue coordinator, and the
/// share provider) and rendered by `FailedSaveCardViewController` here, so every
/// app draws the SAME error card instead of each inventing one.
public struct FailedSaveCardModel {

    /// The reading-list item this card stands for. The card watches
    /// `.rescueProgressChanged` for this id so the eclipse bar advances without
    /// the host reloading its whole carousel several times a second.
    public var itemID: UUID
    /// The URL that failed. The card's whole content area is this page, loaded in
    /// a real `WKWebView` — a page that a background `URLSession` couldn't read
    /// very often renders fine in a web view with the user's own cookies, so
    /// showing it is both the explanation and the consolation prize.
    public var url: URL?
    /// The same URL as display text for the bar under the web view, scheme
    /// stripped. Shown in full: which link broke is the point.
    public var urlText: String
    /// Whether a rescue is running right now — the web view goes under a dimming
    /// overlay with the eclipse progress bar over it.
    public var isRescuing: Bool
    /// The running rescue's fraction, 0…1. Ignored unless `isRescuing`.
    public var progress: Double
    /// Whether the LLM rescue path is available at all (Apple Intelligence
    /// present, engine installed). False hides the button rather than offering a
    /// no-op.
    public var canRescue: Bool
    /// Whether this item's one Apple Intelligence attempt for THIS app version is
    /// already spent. True replaces the button with the apology and a Delete —
    /// the card has nothing left to offer until Luna itself changes.
    public var hasSpentAIAttempt: Bool

    public init(
        itemID: UUID, url: URL?, urlText: String,
        isRescuing: Bool = false, progress: Double = 0,
        canRescue: Bool = true, hasSpentAIAttempt: Bool = false
    ) {
        self.itemID = itemID
        self.url = url
        self.urlText = urlText
        self.isRescuing = isRescuing
        self.progress = progress
        self.canRescue = canRescue
        self.hasSpentAIAttempt = hasSpentAIAttempt
    }
}

/// What the card's buttons do. Injected closures, not a delegate: each root wires
/// them to its own store/share/rescue plumbing and the view stays free of every
/// tier above LunaDesignSystem.
public struct FailedSaveCardActions {
    /// Run the LLM rescue. Takes no hint — the model classifies the page itself
    /// (`RescueRequest.ContentHint.auto`), which is why the card has no picker.
    public var rescue: () -> Void
    /// Share the raw URL (a failed save has nothing else to share).
    public var share: (UIView) -> Void
    /// Delete the item. Offered only in the terminal state, where it's the only
    /// thing left to do.
    public var delete: () -> Void

    public init(
        rescue: @escaping () -> Void,
        share: @escaping (UIView) -> Void,
        delete: @escaping () -> Void
    ) {
        self.rescue = rescue
        self.share = share
        self.delete = delete
    }
}

/// The error state of a saved link, as a carousel card: the page itself in a
/// near-full-bleed web view, a URL bar with reload and share under it, and in the
/// chin the one thing worth trying — "Retry with AI".
///
/// Deliberately NOT playable and NOT tappable-through: a failed card's only
/// interactions are its own controls, so the carousel's tap/scrub gestures don't
/// fight them. Link taps inside the web view are also refused and re-presented
/// full screen, so the URL bar never lies about which page this card is.
public final class FailedSaveCardViewController: CardContentViewController {

    /// The web view is inset by just enough to clear the card's 22pt corner
    /// radius without any visible gutter — "almost full bleed".
    private static let webInset: CGFloat = 8
    private static let webCornerRadius: CGFloat = 14
    /// How dark the overlay gets while the rescue runs.
    private static let overlayOpacity: CGFloat = 0.4

    private var model: FailedSaveCardModel
    private let actions: FailedSaveCardActions
    /// The item's CURRENT state, recomputed on demand. Injected because the
    /// rescue coordinator and the failure sidecar both live a tier above this one.
    ///
    /// The card polls this rather than waiting to be rebuilt: neither carousel
    /// host rebuilds a card whose item didn't change identity or state, and a
    /// rescue that ends still-failed changes neither — so a card that relied on
    /// its host would keep the overlay up forever.
    private let stateProvider: () -> FailedSaveCardModel?

    private var progressObserver: NSObjectProtocol?
    /// The rescue reports ~7 stages over up to 90 seconds and the coordinator
    /// interpolates between them, so the bar needs its own tick to show that —
    /// and it's what notices the attempt ending.
    private var progressTicker: Timer?
    /// Set on the tap that starts a rescue and cleared once the coordinator
    /// confirms the attempt in flight. Between those two moments the provider
    /// still reports "not rescuing" (the coordinator starts on a task hop), and
    /// without this latch the next tick would tear the overlay straight back down.
    private var pendingRescueStart: Date?
    private var sawRescueInFlight = false
    /// How long the latch waits for confirmation before concluding the rescue
    /// never started (an unavailable engine declines synchronously and silently).
    private static let rescueStartGrace: TimeInterval = 6

    /// Created lazily: a carousel mounts the centered card plus its two peeks, and
    /// a `WKWebView` per mounted card is the expensive part of this design.
    private var webView: WKWebView?
    private let webContainer = UIView()
    /// Covers ONLY the web view while a rescue runs — the URL bar and its share
    /// button stay lit and usable underneath, per the card's contract.
    private let dimmingView = UIView()
    private let progressBar = EclipseProgressBar()

    private let urlBar = UIView()
    private let reloadButton = UIButton(type: .system)
    private let urlLabel = UILabel()
    private let shareButton = UIButton(type: .system)

    /// The chin: either the AI button, or (terminally) the apology + Delete.
    private let chinStack = UIStackView()
    private let rescueButton = UIButton(type: .system)
    private let apologyLabel = UILabel()
    private let deleteButton = UIButton(type: .system)

    private var hasStartedLoad = false

    public init(
        model: FailedSaveCardModel,
        actions: FailedSaveCardActions,
        stateProvider: @escaping () -> FailedSaveCardModel? = { nil }
    ) {
        self.model = model
        self.actions = actions
        self.stateProvider = stateProvider
        super.init()
    }

    deinit {
        progressTicker?.invalidate()
        if let progressObserver {
            NotificationCenter.default.removeObserver(progressObserver)
        }
    }

    /// The card's own interactions are its controls; a stray card tap would
    /// otherwise page or toggle playback under the user's finger.
    public override func allowsCardTap(at point: CGPoint) -> Bool { false }

    /// A long press over the page belongs to the web view (link previews, text
    /// selection); the card's own Share/Delete menu still lives on its chrome.
    public override func longPressSelectsContent(at point: CGPoint) -> Bool {
        webContainer.frame.contains(point)
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        buildHierarchy()
        observeProgress()
        apply(model)
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        loadPageIfNeeded()
    }

    /// Re-renders in place (a rescue started, advanced, or finished) so the host
    /// doesn't have to tear the card down and rebuild it mid-carousel.
    public func update(_ model: FailedSaveCardModel) {
        let urlChanged = model.url != self.model.url
        self.model = model
        guard isViewLoaded else { return }
        if urlChanged {
            hasStartedLoad = false
            loadPageIfNeeded()
        }
        apply(model)
    }

    // MARK: - Hierarchy

    private func buildHierarchy() {
        webContainer.backgroundColor = LunaColors.tertiaryBackground
        webContainer.layer.cornerRadius = Self.webCornerRadius
        webContainer.layer.cornerCurve = .continuous
        webContainer.clipsToBounds = true
        webContainer.translatesAutoresizingMaskIntoConstraints = false

        dimmingView.backgroundColor = UIColor.black.withAlphaComponent(Self.overlayOpacity)
        dimmingView.isHidden = true
        dimmingView.translatesAutoresizingMaskIntoConstraints = false
        // Swallows touches so the page can't be poked at mid-extraction, while the
        // URL bar below it — outside this view — stays live.
        dimmingView.isUserInteractionEnabled = true

        progressBar.translatesAutoresizingMaskIntoConstraints = false
        dimmingView.addSubview(progressBar)
        webContainer.addSubview(dimmingView)

        buildURLBar()
        buildChin()

        let stack = UIStackView(arrangedSubviews: [webContainer, urlBar, chinStack])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: Self.webInset),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Self.webInset),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Self.webInset),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14),

            dimmingView.topAnchor.constraint(equalTo: webContainer.topAnchor),
            dimmingView.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor),
            dimmingView.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
            dimmingView.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
            progressBar.centerYAnchor.constraint(equalTo: dimmingView.centerYAnchor),
            progressBar.leadingAnchor.constraint(equalTo: dimmingView.leadingAnchor, constant: 32),
            progressBar.trailingAnchor.constraint(equalTo: dimmingView.trailingAnchor, constant: -32),
        ])
    }

    private func buildURLBar() {
        urlBar.translatesAutoresizingMaskIntoConstraints = false

        configureBarButton(reloadButton, symbol: "arrow.clockwise",
                           label: L10n.string("Reload page"))
        reloadButton.addAction(UIAction { [weak self] _ in self?.reload() },
                               for: .touchUpInside)

        configureBarButton(shareButton, symbol: "square.and.arrow.up",
                           label: L10n.string("Share link"))
        shareButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.actions.share(self.shareButton)
        }, for: .touchUpInside)

        urlLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        urlLabel.textColor = LunaColors.secondaryText
        urlLabel.numberOfLines = 1
        // The tail of a URL (the slug) identifies the page; the head is mostly the
        // host, which the page itself is already showing.
        urlLabel.lineBreakMode = .byTruncatingMiddle
        urlLabel.textAlignment = .center

        let row = UIStackView(arrangedSubviews: [reloadButton, urlLabel, shareButton])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        urlBar.addSubview(row)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: urlBar.topAnchor),
            row.bottomAnchor.constraint(equalTo: urlBar.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: urlBar.leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(equalTo: urlBar.trailingAnchor, constant: -6),
        ])
    }

    private func buildChin() {
        rescueButton.configuration = Self.rescueConfiguration()
        rescueButton.contentHorizontalAlignment = .center
        rescueButton.addAction(UIAction { [weak self] _ in
            self?.beginRescue()
        }, for: .touchUpInside)

        apologyLabel.text = FailedSaveCopy.terminal
        apologyLabel.font = .preferredFont(forTextStyle: .footnote)
        apologyLabel.adjustsFontForContentSizeCategory = true
        apologyLabel.textColor = LunaColors.secondaryText
        apologyLabel.textAlignment = .center
        apologyLabel.numberOfLines = 2

        deleteButton.configuration = GlassStyle.actionButtonConfiguration(
            title: L10n.string("Delete"), symbol: "trash", compact: true)
        deleteButton.tintColor = LunaColors.errorAccent
        deleteButton.contentHorizontalAlignment = .center
        deleteButton.addAction(UIAction { [weak self] _ in
            self?.actions.delete()
        }, for: .touchUpInside)

        chinStack.axis = .vertical
        chinStack.spacing = 8
        chinStack.alignment = .fill
        for subview in [rescueButton, apologyLabel, deleteButton] {
            chinStack.addArrangedSubview(subview)
        }
    }

    /// A hairline-glass circular button for the URL bar's two ends.
    private func configureBarButton(_ button: UIButton, symbol: String, label: String) {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: symbol)
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            pointSize: 13, weight: .semibold)
        config.contentInsets = NSDirectionalEdgeInsets(
            top: 6, leading: 6, bottom: 6, trailing: 6)
        button.configuration = config
        button.tintColor = LunaColors.secondaryText
        button.accessibilityLabel = label
        button.setContentHuggingPriority(.required, for: .horizontal)
    }

    /// "Retry with AI ✦", styled by the one shared definition every error surface
    /// uses (`GlassStyle.retryWithAIConfiguration`).
    private static func rescueConfiguration() -> UIButton.Configuration {
        GlassStyle.retryWithAIConfiguration()
    }

    // MARK: - Web view

    private func loadPageIfNeeded() {
        guard !hasStartedLoad, let url = model.url else { return }
        hasStartedLoad = true
        let web = makeWebView()
        web.load(URLRequest(url: url))
    }

    private func makeWebView() -> WKWebView {
        if let webView { return webView }
        let configuration = WebJunkBlocker.makeConfiguration()
        // The user's own cookie store, deliberately: a page behind a wall the user
        // is already through is exactly the case where a background fetch failed
        // and a real web view succeeds.
        configuration.websiteDataStore = .default()
        let web = WKWebView(frame: webContainer.bounds, configuration: configuration)
        web.navigationDelegate = self
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.showsVerticalScrollIndicator = false
        // The carousel pages horizontally; a bouncing web view would fight it.
        web.scrollView.alwaysBounceHorizontal = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.translatesAutoresizingMaskIntoConstraints = false
        webContainer.insertSubview(web, belowSubview: dimmingView)
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: webContainer.topAnchor),
            web.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
        ])
        webView = web
        return web
    }

    private func reload() {
        guard !model.isRescuing else { return }
        guard let webView, webView.url != nil else {
            hasStartedLoad = false
            loadPageIfNeeded()
            return
        }
        webView.reload()
    }

    // MARK: - Rescue

    /// The overlay goes up on the TAP, not on the first progress report: the
    /// coordinator's work starts on a background executor and the user needs to
    /// see the press land immediately.
    private func beginRescue() {
        guard !model.isRescuing else { return }
        pendingRescueStart = Date()
        sawRescueInFlight = false
        model.isRescuing = true
        model.progress = RescueStage.queued.fraction
        progressBar.setProgress(Float(model.progress), animated: false)
        apply(model)
        actions.rescue()
    }

    /// Stage reports are per-item, so the card filters on its own id. Cheap
    /// enough to leave installed for the card's whole life — the notification
    /// only fires while some rescue is actually running.
    private func observeProgress() {
        progressObserver = NotificationCenter.default.addObserver(
            forName: .rescueProgressChanged, object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  note.userInfo?[RescueProgressKey.itemID] as? UUID == self.model.itemID
            else { return }
            self.refreshState()
        }
    }

    /// Re-reads the item's state and re-renders. This is how the overlay comes
    /// DOWN as well as how the bar advances: when the attempt ends the provider
    /// stops reporting a rescue, and the same read brings back whether the
    /// version's AI attempt is now spent — which is the terminal chin.
    private func refreshState() {
        guard var latest = stateProvider() else { return }
        if latest.isRescuing {
            sawRescueInFlight = true
            pendingRescueStart = nil
        } else if let started = pendingRescueStart {
            let gaveUp = sawRescueInFlight
                || Date().timeIntervalSince(started) > Self.rescueStartGrace
            if gaveUp {
                pendingRescueStart = nil
                sawRescueInFlight = false
            } else {
                // Still waiting for the coordinator to pick the attempt up; hold
                // the overlay the tap put there rather than flickering it away.
                latest.isRescuing = true
                latest.progress = max(model.progress, RescueStage.queued.fraction)
            }
        }
        model = latest
        apply(model)
    }

    private func updateProgressTicker(rescuing: Bool) {
        if rescuing, progressTicker == nil {
            let ticker = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) {
                [weak self] _ in self?.refreshState()
            }
            ticker.tolerance = 0.1
            progressTicker = ticker
        } else if !rescuing {
            progressTicker?.invalidate()
            progressTicker = nil
        }
    }

    // MARK: - Rendering

    private func apply(_ model: FailedSaveCardModel) {
        urlLabel.text = model.urlText

        let rescuing = model.isRescuing
        dimmingView.isHidden = !rescuing
        // The reload button is the one control the overlay disables — reloading
        // the page under a running extraction would pull the ground out from
        // under it. Share stays live: the URL is valid either way.
        reloadButton.isEnabled = !rescuing
        reloadButton.alpha = rescuing ? 0.4 : 1
        if rescuing {
            progressBar.setProgress(Float(model.progress), animated: true)
        }
        updateProgressTicker(rescuing: rescuing)

        // Two chin states: the offer, or (terminally) the apology + Delete.
        // A running rescue keeps the offer's button in place and merely disables
        // it — hiding it would collapse the chin and resize the web view under
        // the overlay, which reads as the card breaking rather than working.
        let terminal = model.hasSpentAIAttempt || !model.canRescue
        rescueButton.isHidden = terminal
        rescueButton.isEnabled = !rescuing
        rescueButton.alpha = rescuing ? 0.5 : 1
        apologyLabel.isHidden = !terminal
        deleteButton.isHidden = !terminal
    }
}

// MARK: - WKNavigationDelegate

extension FailedSaveCardViewController: WKNavigationDelegate {

    /// The card is a window onto ONE page — the URL bar under it names that page,
    /// and a tapped link that navigated in place would make the bar wrong. A link
    /// tap opens full screen instead, where there's chrome to explain where you
    /// are and a way back.
    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.navigationType == .linkActivated,
              let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        WebPageViewController.present(url: url, from: self)
    }
}

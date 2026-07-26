//
//  ProductSearchOverlayViewController.swift
//  LunaPriceUI
//

import LunaDesignSystem
import LunaHTMLClassification
import LunaPriceIngest
import LunaURLClassification
import UIKit
import WebKit

/// The outcome the host reports after attempting to add the overlay's current page
/// as a seller. Drives the overlay's exit behavior: a successful add dismisses the
/// overlay (returning to the price-tracker page); a failure keeps it open and shows
/// a clear, visible message — never a silent no-op.
public enum ProductSearchAddOutcome {
    /// The page was added (price resolved + store upserted). The overlay dismisses.
    case added
    /// No price could be extracted from the page. The overlay shows a "couldn't find
    /// a price" message and stays open so the user can pick another page.
    case noPrice
    /// The page is already a seller for this tracker. The overlay shows a message and
    /// stays open.
    case duplicate
}

/// Reports the overlay's confirmed "Use this page?" pick to its host. The host
/// performs the mandatory price fetch + dedupe + add and MUST call `completion`
/// with the outcome so the overlay can dismiss on success or show a clear
/// message on failure (never a silent no-op).
public protocol ProductSearchOverlayDelegate: AnyObject {
    func productSearchOverlay(
        _ overlay: ProductSearchOverlayViewController,
        didConfirmPage urlString: String, html: String,
        completion: @escaping (ProductSearchAddOutcome) -> Void)
}

/// A near-fullscreen web search/browse overlay for adding a seller to a price
/// tracker, styled like the inline reader (`SplitWebOverlayViewController`): a themed
/// `WKWebView` inside an inset rounded glass card, compact close/Safari tabs above it,
/// and a bottom URL bar with back/forward controls and a circular "+" to add the
/// current page.
///
/// It preloads a Google Shopping search for the product, lets the user browse/type
/// freely, and offers two ways to add the page being viewed as a seller:
/// - tapping the "+" button → a "Use this page?" confirmation, or
/// - **auto-detection**: when a page finishes loading and the UNIFIED
///   `ProductPageSuggestion` (same `Classifier` + `ProductMetadataExtractor` the
///   ingest pipeline uses) says the rendered page is a product WITH a price, the same
///   confirmation is presented automatically — debounced per-URL via
///   `ProductSuggestionDebouncer` so it never re-fires for the same page.
///
/// The overlay never touches the reading-list store: when the user confirms, it
/// hands the current URL + its rendered HTML up via `delegate` and AWAITS the
/// host's `ProductSearchAddOutcome`. On `.added` the overlay dismisses (returning to
/// the tracker); on `.noPrice`/`.duplicate` it shows a message and stays open.
///
/// The bottom URL bar is pinned to `view.keyboardLayoutGuide.topAnchor` (high
/// priority) with a safe-area cap, so it rides up just above the keyboard while the
/// user types and drops back when the keyboard dismisses — the field stays visible
/// and usable the whole time.
public final class ProductSearchOverlayViewController: UIViewController, WKNavigationDelegate,
    UITextFieldDelegate, WKScriptMessageHandler, UIViewControllerTransitioningDelegate {

    public weak var delegate: ProductSearchOverlayDelegate?

    private let initialURL: URL
    private let trackedProduct: ProductInfo
    private let eclipseSourcePointInWindow: CGPoint?
    private let eclipseSceneFrameInWindow: CGRect?

    private let dimView = UIView()
    private let card = UIView()
    private let cardShadow = UIView()
    private let topTabs = UIView()
    private let closeTab = UIVisualEffectView(effect: GlassStyle.barEffect())
    private let safariTab = UIVisualEffectView(effect: GlassStyle.barEffect())
    private let closeButton = UIButton(type: .system)
    private let safariButton = UIButton(type: .system)
    private let backButton = UIButton(type: .system)
    private let forwardButton = UIButton(type: .system)

    private let bottomBar = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    private let urlField = UITextField()
    private let addButton = UIButton(type: .system)

    private var webView: WKWebView?

    /// Per-URL debounce so auto-suggest fires at most once per page.
    private var suggestionDebouncer = ProductSuggestionDebouncer()
    /// True while a "Use this page?" alert is on screen, so a finishing navigation
    /// doesn't stack a second one.
    private var isOfferingUseThisPage = false
    /// Product metadata often arrives after WebKit's initial completion for
    /// JavaScript storefronts. Cancel these checks on navigation so a stale page
    /// cannot offer itself as the current seller.
    private var productDetectionWorkItems: [DispatchWorkItem] = []

    /// The bridge observes Google Shopping's selected-item popover, which changes
    /// the DOM without committing a WebKit navigation. It reports the first visible
    /// merchant CTA from that popover, never a Google URL.
    private static let googleShoppingSellerMessageName = "puttyGoogleShoppingSeller"

    private static let cardInset: CGFloat = 12
    private static let cardCornerRadius: CGFloat = 26
    private static let topTabHeight: CGFloat = 38
    private static let bottomBarHeight: CGFloat = 60
    private static let buttonSize: CGFloat = 40
    private static let buttonInset: CGFloat = 14

    public init(
        initialURL: URL,
        trackedProduct: ProductInfo,
        eclipseSourcePointInWindow: CGPoint? = nil,
        eclipseSceneFrameInWindow: CGRect? = nil
    ) {
        self.initialURL = initialURL
        self.trackedProduct = trackedProduct
        self.eclipseSourcePointInWindow = eclipseSourcePointInWindow
        self.eclipseSceneFrameInWindow = eclipseSceneFrameInWindow
        super.init(nibName: nil, bundle: nil)
        if eclipseSourcePointInWindow != nil {
            modalPresentationStyle = .custom
            transitioningDelegate = self
        } else {
            modalPresentationStyle = .overFullScreen
        }
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        dimView.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        dimView.frame = view.bounds
        dimView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(dimView)

        cardShadow.backgroundColor = .clear
        cardShadow.layer.shadowColor = UIColor.black.cgColor
        cardShadow.layer.shadowOpacity = 0.22
        cardShadow.layer.shadowRadius = 18
        cardShadow.layer.shadowOffset = CGSize(width: 0, height: 6)
        view.addSubview(cardShadow)

        card.backgroundColor = ReaderDepth.backgroundColor(for: 0)
        card.layer.cornerRadius = Self.cardCornerRadius
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 0.5
        card.layer.borderColor = LunaColors.separator.withAlphaComponent(0.6).cgColor
        card.clipsToBounds = true
        view.addSubview(card)

        configureWebView()
        configureTopTabs()
        configureBottomBar()
        loadURL(initialURL)
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let frame = cardFrame
        card.frame = frame
        cardShadow.frame = frame
        cardShadow.layer.shadowPath = UIBezierPath(
            roundedRect: CGRect(origin: .zero, size: frame.size),
            cornerRadius: Self.cardCornerRadius).cgPath
        layoutCardContents()
    }

    private var cardFrame: CGRect {
        let top = view.safeAreaInsets.top + 8 + Self.topTabHeight - 4
        let bottom = view.bounds.height - view.safeAreaInsets.bottom - 8
        return CGRect(x: Self.cardInset, y: top,
                      width: view.bounds.width - Self.cardInset * 2, height: max(bottom - top, 0))
    }

    // MARK: - Web view

    private func configureWebView() {
        let configuration = WebJunkBlocker.makeConfiguration()
        configuration.userContentController.add(
            WeakScriptMessageHandler(target: self), name: Self.googleShoppingSellerMessageName)
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.googleShoppingSellerObserver,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true))
        let webView = WKWebView(frame: .zero, configuration: configuration)
        self.webView = webView
        let themed = ReaderDepth.backgroundColor(for: 0)
        webView.isOpaque = false
        webView.backgroundColor = themed
        webView.scrollView.backgroundColor = themed
        webView.underPageBackgroundColor = themed
        webView.scrollView.contentInset.bottom = Self.bottomBarHeight
        webView.navigationDelegate = self
        card.addSubview(webView)
    }

    private func loadURL(_ url: URL) {
        webView?.load(URLRequest(url: url))
        urlField.text = url.absoluteString
    }

    // MARK: - Chrome

    private func configureTopTabs() {
        topTabs.backgroundColor = .clear
        view.addSubview(topTabs)

        for tab in [closeTab, safariTab] {
            tab.clipsToBounds = true
            tab.layer.cornerRadius = 12
            tab.layer.cornerCurve = .continuous
            topTabs.addSubview(tab)
        }
        closeButton.configuration = GlassStyle.circularButtonConfiguration(symbol: "xmark")
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.accessibilityLabel = "Close"
        closeTab.contentView.addSubview(closeButton)

        safariButton.configuration = GlassStyle.circularButtonConfiguration(symbol: "safari")
        safariButton.addTarget(self, action: #selector(openInSafariTapped), for: .touchUpInside)
        safariButton.accessibilityLabel = "Open in Safari"
        safariTab.contentView.addSubview(safariButton)

        backButton.configuration = GlassStyle.circularButtonConfiguration(symbol: "chevron.backward")
        backButton.addTarget(self, action: #selector(goBackTapped), for: .touchUpInside)

        forwardButton.configuration = GlassStyle.circularButtonConfiguration(symbol: "chevron.forward")
        forwardButton.addTarget(self, action: #selector(goForwardTapped), for: .touchUpInside)

        updateNavButtons()
    }

    private func configureBottomBar() {
        bottomBar.clipsToBounds = true
        bottomBar.layer.cornerRadius = Self.cardCornerRadius
        bottomBar.layer.cornerCurve = .continuous
        bottomBar.layer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        // The bar is a direct child of the root view (NOT the card) so it can be
        // pinned to the keyboard layout guide and ride above the keyboard. It is
        // visually flush with the card's bottom when the keyboard is down.
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bottomBar)

        urlField.borderStyle = .roundedRect
        urlField.font = .preferredFont(forTextStyle: .footnote)
        urlField.autocapitalizationType = .none
        urlField.autocorrectionType = .no
        urlField.keyboardType = .URL
        urlField.clearButtonMode = .whileEditing
        urlField.returnKeyType = .go
        urlField.placeholder = "Search or enter a URL"
        urlField.delegate = self
        bottomBar.contentView.addSubview(backButton)
        bottomBar.contentView.addSubview(forwardButton)
        bottomBar.contentView.addSubview(urlField)

        var addConfiguration = GlassStyle.circularButtonConfiguration(symbol: "plus")
        addConfiguration.baseForegroundColor = LunaSurfacePalette.baseColor(for: .priceTracker)
        addButton.configuration = addConfiguration
        addButton.addTarget(self, action: #selector(addTapped), for: .touchUpInside)
        bottomBar.contentView.addSubview(addButton)

        // Rise above the keyboard while typing (the guide tracks the real keyboard
        // frame); cap above the bottom safe area when the keyboard is down. High
        // priority so the keyboard guide wins over the cap exactly when the keyboard
        // is up.
        let aboveKeyboard = bottomBar.bottomAnchor.constraint(
            equalTo: view.keyboardLayoutGuide.topAnchor)
        aboveKeyboard.priority = .required
        let cap = bottomBar.bottomAnchor.constraint(
            lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8)
        NSLayoutConstraint.activate([
            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Self.cardInset),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Self.cardInset),
            bottomBar.heightAnchor.constraint(equalToConstant: Self.bottomBarHeight),
            aboveKeyboard,
            cap,
        ])
    }

    private func layoutCardContents() {
        webView?.frame = card.bounds
        let s = Self.buttonSize
        let tabY = view.safeAreaInsets.top + 8
        topTabs.frame = CGRect(
            x: Self.cardInset, y: tabY,
            width: view.bounds.width - Self.cardInset * 2, height: Self.topTabHeight)
        closeTab.frame = CGRect(x: 0, y: 0, width: 50, height: Self.topTabHeight)
        safariTab.frame = CGRect(
            x: topTabs.bounds.width - 50, y: 0, width: 50, height: Self.topTabHeight)
        closeButton.frame = CGRect(
            x: 6, y: (Self.topTabHeight - 34) / 2, width: 34, height: 34)
        safariButton.frame = CGRect(
            x: 10, y: (Self.topTabHeight - 34) / 2, width: 34, height: 34)

        let by = (Self.bottomBarHeight - s) / 2
        backButton.frame = CGRect(x: 8, y: by, width: s, height: s)
        forwardButton.frame = CGRect(x: backButton.frame.maxX + 2, y: by, width: s, height: s)
        addButton.frame = CGRect(
            x: bottomBar.bounds.width - Self.buttonInset - s, y: by, width: s, height: s)
        urlField.frame = CGRect(
            x: forwardButton.frame.maxX + 5, y: (Self.bottomBarHeight - 36) / 2,
            width: addButton.frame.minX - 8 - (forwardButton.frame.maxX + 5), height: 36)
    }

    private func updateNavButtons() {
        backButton.isEnabled = webView?.canGoBack ?? false
        forwardButton.isEnabled = webView?.canGoForward ?? false
    }

    // MARK: - Actions

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    @objc private func openInSafariTapped() {
        guard let url = webView?.url else { return }
        UIApplication.shared.open(url)
    }

    @objc private func goBackTapped() { webView?.goBack() }
    @objc private func goForwardTapped() { webView?.goForward() }

    @objc private func addTapped() {
        offerUseThisPage()
    }

    public func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        guard let url = ProductSearchURL.navigationURL(fromBarText: textField.text ?? "") else {
            return true
        }
        loadURL(url)
        return true
    }

    /// Presents the "Use this page?" confirmation. On "Add to tracker" it reads the
    /// page's rendered HTML and hands it (with the current URL) up to the host.
    private func offerUseThisPage() {
        guard let webView, let url = webView.url else { return }
        offerUseThisPage(urlString: url.absoluteString, html: nil)
    }

    /// Presents the same confirmation as the + button. Auto-detection supplies the
    /// pipeline's canonical seller URL and HTML; manual + keeps reading the live
    /// page at confirmation time.
    private func offerUseThisPage(urlString: String, html: String?) {
        guard !isOfferingUseThisPage else { return }
        isOfferingUseThisPage = true
        let alert = UIAlertController(
            title: "Use this page?",
            message: "Add this page as a seller for this product.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Add to tracker", style: .default) { [weak self] _ in
            self?.isOfferingUseThisPage = false
            self?.handleAddCurrentPage(urlString: urlString, prefetchedHTML: html)
        })
        alert.addAction(UIAlertAction(title: "No thanks", style: .cancel) { [weak self] _ in
            self?.isOfferingUseThisPage = false
        })
        present(alert, animated: true)
    }

    /// Reads the rendered HTML and hands it to the host, then routes the host's
    /// outcome to the overlay's exit behavior (dismiss on success, message otherwise).
    private func handleAddCurrentPage(urlString: String, prefetchedHTML: String?) {
        if let prefetchedHTML {
            delegate?.productSearchOverlay(self, didConfirmPage: urlString, html: prefetchedHTML) {
                [weak self] outcome in
                self?.handleAddOutcome(outcome)
            }
            return
        }
        webView?.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] result, _ in
            guard let self else { return }
            let html = (result as? String) ?? ""
            self.delegate?.productSearchOverlay(self, didConfirmPage: urlString, html: html) {
                [weak self] outcome in
                self?.handleAddOutcome(outcome)
            }
        }
    }

    /// Applies the host's add outcome: dismiss + return to the tracker on success,
    /// otherwise a clear visible message so the user is never left wondering.
    private func handleAddOutcome(_ outcome: ProductSearchAddOutcome) {
        switch outcome {
        case .added:
            dismiss(animated: true)
        case .noPrice:
            presentPriceMessage(
                title: "Couldn't find a price",
                message: "We couldn't find a price on this page, so it wasn't added. "
                    + "Try a product page that shows a price.")
        case .duplicate:
            presentPriceMessage(
                title: "Already tracked",
                message: "This page is already a seller for this product.")
        }
    }


    // MARK: - WKNavigationDelegate

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        updateNavButtons()
        if let current = webView.url?.absoluteString { urlField.text = current }
        scheduleProductDetection(for: webView, delays: [0, 0.35, 1.1, 2.5, 5])
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        cancelProductDetection()
        updateNavButtons()
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        scheduleProductDetection(for: webView, delays: [0.15])
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        updateNavButtons()
    }

    public func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
    ) { updateNavButtons() }

    /// Reads the finished page's rendered HTML and, if the UNIFIED
    /// `ProductPageSuggestion` says it's a product WITH a resolvable price (the exact
    /// condition under which Add succeeds), auto-presents "Use this page?".
    /// Debounced per-URL so it fires once per page.
    private func autoDetectProductIfNeeded(in webView: WKWebView) {
        guard let url = webView.url,
              !suggestionDebouncer.hasOffered(urlString: url.absoluteString),
              !isOfferingUseThisPage else { return }
        webView.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] result, _ in
            guard let self, let html = result as? String else { return }
            Task { [weak self] in
                guard let self else { return }
                let suggestion = await ProductPageSuggestion.resolve(url: url, html: html)
                await MainActor.run {
                guard let suggestion,
                      webView.url == url,
                      Self.matchesTrackedProduct(suggestion.metadata, tracked: self.trackedProduct),
                          !self.isOfferingUseThisPage,
                          self.suggestionDebouncer.shouldOffer(urlString: suggestion.url.absoluteString)
                    else { return }
                    self.offerUseThisPage(urlString: suggestion.url.absoluteString, html: suggestion.html)
                }
            }
        }
    }

    /// Re-checks the live DOM while a page hydrates, while preserving the existing
    /// unified suggestion pipeline and one-prompt-per-URL debounce.
    private func scheduleProductDetection(for webView: WKWebView, delays: [TimeInterval]) {
        cancelProductDetection()
        for delay in delays {
            let work = DispatchWorkItem { [weak self, weak webView] in
                guard let self, let webView else { return }
                self.autoDetectProductIfNeeded(in: webView)
            }
            productDetectionWorkItems.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func cancelProductDetection() {
        productDetectionWorkItems.forEach { $0.cancel() }
        productDetectionWorkItems.removeAll()
    }

    // MARK: - Google Shopping selected-item popovers

    public func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == Self.googleShoppingSellerMessageName,
              let urlString = message.body as? String,
              let url = URL(string: urlString),
              !isOfferingUseThisPage,
              !suggestionDebouncer.hasOffered(urlString: urlString) else { return }
        processSellerCandidate(url)
    }

    /// A Google result detail is not a navigation: its HTML describes Google, not
    /// the seller. Process the first merchant URL independently through the shared
    /// pipeline, then present exactly the same confirmation as a + tap.
    private func processSellerCandidate(_ url: URL) {
        Task { [weak self] in
            guard let self else { return }
            let suggestion = await ProductPageSuggestion.resolve(url: url)
            await MainActor.run {
                guard let suggestion,
                      Self.matchesTrackedProduct(suggestion.metadata, tracked: self.trackedProduct),
                      !self.isOfferingUseThisPage,
                      self.suggestionDebouncer.shouldOffer(urlString: suggestion.url.absoluteString)
                else { return }
                self.offerUseThisPage(urlString: suggestion.url.absoluteString, html: suggestion.html)
            }
        }
    }

    private static let googleShoppingSellerObserver = #"""
    (() => {
      if (!/(^|\.)google\.[a-z.]+$/i.test(location.hostname)) return;
      const message = 'puttyGoogleShoppingSeller';
      let lastSeller = '';
      const visible = element => {
        const style = getComputedStyle(element);
        return style.display !== 'none' && style.visibility !== 'hidden' && element.getClientRects().length > 0;
      };
      const destination = href => {
        try {
          const url = new URL(href, location.href);
          if (!/(^|\.)google\.[a-z.]+$/i.test(url.hostname)) return url.href;
          for (const key of ['url', 'q', 'adurl']) {
            const value = url.searchParams.get(key);
            if (value && /^https?:/i.test(value)) return value;
          }
        } catch (_) {}
        return '';
      };
      const findSeller = () => {
        const dialogs = [...document.querySelectorAll('[role="dialog"], [aria-modal="true"]')]
          .filter(visible);
        // Google changes its detail-panel accessibility markup frequently. Prefer a
        // dialog when it exists, but after a product-card tap fall back to the page
        // so the selected panel still works when it has no dialog role.
        const roots = dialogs.length ? dialogs : [document.body];
        for (const root of roots) {
          const links = [...root.querySelectorAll('a[href]')].filter(visible);
          const merchantCTA = links.find(link => /^(visit site|go to (store|site)|shop now|buy now)$/i.test((link.innerText || '').trim()));
          const seller = merchantCTA || links.find(link => destination(link.href));
          if (seller) {
            const url = destination(seller.href);
            if (url) return url;
          }
        }
        return '';
      };
      let queued = false;
      let userSelectedItem = false;
      const inspect = () => {
        if (!userSelectedItem) return;
        if (queued) return;
        queued = true;
        setTimeout(() => {
          queued = false;
          const seller = findSeller();
          if (seller && seller !== lastSeller) {
            lastSeller = seller;
            window.webkit.messageHandlers[message].postMessage(seller);
          }
        }, 150);
      };
      new MutationObserver(inspect).observe(document.documentElement, { childList: true, subtree: true, attributes: true });
      document.addEventListener('click', () => {
        userSelectedItem = true;
        inspect();
      }, true);
    })();
    """#

    deinit {
        productDetectionWorkItems.forEach { $0.cancel() }
        webView?.configuration.userContentController.removeScriptMessageHandler(
            forName: Self.googleShoppingSellerMessageName)
    }

    /// A seller suggestion must be for the tracker currently being edited, not just
    /// any priced product reached from a shopping search.
    private static func matchesTrackedProduct(_ metadata: ProductMetadata, tracked: ProductInfo) -> Bool {
        let candidate = ProductInfo(
            name: metadata.name, priceAmount: metadata.price.amount,
            priceCurrency: metadata.price.currency, imageURL: metadata.imageURL,
            brand: metadata.brand, productID: metadata.productID)
        if let candidateID = ProductMatcher.normalizedID(candidate.productID),
           candidateID == ProductMatcher.normalizedID(tracked.productID) {
            return true
        }
        return ProductMatcher.brandsCompatible(candidate.brand, tracked.brand)
            && ProductMatcher.nameSimilarity(candidate.name, tracked.name) >= ProductMatcher.nameThreshold
    }

    // MARK: - Card eclipse presentation

    public func presentationController(
        forPresented presented: UIViewController,
        presenting: UIViewController?,
        source: UIViewController
    ) -> UIPresentationController? {
        ProductSearchPresentationController(
            presentedViewController: presented, presenting: presenting)
    }

    public func animationController(
        forPresented presented: UIViewController,
        presenting: UIViewController,
        source: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        guard let point = eclipseSourcePointInWindow else { return nil }
        return ProductSearchEclipseAnimator(
            sourcePointInWindow: point,
            sceneFrameInWindow: eclipseSceneFrameInWindow,
            direction: .forward)
    }

    public func animationController(
        forDismissed dismissed: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        guard let point = eclipseSourcePointInWindow else { return nil }
        return ProductSearchEclipseAnimator(
            sourcePointInWindow: point,
            sceneFrameInWindow: eclipseSceneFrameInWindow,
            direction: .reverse)
    }
}

private final class ProductSearchPresentationController: UIPresentationController {
    override var frameOfPresentedViewInContainerView: CGRect {
        containerView?.bounds ?? .zero
    }

    override var shouldRemovePresentersView: Bool { false }
}

/// The Price Tracker's seller browser uses the same eclipse vocabulary as the
/// Reader's inline page: a touch-sized black moon expands while a second dark
/// surface rises from below, then the web card appears at totality.
private final class ProductSearchEclipseAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    enum Direction { case forward, reverse }

    private let sourcePointInWindow: CGPoint
    private let sceneFrameInWindow: CGRect?
    private let direction: Direction

    init(
        sourcePointInWindow: CGPoint,
        sceneFrameInWindow: CGRect?,
        direction: Direction
    ) {
        self.sourcePointInWindow = sourcePointInWindow
        self.sceneFrameInWindow = sceneFrameInWindow
        self.direction = direction
    }

    func transitionDuration(
        using transitionContext: UIViewControllerContextTransitioning?
    ) -> TimeInterval {
        CardEclipseTransition.duration
    }

    func animateTransition(using context: UIViewControllerContextTransitioning) {
        guard let fromController = context.viewController(forKey: .from),
              let toController = context.viewController(forKey: .to)
        else {
            context.completeTransition(false)
            return
        }
        let container = context.containerView
        let fromView = context.view(forKey: .from) ?? fromController.view!
        let toView = context.view(forKey: .to) ?? toController.view!
        let finalFrame = context.finalFrame(for: toController)
        toView.frame = finalFrame.isEmpty ? container.bounds : finalFrame

        let sceneFrame = sceneFrameInWindow.map { container.convert($0, from: nil) }
            ?? container.bounds.insetBy(dx: 12, dy: 12)
        let sourcePoint = container.convert(sourcePointInWindow, from: nil)

        switch direction {
        case .forward:
            toView.alpha = 0
            container.addSubview(toView)
            container.bringSubviewToFront(fromView)
            animateScene(
                in: container, frame: sceneFrame, sourcePoint: sourcePoint,
                reverse: false, outgoingView: nil,
                atZenith: {
                    container.bringSubviewToFront(toView)
                    UIView.animate(withDuration: 0.14) { toView.alpha = 1 }
                },
                completion: {
                    context.completeTransition(!context.transitionWasCancelled)
                })
        case .reverse:
            toView.alpha = 1
            if toView.window == nil, toView.superview == nil {
                container.insertSubview(toView, belowSubview: fromView)
            }
            animateScene(
                in: container, frame: sceneFrame, sourcePoint: sourcePoint,
                reverse: true, outgoingView: fromView,
                atZenith: {},
                completion: {
                    fromView.alpha = 1
                    context.completeTransition(!context.transitionWasCancelled)
                })
        }
    }

    private func animateScene(
        in container: UIView,
        frame: CGRect,
        sourcePoint: CGPoint,
        reverse: Bool,
        outgoingView: UIView?,
        atZenith: @escaping () -> Void,
        completion: @escaping () -> Void
    ) {
        let surface = UIView(frame: frame)
        surface.isUserInteractionEnabled = false
        surface.clipsToBounds = false
        container.addSubview(surface)

        let corona = CardEclipseTransition.makeCorona(frame: surface.bounds)
        corona.alpha = reverse ? 1 : 0
        surface.addSubview(corona)

        let clipped = UIView(frame: surface.bounds)
        clipped.clipsToBounds = true
        clipped.layer.cornerRadius = CardSurfaceView.cornerRadius
        clipped.layer.cornerCurve = .continuous
        surface.addSubview(clipped)

        let localPoint = CGPoint(
            x: min(max(sourcePoint.x - frame.minX, 0), frame.width),
            y: min(max(sourcePoint.y - frame.minY, 0), frame.height))
        let circle = UIView(frame: CGRect(x: 0, y: 0, width: 2, height: 2))
        circle.center = localPoint
        circle.backgroundColor = .black
        circle.layer.cornerRadius = 1
        clipped.addSubview(circle)

        let eclipse = UIView(frame: surface.bounds)
        eclipse.backgroundColor = .black
        eclipse.layer.cornerRadius = reverse ? 0 : 30
        eclipse.layer.cornerCurve = .continuous
        eclipse.transform = reverse
            ? .identity
            : CGAffineTransform(translationX: 0, y: surface.bounds.height * 0.34)
        eclipse.alpha = reverse ? 1 : 0
        clipped.addSubview(eclipse)

        let flare = EclipseFlareView(frame: CGRect(x: 0, y: 0, width: 130, height: 130))
        flare.center = CGPoint(x: eclipse.bounds.midX, y: 0)
        flare.alpha = reverse ? 1 : 0
        flare.transform = reverse
            ? .identity
            : CGAffineTransform(scaleX: 0.45, y: 0.45)
        eclipse.addSubview(flare)

        let farthestX = max(localPoint.x, surface.bounds.width - localPoint.x)
        let farthestY = max(localPoint.y, surface.bounds.height - localPoint.y)
        let diameter = hypot(farthestX, farthestY) * 2 + 8

        if reverse {
            circle.transform = CGAffineTransform(scaleX: diameter / 2, y: diameter / 2)
            container.bringSubviewToFront(outgoingView ?? surface)
            UIView.animate(
                withDuration: UIAccessibility.isReduceMotionEnabled ? 0.1 : 0.15,
                animations: { outgoingView?.alpha = 0 }
            ) { _ in
                container.bringSubviewToFront(surface)
                atZenith()
                UIView.animate(
                    withDuration: UIAccessibility.isReduceMotionEnabled
                        ? 0.1 : CardEclipseTransition.duration * 0.66,
                    animations: {
                        corona.alpha = 0
                        flare.alpha = 0
                        circle.transform = .identity
                        eclipse.transform = CGAffineTransform(
                            translationX: 0, y: surface.bounds.height * 0.34)
                        eclipse.alpha = 0
                        eclipse.layer.cornerRadius = 30
                    },
                    completion: { _ in surface.removeFromSuperview(); completion() })
            }
            return
        }

        UIView.animateKeyframes(
            withDuration: UIAccessibility.isReduceMotionEnabled
                ? 0.2 : CardEclipseTransition.duration * 0.66,
            delay: 0,
            options: [.calculationModeCubic, .beginFromCurrentState],
            animations: {
                UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 1) {
                    circle.transform = CGAffineTransform(
                        scaleX: diameter / 2, y: diameter / 2)
                    eclipse.transform = .identity
                    eclipse.alpha = 1
                    eclipse.layer.cornerRadius = 0
                }
                UIView.addKeyframe(withRelativeStartTime: 0.8, relativeDuration: 0.2) {
                    corona.alpha = 1
                    flare.alpha = 1
                    flare.transform = .identity
                }
            },
            completion: { _ in
                atZenith()
                UIView.animate(
                    withDuration: UIAccessibility.isReduceMotionEnabled
                        ? 0.1 : CardEclipseTransition.duration * 0.34,
                    animations: {
                        corona.alpha = 0
                        flare.alpha = 0
                        eclipse.alpha = 0
                        circle.alpha = 0
                    },
                    completion: { _ in surface.removeFromSuperview(); completion() })
            })
    }
}

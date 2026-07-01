//
//  ProductSearchOverlayViewController.swift
//  Luna
//

import LunaReaderUI
import LunaDesignSystem
import LunaHTMLClassification
import LunaURLClassification
import LunaTransitions
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

/// A near-fullscreen web search/browse overlay for adding a seller to a price
/// tracker, styled like the inline reader (`SplitWebOverlayViewController`): a themed
/// `WKWebView` inside an inset rounded glass card with a glass header (close +
/// back/forward), and a bottom URL bar with a circular "+" to add the current page.
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
/// hands the current URL + its rendered HTML up via `onUseThisPage` and AWAITS the
/// host's `ProductSearchAddOutcome`. On `.added` the overlay dismisses (returning to
/// the tracker); on `.noPrice`/`.duplicate` it shows a message and stays open.
///
/// The bottom URL bar is pinned to `view.keyboardLayoutGuide.topAnchor` (high
/// priority) with a safe-area cap, so it rides up just above the keyboard while the
/// user types and drops back when the keyboard dismisses — the field stays visible
/// and usable the whole time (the same pattern as `SearchViewController`).
public final class ProductSearchOverlayViewController: UIViewController, WKNavigationDelegate, UITextFieldDelegate,
    WKScriptMessageHandler {

    /// Called when the user confirms "Add to tracker" for the current page. `html` is
    /// the page's rendered `outerHTML` (the host reuses it for the fast price path).
    /// The host performs the mandatory price fetch + dedupe + add and MUST call
    /// `completion` with the outcome so the overlay can dismiss on success or show a
    /// clear message on failure (never a silent no-op).
    public var onUseThisPage: ((_ urlString: String, _ html: String,
                         _ completion: @escaping (ProductSearchAddOutcome) -> Void) -> Void)?

    private let initialURL: URL
    private let trackedProduct: ProductInfo

    private let dimView = UIView()
    private let card = UIView()
    private let cardShadow = UIView()
    private let header = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    private let closeButton = UIButton(type: .system)
    private let backButton = UIButton(type: .system)
    private let forwardButton = UIButton(type: .system)
    private let titleLabel = UILabel()

    private let bottomBar = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    private let urlField = UITextField()
    private let addButton = UIButton(type: .system)

    private var webView: WKWebView?

    /// Pins the bottom bar above the keyboard (high priority); a safe-area cap keeps
    /// it above the home indicator when the keyboard is down. Auto Layout so the bar
    /// animates with the keyboard — the URL field is never covered while typing.
    private var bottomBarBottomCap: NSLayoutConstraint?

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
    private static let headerHeight: CGFloat = 60
    private static let bottomBarHeight: CGFloat = 60
    private static let buttonSize: CGFloat = 40
    private static let buttonInset: CGFloat = 14

    public init(initialURL: URL, trackedProduct: ProductInfo) {
        self.initialURL = initialURL
        self.trackedProduct = trackedProduct
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
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
        card.layer.borderColor = UIColor.separator.withAlphaComponent(0.6).cgColor
        card.clipsToBounds = true
        view.addSubview(card)

        configureWebView()
        configureHeader()
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
        let top = view.safeAreaInsets.top + 8
        let bottom = view.bounds.height - view.safeAreaInsets.bottom - 8
        return CGRect(x: Self.cardInset, y: top,
                      width: view.bounds.width - Self.cardInset * 2, height: max(bottom - top, 0))
    }

    // MARK: - Web view

    private func configureWebView() {
        let configuration = WebJunkBlocker.makeConfiguration()
        configuration.userContentController.add(
            self, name: Self.googleShoppingSellerMessageName)
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
        webView.scrollView.contentInset.top = Self.headerHeight
        webView.scrollView.verticalScrollIndicatorInsets.top = Self.headerHeight
        webView.scrollView.contentInset.bottom = Self.bottomBarHeight
        webView.navigationDelegate = self
        card.addSubview(webView)
    }

    private func loadURL(_ url: URL) {
        webView?.load(URLRequest(url: url))
        urlField.text = url.absoluteString
    }

    // MARK: - Chrome

    private func configureHeader() {
        header.clipsToBounds = true
        header.layer.cornerRadius = Self.cardCornerRadius
        header.layer.cornerCurve = .continuous
        header.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        card.addSubview(header)

        closeButton.configuration = GlassStyle.circularButtonConfiguration(symbol: "xmark")
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        header.contentView.addSubview(closeButton)

        backButton.configuration = GlassStyle.circularButtonConfiguration(symbol: "chevron.backward")
        backButton.addTarget(self, action: #selector(goBackTapped), for: .touchUpInside)
        header.contentView.addSubview(backButton)

        forwardButton.configuration = GlassStyle.circularButtonConfiguration(symbol: "chevron.forward")
        forwardButton.addTarget(self, action: #selector(goForwardTapped), for: .touchUpInside)
        header.contentView.addSubview(forwardButton)

        titleLabel.font = .preferredFont(forTextStyle: .subheadline)
        titleLabel.textColor = .secondaryLabel
        titleLabel.textAlignment = .center
        titleLabel.text = "Find a seller"
        header.contentView.addSubview(titleLabel)

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
        bottomBar.contentView.addSubview(urlField)

        addButton.configuration = GlassStyle.circularButtonConfiguration(symbol: "plus")
        addButton.tintColor = GlassStyle.readingAccent
        addButton.addTarget(self, action: #selector(addTapped), for: .touchUpInside)
        bottomBar.contentView.addSubview(addButton)

        // Rise above the keyboard while typing (the guide tracks the real keyboard
        // frame); cap above the bottom safe area when the keyboard is down. High
        // priority so the keyboard guide wins over the cap exactly when the keyboard
        // is up — matching `SearchViewController`'s pattern.
        let aboveKeyboard = bottomBar.bottomAnchor.constraint(
            equalTo: view.keyboardLayoutGuide.topAnchor)
        aboveKeyboard.priority = .required
        let cap = bottomBar.bottomAnchor.constraint(
            lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8)
        bottomBarBottomCap = cap
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
        header.frame = CGRect(x: 0, y: 0, width: card.bounds.width, height: Self.headerHeight)

        let s = Self.buttonSize
        let y = (Self.headerHeight - s) / 2
        closeButton.frame = CGRect(x: Self.buttonInset, y: y, width: s, height: s)
        forwardButton.frame = CGRect(
            x: card.bounds.width - Self.buttonInset - s, y: y, width: s, height: s)
        backButton.frame = CGRect(
            x: forwardButton.frame.minX - 6 - s, y: y, width: s, height: s)
        let titleLeft = closeButton.frame.maxX + 8
        let titleRight = backButton.frame.minX - 8
        titleLabel.frame = CGRect(
            x: titleLeft, y: 0, width: max(titleRight - titleLeft, 0), height: Self.headerHeight)

        let by = (Self.bottomBarHeight - s) / 2
        addButton.frame = CGRect(
            x: bottomBar.bounds.width - Self.buttonInset - s, y: by, width: s, height: s)
        urlField.frame = CGRect(
            x: Self.buttonInset, y: (Self.bottomBarHeight - 36) / 2,
            width: addButton.frame.minX - 8 - Self.buttonInset, height: 36)
    }

    private func updateNavButtons() {
        backButton.isEnabled = webView?.canGoBack ?? false
        forwardButton.isEnabled = webView?.canGoForward ?? false
    }

    // MARK: - Actions

    @objc private func closeTapped() {
        dismiss(animated: true)
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
        DotMatrixModal.present(alert, from: self)
    }

    /// Reads the rendered HTML and hands it to the host, then routes the host's
    /// outcome to the overlay's exit behavior (dismiss on success, message otherwise).
    private func handleAddCurrentPage(urlString: String, prefetchedHTML: String?) {
        if let prefetchedHTML {
            onUseThisPage?(urlString, prefetchedHTML) { [weak self] outcome in
                self?.handleAddOutcome(outcome)
            }
            return
        }
        webView?.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] result, _ in
            guard let self else { return }
            let html = (result as? String) ?? ""
            self.onUseThisPage?(urlString, html) { [weak self] outcome in
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
            presentMessage(
                title: "Couldn't find a price",
                message: "We couldn't find a price on this page, so it wasn't added. "
                    + "Try a product page that shows a price.")
        case .duplicate:
            presentMessage(
                title: "Already tracked",
                message: "This page is already a seller for this product.")
        }
    }

    private func presentMessage(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        DotMatrixModal.present(alert, from: self)
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
}

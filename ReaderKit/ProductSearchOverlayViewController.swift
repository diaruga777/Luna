//
//  ProductSearchOverlayViewController.swift
//  Clip
//

import UIKit
import WebKit

/// A near-fullscreen web search/browse overlay for adding a seller to a price
/// tracker, styled like the inline reader (`SplitWebOverlayViewController`): a themed
/// `WKWebView` inside an inset rounded glass card with a glass header (close +
/// back/forward), and a bottom URL bar with a circular "+" to add the current page.
///
/// It preloads a Google Shopping search for the product, lets the user browse/type
/// freely, and offers two ways to add the page being viewed as a seller:
/// - tapping the "+" button → a "Use this page?" confirmation, or
/// - **auto-detection**: when a page finishes loading and `ProductPageDetector`
///   classifies it as a product, the same confirmation is presented automatically
///   (debounced per-URL so it never re-fires for the same page).
///
/// The overlay never touches the reading-list store: when the user confirms, it
/// hands the current URL + its rendered HTML up via `onUseThisPage`, and the host
/// (the price-tracking editor) performs the mandatory price fetch + dedupe + add.
final class ProductSearchOverlayViewController: UIViewController, WKNavigationDelegate, UITextFieldDelegate {

    /// Called when the user confirms "Add to tracker" for the current page. The host
    /// performs the price fetch (mandatory) + dedupe + add. `html` is the page's
    /// rendered `outerHTML` (so the host can reuse it for the fast price path).
    var onUseThisPage: ((_ urlString: String, _ html: String) -> Void)?

    private let initialURL: URL
    private let detector = ProductPageDetector()

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

    /// URLs we've already offered "Use this page?" for via auto-detection, so it
    /// fires at most once per page even as `didFinish` re-fires on in-page updates.
    private var autoOfferedURLStrings: Set<String> = []
    /// True while a "Use this page?" alert is on screen, so a finishing navigation
    /// doesn't stack a second one.
    private var isOfferingUseThisPage = false

    private static let cardInset: CGFloat = 12
    private static let cardCornerRadius: CGFloat = 26
    private static let headerHeight: CGFloat = 60
    private static let bottomBarHeight: CGFloat = 60
    private static let buttonSize: CGFloat = 40
    private static let buttonInset: CGFloat = 14

    init(initialURL: URL) {
        self.initialURL = initialURL
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Lifecycle

    override func viewDidLoad() {
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

    override func viewDidLayoutSubviews() {
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
        let webView = WKWebView(frame: .zero, configuration: WebJunkBlocker.makeConfiguration())
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
        card.addSubview(bottomBar)

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
    }

    private func layoutCardContents() {
        webView?.frame = card.bounds
        header.frame = CGRect(x: 0, y: 0, width: card.bounds.width, height: Self.headerHeight)
        bottomBar.frame = CGRect(
            x: 0, y: card.bounds.height - Self.bottomBarHeight,
            width: card.bounds.width, height: Self.bottomBarHeight)

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
            x: card.bounds.width - Self.buttonInset - s, y: by, width: s, height: s)
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

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
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
        guard !isOfferingUseThisPage, let webView, let url = webView.url else { return }
        isOfferingUseThisPage = true
        let alert = UIAlertController(
            title: "Use this page?",
            message: "Add this page as a seller for this product.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Add to tracker", style: .default) { [weak self] _ in
            self?.isOfferingUseThisPage = false
            self?.handleAddCurrentPage(urlString: url.absoluteString)
        })
        alert.addAction(UIAlertAction(title: "No thanks", style: .cancel) { [weak self] _ in
            self?.isOfferingUseThisPage = false
        })
        present(alert, animated: true)
    }

    private func handleAddCurrentPage(urlString: String) {
        webView?.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] result, _ in
            let html = (result as? String) ?? ""
            self?.onUseThisPage?(urlString, html)
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        updateNavButtons()
        if let current = webView.url?.absoluteString { urlField.text = current }
        autoDetectProductIfNeeded(in: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        updateNavButtons()
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
    ) { updateNavButtons() }

    /// Reads the finished page's rendered HTML and, if `ProductPageDetector` says it's
    /// a product page we haven't already offered, auto-presents "Use this page?".
    private func autoDetectProductIfNeeded(in webView: WKWebView) {
        guard let urlString = webView.url?.absoluteString,
              !autoOfferedURLStrings.contains(urlString),
              !isOfferingUseThisPage else { return }
        webView.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] result, _ in
            guard let self, let html = result as? String,
                  self.detector.detect(urlString: urlString, html: html) != nil else { return }
            // Debounce: offer at most once per URL.
            self.autoOfferedURLStrings.insert(urlString)
            self.offerUseThisPage()
        }
    }
}

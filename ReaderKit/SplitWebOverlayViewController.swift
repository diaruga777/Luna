//
//  SplitWebOverlayViewController.swift
//  Clip
//

import UIKit
import WebKit

/// The inline reader shown when a link is tapped in the scroll reader.
///
/// The reader is snapshotted (in WINDOW coordinates) and split at the top of the
/// tapped link's line. An inset rounded glass card grows out from the cut to the
/// space between a one-line top peek (the line above the link) and a one-line
/// bottom peek (the link's line). The card shows the linked page — rendered with
/// the app's reader when the page is article-like, otherwise a web view — and
/// scrolls/navigates INDEPENDENTLY. A liquid-glass header holds the close + save
/// buttons; content scrolls under it.
///
/// All motion is a single `progress` (0 = fully open, 1 = closed back onto the
/// cut line). The peeks are derived FROM the interpolating card frame so they
/// stay flush with it (no gaps / ghost copies). Dismiss via the ✕, the bottom
/// chevron, or an interactive drag on either peek (the card loses twice the drag
/// distance); once fully closed it dismisses and never re-grows.
final class SplitWebOverlayViewController: UIViewController, UIGestureRecognizerDelegate,
                                           WKNavigationDelegate, UITextViewDelegate {

    /// Called once on dismissal (the reader never moved — the overlay covered it).
    var onDismiss: (() -> Void)?

    private let url: URL
    private let shareProvider: ReaderShareProviding?
    private let lineHeight: CGFloat
    /// Window-y of the top of the tapped link's line (clamped so the peeks fit).
    private var cutY: CGFloat
    private let topHalf: UIView?
    private let bottomHalf: UIView?

    private let dimView = UIView()
    private let card = UIView()
    private let cardShadow = UIView()
    private let header = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
    private let webView = WKWebView(frame: .zero, configuration: WebJunkBlocker.makeConfiguration())
    private let nestedTextView = UITextView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let closeButton = UIButton(type: .system)
    private let saveButton = UIButton(type: .system)
    private let bottomChevron = UIButton(type: .system)

    private static let cardInset: CGFloat = 12
    private static let cardCornerRadius: CGFloat = 26
    private static let buttonSize: CGFloat = 40
    private static let headerHeight: CGFloat = 54

    private var didAnimateIn = false
    private var didDismiss = false
    /// Once a drag fully compresses the card it dismisses and stops responding —
    /// dragging back must not re-grow it.
    private var isClosing = false
    private var articleProbe: Task<Void, Never>?
    private var showingReader = false

    init(url: URL, shareProvider: ReaderShareProviding?, lineHeight: CGFloat,
         cutY: CGFloat, topHalf: UIView?, bottomHalf: UIView?) {
        self.url = url
        self.shareProvider = shareProvider
        self.lineHeight = max(lineHeight, 18)
        self.cutY = cutY
        self.topHalf = topHalf
        self.bottomHalf = bottomHalf
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { articleProbe?.cancel() }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        dimView.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        dimView.frame = view.bounds
        dimView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(dimView)

        // The peeks are snapshots clipped to their own bounds so they never bleed
        // past where they sit on screen.
        for half in [topHalf, bottomHalf].compactMap({ $0 }) {
            half.clipsToBounds = true
            half.isUserInteractionEnabled = true
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePeekPan(_:)))
            pan.delegate = self
            half.addGestureRecognizer(pan)
            view.addSubview(half)
        }

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

        // Web view + (lazily) the nested reader fill the card; both scroll under
        // the header via a top content inset.
        webView.scrollView.isScrollEnabled = true
        webView.scrollView.contentInset.top = Self.headerHeight
        webView.scrollView.verticalScrollIndicatorInsets.top = Self.headerHeight
        card.addSubview(webView)

        configureHeader()       // glass header with the close + save buttons
        spinner.hidesWhenStopped = true
        spinner.startAnimating()
        card.addSubview(spinner)
        configureChevron()

        WebJunkBlocker.applyRuleList(to: webView.configuration.userContentController)
        webView.navigationDelegate = self
        webView.load(URLRequest(url: url))
        probeForArticle()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didAnimateIn else { return }
        didAnimateIn = true
        animateOpen()
    }

    // MARK: - Geometry

    private var hasPeeks: Bool { topHalf != nil || bottomHalf != nil }

    private var openCardFrame: CGRect {
        let width = view.bounds.width
        let peek = hasPeeks ? lineHeight : 0
        let top = view.safeAreaInsets.top + peek
        let bottom = view.bounds.height - view.safeAreaInsets.bottom - peek
        return CGRect(x: Self.cardInset, y: top,
                      width: width - Self.cardInset * 2, height: max(bottom - top, 0))
    }

    /// Lays everything out for compression `progress` (0 open … 1 closed onto the
    /// cut). The card interpolates between its open frame and a zero-height sliver
    /// at `cutY`; the peeks are pinned flush to the card's top/bottom edges.
    private func apply(progress p: CGFloat) {
        let clamped = min(max(p, 0), 1)
        let open = openCardFrame
        let cardTop = open.minY + (cutY - open.minY) * clamped
        let cardBottom = open.maxY + (cutY - open.maxY) * clamped
        let frame = CGRect(x: open.minX, y: cardTop, width: open.width, height: max(cardBottom - cardTop, 0))

        card.frame = frame
        cardShadow.frame = frame
        cardShadow.layer.shadowPath = UIBezierPath(
            roundedRect: CGRect(origin: .zero, size: frame.size),
            cornerRadius: Self.cardCornerRadius).cgPath
        webView.frame = card.bounds
        nestedTextView.frame = card.bounds
        layoutHeader()
        spinner.center = CGPoint(x: card.bounds.midX, y: card.bounds.midY + Self.headerHeight / 2)

        // Peeks flush to the card edges → no gap for the live reader to show through.
        if let topHalf { topHalf.frame.origin.y = cardTop - topHalf.bounds.height }
        if let bottomHalf { bottomHalf.frame.origin.y = cardBottom }

        // Chevron straddles the card's bottom edge, kept clear of the home indicator.
        let chevronY = min(cardBottom, view.bounds.height - view.safeAreaInsets.bottom - 6)
        bottomChevron.center = CGPoint(x: frame.midX, y: chevronY)

        let chromeAlpha = 1 - clamped
        header.alpha = chromeAlpha
        bottomChevron.alpha = chromeAlpha
    }

    // MARK: - Open / dismiss

    private func animateOpen() {
        let width = view.bounds.width
        let screenH = view.bounds.height
        cutY = min(max(cutY, openCardFrame.minY), openCardFrame.maxY)
        // Peeks start as full-screen halves matching the reader (progress = 1).
        topHalf?.frame = CGRect(x: 0, y: 0, width: width, height: max(cutY, 1))
        bottomHalf?.frame = CGRect(x: 0, y: cutY, width: width, height: max(screenH - cutY, 1))
        apply(progress: 1)
        dimView.alpha = 1   // backdrop for the card's side margins (and RSVP)

        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.9,
                       initialSpringVelocity: 0.2) {
            self.apply(progress: 0)
        }
    }

    private func animateDismiss() {
        guard !didDismiss else { return }
        didDismiss = true
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseIn) {
            self.apply(progress: 1)
            self.dimView.alpha = 0
        } completion: { _ in
            self.onDismiss?()
            self.dismiss(animated: false)
        }
    }

    // MARK: - Interactive peek drag

    @objc private func handlePeekPan(_ gesture: UIPanGestureRecognizer) {
        guard !didDismiss, !isClosing else { return }
        let openHeight = max(openCardFrame.height, 1)
        let progress = min((abs(gesture.translation(in: view).y) * 2) / openHeight, 1)

        switch gesture.state {
        case .changed:
            apply(progress: progress)
            if progress >= 1 {   // fully compressed → dismiss; never re-grow
                isClosing = true
                animateDismiss()
            }
        case .ended, .cancelled:
            if progress >= 0.5 || abs(gesture.velocity(in: view).y) > 800 {
                animateDismiss()
            } else {
                UIView.animate(withDuration: 0.25) { self.apply(progress: 0) }
            }
        default:
            break
        }
    }

    // MARK: - Chrome

    private func configureHeader() {
        header.clipsToBounds = true
        header.layer.cornerRadius = Self.cardCornerRadius
        header.layer.cornerCurve = .continuous
        header.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        card.addSubview(header)

        closeButton.configuration = GlassStyle.circularButtonConfiguration(symbol: "xmark")
        closeButton.addTarget(self, action: #selector(dismissTapped), for: .touchUpInside)
        header.contentView.addSubview(closeButton)

        if shareProvider != nil {
            saveButton.configuration = GlassStyle.circularButtonConfiguration(symbol: "square.and.arrow.down")
            saveButton.tintColor = GlassStyle.readingAccent
            saveButton.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)
            header.contentView.addSubview(saveButton)
        }
    }

    private func layoutHeader() {
        header.frame = CGRect(x: 0, y: 0, width: card.bounds.width, height: Self.headerHeight)
        let s = Self.buttonSize
        let y = (Self.headerHeight - s) / 2
        closeButton.frame = CGRect(x: 8, y: y, width: s, height: s)
        saveButton.frame = CGRect(x: card.bounds.width - s - 8, y: y, width: s, height: s)
    }

    private func configureChevron() {
        var config = GlassStyle.circularButtonConfiguration(symbol: "chevron.compact.down")
        config.baseForegroundColor = GlassStyle.readingAccent   // blue icon
        bottomChevron.configuration = config
        bottomChevron.tintColor = GlassStyle.readingAccent
        bottomChevron.bounds = CGRect(x: 0, y: 0, width: Self.buttonSize, height: Self.buttonSize)
        bottomChevron.addTarget(self, action: #selector(dismissTapped), for: .touchUpInside)
        view.addSubview(bottomChevron)
    }

    @objc private func dismissTapped() { animateDismiss() }

    @objc private func saveTapped() {
        shareProvider?.saveLink(urlString: url.absoluteString)
        var config = GlassStyle.circularButtonConfiguration(symbol: "checkmark")
        config.baseForegroundColor = GlassStyle.readingAccent
        saveButton.configuration = config
        saveButton.tintColor = GlassStyle.readingAccent
        saveButton.isEnabled = false
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { false }

    // MARK: - Reader rendering (#2)

    /// Fetches + extracts the linked page off-main; if it's article-like, renders
    /// it with the app reader's text styling instead of showing the raw web view.
    private func probeForArticle() {
        let target = url
        articleProbe = Task { [weak self] in
            let content: ArticleContent? = await Task.detached(priority: .userInitiated) {
                guard let html = try? await ArticleFetcher().fetchHTML(from: target) else { return nil }
                return try? ArticleExtractor().extract(html: html, baseURL: target)
            }.value
            guard let self, !Task.isCancelled, let content else { return }
            let blocks = content.blocks.filter { !$0.text.isEmpty }
            let totalText = blocks.reduce(0) { $0 + $1.text.count }
            guard totalText >= 600, blocks.count >= 3 else { return }   // article-like
            await MainActor.run { self.showReader(content) }
        }
    }

    private func showReader(_ content: ArticleContent) {
        guard !didDismiss, !showingReader else { return }
        showingReader = true
        webView.stopLoading()
        spinner.stopAnimating()

        nestedTextView.attributedText = ArticleTextRenderer.render(content).text
        nestedTextView.isEditable = false
        nestedTextView.backgroundColor = .clear
        nestedTextView.textContainerInset = UIEdgeInsets(
            top: Self.headerHeight + 12, left: 20, bottom: 40, right: 20)
        nestedTextView.delegate = self
        nestedTextView.linkTextAttributes = [
            .foregroundColor: GlassStyle.readingAccent,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        nestedTextView.frame = card.bounds
        card.insertSubview(nestedTextView, belowSubview: header)
        webView.isHidden = true
    }

    /// A link tapped inside the nested reader falls back to the web view in place.
    func textView(
        _ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction
    ) -> UIAction? {
        if case .link(let linkURL) = textItem.content {
            return UIAction { [weak self] _ in
                guard let self else { return }
                self.nestedTextView.removeFromSuperview()
                self.showingReader = false
                self.webView.isHidden = false
                self.spinner.startAnimating()
                self.webView.load(URLRequest(url: linkURL))
            }
        }
        return defaultAction
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if !showingReader { spinner.stopAnimating() }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        spinner.stopAnimating()
    }
    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
    ) { spinner.stopAnimating() }
}

//
//  SplitWebOverlayViewController.swift
//  Clip
//

import UIKit
import WebKit

/// The inline reader shown when a link is tapped in the scroll reader.
///
/// The reader is snapshotted (in WINDOW coordinates) and split at the top of the
/// tapped link's line: the part above parks as a one-line peek at the top, the
/// link's line as a one-line peek at the bottom, and an inset rounded glass card
/// grows out from the cut to fill the space between them. The card's web view
/// scrolls and navigates INDEPENDENTLY.
///
/// Three ways to dismiss, all compressing the card to zero from its center while
/// the peeks rejoin: the ✕ at the card's top-left, the chevron on its bottom
/// edge, or an interactive drag started in either peek (the card loses twice the
/// drag distance). Also backs the RSVP link pill, presented with nil peeks so the
/// card simply grows from the screen's center over a dimmed backdrop.
final class SplitWebOverlayViewController: UIViewController, UIGestureRecognizerDelegate {

    /// Called once on dismissal (the reader never moved — the overlay covered it).
    var onDismiss: (() -> Void)?

    private let url: URL
    private let shareProvider: ReaderShareProviding?
    private let lineHeight: CGFloat
    /// Window-y of the top of the tapped link's line (screen == overlay coords).
    private let cutY: CGFloat
    private let topHalf: UIView?
    private let bottomHalf: UIView?

    private let dimView = UIView()
    private let card = UIView()
    private let cardShadow = UIView()
    private let webView = WKWebView(frame: .zero, configuration: WebJunkBlocker.makeConfiguration())
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let closeButton = UIButton(type: .system)
    private let saveButton = UIButton(type: .system)
    private let bottomChevron = UIButton(type: .system)

    private static let cardInset: CGFloat = 12
    private static let cardCornerRadius: CGFloat = 26
    private static let buttonSize: CGFloat = 40

    private var didAnimateIn = false
    private var didDismiss = false
    private var openTopHalfY: CGFloat = 0
    private var openBottomHalfY: CGFloat = 0

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

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        dimView.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        dimView.frame = view.bounds
        dimView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(dimView)

        if let topHalf { view.addSubview(topHalf) }
        if let bottomHalf { view.addSubview(bottomHalf) }
        addPeekPan(topHalf)
        addPeekPan(bottomHalf)

        webView.scrollView.isScrollEnabled = true
        webView.layer.cornerRadius = Self.cardCornerRadius
        webView.layer.cornerCurve = .continuous
        webView.clipsToBounds = true

        cardShadow.backgroundColor = .clear
        cardShadow.layer.shadowColor = UIColor.black.cgColor
        cardShadow.layer.shadowOpacity = 0.22
        cardShadow.layer.shadowRadius = 18
        cardShadow.layer.shadowOffset = CGSize(width: 0, height: 6)

        card.backgroundColor = ReaderDepth.backgroundColor(for: 0)
        card.layer.cornerRadius = Self.cardCornerRadius
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 0.5
        card.layer.borderColor = UIColor.separator.withAlphaComponent(0.6).cgColor
        card.clipsToBounds = true
        card.addSubview(webView)

        spinner.hidesWhenStopped = true
        spinner.startAnimating()

        view.addSubview(cardShadow)
        view.addSubview(card)
        view.addSubview(spinner)
        configureChrome()

        WebJunkBlocker.applyRuleList(to: webView.configuration.userContentController)
        webView.navigationDelegate = self
        webView.load(URLRequest(url: url))
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didAnimateIn else { return }
        didAnimateIn = true
        animateOpen()
    }

    // MARK: - Geometry

    private var openCardFrame: CGRect {
        let width = view.bounds.width
        let hasPeeks = topHalf != nil || bottomHalf != nil
        let peek = hasPeeks ? lineHeight : 0
        let top = view.safeAreaInsets.top + peek + 4
        let bottom = view.bounds.height - view.safeAreaInsets.bottom - peek - 4
        return CGRect(x: Self.cardInset, y: top,
                      width: width - Self.cardInset * 2, height: max(bottom - top, 0))
    }

    private func layoutCard(_ frame: CGRect) {
        card.frame = frame
        cardShadow.frame = frame
        cardShadow.layer.shadowPath = UIBezierPath(
            roundedRect: CGRect(origin: .zero, size: frame.size),
            cornerRadius: Self.cardCornerRadius).cgPath
        webView.frame = card.bounds
        spinner.center = CGPoint(x: frame.midX, y: frame.midY)
        let s = Self.buttonSize
        closeButton.frame = CGRect(x: frame.minX + 6, y: frame.minY + 6, width: s, height: s)
        saveButton.frame = CGRect(x: frame.maxX - s - 6, y: frame.minY + 6, width: s, height: s)
        // Keep the chevron clear of the home-indicator gesture zone at the very
        // bottom (taps there get swallowed by the system).
        bottomChevron.frame = CGRect(x: frame.midX - s / 2, y: frame.maxY - s - 12, width: s, height: s)
    }

    // MARK: - Open / compress / dismiss

    private func animateOpen() {
        let width = view.bounds.width
        let open = openCardFrame
        let height = view.bounds.height
        openTopHalfY = view.safeAreaInsets.top + lineHeight - cutY
        openBottomHalfY = height - view.safeAreaInsets.bottom - lineHeight

        topHalf?.frame = CGRect(x: 0, y: 0, width: width, height: max(cutY, 1))
        bottomHalf?.frame = CGRect(x: 0, y: cutY, width: width, height: max(height - cutY, 1))
        // Card starts as a zero-height sliver at the cut.
        layoutCard(CGRect(x: open.minX, y: cutY, width: open.width, height: 0))
        setChromeAlpha(0)
        dimView.alpha = (topHalf == nil && bottomHalf == nil) ? 0 : 1

        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.9,
                       initialSpringVelocity: 0.2) {
            self.topHalf?.frame.origin.y = self.openTopHalfY
            self.bottomHalf?.frame.origin.y = self.openBottomHalfY
            self.layoutCard(open)
            self.setChromeAlpha(1)
        }
    }

    /// progress 0 = open, 1 = dismissed: card loses height equally top + bottom.
    private func applyCompression(_ progress: CGFloat) {
        let p = min(max(progress, 0), 1)
        let open = openCardFrame
        let height = open.height * (1 - p)
        let centerY = open.midY
        layoutCard(CGRect(x: open.minX, y: centerY - height / 2, width: open.width, height: height))
        topHalf?.frame.origin.y = openTopHalfY + (0 - openTopHalfY) * p
        bottomHalf?.frame.origin.y = openBottomHalfY + (cutY - openBottomHalfY) * p
        setChromeAlpha(1 - p)
    }

    private func animateDismiss() {
        guard !didDismiss else { return }
        didDismiss = true
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseIn) {
            self.applyCompression(1)
            self.dimView.alpha = 0
        } completion: { _ in
            self.onDismiss?()
            self.dismiss(animated: false)
        }
    }

    // MARK: - Interactive peek drag

    private func addPeekPan(_ peek: UIView?) {
        guard let peek else { return }
        peek.isUserInteractionEnabled = true
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePeekPan(_:)))
        pan.delegate = self
        peek.addGestureRecognizer(pan)
    }

    @objc private func handlePeekPan(_ gesture: UIPanGestureRecognizer) {
        guard !didDismiss else { return }
        let openHeight = max(openCardFrame.height, 1)
        let progress = (abs(gesture.translation(in: view).y) * 2) / openHeight
        switch gesture.state {
        case .changed:
            applyCompression(progress)
        case .ended, .cancelled:
            if progress >= 0.5 || abs(gesture.velocity(in: view).y) > 800 {
                animateDismiss()
            } else {
                UIView.animate(withDuration: 0.25) { self.applyCompression(0) }
            }
        default:
            break
        }
    }

    // MARK: - Chrome

    private func configureChrome() {
        closeButton.configuration = GlassStyle.circularButtonConfiguration(symbol: "xmark")
        closeButton.addTarget(self, action: #selector(dismissTapped), for: .touchUpInside)
        view.addSubview(closeButton)

        bottomChevron.configuration = GlassStyle.circularButtonConfiguration(symbol: "chevron.compact.down")
        bottomChevron.tintColor = GlassStyle.readingAccent
        bottomChevron.addTarget(self, action: #selector(dismissTapped), for: .touchUpInside)
        view.addSubview(bottomChevron)

        guard shareProvider != nil else { return }
        saveButton.configuration = GlassStyle.circularButtonConfiguration(symbol: "square.and.arrow.down")
        saveButton.tintColor = GlassStyle.readingAccent
        saveButton.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)
        view.addSubview(saveButton)
    }

    private func setChromeAlpha(_ alpha: CGFloat) {
        closeButton.alpha = alpha
        bottomChevron.alpha = alpha
        saveButton.alpha = alpha
    }

    @objc private func dismissTapped() { animateDismiss() }

    @objc private func saveTapped() {
        shareProvider?.saveLink(urlString: url.absoluteString)
        saveButton.configuration = GlassStyle.circularButtonConfiguration(symbol: "checkmark")
        saveButton.tintColor = GlassStyle.readingAccent
        saveButton.isEnabled = false
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { false }
}

extension SplitWebOverlayViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { spinner.stopAnimating() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        spinner.stopAnimating()
    }
    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
    ) { spinner.stopAnimating() }
}

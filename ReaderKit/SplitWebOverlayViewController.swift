//
//  SplitWebOverlayViewController.swift
//  Clip
//

import UIKit
import WebKit

/// The inline reader shown when a link is tapped in the scroll reader.
///
/// The outer reader splits along the line boundary at the tapped link: the line
/// ABOVE the link parks as a one-line peek at the top, the link's line parks as a
/// one-line peek at the bottom (both are live snapshots of the reader), and an
/// inset rounded glass card grows out from the cut to fill the space between
/// them. The card's web view scrolls and navigates INDEPENDENTLY — its gestures
/// never reach the outer reader.
///
/// Three ways to dismiss, all animating the card's height back to zero from its
/// center while the two peeks rejoin:
///   1. the ✕ hovering at the card's top-left,
///   2. the chevron on the card's bottom edge,
///   3. an interactive drag started in either peek — the card compresses by
///      twice the drag distance until it dismisses.
final class SplitWebOverlayViewController: UIViewController, UIGestureRecognizerDelegate {

    /// Called once on dismissal so the presenter can keep its reader untouched
    /// (the reader never moved — the overlay covered it).
    var onDismiss: (() -> Void)?

    private let url: URL
    private let shareProvider: ReaderShareProviding?
    /// Height of one text line (the peek height top and bottom).
    private let lineHeight: CGFloat
    /// Screen-y of the top of the tapped link's line at tap time.
    private let lineTopScreen: CGFloat
    /// Live snapshots of the reader above / at-and-below the link line.
    private let topHalf: UIView?
    private let bottomHalf: UIView?

    private let card = UIView()
    private let cardShadow = UIView()
    private let webView = WKWebView(frame: .zero, configuration: WebJunkBlocker.makeConfiguration())
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let closeButton = UIButton(type: .system)
    private let saveButton = UIButton(type: .system)
    private let bottomChevron = UIButton(type: .system)

    private static let cardInset: CGFloat = 14
    private static let cardCornerRadius: CGFloat = 26

    private var didAnimateIn = false
    private var didDismiss = false
    /// The two snapshot y-origins in the fully-open state (parked peeks).
    private var openTopHalfY: CGFloat = 0
    private var openBottomHalfY: CGFloat = 0

    init(url: URL, shareProvider: ReaderShareProviding?, lineHeight: CGFloat,
         lineTopScreen: CGFloat, topHalf: UIView?, bottomHalf: UIView?) {
        self.url = url
        self.shareProvider = shareProvider
        self.lineHeight = max(lineHeight, 16)
        self.lineTopScreen = lineTopScreen
        self.topHalf = topHalf
        self.bottomHalf = bottomHalf
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        // The card's web view scrolls + navigates on its own.
        webView.scrollView.isScrollEnabled = true
        webView.layer.cornerRadius = Self.cardCornerRadius
        webView.layer.cornerCurve = .continuous
        webView.clipsToBounds = true

        cardShadow.backgroundColor = .clear
        cardShadow.layer.shadowColor = UIColor.black.cgColor
        cardShadow.layer.shadowOpacity = 0.18
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

        if let topHalf { view.insertSubview(topHalf, belowSubview: card) }
        if let bottomHalf { view.insertSubview(bottomHalf, belowSubview: card) }
        addPeekPanGesture(to: topHalf)
        addPeekPanGesture(to: bottomHalf)

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
        let top = view.safeAreaInsets.top + lineHeight
        let bottom = view.bounds.height - view.safeAreaInsets.bottom - lineHeight
        return CGRect(x: Self.cardInset, y: top,
                      width: width - Self.cardInset * 2, height: max(bottom - top, 0))
    }

    /// Lays the card (and shadow + chrome + web view) into `frame`.
    private func layoutCard(_ frame: CGRect) {
        card.frame = frame
        cardShadow.frame = frame
        cardShadow.layer.shadowPath = UIBezierPath(
            roundedRect: CGRect(origin: .zero, size: frame.size),
            cornerRadius: Self.cardCornerRadius).cgPath
        webView.frame = card.bounds
        spinner.center = CGPoint(x: frame.midX, y: frame.midY)
        closeButton.center = CGPoint(x: frame.minX + 24, y: frame.minY + 24)
        saveButton.center = CGPoint(x: frame.maxX - 24, y: frame.minY + 24)
        bottomChevron.center = CGPoint(x: frame.midX, y: frame.maxY - 16)
    }

    // MARK: - Open / compress / dismiss

    private func animateOpen() {
        let width = view.bounds.width
        let open = openCardFrame
        openTopHalfY = view.safeAreaInsets.top + lineHeight - lineTopScreen
        openBottomHalfY = view.bounds.height - view.safeAreaInsets.bottom - lineHeight

        // Start: snapshots match the reader, card is a zero-height sliver at the cut.
        topHalf?.frame = CGRect(x: 0, y: 0, width: width, height: max(lineTopScreen, 1))
        bottomHalf?.frame = CGRect(
            x: 0, y: lineTopScreen, width: width,
            height: max(view.bounds.height - lineTopScreen, 1))
        layoutCard(CGRect(x: open.minX, y: lineTopScreen, width: open.width, height: 0))
        setChromeAlpha(0)

        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.9,
                       initialSpringVelocity: 0.2) {
            self.topHalf?.frame.origin.y = self.openTopHalfY
            self.bottomHalf?.frame.origin.y = self.openBottomHalfY
            self.layoutCard(open)
            self.setChromeAlpha(1)
        }
    }

    /// Applies a compression `progress` in 0…1 (0 = fully open, 1 = dismissed):
    /// the card loses height equally from top and bottom, the peeks rejoin.
    private func applyCompression(_ progress: CGFloat) {
        let p = min(max(progress, 0), 1)
        let open = openCardFrame
        let height = open.height * (1 - p)
        let centerY = open.midY
        layoutCard(CGRect(x: open.minX, y: centerY - height / 2, width: open.width, height: height))
        topHalf?.frame.origin.y = openTopHalfY + (0 - openTopHalfY) * p
        bottomHalf?.frame.origin.y = openBottomHalfY + (lineTopScreen - openBottomHalfY) * p
        setChromeAlpha(1 - p)
    }

    /// Animates a full compress-to-zero, then dismisses.
    private func animateDismiss() {
        guard !didDismiss else { return }
        didDismiss = true
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        UIView.animate(withDuration: 0.32, delay: 0, options: .curveEaseIn) {
            self.applyCompression(1)
        } completion: { _ in
            self.onDismiss?()
            self.dismiss(animated: false)
        }
    }

    // MARK: - Interactive peek drag

    private func addPeekPanGesture(to peek: UIView?) {
        guard let peek else { return }
        peek.isUserInteractionEnabled = true
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePeekPan(_:)))
        pan.delegate = self
        peek.addGestureRecognizer(pan)
    }

    @objc private func handlePeekPan(_ gesture: UIPanGestureRecognizer) {
        guard !didDismiss else { return }
        let openHeight = max(openCardFrame.height, 1)
        // Height loss is double the drag distance, so progress = 2·|dy| / openHeight.
        let distance = abs(gesture.translation(in: view).y)
        let progress = (distance * 2) / openHeight

        switch gesture.state {
        case .changed:
            applyCompression(progress)
        case .ended, .cancelled:
            let velocity = abs(gesture.velocity(in: view).y)
            if progress >= 0.5 || velocity > 900 {
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

    // The peek pan should win over any ambient gestures.
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

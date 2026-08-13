//
//  RescueFailureViewController.swift
//  LunaShareSurface
//

import LunaDesignSystem
import LunaModels
import UIKit
import WebKit

/// The three host legs the extension's failure card needs.
@MainActor
public protocol RescueFailureCardDelegate: AnyObject {
    /// Records the pending rescue, so the app's foreground drain picks it up.
    func rescueFailureCardDidRequestRescue(_ card: RescueFailureViewController)

    /// Best-effort deep-link open. An extension cannot observe whether it
    /// succeeded, which is why the card always then leaves the manual "Open Luna
    /// to finish saving" reassurance up.
    func rescueFailureCard(_ card: RescueFailureViewController, openApp url: URL)

    /// The user is done with the card.
    func rescueFailureCardDidFinish(_ card: RescueFailureViewController)
}

/// The extension failure card shown when a share/action save can't be loaded.
///
/// Deliberately the SAME card as the in-app failed save
/// (`FailedSaveCardViewController`, see `claudedocs/failed-saves.md`): a red-rimmed
/// card surface, the page itself in a near-full-bleed web view, a URL bar under it,
/// and "Retry with AI ✦" in the chin. A user who hits this in the share sheet and
/// then opens Luna should recognise the same object, not meet two different
/// apologies for one failure.
///
/// The one honest difference: an extension links NO rescue engine, so the button
/// can't run anything. It records a pending-rescue request and best-effort opens
/// the containing app — hence no progress overlay here, and a reassurance line in
/// place of a result. There is no content-type picker in either card; the model
/// classifies the page itself.
public final class RescueFailureViewController: UIViewController {
    private let url: URL?
    private let rescueURL: URL?
    /// Held STRONGLY, and deliberately: the conformer is a small coordinator the
    /// save flow makes for this card, not the card's owner, so nothing cycles —
    /// and it has to outlive the driver that raised the card, which is a
    /// temporary. Nil in a staged card, where every leg is a no-op.
    private let delegate: (any RescueFailureCardDelegate)?

    /// Matches the in-app card's geometry so the two read as one design.
    private static let webInset: CGFloat = 8
    private static let webCornerRadius: CGFloat = 14

    private let cardView = CardSurfaceView()
    private var webView: WKWebView?
    private let webContainer = UIView()
    private let urlLabel = UILabel()
    private let reloadButton = UIButton(type: .system)
    private let shareButton = UIButton(type: .system)
    private lazy var rescueButton = UIButton(type: .system)
    private let manualLabel = UILabel()
    private lazy var doneButton = UIButton(type: .system)
    private let chinStack = UIStackView()

    /// - url: the page that failed. Nil ⇒ the card shows its chrome with no page.
    /// - rescueURL: this app's `<scheme>://rescue` deep link (built by the driver);
    ///   nil ⇒ only the manual "Open Luna" instruction is shown.
    /// - delegate: the host legs — the deep-link open, the pending-rescue record,
    ///   and completion.
    public init(
        url: URL?,
        rescueURL: URL?,
        delegate: (any RescueFailureCardDelegate)?
    ) {
        self.url = url
        self.rescueURL = rescueURL
        self.delegate = delegate
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LunaColors.background
        // An extension lives in someone else's window, so the appearance has to be
        // applied to the view controller rather than a window we don't own
        // (`claudedocs/visual-effects.md`).
        AppearanceSettings.apply(to: self)
        navigationItem.title = FailedSaveCopy.couldNotLoad
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped))

        buildCard()
        loadPage()
    }

    // MARK: - Hierarchy

    private func buildCard() {
        cardView.translatesAutoresizingMaskIntoConstraints = false
        cardView.setBorderEnabled(true)
        // The same red rim the in-app card carries, from the same source.
        cardView.setEdgeGlow(LunaColors.errorAccent)
        view.addSubview(cardView)

        webContainer.backgroundColor = LunaColors.tertiaryBackground
        webContainer.layer.cornerRadius = Self.webCornerRadius
        webContainer.layer.cornerCurve = .continuous
        webContainer.clipsToBounds = true
        webContainer.translatesAutoresizingMaskIntoConstraints = false

        let urlBar = buildURLBar()
        buildChin()

        let stack = UIStackView(arrangedSubviews: [webContainer, urlBar, chinStack])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        cardView.installContentView(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            cardView.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            cardView.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            cardView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            cardView.leadingAnchor.constraint(
                greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            cardView.trailingAnchor.constraint(
                lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            // The failure card is a card, not a banner across an iPad sheet.
            cardView.widthAnchor.constraint(
                lessThanOrEqualToConstant: LunaLayout.readableWidth),

            stack.topAnchor.constraint(
                equalTo: cardView.contentContainer.topAnchor, constant: Self.webInset),
            stack.leadingAnchor.constraint(
                equalTo: cardView.contentContainer.leadingAnchor, constant: Self.webInset),
            stack.trailingAnchor.constraint(
                equalTo: cardView.contentContainer.trailingAnchor, constant: -Self.webInset),
            stack.bottomAnchor.constraint(
                equalTo: cardView.contentContainer.bottomAnchor, constant: -14),
        ])
    }

    private func buildURLBar() -> UIView {
        let bar = UIView()
        bar.translatesAutoresizingMaskIntoConstraints = false

        configureBarButton(reloadButton, symbol: "arrow.clockwise",
                           label: L10n.string("CardDeck_failedSave_reloadPageAccessibilityLabel"))
        reloadButton.addAction(UIAction { [weak self] _ in self?.webView?.reload() },
                               for: .touchUpInside)
        configureBarButton(shareButton, symbol: "square.and.arrow.up",
                           label: L10n.string("Common_shareLink"))
        shareButton.addAction(UIAction { [weak self] _ in self?.shareTapped() },
                              for: .touchUpInside)

        urlLabel.text = url.map { FailedSaveCopy.displayURL($0) }
        urlLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        urlLabel.textColor = LunaColors.secondaryText
        urlLabel.numberOfLines = 1
        urlLabel.lineBreakMode = .byTruncatingMiddle
        urlLabel.textAlignment = .center

        let row = UIStackView(arrangedSubviews: [reloadButton, urlLabel, shareButton])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: bar.topAnchor),
            row.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -6),
        ])
        return bar
    }

    private func buildChin() {
        rescueButton.configuration = GlassStyle.retryWithAIConfiguration()
        rescueButton.contentHorizontalAlignment = .center
        rescueButton.addTarget(self, action: #selector(finishTapped), for: .touchUpInside)
        rescueButton.isHidden = rescueURL == nil

        manualLabel.text = L10n.string("ShareExtension_rescueFailure_manualInstructionMessage")
        manualLabel.textColor = LunaColors.secondaryText
        manualLabel.font = .preferredFont(forTextStyle: .footnote)
        manualLabel.textAlignment = .center
        manualLabel.numberOfLines = 2
        manualLabel.isHidden = true

        doneButton.configuration = GlassStyle.actionButtonConfiguration(
            title: L10n.string("Common_done"), symbol: "checkmark", compact: true)
        doneButton.contentHorizontalAlignment = .center
        doneButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        doneButton.isHidden = true

        chinStack.axis = .vertical
        chinStack.spacing = 8
        chinStack.alignment = .fill
        for subview in [rescueButton, manualLabel, doneButton] {
            chinStack.addArrangedSubview(subview)
        }
    }

    /// The same hairline circular button the in-app card's URL bar uses.
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

    // MARK: - Web view

    private func loadPage() {
        guard let url else {
            reloadButton.isEnabled = false
            return
        }
        let configuration = WebJunkBlocker.makeConfiguration()
        // The user's own cookies — the same reason the in-app card uses them: a
        // page a background fetch couldn't read often renders here.
        configuration.websiteDataStore = .default()
        let web = WKWebView(frame: webContainer.bounds, configuration: configuration)
        web.navigationDelegate = self
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.showsVerticalScrollIndicator = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.translatesAutoresizingMaskIntoConstraints = false
        webContainer.addSubview(web)
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: webContainer.topAnchor),
            web.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
        ])
        webView = web
        web.load(URLRequest(url: url))
    }

    // MARK: - Actions

    private func shareTapped() {
        guard let url else { return }
        LunaShareSheet.present(items: [url], from: self, anchor: .view(shareButton))
    }

    @objc private func finishTapped() {
        // Record the pending request first — so the open never loses it.
        delegate?.rescueFailureCardDidRequestRescue(self)
        if let url = rescueURL { delegate?.rescueFailureCard(self, openApp: url) }
        // We can't observe whether the deep-link open succeeded from an extension,
        // so always leave the manual instruction (the app's foreground drain is the
        // real guarantee).
        rescueButton.isHidden = true
        manualLabel.isHidden = false
        doneButton.isHidden = false
    }

    @objc private func cancelTapped() {
        delegate?.rescueFailureCardDidFinish(self)
    }

    #if DEBUG
    /// Test seam: fires the same record-the-request path the button does, without
    /// synthesizing a touch on a card that was never put in a window.
    public func recordPendingRescueForTesting() {
        delegate?.rescueFailureCardDidRequestRescue(self)
    }
    #endif
}

// MARK: - WKNavigationDelegate

extension RescueFailureViewController: WKNavigationDelegate {

    /// The card is a window onto ONE page and the URL bar names it, so a tapped
    /// link is refused rather than navigating in place. There's no full-screen
    /// browser to hand off to inside an extension, so this simply declines.
    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        decisionHandler(navigationAction.navigationType == .linkActivated ? .cancel : .allow)
    }
}

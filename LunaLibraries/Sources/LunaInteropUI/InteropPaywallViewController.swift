//
//  InteropPaywallViewController.swift
//  LunaInteropUI
//

import LunaInterop
import LunaDesignSystem
import UIKit

/// The Luna Interoperability paywall: the full purchase/restore screen, reached
/// from Settings ("Luna Interoperability") and from the `<ownScheme>://interop`
/// deep link the extension prompt opens. Main-app only — extensions never
/// present this (purchases can't run there); they deep-link here instead.
///
/// Shows the one-time non-consumable's live App Store price, what it unlocks
/// ("send any link to any Luna app"), Buy, Restore, and — mandatory — the
/// restore caveat: each Luna app sells its OWN product, so restoring only works
/// in the app the unlock was originally bought in.
public final class InteropPaywallViewController: UIViewController {

    private let purchaseController: InteropPurchaseController
    /// Called after a successful purchase or restore, so a presenting flow can
    /// retry whatever the lock was blocking.
    public var onUnlocked: (() -> Void)?

    private let stateBadge = UIImageView()
    private let headline = UILabel()
    private let explainer = UILabel()
    private let priceLabel = UILabel()
    private let buyButton = UIButton(type: .system)
    private let restoreButton = UIButton(type: .system)
    private let restoreCaveat = UILabel()
    private let statusLabel = UILabel()

    public init(purchaseController: InteropPurchaseController = .shared) {
        self.purchaseController = purchaseController
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "Luna Interoperability"

        stateBadge.contentMode = .center

        headline.font = .preferredFont(forTextStyle: .title3)
        headline.textAlignment = .center
        headline.numberOfLines = 0

        explainer.font = .preferredFont(forTextStyle: .body)
        explainer.textColor = .secondaryLabel
        explainer.textAlignment = .center
        explainer.numberOfLines = 0
        explainer.text = "Send any link to any Luna app. Save articles you find while "
            + "price-tracking, products you spot while reading, and videos from "
            + "anywhere — every Luna app can file a link where it belongs. One "
            + "purchase unlocks this in all Luna apps on this device."

        priceLabel.font = .preferredFont(forTextStyle: .headline)
        priceLabel.textAlignment = .center

        var buyConfig = UIButton.Configuration.filled()
        buyConfig.title = "Unlock"
        buyConfig.image = UIImage(systemName: "cart")
        buyConfig.imagePadding = 8
        buyConfig.baseBackgroundColor = GlassStyle.readingAccent
        buyButton.configuration = buyConfig
        buyButton.addAction(UIAction { [weak self] _ in self?.buyTapped() }, for: .touchUpInside)

        var restoreConfig = UIButton.Configuration.tinted()
        restoreConfig.title = "Restore Purchase"
        restoreConfig.baseForegroundColor = GlassStyle.readingAccent
        restoreButton.configuration = restoreConfig
        restoreButton.addAction(UIAction { [weak self] _ in self?.restoreTapped() }, for: .touchUpInside)

        restoreCaveat.font = .preferredFont(forTextStyle: .footnote)
        restoreCaveat.textColor = .secondaryLabel
        restoreCaveat.textAlignment = .center
        restoreCaveat.numberOfLines = 0
        restoreCaveat.text = "Purchases restore through the Luna app you originally bought "
            + "the unlock in — if you paid in another Luna app, open that app and tap "
            + "Restore there. Apps on this device already share one unlock."

        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.isHidden = true

        let stack = UIStackView(arrangedSubviews: [
            stateBadge, headline, explainer, priceLabel, buyButton, statusLabel,
            restoreButton, restoreCaveat,
        ])
        stack.axis = .vertical
        stack.spacing = 16
        stack.setCustomSpacing(8, after: headline)
        stack.setCustomSpacing(24, after: explainer)
        stack.setCustomSpacing(8, after: priceLabel)
        stack.setCustomSpacing(8, after: restoreButton)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
        ])

        render()
        if !purchaseController.isUnlocked {
            loadPrice()
        }
    }

    /// Renders locked vs unlocked (by reason). Single source of truth for every
    /// state so a purchase/restore mid-screen re-renders consistently. A
    /// build-granted unlock (debug/TestFlight) never offers Buy/Restore and
    /// says so — it must not imply a purchase happened.
    private func render() {
        let status = purchaseController.unlockStatus
        let unlocked = status != .locked
        stateBadge.image = UIImage(
            systemName: unlocked ? "checkmark.circle.fill" : "arrow.left.arrow.right.circle",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 44, weight: .semibold))
        stateBadge.tintColor = unlocked ? .systemGreen : GlassStyle.readingAccent
        switch status {
        case .purchased:
            headline.text = "Luna Interoperability is unlocked"
        case .debugBuild:
            headline.text = "Luna Interoperability is unlocked (debug build)"
        case .testFlight:
            headline.text = "Luna Interoperability is unlocked (TestFlight)"
        case .locked:
            headline.text = "Save across all Luna apps"
        }
        priceLabel.isHidden = unlocked
        buyButton.isHidden = unlocked
        restoreButton.isHidden = unlocked
        restoreCaveat.isHidden = unlocked
        switch status {
        case .purchased:
            explainer.text = "Every Luna app on this device can now save any kind of "
                + "link — articles, videos, and products all land in the right app."
        case .debugBuild, .testFlight:
            explainer.text = "All paid features are free on this build — every Luna "
                + "app on this device can save any kind of link. Nothing was "
                + "purchased; the App Store version sells this unlock for $1.99."
        case .locked:
            break // keep the sales copy set in viewDidLoad
        }
    }

    private func loadPrice() {
        priceLabel.text = "One-time purchase"
        Task { [weak self] in
            guard let self else { return }
            if let product = await self.purchaseController.loadProduct() {
                self.priceLabel.text = "One-time purchase — \(product.displayPrice)"
                var config = self.buyButton.configuration
                config?.title = "Unlock for \(product.displayPrice)"
                self.buyButton.configuration = config
            } else {
                self.priceLabel.text = "One-time purchase — price unavailable right now"
            }
        }
    }

    private func buyTapped() {
        buyButton.isEnabled = false
        showStatus("Contacting the App Store…")
        Task { [weak self] in
            guard let self else { return }
            do {
                switch try await self.purchaseController.purchase() {
                case .unlocked:
                    self.statusLabel.isHidden = true
                    self.render()
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    self.onUnlocked?()
                case .userCancelled:
                    self.statusLabel.isHidden = true
                case .pending:
                    self.showStatus("Purchase pending approval — it will unlock automatically "
                        + "once approved.")
                }
            } catch {
                self.showStatus("The purchase couldn't be completed. Please try again.",
                                isError: true)
            }
            self.buyButton.isEnabled = true
        }
    }

    private func restoreTapped() {
        restoreButton.isEnabled = false
        showStatus("Restoring…")
        Task { [weak self] in
            guard let self else { return }
            let restored = (try? await self.purchaseController.restore()) ?? false
            if restored {
                self.statusLabel.isHidden = true
                self.render()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                self.onUnlocked?()
            } else {
                // The caveat below the button already explains the most likely
                // reason (bought in a different Luna app); restate it here so the
                // outcome isn't a silent nothing.
                self.showStatus("No purchase to restore in this app. If you bought the "
                    + "unlock in another Luna app, open that app and tap Restore there.",
                    isError: true)
            }
            self.restoreButton.isEnabled = true
        }
    }

    private func showStatus(_ text: String, isError: Bool = false) {
        statusLabel.text = text
        statusLabel.textColor = isError ? .systemRed : .secondaryLabel
        statusLabel.isHidden = false
    }
}

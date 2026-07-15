//
//  InteropPromptViewController.swift
//  LunaInteropUI
//

import LunaInterop
import LunaURLClassification
import LunaDesignSystem
import UIKit

/// The cross-app-interop prompt, shown when a save's outcome belongs to a
/// DIFFERENT Luna app (`claudedocs/interop-purchase.md`). One screen, two
/// configurations (`InteropPromptKind`):
///
/// - `.needsInstall` — the save WENT THROUGH (paid, or same-surface), but the
///   owning app isn't installed: purely informational ("install Luna X to see
///   it there"). A custom `luna*://` scheme can't fall back to the App Store
///   and there are no App Store listings yet, so the install step is text, not
///   a link.
/// - `.blocked` — unpaid cross-surface write, NOTHING was saved: shows the
///   install step too (when the owner is uninstalled) plus the pay step. The
///   pay step differs by context:
///     - in-app: runs the purchase right here via `InteropPurchaseController`
///       and calls `onUnlocked` so the caller can retry the save;
///     - in-extension: purchases can't run in an app extension, so the button
///       deep-links `<current app's ownScheme>://interop` (via the host's
///       injected opener — `extensionContext.open` has no UIApplication in an
///       extension) with always-visible manual fallback instructions.
///
/// Presentation chrome is the HOST's job: extensions present it through
/// `ExtensionHost.presentModally` (which wraps it in their nav + Done), the
/// app presents it modally (`onDone` dismisses). Same pattern as
/// `SavedNonTextualViewController`.
public final class InteropPromptViewController: UIViewController {

    /// Where the prompt is running, which decides how the pay step works.
    public enum Context {
        /// The main app: the purchase runs inline.
        case inApp
        /// A share/action extension: `openURL` is the host's
        /// `extensionContext.open` (or equivalent). The pay step deep-links
        /// into the containing app instead of purchasing.
        case extensionHost(openURL: (URL) -> Void)
    }

    private let kind: InteropPromptKind
    private let context: Context
    private let currentSurface: InteropSurface
    private let purchaseController: InteropPurchaseController
    /// Blocked + in-app only: called after a successful inline purchase so the
    /// caller can retry the save that was blocked.
    private let onUnlocked: (() -> Void)?
    /// Called when the user is done with the prompt (Done button / after a
    /// successful purchase). The host completes/dismisses.
    public var onDone: (() -> Void)?

    private let payButton = UIButton(type: .system)
    private let payStatus = UILabel()

    public init(
        kind: InteropPromptKind,
        context: Context,
        currentSurface: InteropSurface = .current,
        purchaseController: InteropPurchaseController = .shared,
        onUnlocked: (() -> Void)? = nil
    ) {
        self.kind = kind
        self.context = context
        self.currentSurface = currentSurface
        self.purchaseController = purchaseController
        self.onUnlocked = onUnlocked
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let owner = kind.owner

        switch kind {
        case .needsInstall:
            title = "Saved to Luna"
        case .blocked:
            title = "Not Saved"
        }
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.finish() })

        // Header: icon + headline naming the owning app.
        let isBlocked: Bool
        if case .blocked = kind { isBlocked = true } else { isBlocked = false }

        let badge = UIImageView(image: UIImage(
            systemName: isBlocked ? "lock.circle.fill" : "checkmark.circle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 44, weight: .semibold)))
        badge.tintColor = isBlocked ? .systemOrange : GlassStyle.readingAccent
        badge.contentMode = .center

        let headline = UILabel()
        headline.font = .preferredFont(forTextStyle: .headline)
        headline.textAlignment = .center
        headline.numberOfLines = 0

        let explainer = UILabel()
        explainer.font = .preferredFont(forTextStyle: .body)
        explainer.textColor = .secondaryLabel
        explainer.textAlignment = .center
        explainer.numberOfLines = 0

        switch kind {
        case .needsInstall:
            headline.text = "This link is handled by \(owner.displayName)"
            explainer.text = "It's saved — it will appear in \(owner.displayName) "
                + "once that app is installed on this device."
        case .blocked(_, let ownerInstalled):
            headline.text = "This link is handled by \(owner.displayName)"
            explainer.text = ownerInstalled
                ? "Saving it from \(currentSurface.displayName) needs the one-time "
                    + "Luna Interoperability unlock. You can also share it straight "
                    + "to \(owner.displayName) instead."
                : "Saving it from \(currentSurface.displayName) needs the one-time "
                    + "Luna Interoperability unlock."
        }

        var steps: [UIView] = [badge, headline, explainer]

        // Install step — whenever the owning app is missing (paid or not).
        if needsInstallStep {
            steps.append(makeStepView(
                symbolName: "arrow.down.app",
                title: "Install \(owner.displayName)",
                detail: "Get \(owner.displayName) from the App Store so links like "
                    + "this one have somewhere to appear."))
        }

        // Pay step — blocked only.
        if isBlocked {
            steps.append(contentsOf: makePayStepViews())
        }

        let stack = UIStackView(arrangedSubviews: steps)
        stack.axis = .vertical
        stack.spacing = 16
        stack.setCustomSpacing(8, after: headline)
        stack.setCustomSpacing(28, after: explainer)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
        ])
    }

    private var needsInstallStep: Bool {
        switch kind {
        case .needsInstall: return true
        case .blocked(_, let ownerInstalled): return !ownerInstalled
        }
    }

    // MARK: - Step rows

    /// A horizontal icon + title/detail row, shared by the install step (and
    /// visually consistent with the pay step's button-above-footnote shape).
    private func makeStepView(symbolName: String, title: String, detail: String) -> UIView {
        let icon = UIImageView(image: UIImage(
            systemName: symbolName,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 28, weight: .regular)))
        icon.tintColor = GlassStyle.readingAccent
        icon.contentMode = .center
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.numberOfLines = 0

        let detailLabel = UILabel()
        detailLabel.text = detail
        detailLabel.font = .preferredFont(forTextStyle: .subheadline)
        detailLabel.textColor = .secondaryLabel
        detailLabel.numberOfLines = 0

        let textStack = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        textStack.axis = .vertical
        textStack.spacing = 2

        let row = UIStackView(arrangedSubviews: [icon, textStack])
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = 12

        let card = UIView()
        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
        ])
        return card
    }

    // MARK: - Pay step

    private func makePayStepViews() -> [UIView] {
        var views: [UIView] = []
        var config = UIButton.Configuration.filled()
        config.image = UIImage(systemName: "cart")
        config.imagePadding = 8
        config.baseBackgroundColor = GlassStyle.readingAccent

        payStatus.font = .preferredFont(forTextStyle: .subheadline)
        payStatus.textColor = .secondaryLabel
        payStatus.textAlignment = .center
        payStatus.numberOfLines = 0
        payStatus.isHidden = true

        switch context {
        case .inApp:
            config.title = "Unlock Luna Interoperability ($1.99)"
            payButton.configuration = config
            payButton.addAction(
                UIAction { [weak self] _ in self?.purchaseInline() }, for: .touchUpInside)
            views.append(payButton)
            views.append(payStatus)

        case .extensionHost(let openURL):
            // Purchases can't run inside an app extension: hand off to the
            // CONTAINING app's paywall via its own scheme. A custom scheme open
            // can silently fail from an extension, so the manual route is
            // always visible below the button, not tucked behind a failure.
            config.title = "Unlock in \(currentSurface.displayName) ($1.99)"
            payButton.configuration = config
            let scheme = currentSurface.deepLinkScheme
            payButton.addAction(UIAction { _ in
                if let url = LunaDeepLink.interopLink(scheme: scheme) {
                    openURL(url)
                }
            }, for: .touchUpInside)
            views.append(payButton)

            let fallback = UILabel()
            fallback.font = .preferredFont(forTextStyle: .footnote)
            fallback.textColor = .secondaryLabel
            fallback.textAlignment = .center
            fallback.numberOfLines = 0
            fallback.text = "If nothing opens, open \(currentSurface.displayName) and go to "
                + "Settings → Luna Interoperability to unlock."
            views.append(fallback)
        }
        return views
    }

    /// In-app purchase: runs StoreKit inline; on success flips the button to a
    /// confirmation, notifies `onUnlocked` (the caller retries the blocked
    /// save), and dismisses shortly after.
    private func purchaseInline() {
        payButton.isEnabled = false
        payStatus.text = "Contacting the App Store…"
        payStatus.textColor = .secondaryLabel
        payStatus.isHidden = false
        Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await self.purchaseController.purchase()
                switch outcome {
                case .unlocked:
                    self.payStatus.text = "Unlocked — saving your link."
                    var config = self.payButton.configuration
                    config?.title = "Unlocked"
                    config?.image = UIImage(systemName: "checkmark.circle.fill")
                    self.payButton.configuration = config
                    self.onUnlocked?()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                        self?.finish()
                    }
                case .userCancelled:
                    self.payButton.isEnabled = true
                    self.payStatus.isHidden = true
                case .pending:
                    self.payButton.isEnabled = true
                    self.payStatus.text = "Purchase pending approval. Your link isn't saved yet — "
                        + "share it again once the purchase is approved."
                }
            } catch {
                self.payButton.isEnabled = true
                self.payStatus.text = "The purchase couldn't be completed. Please try again."
                self.payStatus.textColor = .systemRed
            }
        }
    }

    private func finish() {
        if let onDone {
            onDone()
        } else {
            dismiss(animated: true)
        }
    }
}

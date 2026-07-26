//
//  FailedSaveCardViewController.swift
//  LunaReadingListUI
//

import LunaDesignSystem
import LunaModels
import UIKit

/// Everything a failed save's card shows and can do. Assembled by the app shell
/// (which alone can reach the failure sidecar, the favicon cache, the rescue
/// coordinator, and the share provider) and rendered by
/// `FailedSaveCardViewController` here, so the Reader and Downloader roots draw
/// the SAME error card instead of each inventing one.
public struct FailedSaveCardModel {

    /// Best-effort headline — a fetched title, the stored one, a slug guess, or
    /// the host. Never empty (see `FailedSaveNaming.displayTitle`).
    public var title: String
    /// Publisher / site name shown beside the favicon.
    public var siteName: String?
    /// The URL that failed, scheme stripped. Shown in full: which link broke is
    /// the first thing the user needs.
    public var urlText: String
    /// One sentence naming the failure, from `SaveFailureReason.headline`.
    public var detail: String
    /// An optional second sentence suggesting what to do about it.
    public var suggestion: String?
    /// "Tried 3 times · 2 days ago"-style provenance, or nil when there's only
    /// been the one attempt.
    public var attemptFooter: String?
    /// Whether a rescue is running right now — the card shows a spinner and
    /// disables its buttons instead of offering the same tap again.
    public var isRescuing: Bool
    /// Hints the user may pick from before invoking the LLM. Empty means the
    /// running app implies the hint (single-content apps) and the card just
    /// shows one button; more than one means the central Luna app is asking.
    public var hintChoices: [RescueHint]
    /// Whether the LLM rescue path is available at all (Apple Intelligence
    /// present, engine installed). False hides the button entirely rather than
    /// offering a no-op.
    public var canRescue: Bool
    /// Whether a plain re-fetch is worth offering next to the LLM path.
    public var canRetry: Bool

    public init(
        title: String, siteName: String? = nil, urlText: String,
        detail: String, suggestion: String? = nil, attemptFooter: String? = nil,
        isRescuing: Bool = false, hintChoices: [RescueHint] = [],
        canRescue: Bool = true, canRetry: Bool = false
    ) {
        self.title = title
        self.siteName = siteName
        self.urlText = urlText
        self.detail = detail
        self.suggestion = suggestion
        self.attemptFooter = attemptFooter
        self.isRescuing = isRescuing
        self.hintChoices = hintChoices
        self.canRescue = canRescue
        self.canRetry = canRetry
    }
}

/// What the card's buttons do. Injected closures, not a delegate: each root
/// wires them to its own store/share/rescue plumbing and the view stays free of
/// every tier above LunaDesignSystem.
public struct FailedSaveCardActions {
    /// Run the LLM rescue with this hint (nil = let the app imply it).
    public var rescue: (RescueHint?) -> Void
    /// Open the failing URL in the full-screen in-app web view.
    public var openInBrowser: () -> Void
    /// Share the URL (a failed save has nothing else to share).
    public var share: (UIView) -> Void
    /// Re-run the ordinary background fetch.
    public var retry: (() -> Void)?

    public init(
        rescue: @escaping (RescueHint?) -> Void,
        openInBrowser: @escaping () -> Void,
        share: @escaping (UIView) -> Void,
        retry: (() -> Void)? = nil
    ) {
        self.rescue = rescue
        self.openInBrowser = openInBrowser
        self.share = share
        self.retry = retry
    }
}

/// The error state of a saved link, as a carousel card: favicon + real title,
/// the URL that failed, what went wrong, and the three things worth doing about
/// it (ask Apple Intelligence, open it in a browser, share it elsewhere).
///
/// Deliberately NOT playable and NOT tappable-through: a failed card's only
/// interactions are its own buttons, so the carousel's tap/scrub gestures don't
/// fight them.
public final class FailedSaveCardViewController: CardContentViewController {

    private var model: FailedSaveCardModel
    private let actions: FailedSaveCardActions
    /// Injected so the app's favicon cache (which lives in the app shell) stays
    /// out of this tier. Called on the main queue, possibly twice: a fallback
    /// glyph first, then the fetched icon.
    private let loadIcon: (@escaping (UIImage?) -> Void) -> Void

    private let scrollView = UIScrollView()
    private let iconView = UIImageView()
    private let iconContainer = UIView()
    private let titleLabel = UILabel()
    private let siteLabel = UILabel()
    private let urlLabel = UILabel()
    private let detailLabel = UILabel()
    private let suggestionLabel = UILabel()
    private let footerLabel = UILabel()
    private let spinner = DotMatrixSpinnerView(dimension: 3, side: 18)
    private let hintControl = LunaSegmentedControl()
    private let rescueButton = UIButton(type: .system)
    private let browserButton = UIButton(type: .system)
    private let shareButton = UIButton(type: .system)
    private let retryButton = UIButton(type: .system)
    private let buttonStack = UIStackView()
    /// The three lesser actions share one line as compact pills, so the card
    /// reads as "one thing to try, plus the usual escapes" rather than a list.
    private let secondaryButtonRow = UIStackView()
    private let contentStack = UIStackView()

    public init(
        model: FailedSaveCardModel,
        actions: FailedSaveCardActions,
        loadIcon: @escaping (@escaping (UIImage?) -> Void) -> Void = { $0(nil) }
    ) {
        self.model = model
        self.actions = actions
        self.loadIcon = loadIcon
        super.init()
    }

    /// The card's own interactions are its buttons; a stray card tap would
    /// otherwise page or toggle playback under the user's finger.
    public override func allowsCardTap(at point: CGPoint) -> Bool { false }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        buildHierarchy()
        apply(model)
        loadIcon { [weak self] image in
            guard let image else { return }
            self?.setIcon(image)
        }
    }

    /// Re-renders in place (a rescue started/finished, a metadata read landed) so
    /// the host doesn't have to tear the card down and rebuild it mid-carousel.
    public func update(_ model: FailedSaveCardModel) {
        self.model = model
        guard isViewLoaded else { return }
        apply(model)
    }

    public func setIcon(_ image: UIImage) {
        iconView.image = image
        iconView.tintColor = nil
        iconView.contentMode = .scaleAspectFit
    }

    // MARK: - Hierarchy

    private func buildHierarchy() {
        // A tall error card with a long URL and two paragraphs can outgrow a
        // short card on a small device — scroll rather than clip.
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = false
        scrollView.showsVerticalScrollIndicator = false
        view.addSubview(scrollView)

        iconContainer.backgroundColor = LunaColors.tertiaryBackground
        iconContainer.layer.cornerRadius = 12
        iconContainer.layer.cornerCurve = .continuous
        iconContainer.clipsToBounds = true
        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        // A site with no reachable icon gets a question mark, not a blank box.
        iconView.image = UIImage(systemName: "questionmark")
        iconView.tintColor = LunaColors.tertiaryText
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.addSubview(iconView)

        titleLabel.font = .preferredFont(forTextStyle: .title3)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = LunaColors.primaryText
        titleLabel.numberOfLines = 3

        siteLabel.font = .preferredFont(forTextStyle: .footnote)
        siteLabel.adjustsFontForContentSizeCategory = true
        siteLabel.textColor = LunaColors.secondaryText
        siteLabel.numberOfLines = 1

        urlLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        urlLabel.textColor = LunaColors.tertiaryText
        urlLabel.numberOfLines = 3
        urlLabel.lineBreakMode = .byCharWrapping

        // What went wrong is stated, not shouted: the card's red lives entirely
        // in the rim glow the carousel draws around it (`setEdgeGlow`), so the
        // content stays in the app's ordinary text hierarchy.
        detailLabel.font = .preferredFont(forTextStyle: .subheadline)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = LunaColors.primaryText
        detailLabel.numberOfLines = 0

        suggestionLabel.font = .preferredFont(forTextStyle: .footnote)
        suggestionLabel.adjustsFontForContentSizeCategory = true
        suggestionLabel.textColor = LunaColors.secondaryText
        suggestionLabel.numberOfLines = 0

        footerLabel.font = .preferredFont(forTextStyle: .caption2)
        footerLabel.adjustsFontForContentSizeCategory = true
        footerLabel.textColor = LunaColors.quaternaryText
        footerLabel.numberOfLines = 1

        spinner.color = LunaColors.secondaryText
        spinner.hidesWhenStopped = true

        hintControl.addAction(UIAction { [weak self] _ in
            self?.updateRescueTitle()
        }, for: .valueChanged)

        applyRescueTitle()
        configure(browserButton, title: L10n.string("Browser"), symbol: "globe")
        configure(shareButton, title: L10n.string("Share"), symbol: "square.and.arrow.up")
        configure(retryButton, title: L10n.string("Retry"), symbol: "arrow.clockwise")

        rescueButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.actions.rescue(self.selectedHint())
        }, for: .touchUpInside)
        browserButton.addAction(UIAction { [weak self] _ in
            self?.actions.openInBrowser()
        }, for: .touchUpInside)
        shareButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.actions.share(self.shareButton)
        }, for: .touchUpInside)
        retryButton.addAction(UIAction { [weak self] _ in
            self?.actions.retry?()
        }, for: .touchUpInside)

        secondaryButtonRow.axis = .horizontal
        secondaryButtonRow.spacing = 8
        secondaryButtonRow.distribution = .fillEqually
        for button in [browserButton, shareButton, retryButton] {
            secondaryButtonRow.addArrangedSubview(button)
        }
        buttonStack.axis = .vertical
        buttonStack.spacing = 10
        buttonStack.addArrangedSubview(rescueButton)
        buttonStack.addArrangedSubview(secondaryButtonRow)

        let header = UIStackView(arrangedSubviews: [iconContainer, headerTextStack()])
        header.axis = .horizontal
        header.spacing = 12
        header.alignment = .top

        contentStack.axis = .vertical
        contentStack.spacing = 12
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        for subview in [header, urlLabel, detailLabel, suggestionLabel,
                        spinner, hintControl, buttonStack, footerLabel] {
            contentStack.addArrangedSubview(subview)
        }
        contentStack.setCustomSpacing(6, after: header)
        contentStack.setCustomSpacing(4, after: detailLabel)
        contentStack.setCustomSpacing(18, after: suggestionLabel)
        scrollView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            contentStack.leadingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 22),
            contentStack.trailingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -22),
            contentStack.widthAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -44),
            // Vertically centered while it fits, top-aligned once it doesn't.
            contentStack.topAnchor.constraint(
                greaterThanOrEqualTo: scrollView.contentLayoutGuide.topAnchor, constant: 28),
            contentStack.bottomAnchor.constraint(
                lessThanOrEqualTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -28),
            contentStack.centerYAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.centerYAnchor),
            scrollView.contentLayoutGuide.heightAnchor.constraint(
                greaterThanOrEqualTo: scrollView.frameLayoutGuide.heightAnchor),

            iconContainer.widthAnchor.constraint(equalToConstant: 40),
            iconContainer.heightAnchor.constraint(equalToConstant: 40),
            iconView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 26),
            iconView.heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    private func headerTextStack() -> UIStackView {
        let stack = UIStackView(arrangedSubviews: [titleLabel, siteLabel])
        stack.axis = .vertical
        stack.spacing = 2
        return stack
    }

    /// One of the compact glass pills sharing the secondary row.
    private func configure(_ button: UIButton, title: String, symbol: String) {
        button.configuration = GlassStyle.actionButtonConfiguration(
            title: title, symbol: symbol, compact: true)
        button.contentHorizontalAlignment = .center
    }

    // MARK: - Rendering

    private func apply(_ model: FailedSaveCardModel) {
        titleLabel.text = model.title
        siteLabel.text = model.siteName
        siteLabel.isHidden = model.siteName == nil
        urlLabel.text = model.urlText
        detailLabel.text = model.detail
        suggestionLabel.text = model.suggestion
        suggestionLabel.isHidden = model.suggestion == nil
        footerLabel.text = model.attemptFooter
        footerLabel.isHidden = model.attemptFooter == nil

        applyHintChoices(model.hintChoices)
        rescueButton.isHidden = !model.canRescue
        retryButton.isHidden = !model.canRetry || model.isRescuing

        // While the LLM is working the card says so once, and every button that
        // would start it again goes away.
        if model.isRescuing {
            spinner.startAnimating()
            detailLabel.text = L10n.string("Trying harder with Apple Intelligence…")
            suggestionLabel.isHidden = true
            hintControl.isHidden = true
            rescueButton.isHidden = true
        } else {
            spinner.stopAnimating()
        }
        spinner.isHidden = !model.isRescuing
        // An empty secondary row would still claim its stack spacing.
        secondaryButtonRow.isHidden = secondaryButtonRow.arrangedSubviews.allSatisfy(\.isHidden)
        updateRescueTitle()
    }

    private func applyHintChoices(_ choices: [RescueHint]) {
        // One implied hint (a single-content app) needs no picker at all.
        guard choices.count > 1 else {
            hintControl.isHidden = true
            return
        }
        hintControl.isHidden = false
        guard hintControl.numberOfSegments != choices.count else { return }
        hintControl.removeAllSegments()
        for (index, hint) in choices.enumerated() {
            hintControl.insertSegment(withTitle: hint.displayName, at: index, animated: false)
        }
        hintControl.selectedSegmentIndex = 0
    }

    private func selectedHint() -> RescueHint? {
        guard model.hintChoices.count > 1 else { return model.hintChoices.first }
        let index = hintControl.selectedSegmentIndex
        guard model.hintChoices.indices.contains(index) else { return model.hintChoices.first }
        return model.hintChoices[index]
    }

    /// With a picker up, the button names what it will attempt, so the two
    /// controls read as one sentence ("Price Tracker" → "Extract as Price Tracker").
    private func updateRescueTitle() {
        guard !rescueButton.isHidden else { return }
        applyRescueTitle()
    }

    private func applyRescueTitle() {
        let title = model.hintChoices.count > 1
            ? selectedHint().map { L10n.string("Extract as \($0.displayName)") }
                ?? L10n.string("Try with Apple Intelligence")
            : L10n.string("Try with Apple Intelligence")
        rescueButton.configuration = GlassStyle.actionButtonConfiguration(
            title: title, symbol: "wand.and.stars", prominent: true)
        rescueButton.contentHorizontalAlignment = .center
    }
}

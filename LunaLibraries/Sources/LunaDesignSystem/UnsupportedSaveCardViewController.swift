//
//  UnsupportedSaveCardViewController.swift
//  LunaDesignSystem
//

import LunaModels
import UIKit

/// The ONE screen every Luna surface shows when a link is classified into a
/// content kind the running app doesn't handle: the main app's interactive
/// saves, the share extension, and the action extension all present THIS,
/// so a user who meets the message in the share sheet and again in the app
/// recognises one object rather than two different apologies.
///
/// It is dressed as the root card carousel, because that is what the app looks
/// like: the starry sky behind, one 9:16 Liquid-Glass-rimmed card at the
/// carousel's own geometry, and the app's own tint carried by both (the rim's
/// glass and the starlight both come from `LunaSurfacePalette`, which resolves
/// per bundle id — so an extension inherits its host app's colour).
///
/// The content is two statements. The header names what just failed and where
/// ("Unable to save this link in Luna Reader") and is shown for EVERY drop. If
/// a sibling Luna app owns the kind, its actual app icon and the line naming it
/// follow underneath; a drop with no sibling owner shows the header alone.
///
/// Lives in LunaDesignSystem — below both the app shell and LunaShareSurface —
/// so all three hosts can present the same type. Nothing was saved, so the card
/// never shows a checkmark and its only action is dismissal.
public final class UnsupportedSaveCardViewController: UIViewController {

    /// The Luna app that DOES handle the dropped link, or nil when the link
    /// belongs to no sibling app (header only).
    private let owner: LunaApp?
    private let currentApp: LunaApp

    /// Runs when the user dismisses the card. The extensions complete their
    /// request silently here; the app dismisses the presentation.
    public var onDone: (() -> Void)?

    private let cardView = CardSurfaceView()
    private let contentStack = UIStackView()
    private let doneButton = UIButton(type: .system)
    /// Held so `viewDidLayoutSubviews` can hand them the width they wrap at —
    /// the card's own frame is only known then. See `applyLabelWrapWidth`.
    private var wrappingLabels: [UILabel] = []

    /// The card's own inner margin — wide enough that the text never crowds the
    /// 22pt corner radius.
    private static let contentInset: CGFloat = 26
    private static let iconSide: CGFloat = 96

    public init(owner: LunaApp?, currentApp: LunaApp = .current) {
        self.owner = owner
        self.currentApp = currentApp
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LunaColors.background
        // The extensions render inside the host's window, so the appearance is
        // applied to the view controller rather than a window we don't own
        // (`claudedocs/visual-effects.md`). In the app this is a no-op repeat of
        // what the window already carries.
        AppearanceSettings.apply(to: self)
        StarfieldView.install(behindContentsOf: view)

        cardView.setBorderEnabled(true)
        view.addSubview(cardView)

        buildContent()
    }

    /// The card carries its own Done pill, so a host that wrapped it in
    /// navigation chrome (the extensions do) must not also show an empty bar
    /// above it — the app presents the card bare, and the two have to match.
    /// Safe to do unconditionally: this card is always terminal in its stack.
    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
    }

    // MARK: - Hierarchy

    private func buildContent() {
        let header = UILabel()
        header.text = UnsupportedSaveCopy.header(current: currentApp)
        header.textColor = LunaColors.primaryText
        header.font = .preferredFont(forTextStyle: .title3)
        header.adjustsFontForContentSizeCategory = true
        header.textAlignment = .center
        header.numberOfLines = 0
        wrappingLabels.append(header)

        // `.fill`, not `.center`: a centered stack sizes a multi-line label to
        // its own ambiguous intrinsic width, which wrapped the header
        // differently on every screen. The labels span the stack and centre
        // their TEXT instead; only the fixed-size icon needs a centring wrapper.
        contentStack.axis = .vertical
        contentStack.alignment = .fill
        contentStack.spacing = 24
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(header)

        if let owner {
            let icon = LunaAppIconView(app: owner, side: Self.iconSide)
            let iconRow = UIView()
            iconRow.addSubview(icon)

            let upsell = UILabel()
            upsell.text = UnsupportedSaveCopy.upsell(owner: owner)
            upsell.textColor = LunaColors.secondaryText
            upsell.font = .preferredFont(forTextStyle: .subheadline)
            upsell.adjustsFontForContentSizeCategory = true
            upsell.textAlignment = .center
            upsell.numberOfLines = 0
            wrappingLabels.append(upsell)

            // Icon and its line are one unit, tighter than the gap to the header.
            let owned = UIStackView(arrangedSubviews: [iconRow, upsell])
            owned.axis = .vertical
            owned.alignment = .fill
            owned.spacing = 16
            contentStack.addArrangedSubview(owned)
            NSLayoutConstraint.activate([
                icon.centerXAnchor.constraint(equalTo: iconRow.centerXAnchor),
                icon.topAnchor.constraint(equalTo: iconRow.topAnchor),
                icon.bottomAnchor.constraint(equalTo: iconRow.bottomAnchor),
            ])
        }

        doneButton.configuration = GlassStyle.actionButtonConfiguration(
            title: L10n.string("Done"), symbol: "checkmark", prominent: true)
        doneButton.addAction(
            UIAction { [weak self] _ in self?.onDone?() }, for: .touchUpInside)
        doneButton.translatesAutoresizingMaskIntoConstraints = false

        // The message sits in the card's optical middle; Done rides the chin,
        // the way the carousel's cards put their one action at the bottom.
        let container = UIView()
        container.addSubview(contentStack)
        container.addSubview(doneButton)
        cardView.installContentView(container)

        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(
                equalTo: container.leadingAnchor, constant: Self.contentInset),
            contentStack.trailingAnchor.constraint(
                equalTo: container.trailingAnchor, constant: -Self.contentInset),
            contentStack.centerYAnchor.constraint(
                equalTo: container.centerYAnchor, constant: -Self.iconSide / 4),

            doneButton.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            doneButton.bottomAnchor.constraint(
                equalTo: container.bottomAnchor, constant: -Self.contentInset),
            doneButton.topAnchor.constraint(
                greaterThanOrEqualTo: contentStack.bottomAnchor, constant: 24),
        ])
    }

    // MARK: - Layout

    /// The card is frame-laid out from the SAME metrics the carousel resolves,
    /// so its width matches the deck's centered card exactly.
    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.bounds.inset(by: view.safeAreaInsets)
        guard safe.width > 0, safe.height > 0 else { return }
        let metrics = CardCarouselMetrics.resolve(containerSize: safe.size)
        cardView.frame = metrics.centeredCardFrame().offsetBy(
            dx: safe.minX, dy: safe.minY)
        applyLabelWrapWidth(cardWidth: cardView.bounds.width)
    }

    /// The card's content view is installed by autoresizing into a container
    /// whose width is zero until the frame above is set, so a `numberOfLines =
    /// 0` label can resolve its intrinsic size against nothing and never be
    /// asked again — on a cold-launched app that hyphenated the header down a
    /// six-line column ("Luna Down-/loader"). Handing both labels the width
    /// they actually get removes the guess. Only written when it CHANGES: the
    /// invalidation it triggers would otherwise loop.
    private func applyLabelWrapWidth(cardWidth: CGFloat) {
        let width = cardWidth - Self.contentInset * 2
        guard width > 0 else { return }
        for label in wrappingLabels where label.preferredMaxLayoutWidth != width {
            label.preferredMaxLayoutWidth = width
        }
    }
}

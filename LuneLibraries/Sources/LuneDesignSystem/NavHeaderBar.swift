//
//  NavHeaderBar.swift
//  LuneDesignSystem
//
//  A plain-UIView recreation of a standard small-title UINavigationBar header, used
//  in place of the UINavigationController's own navigation bar. Because it's an
//  ordinary content subview of a screen (pinned to the safe-area top), it is captured
//  and animated as part of the Dot Matrix push/pop pixel-wipe transition — unlike the
//  real nav bar, which UIKit renders/animates separately and "pops" in at the end of
//  the transition.
//
//  Layout matches a system small-title bar: a 44pt bar below the safe-area top, with a
//  leading control stack, a centered (large: leading) title, and a trailing control
//  stack. A solid (de-glassed) background fill + hairline separator fade in as content
//  scrolls under it (mirroring a standard nav bar over a scroll view), via
//  `updateScrolledAppearance`.
//
//  Restyle note (Task 3): the button factories below produce PLAIN system-styled
//  controls (no liquid-glass coupling), so they can be freely restyled.
//

import UIKit

public final class NavHeaderBar: UIView {

    /// The fixed height of the bar row itself (below the safe-area inset), matching a
    /// standard compact navigation bar.
    public static let barHeight: CGFloat = 44

    /// The standard horizontal inset of bar content from the screen edges.
    public static let horizontalInset: CGFloat = 8

    // De-glassed (Task 3): a solid, trait-aware fill that fades in on scroll instead of
    // a live blur. The header sits on a solid screen background, so the blur added little
    // and could not be captured faithfully by the Dot Matrix pixel-wipe transition.
    private let backgroundFill: UIView = {
        let view = UIView()
        view.backgroundColor = .systemBackground
        view.translatesAutoresizingMaskIntoConstraints = false
        view.alpha = 0
        return view
    }()

    private let separator: UIView = {
        let line = UIView()
        line.backgroundColor = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.alpha = 0
        return line
    }()

    /// The bar row (44pt), pinned to the bottom of the header (i.e. directly under the
    /// safe-area top inset the header itself spans).
    private let barRow = UIView()

    private let titleLabel = UILabel()
    private let leadingStack = UIStackView()
    private let trailingStack = UIStackView()

    /// The header's total height = top safe-area inset + bar row. When the header is
    /// pinned by its top/leading/trailing only (e.g. a subview of a scroll view's frame
    /// guide), the host drives this; when pinned bottom-anchored to a safe-area guide it
    /// stays inactive.
    private var heightConstraint: NSLayoutConstraint?

    /// Whether the title renders as a large, leading-aligned title that scrolls AWAY
    /// (handled by the host placing it; here it only affects the resting font/size of
    /// the inline title — large-title screens keep this `false` and host the big title
    /// separately as scrolling content).
    public var title: String? {
        didSet { titleLabel.text = title }
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .clear

        addSubview(backgroundFill)
        addSubview(separator)
        barRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(barRow)

        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        leadingStack.axis = .horizontal
        leadingStack.spacing = 8
        leadingStack.alignment = .center
        leadingStack.translatesAutoresizingMaskIntoConstraints = false

        trailingStack.axis = .horizontal
        trailingStack.spacing = 8
        trailingStack.alignment = .center
        trailingStack.translatesAutoresizingMaskIntoConstraints = false

        barRow.addSubview(titleLabel)
        barRow.addSubview(leadingStack)
        barRow.addSubview(trailingStack)

        NSLayoutConstraint.activate([
            backgroundFill.topAnchor.constraint(equalTo: topAnchor),
            backgroundFill.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundFill.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundFill.bottomAnchor.constraint(equalTo: bottomAnchor),

            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),

            barRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            barRow.trailingAnchor.constraint(equalTo: trailingAnchor),
            barRow.bottomAnchor.constraint(equalTo: bottomAnchor),
            barRow.heightAnchor.constraint(equalToConstant: Self.barHeight),

            leadingStack.leadingAnchor.constraint(equalTo: barRow.leadingAnchor, constant: Self.horizontalInset),
            leadingStack.centerYAnchor.constraint(equalTo: barRow.centerYAnchor),
            trailingStack.trailingAnchor.constraint(equalTo: barRow.trailingAnchor, constant: -Self.horizontalInset),
            trailingStack.centerYAnchor.constraint(equalTo: barRow.centerYAnchor),

            titleLabel.centerXAnchor.constraint(equalTo: barRow.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: barRow.centerYAnchor),
            // Keep the centered title clear of the button clusters.
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingStack.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingStack.leadingAnchor, constant: -8),
        ])
    }

    /// Drives the header's total height (top safe-area inset + 44pt bar row) for hosts
    /// that pin the header by top/leading/trailing only (scroll-view frame-guide mount).
    /// Idempotent; only the constant changes after the first call.
    public func setManagedHeight(topSafeAreaInset: CGFloat) {
        let target = topSafeAreaInset + Self.barHeight
        if let heightConstraint {
            if abs(heightConstraint.constant - target) > 0.5 { heightConstraint.constant = target }
        } else {
            let constraint = heightAnchor.constraint(equalToConstant: target)
            constraint.isActive = true
            heightConstraint = constraint
        }
    }

    // MARK: - Content

    /// Replaces the leading control cluster (e.g. a back button, or settings/friends).
    public func setLeadingControls(_ controls: [UIView]) {
        replace(stack: leadingStack, with: controls)
    }

    /// Replaces the trailing control cluster (e.g. add/search, or share/clear).
    public func setTrailingControls(_ controls: [UIView]) {
        replace(stack: trailingStack, with: controls)
    }

    private func replace(stack: UIStackView, with controls: [UIView]) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for control in controls { stack.addArrangedSubview(control) }
    }

    // MARK: - Scrolled appearance

    /// Fades the material background + hairline separator in as scrollable content
    /// passes under the bar, matching a standard navigation bar over a scroll view.
    /// `contentOffsetY` and `adjustedTopInset` are the scroll view's live values.
    public func updateScrolledAppearance(contentOffsetY: CGFloat, adjustedTopInset: CGFloat) {
        // 0 when the content top sits at (or below) the bar; ramps to 1 over the first
        // few points the content scrolls UNDER the bar.
        let scrolledUnder = contentOffsetY + adjustedTopInset
        let amount = max(0, min(1, scrolledUnder / 6))
        backgroundFill.alpha = amount
        separator.alpha = amount
    }

    // MARK: - Button factories

    /// A back chevron control wired to `action` on `target`, styled like the system
    /// back button's chevron (label-tinted).
    public static func backButton(target: Any?, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(
            UIImage(systemName: "chevron.backward",
                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)),
            for: .normal)
        button.tintColor = .label
        button.accessibilityLabel = "Back"
        button.addTarget(target, action: action, for: .touchUpInside)
        sizeToBarButton(button)
        return button
    }

    /// An icon (SF Symbol) bar button styled like a plain `UIBarButtonItem` image item.
    public static func imageButton(
        systemName: String, target: Any?, action: Selector,
        tint: UIColor = .label, accessibilityLabel: String? = nil
    ) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(
            UIImage(systemName: systemName,
                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)),
            for: .normal)
        button.tintColor = tint
        button.accessibilityLabel = accessibilityLabel
        button.addTarget(target, action: action, for: .touchUpInside)
        sizeToBarButton(button)
        return button
    }

    /// A text bar button styled like a plain `UIBarButtonItem` title item (system blue,
    /// or a custom tint, e.g. red for destructive).
    public static func textButton(
        title: String, target: Any?, action: Selector,
        tint: UIColor = .tintColor, bold: Bool = false
    ) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 17, weight: bold ? .semibold : .regular)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.tintColor = tint
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.barHeight).isActive = true
        return button
    }

    /// Gives an icon button a 44pt-tall square-ish hit target like a system bar button.
    private static func sizeToBarButton(_ button: UIButton) {
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 34),
            button.heightAnchor.constraint(equalToConstant: Self.barHeight),
        ])
    }
}

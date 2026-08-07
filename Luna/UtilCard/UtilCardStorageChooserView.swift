//
//  UtilCardStorageChooserView.swift
//  Luna
//

import LunaDesignSystem
import LunaModels
import UIKit

/// The util card's one-line "Store downloads …" choice, at the top of the setup
/// block in the two apps that download media.
///
/// It wears no pill and no rim — it is a sentence with one word you can change,
/// not another action button under three action buttons. Tapping the selector
/// opens both options IN PLACE: the panel lands with the selected option exactly
/// where the collapsed selector was, so the word you were reading does not move
/// and the alternative appears beside it, over whatever the card had there.
final class UtilCardStorageChooserView: UIView {

    enum Option: CaseIterable, Equatable {
        case luna
        case photos
    }

    /// One text line's worth of row. The block above the paste field is tight,
    /// and this row is prose rather than a target the size of a button.
    static let height: CGFloat = 34

    private static let labelFont = UIFont.systemFont(ofSize: 15, weight: .regular)
    private static let optionFont = UIFont.systemFont(ofSize: 15, weight: .semibold)
    /// The icons are height-matched to the text they precede, not to the row.
    private static var iconSide: CGFloat { optionFont.lineHeight.rounded() }
    private static let iconToTitle: CGFloat = 6
    private static let labelToSelector: CGFloat = 6
    private static let selectorToChevron: CGFloat = 5
    private static let chevronWidth: CGFloat = 10
    /// The expanded panel's padding around its rows, and the row height it uses
    /// — which is the collapsed selector's own height, so the selected option
    /// lands exactly where it already was. The horizontal padding is
    /// `labelToSelector` on purpose: the panel's leading edge then lands in the
    /// seam after "Store downloads" instead of over its last letters.
    private static var panelPadding: CGSize { CGSize(width: labelToSelector, height: 7) }
    private static var optionRowHeight: CGFloat { iconSide + 8 }

    /// The user tapped an option. `luna` is applied by the caller directly;
    /// `photos` may be refused, which is why the caller — not this view — owns
    /// what the selection becomes.
    var onSelect: ((Option) -> Void)?

    private(set) var selection: Option = .photos

    private let titleLabel = UILabel()
    private let selector = UIControl()
    private let selectorIcon = UIImageView()
    private let selectorLabel = UILabel()
    private let chevron = UIImageView()

    /// The expansion lives in the CARD, not in this row: it has to cover the
    /// rows and buttons around it, and a row-sized view cannot.
    private var panel: UIView?
    private var dismissCatcher: UIControl?
    private var optionRows: [Option: UIControl] = [:]

    var isExpanded: Bool { panel != nil }

    init() {
        super.init(frame: .zero)
        accessibilityIdentifier = "utilCard.storage"

        titleLabel.text = L10n.string("Onboarding_Util_storage1Label")
        titleLabel.font = Self.labelFont
        titleLabel.textColor = LunaColors.primaryText
        titleLabel.isAccessibilityElement = false
        addSubview(titleLabel)

        selectorIcon.contentMode = .scaleAspectFill
        selectorIcon.clipsToBounds = true
        selectorIcon.layer.cornerCurve = .continuous
        selectorLabel.font = Self.optionFont
        selectorLabel.textColor = LunaColors.primaryText
        chevron.image = UIImage(
            systemName: "chevron.up.chevron.down",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .semibold))
        chevron.tintColor = UIColor.white.withAlphaComponent(0.45)
        chevron.contentMode = .scaleAspectFit
        for subview in [selectorIcon, selectorLabel, chevron] as [UIView] {
            subview.isUserInteractionEnabled = false
            selector.addSubview(subview)
        }
        selector.addTarget(self, action: #selector(selectorTapped), for: .touchUpInside)
        selector.isAccessibilityElement = true
        selector.accessibilityTraits = .button
        selector.accessibilityLabel = titleLabel.text
        selector.accessibilityIdentifier = "utilCard.storage.selector"
        addSubview(selector)

        apply(selection: selection)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The choice as it stands. Setting it collapses nothing — the caller
    /// applies the outcome of a tap, which may be the value that was already
    /// there (a refused Photos request reverts to Luna).
    func setSelection(_ option: Option) {
        guard option != selection else { return }
        selection = option
        apply(selection: option)
        setNeedsLayout()
    }

    private func apply(selection: Option) {
        selectorIcon.image = Self.icon(for: selection)
        selectorLabel.text = Self.title(for: selection)
        selector.accessibilityValue = selectorLabel.text
        for (option, row) in optionRows {
            row.alpha = option == selection ? 1 : 0.55
        }
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let titleWidth = titleLabel.sizeThatFits(bounds.size).width.rounded(.up)
        titleLabel.frame = CGRect(
            x: 0, y: 0, width: titleWidth, height: bounds.height)

        let selectorWidth = Self.selectorWidth(for: selection)
        let selectorHeight = Self.optionRowHeight
        selector.frame = CGRect(
            x: titleLabel.frame.maxX + Self.labelToSelector,
            y: ((bounds.height - selectorHeight) / 2).rounded(),
            width: selectorWidth,
            height: selectorHeight)
        layoutSelectorContents(
            in: selector,
            icon: selectorIcon,
            label: selectorLabel,
            trailingReserve: Self.selectorToChevron + Self.chevronWidth)
        chevron.frame = CGRect(
            x: selector.bounds.width - Self.chevronWidth,
            y: ((selectorHeight - 10) / 2).rounded(),
            width: Self.chevronWidth,
            height: 10)

        // A reflow underneath the open panel would otherwise leave it anchored
        // to where the row used to be.
        if panel != nil { positionExpansion() }
    }

    /// The icon-then-text run shared by the collapsed selector and each row of
    /// the expanded panel, so the two line up to the point.
    private func layoutSelectorContents(
        in container: UIView,
        icon: UIImageView,
        label: UILabel,
        trailingReserve: CGFloat = 0
    ) {
        let side = Self.iconSide
        icon.frame = CGRect(
            x: 0,
            y: ((container.bounds.height - side) / 2).rounded(),
            width: side,
            height: side)
        icon.layer.cornerRadius = side * LunaAppIconImage.cornerRadiusRatio
        let labelX = icon.frame.maxX + Self.iconToTitle
        label.frame = CGRect(
            x: labelX,
            y: 0,
            width: max(0, container.bounds.width - labelX - trailingReserve),
            height: container.bounds.height)
    }

    /// The row's whole width, so the card can lay a chooser out without asking
    /// it to size itself against an unknown container.
    static func selectorWidth(for option: Option) -> CGFloat {
        let text = (title(for: option) as NSString)
            .size(withAttributes: [.font: optionFont]).width.rounded(.up)
        return iconSide + iconToTitle + text + selectorToChevron + chevronWidth
    }

    // MARK: - Expansion

    @objc private func selectorTapped() {
        if isExpanded { collapse() } else { expand() }
    }

    private func expand() {
        guard let host = superview, panel == nil else { return }

        let catcher = UIControl(frame: host.bounds)
        catcher.backgroundColor = .clear
        catcher.addTarget(self, action: #selector(catcherTapped), for: .touchUpInside)
        host.addSubview(catcher)
        dismissCatcher = catcher

        let panel = UIView()
        panel.backgroundColor = UIColor(white: 0.13, alpha: 1)
        panel.layer.cornerRadius = 12
        panel.layer.cornerCurve = .continuous
        // No rim: the panel separates itself from the card by being lighter than
        // it and by the shadow it casts, the way a menu does.
        panel.layer.shadowColor = UIColor.black.cgColor
        panel.layer.shadowOpacity = 0.55
        panel.layer.shadowRadius = 14
        panel.layer.shadowOffset = CGSize(width: 0, height: 6)
        host.addSubview(panel)
        self.panel = panel

        optionRows = [:]
        for option in Option.allCases {
            let row = UIControl()
            let icon = UIImageView(image: Self.icon(for: option))
            icon.contentMode = .scaleAspectFill
            icon.clipsToBounds = true
            icon.layer.cornerCurve = .continuous
            let label = UILabel()
            label.text = Self.title(for: option)
            label.font = Self.optionFont
            label.textColor = LunaColors.primaryText
            icon.isUserInteractionEnabled = false
            label.isUserInteractionEnabled = false
            row.addSubview(icon)
            row.addSubview(label)
            row.tag = option == .luna ? 0 : 1
            row.accessibilityIdentifier = option == .luna
                ? "utilCard.storage.option.luna"
                : "utilCard.storage.option.photos"
            row.accessibilityLabel = label.text
            row.accessibilityTraits = .button
            row.addTarget(self, action: #selector(optionTapped(_:)), for: .touchUpInside)
            row.alpha = option == selection ? 1 : 0.55
            panel.addSubview(row)
            optionRows[option] = row
        }

        positionExpansion()
        // The panel takes over the selector's job while it is open; the chevron
        // left behind beside it reads as a second, orphaned control.
        chevron.isHidden = true
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        panel.alpha = 0
        panel.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
        UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseOut]) {
            panel.alpha = 1
            panel.transform = .identity
        }
    }

    /// Lands the panel so the SELECTED option's row sits exactly on the
    /// collapsed selector — the point of expanding "in place".
    private func positionExpansion() {
        guard let host = superview, let panel else { return }
        dismissCatcher?.frame = host.bounds

        let rowHeight = Self.optionRowHeight
        let widest = Option.allCases
            .map { Self.selectorWidth(for: $0) - Self.selectorToChevron - Self.chevronWidth }
            .max() ?? 0
        let selectedIndex = CGFloat(Option.allCases.firstIndex(of: selection) ?? 0)
        let anchor = convert(selector.frame, to: host)
        panel.bounds = CGRect(
            x: 0, y: 0,
            width: widest + Self.panelPadding.width * 2,
            height: rowHeight * CGFloat(Option.allCases.count) + Self.panelPadding.height * 2)
        panel.center = CGPoint(
            x: anchor.minX - Self.panelPadding.width + panel.bounds.width / 2,
            y: anchor.minY - Self.panelPadding.height - rowHeight * selectedIndex
                + panel.bounds.height / 2)

        for (index, option) in Option.allCases.enumerated() {
            guard let row = optionRows[option] else { continue }
            row.frame = CGRect(
                x: Self.panelPadding.width,
                y: Self.panelPadding.height + rowHeight * CGFloat(index),
                width: widest,
                height: rowHeight)
            guard let icon = row.subviews.compactMap({ $0 as? UIImageView }).first,
                  let label = row.subviews.compactMap({ $0 as? UILabel }).first
            else { continue }
            layoutSelectorContents(in: row, icon: icon, label: label)
        }
        host.bringSubviewToFront(dismissCatcher ?? panel)
        host.bringSubviewToFront(panel)
    }

    func collapse() {
        guard let panel else { return }
        chevron.isHidden = false
        self.panel = nil
        optionRows = [:]
        let catcher = dismissCatcher
        dismissCatcher = nil
        guard !UIAccessibility.isReduceMotionEnabled else {
            panel.removeFromSuperview()
            catcher?.removeFromSuperview()
            return
        }
        UIView.animate(withDuration: 0.14, delay: 0, options: [.curveEaseIn]) {
            panel.alpha = 0
        } completion: { _ in
            panel.removeFromSuperview()
            catcher?.removeFromSuperview()
        }
    }

    @objc private func catcherTapped() { collapse() }

    @objc private func optionTapped(_ sender: UIControl) {
        let option: Option = sender.tag == 0 ? .luna : .photos
        collapse()
        onSelect?(option)
    }

    // MARK: - Option artwork and wording

    static func title(for option: Option) -> String {
        switch option {
        case .luna: return L10n.string("Onboarding_Util_storage2InLuna")
        case .photos: return L10n.string("Onboarding_Util_storage3InPhotos")
        }
    }

    /// Each option's real artwork: the running app's own icon, and the Photos
    /// pinwheel Luna draws (a sandboxed app cannot read another app's icon).
    static func icon(for option: Option) -> UIImage? {
        switch option {
        case .luna:
            return LunaAppIconImage.image(for: .current)
        case .photos:
            return PhotosAppGlyph.image(side: iconSide)
        }
    }
}

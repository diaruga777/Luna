//
//  UtilCardStorageChooserView.swift
//  Luna
//

import LunaDesignSystem
import LunaModels
import UIKit

/// The two taps the storage row reports.
@MainActor
protocol UtilCardStorageChooserDelegate: AnyObject {
    /// An option was tapped. `luna` is applied by the card directly; `photos`
    /// may be refused, which is why the CARD — not the row — owns what the
    /// selection becomes.
    func storageChooser(
        _ chooser: UtilCardStorageChooserView,
        didChoose option: UtilCardStorageChooserView.Option)

    /// The red exclamation badge was tapped — shown only while the selection is
    /// Photos and this process still lacks Photos access.
    func storageChooserDidTapPermissionError(_ chooser: UtilCardStorageChooserView)
}

/// The util card's one-line "Store downloads …" choice, at the top of the setup
/// block in the two apps that download media.
///
/// The explanatory sentence and its selector read as one centred control. The
/// selector is deliberately more prominent than the prose around it, while the
/// expanded choices become generous, well-separated tap targets.
final class UtilCardStorageChooserView: UIView {

    enum Option: CaseIterable, Equatable {
        case luna
        case photos
    }

    static let height: CGFloat = 46

    private static let labelFont = UIFont.systemFont(ofSize: 16, weight: .regular)
    private static let optionFont = UIFont.systemFont(ofSize: 18, weight: .semibold)
    /// The icons are height-matched to the text they precede, not to the row.
    private static var iconSide: CGFloat { optionFont.lineHeight.rounded() }
    private static let iconToTitle: CGFloat = 6
    private static let labelToSelector: CGFloat = 6
    /// A generous, fixed trailing chamber gives the carets a stable optical
    /// centre after either option's text instead of pinning them to the edge.
    private static let selectorToChevron: CGFloat = 18
    private static let chevronWidth: CGFloat = 16
    private static let selectorHorizontalInset: CGFloat = 8
    /// The expanded panel's padding around its rows, and the row height it uses
    /// — which is the collapsed selector's own height, so the selected option
    /// lands exactly where it already was. The horizontal padding is
    /// `labelToSelector` on purpose: the panel's leading edge then lands in the
    /// seam after "Store downloads" instead of over its last letters.
    private static var panelPadding: CGSize { CGSize(width: 16, height: 14) }
    private static let collapsedSelectorHeight: CGFloat = 40
    private static let optionRowHeight: CGFloat = 58
    private static let optionRowGap: CGFloat = 10
    /// The error badge overlaps the selector's top-trailing corner rather than
    /// claiming its own width — the row's overall size stays fixed whether or
    /// not permission is missing.
    private static let permissionErrorBadgeSide: CGFloat = 20

    /// The util card, which owns this row — hence weak.
    weak var delegate: (any UtilCardStorageChooserDelegate)?

    private(set) var selection: Option = .luna
    private(set) var hasPermissionError = false

    private let titleLabel = UILabel()
    private let selector = UIControl()
    private let selectorIcon = UIImageView()
    private let selectorLabel = UILabel()
    private let chevron = UIImageView()
    private let permissionErrorBadge = UIButton(type: .system)

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
        selector.layer.cornerRadius = 10
        selector.layer.cornerCurve = .continuous
        selector.layer.borderWidth = 1
        selector.layer.borderColor = UIColor.white.withAlphaComponent(0.23).cgColor
        selector.backgroundColor = UIColor.white.withAlphaComponent(0.06)
        chevron.image = UIImage(
            systemName: "chevron.up.chevron.down",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .bold))
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

        permissionErrorBadge.setImage(
            UIImage(systemName: "exclamationmark.circle.fill"), for: .normal)
        permissionErrorBadge.tintColor = .systemRed
        permissionErrorBadge.backgroundColor = LunaColors.background
        permissionErrorBadge.layer.cornerRadius = Self.permissionErrorBadgeSide / 2
        permissionErrorBadge.isHidden = true
        permissionErrorBadge.isAccessibilityElement = true
        permissionErrorBadge.accessibilityTraits = .button
        permissionErrorBadge.accessibilityLabel = L10n.string(
            "Onboarding_Util_storagePermissionBadgeLabel")
        permissionErrorBadge.accessibilityIdentifier = "utilCard.storage.permissionError"
        permissionErrorBadge.addTarget(
            self, action: #selector(permissionErrorTapped), for: .touchUpInside)
        addSubview(permissionErrorBadge)

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

    /// Whether Photos is selected but this process still lacks Photos access
    /// — shown as a red exclamation badge on the selector's corner. Tapping it
    /// is the caller's business (`storageChooserDidTapPermissionError`).
    func setPermissionError(_ hasError: Bool) {
        guard hasError != hasPermissionError else { return }
        hasPermissionError = hasError
        permissionErrorBadge.isHidden = !hasError
        setNeedsLayout()
    }

    @objc private func permissionErrorTapped() {
        delegate?.storageChooserDidTapPermissionError(self)
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
        // The complete line never changes width: both the control and its
        // leading label stay put when switching between "in Luna" and the
        // longer "in Photos" option.
        let selectorWidth = Self.collapsedSelectorWidth
        let selectorHeight = Self.collapsedSelectorHeight
        let wholeWidth = titleWidth + Self.labelToSelector + selectorWidth
        let leading = max((bounds.width - wholeWidth) / 2, 0).rounded()
        titleLabel.frame = CGRect(
            x: leading, y: 0, width: titleWidth, height: bounds.height)
        selector.frame = CGRect(
            x: titleLabel.frame.maxX + Self.labelToSelector,
            y: ((bounds.height - selectorHeight) / 2).rounded(),
            width: selectorWidth,
            height: selectorHeight)
        layoutSelectorContents(
            in: selector,
            icon: selectorIcon,
            label: selectorLabel,
            indicatorWidth: Self.selectorToChevron + Self.chevronWidth,
            drawsAppIconBorder: selection == .luna)
        chevron.frame = CGRect(
            x: (selectorLabel.frame.maxX + Self.selectorToChevron).rounded(),
            y: ((selectorHeight - Self.chevronWidth) / 2).rounded(),
            width: Self.chevronWidth,
            height: Self.chevronWidth)
        // Overlaps the selector's top-trailing corner, like a notification
        // badge, so its presence never shifts the row's fixed width.
        let badgeSide = Self.permissionErrorBadgeSide
        permissionErrorBadge.frame = CGRect(
            x: selector.frame.maxX - badgeSide * 0.6,
            y: selector.frame.minY - badgeSide * 0.4,
            width: badgeSide,
            height: badgeSide)

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
        trailingReserve: CGFloat = 0,
        indicatorWidth: CGFloat = 0,
        drawsAppIconBorder: Bool = false
    ) {
        let side = Self.iconSide
        let naturalWidth = label.sizeThatFits(
            CGSize(width: container.bounds.width, height: container.bounds.height)
        ).width.rounded(.up)
        let contentWidth = side + Self.iconToTitle + naturalWidth + indicatorWidth
        let leading = max(
            Self.selectorHorizontalInset,
            ((container.bounds.width - contentWidth) / 2).rounded())
        icon.frame = CGRect(
            x: leading,
            y: ((container.bounds.height - side) / 2).rounded(),
            width: side,
            height: side)
        icon.layer.cornerRadius = side * LunaAppIconImage.cornerRadiusRatio
        icon.layer.borderWidth = drawsAppIconBorder ? 1 : 0
        icon.layer.borderColor = drawsAppIconBorder
            ? UIColor.white.withAlphaComponent(0.32).cgColor
            : nil
        let labelX = icon.frame.maxX + Self.iconToTitle
        label.frame = CGRect(
            x: labelX,
            y: 0,
            width: min(
                naturalWidth,
                max(0, container.bounds.width - labelX - trailingReserve
                    - Self.selectorHorizontalInset)),
            height: container.bounds.height)
    }

    /// The row's whole width, so the card can lay a chooser out without asking
    /// it to size itself against an unknown container.
    static func selectorWidth(for option: Option) -> CGFloat {
        let text = (title(for: option) as NSString)
            .size(withAttributes: [.font: optionFont]).width.rounded(.up)
        return Self.selectorHorizontalInset * 2 + iconSide + iconToTitle + text
            + selectorToChevron + chevronWidth
    }

    private static var collapsedSelectorWidth: CGFloat {
        Option.allCases.map(selectorWidth(for:)).max() ?? 0
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
        let rowPitch = rowHeight + Self.optionRowGap
        let widest = Self.collapsedSelectorWidth
            - Self.selectorToChevron - Self.chevronWidth
        let selectedIndex = CGFloat(Option.allCases.firstIndex(of: selection) ?? 0)
        let anchor = convert(selector.frame, to: host)
        panel.bounds = CGRect(
            x: 0, y: 0,
            width: widest + Self.panelPadding.width * 2,
            height: rowHeight * CGFloat(Option.allCases.count)
                + Self.optionRowGap * CGFloat(max(Option.allCases.count - 1, 0))
                + Self.panelPadding.height * 2)
        panel.center = CGPoint(
            x: anchor.minX - Self.panelPadding.width + panel.bounds.width / 2,
            y: anchor.minY - Self.panelPadding.height - rowPitch * selectedIndex
                + panel.bounds.height / 2)

        for (index, option) in Option.allCases.enumerated() {
            guard let row = optionRows[option] else { continue }
            row.frame = CGRect(
                x: Self.panelPadding.width,
                y: Self.panelPadding.height + rowPitch * CGFloat(index),
                width: widest,
                height: rowHeight)
            guard let icon = row.subviews.compactMap({ $0 as? UIImageView }).first,
                  let label = row.subviews.compactMap({ $0 as? UILabel }).first
            else { continue }
            layoutSelectorContents(
                in: row, icon: icon, label: label,
                drawsAppIconBorder: option == .luna)
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
        delegate?.storageChooser(self, didChoose: option)
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
            return paddedAppIcon()
        case .photos:
            return PhotosAppGlyph.image(side: iconSide)
        }
    }

    /// The Luna artwork's moon sits close to its asset edge. A little
    /// transparent breathing room inside the same iOS-icon squircle keeps the
    /// moon from reading as pressed against the selector's new rim.
    private static func paddedAppIcon() -> UIImage? {
        guard let image = LunaAppIconImage.image(for: .current) else { return nil }
        let side = iconSide
        let inset = max(2, side * 0.12)
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            image.draw(in: CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2))
        }
    }
}

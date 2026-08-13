//
//  AlertThresholdRow.swift
//  LunaPriceUI
//

import LunaDesignSystem
import LunaModels
import UIKit

/// The alert control every product surface shows: **one row**, 46pt tall —
/// a large bell, a compact two-line "Alert at" + value block, and the slider.
///
/// A card has a fixed height and four things to fit into it, so this row
/// keeps the alert control to one line: the price at the end of the row IS
/// the threshold, and the number moves as the thumb does.
///
/// **Two states, one shape.** A tracker with no alert yet parks the slider where
/// an alert would begin, dims the track and thumb, and puts a **Set** button
/// where the price goes. Dragging the parked slider or tapping Set is the same
/// commit, which is what raises the notification prompt in the host (see
/// `claudedocs/price-tracking.md`). Nothing about the row's geometry changes
/// between the two, so setting an alert never moves the layout underneath.
///
/// Presentation-only: it updates its own readout live and reports the fraction
/// to its delegate — continuously while the slider moves, so the host can move
/// the graph's line with it, and once on commit, when the host should persist.
public protocol AlertThresholdRowDelegate: AnyObject {
    /// The slider moved. Fired continuously.
    func alertThresholdRow(_ row: AlertThresholdRow, didChangeFraction fraction: Double)
    /// The drag ended, or Set was tapped: the final fraction, to persist.
    func alertThresholdRow(_ row: AlertThresholdRow, didCommitFraction fraction: Double)
}

public final class AlertThresholdRow: UIView {

    /// The row's fixed height. Fixed because both hosts lay the row out between
    /// two flexible bands, and a control that changes height with its state
    /// would resize the graph above it.
    public static let height: CGFloat = 46

    /// The host that moves the graph line and persists the threshold. Weak: the
    /// host owns this row.
    public weak var delegate: (any AlertThresholdRowDelegate)?

    private let accent = LunaSurfacePalette.baseColor(for: .priceTracker)
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let slider = UISlider()
    private let priceLabel = UILabel()
    private let setButton = UIButton(type: .system)

    /// Whether the control is showing the no-threshold state.
    private var isUnset = false
    private var initialPrice: Decimal = 0
    private var currency = "USD"

    public init() {
        super.init(frame: .zero)
        buildLayout()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func buildLayout() {
        accessibilityIdentifier = "priceTracker.alert"
        backgroundColor = LunaColors.secondaryBackground
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous

        iconView.image = UIImage(
            systemName: "bell.badge",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold))
        iconView.tintColor = accent
        iconView.contentMode = .center
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.text = L10n.string("PriceTracker_alertThreshold_rowTitle")
        titleLabel.font = .systemFont(ofSize: 10, weight: .medium)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = LunaColors.secondaryText
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        slider.minimumValue = 0.01
        slider.maximumValue = 0.90
        slider.accessibilityLabel = L10n.string("PriceTracker_alertThreshold_title")
        slider.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)
        // .touchCancel included: a system-cancelled drag (incoming call, gesture
        // interruption) has still moved the slider and must persist.
        slider.addTarget(
            self, action: #selector(sliderCommitted),
            for: [.touchUpInside, .touchUpOutside, .touchCancel])
        slider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        priceLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        priceLabel.textColor = accent
        priceLabel.textAlignment = .left
        priceLabel.setContentHuggingPriority(.required, for: .horizontal)
        priceLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        var setConfiguration = UIButton.Configuration.plain()
        setConfiguration.title = L10n.string("PriceTracker_alertThreshold_setButtonTitle")
        setConfiguration.baseForegroundColor = accent
        setConfiguration.contentInsets = .zero
        setConfiguration.titleTextAttributesTransformer =
            UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = .systemFont(ofSize: 12, weight: .semibold)
                return attributes
            }
        setButton.configuration = setConfiguration
        setButton.isHidden = true
        setButton.setContentHuggingPriority(.required, for: .horizontal)
        setButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        setButton.addTarget(self, action: #selector(setAlertTapped), for: .touchUpInside)

        let value = UIStackView(arrangedSubviews: [titleLabel, priceLabel, setButton])
        value.axis = .vertical
        value.alignment = .leading
        value.spacing = -1
        value.setContentHuggingPriority(.required, for: .horizontal)
        value.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stack = UIStackView(arrangedSubviews: [iconView, value, slider])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            value.widthAnchor.constraint(greaterThanOrEqualToConstant: 68),
        ])
    }

    /// Points the row at a tracker: the slider's position and the baseline the
    /// price readout is computed against (the tracker's initial best price). A
    /// nil `fraction` is the "no alert set" state.
    public func configure(fraction: Double?, initialPrice: Decimal, currency: String) {
        self.initialPrice = initialPrice
        self.currency = currency
        isUnset = fraction == nil
        // Parked at where an alert would start, so the first drag is an
        // adjustment rather than a jump from zero.
        slider.value = Float(fraction ?? PriceTracker.defaultAlertThresholdFraction)
        applyState()
    }

    /// The absolute price the slider currently stands for.
    public var thresholdPrice: Decimal {
        initialPrice * (1 - Decimal(Double(slider.value)))
    }

    private func applyState() {
        slider.minimumTrackTintColor = isUnset ? LunaColors.quaternaryText : accent
        slider.thumbTintColor = isUnset ? LunaColors.tertiaryText : nil
        setButton.isHidden = !isUnset
        priceLabel.isHidden = isUnset
        slider.accessibilityValue = isUnset
            ? L10n.string("PriceTracker_alertThreshold_sliderValueUnset")
            : PriceFormatting.string(amount: thresholdPrice, currency: currency)
        updateReadout()
    }

    private func updateReadout() {
        let formatted = PriceFormatting.string(amount: thresholdPrice, currency: currency)
        priceLabel.text = formatted
        if !isUnset { slider.accessibilityValue = formatted }
    }

    @objc private func sliderChanged() {
        // Touching the parked slider IS setting an alert: show the real readout
        // from the first movement, so the value being committed is never a
        // surprise.
        if isUnset {
            isUnset = false
            applyState()
        }
        updateReadout()
        delegate?.alertThresholdRow(self, didChangeFraction: Double(slider.value))
    }

    @objc private func sliderCommitted() {
        if isUnset {
            isUnset = false
            applyState()
        }
        delegate?.alertThresholdRow(self, didCommitFraction: Double(slider.value))
    }

    /// The unset state's button: commits the parked default as-is, so one tap
    /// buys a working alert (and the permission prompt the host raises with it).
    @objc private func setAlertTapped() {
        isUnset = false
        applyState()
        delegate?.alertThresholdRow(self, didCommitFraction: Double(slider.value))
    }
}

//
//  AlertThresholdSlider.swift
//  LunaPriceUI
//

import LunaDesignSystem
import LunaModels
import UIKit

/// The solid rounded pill chrome for the price-tracking editor's interactive
/// `AlertThresholdSlider`. A solid pill (no blur) — it sits on the editor's solid
/// background, so a live blur would add little and can't be captured
/// consistently across presentation contexts.
public enum AlertThresholdPillChrome {
    /// An empty pill with the shared chrome; the caller fills in its own content.
    public static func makePill() -> UIView {
        let pill = UIView()
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.backgroundColor = GlassStyle.solidBarColor
        pill.layer.cornerRadius = 22
        pill.layer.cornerCurve = .continuous
        pill.clipsToBounds = true
        return pill
    }

    /// The pill's "Alert threshold" title label, styled identically everywhere.
    public static func makeTitleLabel() -> UILabel {
        let title = UILabel()
        title.text = L10n.string("Alert threshold")
        title.font = .preferredFont(forTextStyle: .headline)
        title.textColor = LunaColors.primaryText
        return title
    }
}

/// The shared alert-threshold control for price trackers: a solid rounded pill
/// (de-glassed — `GlassStyle.solidBarColor`) containing the title **"Alert threshold"**,
/// a slider over the fractional drop, and a readout line showing the same percent +
/// absolute price text everywhere (`PriceFormatting.thresholdDescription`).
///
/// Used by the price-tracking editor to drive `alertThresholdFraction`. The
/// view is presentation-only: it updates its own readout live while dragging and
/// reports the final fraction via `onCommitted` (when the host should persist),
/// never touching the store itself.
///
/// **Two states.** A tracker whose `alertThresholdFraction` is nil has no alert at
/// all (`configure(fraction: nil, …)`): the slider is PARKED where an alert would
/// begin — dimmed track and thumb — the readout becomes a call to action, and a
/// "Set price alert" button appears beside it. Dragging the parked slider or
/// tapping that button is the SAME commit the set state makes, which is what raises
/// the notification-permission prompt in the host (see
/// `claudedocs/price-tracking.md`). The set state is unchanged, down to its layout:
/// the button is a hidden arranged subview there.
public final class AlertThresholdSlider: UIView {

    /// Fired once the drag ends, with the final fraction. The host persists here.
    public var onCommitted: ((Double) -> Void)?

    private let slider = UISlider()
    private let readoutLabel = UILabel()
    private let pill = AlertThresholdPillChrome.makePill()
    /// The unset state's explicit tap target — a slider you must drag is a poor way
    /// to say "there is no alert yet, make one".
    private let setAlertButton = UIButton(type: .system)
    /// Whether the control is showing the no-threshold state.
    private var isUnset = false

    /// The price baseline + currency the readout's absolute-drop text is computed
    /// against (the tracker's initial best price). Set via `configure`.
    private var initialPrice: Decimal = 0
    private var currency: String = "USD"

    public init() {
        super.init(frame: .zero)
        buildLayout()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func buildLayout() {
        backgroundColor = .clear
        addSubview(pill)

        let title = AlertThresholdPillChrome.makeTitleLabel()

        slider.minimumValue = 0.01
        slider.maximumValue = 0.90
        slider.minimumTrackTintColor = GlassStyle.readingAccent
        slider.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)
        // .touchCancel included: a system-cancelled drag (incoming call, gesture
        // interruption) has still moved the slider and must persist.
        slider.addTarget(self, action: #selector(sliderCommitted),
                         for: [.touchUpInside, .touchUpOutside, .touchCancel])

        readoutLabel.font = .preferredFont(forTextStyle: .subheadline)
        readoutLabel.textColor = LunaColors.secondaryText
        readoutLabel.numberOfLines = 0

        var setAlertConfiguration = UIButton.Configuration.plain()
        setAlertConfiguration.title = L10n.string("Set price alert")
        setAlertConfiguration.baseForegroundColor = GlassStyle.readingAccent
        setAlertConfiguration.contentInsets = .zero
        setAlertButton.configuration = setAlertConfiguration
        setAlertButton.contentHorizontalAlignment = .leading
        setAlertButton.isHidden = true
        setAlertButton.addTarget(self, action: #selector(setAlertTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [title, slider, readoutLabel, setAlertButton])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(stack)

        NSLayoutConstraint.activate([
            pill.topAnchor.constraint(equalTo: topAnchor),
            pill.bottomAnchor.constraint(equalTo: bottomAnchor),
            pill.leadingAnchor.constraint(equalTo: leadingAnchor),
            pill.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: pill.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -20),
        ])
    }

    /// Points the control at a tracker: seeds the slider position and the readout's
    /// absolute-drop baseline (the tracker's initial best price + currency). A nil
    /// `fraction` is the tracker's "no alert set" state and shows the parked slider
    /// plus its call to action.
    public func configure(fraction: Double?, initialPrice: Decimal, currency: String) {
        self.initialPrice = initialPrice
        self.currency = currency
        isUnset = fraction == nil
        // Parked at where an alert would start, so the first drag is an adjustment
        // rather than a jump from zero.
        slider.value = Float(fraction ?? PriceTracker.defaultAlertThresholdFraction)
        applyState()
    }

    /// Paints whichever of the two states the control is in. Called on configure and
    /// on the first interaction (the parked slider becomes live under the finger).
    private func applyState() {
        slider.minimumTrackTintColor = isUnset
            ? LunaColors.quaternaryText : GlassStyle.readingAccent
        slider.thumbTintColor = isUnset ? LunaColors.tertiaryText : nil
        setAlertButton.isHidden = !isUnset
        if isUnset {
            readoutLabel.text = L10n.string(
                "No price alert yet. Set one to be notified when the price drops.")
            readoutLabel.textColor = LunaColors.tertiaryText
            slider.accessibilityValue = L10n.string("No price alert set")
        } else {
            readoutLabel.textColor = LunaColors.secondaryText
            slider.accessibilityValue = nil
            updateReadout(fraction: Double(slider.value))
        }
    }

    private func updateReadout(fraction: Double) {
        readoutLabel.text = PriceFormatting.thresholdDescription(
            fraction: fraction, initialPrice: initialPrice, currency: currency)
    }

    @objc private func sliderChanged() {
        // Touching the parked slider IS setting an alert: show the real readout from
        // the first movement, so the value being committed is never a surprise.
        if isUnset {
            isUnset = false
            applyState()
        }
        updateReadout(fraction: Double(slider.value))
    }

    @objc private func sliderCommitted() {
        if isUnset {
            isUnset = false
            applyState()
        }
        onCommitted?(Double(slider.value))
    }

    /// The unset state's button: commits the parked default as-is, so one tap buys a
    /// working alert (and the permission prompt the host raises with it).
    @objc private func setAlertTapped() {
        isUnset = false
        applyState()
        onCommitted?(Double(slider.value))
    }
}

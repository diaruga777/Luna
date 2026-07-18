//
//  AlertThresholdSlider.swift
//  Luna
//

import LunaDesignSystem
import LunaModels
import UIKit

/// The shared alert-threshold control for price trackers: a solid rounded pill
/// (de-glassed — `GlassStyle.solidBarColor`) containing the title **"Alert threshold"**,
/// a slider over the fractional drop, and a readout line showing the same percent +
/// absolute price text everywhere (`PriceFormatting.thresholdDescription`).
///
/// Used identically by the price-tracking editor and the catch-up price-tracker
/// card, so both render the same and drive the same `alertThresholdFraction`. The
/// view is presentation-only: it updates its own readout live while dragging and
/// reports the final fraction via `onCommitted` (when the host should persist),
/// never touching the store itself.
public final class AlertThresholdSlider: UIView {

    /// Fired once the drag ends, with the final fraction. The host persists here.
    public var onCommitted: ((Double) -> Void)?

    private let slider = UISlider()
    private let readoutLabel = UILabel()
    /// De-glassed (Task 3): a solid rounded pill. This sits on the editor / catch-up
    /// card's solid background, so the live blur added little and could not be captured
    /// consistently across presentation contexts.
    private let pill = UIView()

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

        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.backgroundColor = GlassStyle.solidBarColor
        pill.layer.cornerRadius = 22
        pill.layer.cornerCurve = .continuous
        pill.clipsToBounds = true
        addSubview(pill)

        let title = UILabel()
        title.text = "Alert threshold"
        title.font = .preferredFont(forTextStyle: .headline)
        title.textColor = .label

        slider.minimumValue = 0.01
        slider.maximumValue = 0.90
        slider.minimumTrackTintColor = GlassStyle.readingAccent
        slider.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)
        // .touchCancel included: a system-cancelled drag (incoming call, gesture
        // interruption) has still moved the slider and must persist.
        slider.addTarget(self, action: #selector(sliderCommitted),
                         for: [.touchUpInside, .touchUpOutside, .touchCancel])

        readoutLabel.font = .preferredFont(forTextStyle: .subheadline)
        readoutLabel.textColor = .secondaryLabel
        readoutLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [title, slider, readoutLabel])
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
    /// absolute-drop baseline (the tracker's initial best price + currency).
    public func configure(fraction: Double, initialPrice: Decimal, currency: String) {
        self.initialPrice = initialPrice
        self.currency = currency
        slider.value = Float(fraction)
        updateReadout(fraction: fraction)
    }

    private func updateReadout(fraction: Double) {
        readoutLabel.text = PriceFormatting.thresholdDescription(
            fraction: fraction, initialPrice: initialPrice, currency: currency)
    }

    @objc private func sliderChanged() {
        let fraction = Double(slider.value)
        updateReadout(fraction: fraction)
    }

    @objc private func sliderCommitted() {
        onCommitted?(Double(slider.value))
    }
}

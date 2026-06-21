//
//  AlertThresholdSlider.swift
//  Clip
//

import UIKit

/// The shared alert-threshold control for price trackers: a liquid-glass pill
/// (`GlassStyle.barEffect()`) containing the title **"Alert threshold"**, a slider
/// over the fractional drop, and a readout line showing the same percent + absolute
/// price text everywhere (`PriceFormatting.thresholdDescription`).
///
/// Used identically by the price-tracking editor and the catch-up price-tracker
/// card, so both render the same and drive the same `alertThresholdFraction`. The
/// view is presentation-only: it reports changes via `onChanged` (live, while
/// dragging) and `onCommitted` (on release, when the host should persist), and never
/// touches the store itself.
final class AlertThresholdSlider: UIView {

    /// Fired continuously as the slider drags, with the live fraction (0.01…0.90).
    /// The host updates any dependent UI but should NOT persist here.
    var onChanged: ((Double) -> Void)?
    /// Fired once the drag ends, with the final fraction. The host persists here.
    var onCommitted: ((Double) -> Void)?

    private let slider = UISlider()
    private let readoutLabel = UILabel()
    private let glassPill = UIVisualEffectView(effect: GlassStyle.barEffect())

    /// The price baseline + currency the readout's absolute-drop text is computed
    /// against (the tracker's initial best price). Set via `configure`.
    private var initialPrice: Decimal = 0
    private var currency: String = "USD"

    init() {
        super.init(frame: .zero)
        buildLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func buildLayout() {
        backgroundColor = .clear

        glassPill.translatesAutoresizingMaskIntoConstraints = false
        if #available(iOS 26.0, *) {
            glassPill.cornerConfiguration = .corners(radius: 22)
        } else {
            glassPill.layer.cornerRadius = 22
            glassPill.layer.cornerCurve = .continuous
            glassPill.clipsToBounds = true
        }
        addSubview(glassPill)

        let title = UILabel()
        title.text = "Alert threshold"
        title.font = .preferredFont(forTextStyle: .headline)
        title.textColor = .label

        slider.minimumValue = 0.01
        slider.maximumValue = 0.90
        slider.minimumTrackTintColor = GlassStyle.readingAccent
        slider.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)
        slider.addTarget(self, action: #selector(sliderCommitted),
                         for: [.touchUpInside, .touchUpOutside])

        readoutLabel.font = .preferredFont(forTextStyle: .subheadline)
        readoutLabel.textColor = .secondaryLabel
        readoutLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [title, slider, readoutLabel])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        glassPill.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            glassPill.topAnchor.constraint(equalTo: topAnchor),
            glassPill.bottomAnchor.constraint(equalTo: bottomAnchor),
            glassPill.leadingAnchor.constraint(equalTo: leadingAnchor),
            glassPill.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: glassPill.contentView.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: glassPill.contentView.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: glassPill.contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: glassPill.contentView.trailingAnchor, constant: -20),
        ])
    }

    /// Points the control at a tracker: seeds the slider position and the readout's
    /// absolute-drop baseline (the tracker's initial best price + currency).
    func configure(fraction: Double, initialPrice: Decimal, currency: String) {
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
        onChanged?(fraction)
    }

    @objc private func sliderCommitted() {
        onCommitted?(Double(slider.value))
    }
}

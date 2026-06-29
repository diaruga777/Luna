//
//  DotMatrixSwitch.swift
//  ClipDesignSystem
//
//  A custom dot-matrix-styled toggle that mimics `UISwitch`'s API and footprint, so
//  it can drop into `accessoryView` cells and existing target/action wiring. The
//  track is a pill paved with the app's rounded-square "dots"; the thumb is a small
//  cluster of dots that slides between the off (leading) and on (trailing) ends. When
//  on, the track + thumb take the accent tint; when off they're a muted grey.
//
//  Pure UIKit + Core Animation. No Metal, safe in extensions. Matches `UISwitch`'s
//  ~51×31 footprint, posts `.valueChanged`, and exposes `isOn` / `setOn(_:animated:)`.
//  Accessible as a switch-trait button reporting its on/off value.
//

import QuartzCore
import UIKit

/// A `UISwitch`-compatible toggle rendered in the dot-matrix language.
public final class DotMatrixSwitch: UIControl {

    // MARK: Public API (UISwitch-shaped)

    /// Whether the switch is on. Setting this is non-animated (matches `UISwitch`).
    public var isOn: Bool {
        get { _isOn }
        set { setOn(newValue, animated: false) }
    }

    /// The tint used for the track + thumb when on. Defaults to the system accent.
    public var onTintColorOverride: UIColor? {
        didSet { applyColors() }
    }

    public func setOn(_ on: Bool, animated: Bool) {
        guard on != _isOn else { return }
        _isOn = on
        layoutThumb(animated: animated)
        applyColors(animated: animated)
        updateAccessibility()
    }

    // MARK: Geometry (mirror UISwitch ~51×31)

    private static let footprint = CGSize(width: 51, height: 31)
    /// Dots-per-row in the track and the dot pitch are derived from the footprint.
    private let trackColumns = 13
    private let trackRows = 6
    private let thumbColumns = 5
    private let thumbRows = 6
    private let dotCornerFraction: CGFloat = 0.32
    private let dotSpacingFraction: CGFloat = 0.30

    // MARK: State

    private var _isOn = false

    // MARK: Layers

    private let trackContainer = CALayer()
    private var trackDots: [CALayer] = []
    private let thumbContainer = CALayer()
    private var thumbDots: [CALayer] = []

    // MARK: Init

    public override init(frame: CGRect) {
        super.init(frame: frame.isEmpty ? CGRect(origin: .zero, size: Self.footprint) : frame)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        layer.addSublayer(trackContainer)
        layer.addSublayer(thumbContainer)
        buildTrackDots()
        buildThumbDots()
        applyColors()
        addTarget(self, action: #selector(handleTap), for: .touchUpInside)
        isAccessibilityElement = true
        accessibilityTraits = .button
        updateAccessibility()
    }

    // MARK: Layout

    public override var intrinsicContentSize: CGSize { Self.footprint }

    public override func sizeThatFits(_ size: CGSize) -> CGSize { Self.footprint }

    public override func layoutSubviews() {
        super.layoutSubviews()
        // Center the fixed-footprint control within whatever bounds we're given.
        let box = CGRect(
            x: (bounds.width - Self.footprint.width) / 2,
            y: (bounds.height - Self.footprint.height) / 2,
            width: Self.footprint.width, height: Self.footprint.height)
        trackContainer.frame = box
        layoutTrackDots(in: box.size)
        layoutThumb(animated: false)
    }

    private func cellSize(columns: Int, rows: Int, in size: CGSize) -> CGSize {
        CGSize(width: size.width / CGFloat(columns), height: size.height / CGFloat(rows))
    }

    private func buildTrackDots() {
        trackDots.forEach { $0.removeFromSuperlayer() }
        trackDots = (0..<(trackColumns * trackRows)).map { _ in
            let dot = CALayer()
            trackContainer.addSublayer(dot)
            return dot
        }
    }

    private func buildThumbDots() {
        thumbDots.forEach { $0.removeFromSuperlayer() }
        thumbDots = (0..<(thumbColumns * thumbRows)).map { _ in
            let dot = CALayer()
            thumbContainer.addSublayer(dot)
            return dot
        }
    }

    private func layoutTrackDots(in size: CGSize) {
        guard trackDots.count == trackColumns * trackRows else { return }
        let cell = cellSize(columns: trackColumns, rows: trackRows, in: size)
        let dotW = cell.width * (1 - dotSpacingFraction)
        let dotH = cell.height * (1 - dotSpacingFraction)
        let dotSide = min(dotW, dotH)
        let radius = dotSide * dotCornerFraction
        for row in 0..<trackRows {
            for col in 0..<trackColumns {
                let dot = trackDots[row * trackColumns + col]
                dot.frame = CGRect(
                    x: CGFloat(col) * cell.width + (cell.width - dotSide) / 2,
                    y: CGFloat(row) * cell.height + (cell.height - dotSide) / 2,
                    width: dotSide, height: dotSide)
                dot.cornerRadius = radius
            }
        }
    }

    /// Position the thumb container at the leading (off) or trailing (on) edge and
    /// lay out its dots. The thumb spans `thumbColumns` of the track's columns.
    private func layoutThumb(animated: Bool) {
        let trackSize = trackContainer.frame.size
        guard trackSize.width > 0 else { return }
        let trackCell = cellSize(columns: trackColumns, rows: trackRows, in: trackSize)
        let thumbWidth = trackCell.width * CGFloat(thumbColumns)
        let thumbHeight = trackSize.height
        let leadingX = trackContainer.frame.minX
        let trailingX = trackContainer.frame.maxX - thumbWidth
        let targetX = _isOn ? trailingX : leadingX
        let frame = CGRect(x: targetX, y: trackContainer.frame.minY, width: thumbWidth, height: thumbHeight)

        let apply = {
            self.thumbContainer.frame = frame
            self.layoutThumbDots(in: CGSize(width: thumbWidth, height: thumbHeight), trackCell: trackCell)
        }
        if animated {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.22)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
            apply()
            CATransaction.commit()
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            apply()
            CATransaction.commit()
        }
    }

    private func layoutThumbDots(in size: CGSize, trackCell: CGSize) {
        guard thumbDots.count == thumbColumns * thumbRows else { return }
        // Thumb dots are slightly larger / denser than the track so the thumb reads
        // as a solid raised cluster.
        let cell = cellSize(columns: thumbColumns, rows: thumbRows, in: size)
        let dotW = cell.width * (1 - dotSpacingFraction * 0.6)
        let dotH = cell.height * (1 - dotSpacingFraction * 0.6)
        let dotSide = min(dotW, dotH)
        let radius = dotSide * dotCornerFraction
        for row in 0..<thumbRows {
            for col in 0..<thumbColumns {
                let dot = thumbDots[row * thumbColumns + col]
                dot.frame = CGRect(
                    x: CGFloat(col) * cell.width + (cell.width - dotSide) / 2,
                    y: CGFloat(row) * cell.height + (cell.height - dotSide) / 2,
                    width: dotSide, height: dotSide)
                dot.cornerRadius = radius
            }
        }
    }

    // MARK: Colors

    private var onColor: UIColor { onTintColorOverride ?? .tintColor }
    private var offTrackColor: UIColor {
        UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor.white.withAlphaComponent(0.18)
                : UIColor.black.withAlphaComponent(0.14)
        }
    }
    private var thumbColor: UIColor { .label }

    private func applyColors(animated: Bool = false) {
        let resolved = traitCollection
        let trackCG = (_isOn ? onColor : offTrackColor).resolvedColor(with: resolved).cgColor
        let thumbCG = (_isOn ? UIColor.white : thumbColor).resolvedColor(with: resolved).cgColor

        let apply = {
            self.trackDots.forEach { $0.backgroundColor = trackCG }
            self.thumbDots.forEach { $0.backgroundColor = thumbCG }
        }
        if animated {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.22)
            apply()
            CATransaction.commit()
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            apply()
            CATransaction.commit()
        }
    }

    public override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previous) {
            applyColors()
        }
    }

    // MARK: Interaction

    @objc private func handleTap() {
        setOn(!_isOn, animated: true)
        sendActions(for: .valueChanged)
    }

    // MARK: Accessibility

    private func updateAccessibility() {
        accessibilityValue = _isOn ? NSLocalizedString("On", comment: "switch on")
                                   : NSLocalizedString("Off", comment: "switch off")
        if #available(iOS 17.0, *) {
            accessibilityTraits.insert(.toggleButton)
        }
    }
}

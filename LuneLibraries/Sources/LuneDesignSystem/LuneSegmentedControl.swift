//
//  LuneSegmentedControl.swift
//  LuneDesignSystem
//

import UIKit

/// A small, snapshot-stable segmented control that matches the standard iOS
/// segmented-control shape closely, but owns its selected indicator as a normal
/// layer. This avoids UIKit's private, lazy selected-thumb view disappearing from
/// same-runloop Dot Matrix transition snapshots.
public final class LuneSegmentedControl: UIControl {
    fileprivate struct Segment {
        var title: String?
        var image: UIImage?
    }

    public var selectedSegmentIndex: Int {
        get { selectedIndex }
        set {
            selectedIndex = clampedSelectedIndex(newValue)
            updateSelection(animated: false)
        }
    }

    public var apportionsSegmentWidthsByContent = false {
        didSet {
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }

    private var segments: [Segment] = []
    private var segmentViews: [SegmentView] = []
    private var selectedIndex = UISegmentedControl.noSegment
    private let selectedLayer = CALayer()
    private let separatorLayer = CALayer()
    private var separatorSublayers: [CALayer] = []

    public override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    public convenience init(items: [Any]) {
        self.init(frame: .zero)
        for (index, item) in items.enumerated() {
            if let title = item as? String {
                insertSegment(withTitle: title, at: index, animated: false)
            } else if let image = item as? UIImage {
                insertSegment(with: image, at: index, animated: false)
            }
        }
    }

    public var numberOfSegments: Int { segments.count }

    public func removeAllSegments() {
        segments.removeAll()
        segmentViews.forEach { $0.removeFromSuperview() }
        segmentViews.removeAll()
        selectedSegmentIndex = UISegmentedControl.noSegment
        rebuildSeparators()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    public func insertSegment(withTitle title: String?, at index: Int, animated _: Bool) {
        insert(Segment(title: title, image: nil), at: index)
    }

    public func insertSegment(with image: UIImage?, at index: Int, animated _: Bool) {
        insert(Segment(title: nil, image: image), at: index)
    }

    public override var intrinsicContentSize: CGSize {
        CGSize(width: naturalSegmentWidths().reduce(0, +), height: 32)
    }

    public override func sizeThatFits(_ size: CGSize) -> CGSize {
        let natural = intrinsicContentSize
        return CGSize(
            width: size.width > 0 ? min(natural.width, size.width) : natural.width,
            height: min(natural.height, size.height > 0 ? size.height : natural.height))
    }

    public override func systemLayoutSizeFitting(_ targetSize: CGSize) -> CGSize {
        if targetSize == UIView.layoutFittingCompressedSize {
            return intrinsicContentSize
        }
        return super.systemLayoutSizeFitting(targetSize)
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = min(8, bounds.height / 2)
        selectedLayer.cornerRadius = max(0, min(7, (bounds.height - 4) / 2))
        separatorLayer.frame = bounds
        layoutSegments()
        updateSelection(animated: false)
    }

    public override func tintColorDidChange() {
        super.tintColorDidChange()
        updateColors()
    }

    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateColors()
    }

    public override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        selectSegment(at: touch.location(in: self), sendsAction: true)
        return true
    }

    public override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        selectSegment(at: touch.location(in: self), sendsAction: true)
        return true
    }

    private func commonInit() {
        isMultipleTouchEnabled = false
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        selectedLayer.cornerCurve = .continuous
        layer.addSublayer(selectedLayer)
        layer.addSublayer(separatorLayer)
        updateColors()
    }

    private func insert(_ segment: Segment, at index: Int) {
        let safeIndex = max(0, min(index, segments.count))
        segments.insert(segment, at: safeIndex)
        let view = SegmentView()
        view.configure(segment)
        segmentViews.insert(view, at: safeIndex)
        addSubview(view)
        if selectedSegmentIndex == UISegmentedControl.noSegment {
            selectedSegmentIndex = 0
        }
        rebuildSeparators()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private func selectSegment(at point: CGPoint, sendsAction: Bool) {
        guard bounds.contains(point), !segments.isEmpty else { return }
        for (index, frame) in segmentFrames().enumerated() where frame.contains(point) {
            guard index != selectedSegmentIndex else { return }
            selectedIndex = index
            updateSelection(animated: true)
            if sendsAction { sendActions(for: .valueChanged) }
            return
        }
    }

    private func clampedSelectedIndex(_ index: Int) -> Int {
        guard !segments.isEmpty else { return UISegmentedControl.noSegment }
        if index == UISegmentedControl.noSegment { return index }
        return max(0, min(index, segments.count - 1))
    }

    private func naturalSegmentWidths() -> [CGFloat] {
        segments.map { segment in
            if let title = segment.title {
                let width = (title as NSString).size(withAttributes: [
                    .font: UIFont.systemFont(ofSize: 13, weight: .regular),
                ]).width
                return ceil(width) + 28
            }
            return 44
        }
    }

    private func segmentFrames() -> [CGRect] {
        guard !segments.isEmpty else { return [] }
        let widths = resolvedSegmentWidths()
        var x: CGFloat = 0
        return widths.map { width in
            defer { x += width }
            return CGRect(x: x, y: 0, width: width, height: bounds.height)
        }
    }

    private func resolvedSegmentWidths() -> [CGFloat] {
        let count = segments.count
        guard count > 0 else { return [] }
        guard apportionsSegmentWidthsByContent else {
            return Array(repeating: bounds.width / CGFloat(count), count: count)
        }

        let natural = naturalSegmentWidths()
        let total = natural.reduce(0, +)
        guard bounds.width > total, total > 0 else { return natural }
        return natural.map { ($0 / total) * bounds.width }
    }

    private func layoutSegments() {
        let frames = segmentFrames()
        for (index, view) in segmentViews.enumerated() {
            view.frame = index < frames.count ? frames[index] : .zero
        }
        for (index, layer) in separatorSublayers.enumerated() {
            guard index + 1 < frames.count else {
                layer.frame = .zero
                continue
            }
            let x = frames[index].maxX
            layer.frame = CGRect(x: x, y: 6, width: 1 / max(window?.screen.scale ?? UIScreen.main.scale, 1), height: max(0, bounds.height - 12))
        }
    }

    private func updateSelection(animated: Bool) {
        let frames = segmentFrames()
        let selectedFrame: CGRect
        if selectedSegmentIndex >= 0, selectedSegmentIndex < frames.count {
            selectedFrame = frames[selectedSegmentIndex].insetBy(dx: 2, dy: 2)
        } else {
            selectedFrame = .zero
        }

        let updates = {
            self.selectedLayer.frame = selectedFrame
            self.selectedLayer.isHidden = selectedFrame.isEmpty
        }
        if animated {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.18)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
            updates()
            CATransaction.commit()
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            updates()
            CATransaction.commit()
        }

        for (index, view) in segmentViews.enumerated() {
            view.isSelected = index == selectedSegmentIndex
        }
        updateSeparatorVisibility()
    }

    private func rebuildSeparators() {
        separatorSublayers.forEach { $0.removeFromSuperlayer() }
        separatorSublayers = (0..<max(segments.count - 1, 0)).map { _ in
            let layer = CALayer()
            separatorLayer.addSublayer(layer)
            return layer
        }
        updateColors()
    }

    private func updateSeparatorVisibility() {
        for (index, layer) in separatorSublayers.enumerated() {
            layer.isHidden = index == selectedSegmentIndex || index + 1 == selectedSegmentIndex
        }
    }

    private func updateColors() {
        backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 1.0, alpha: 0.08)
                : UIColor(white: 0.0, alpha: 0.05)
        }
        selectedLayer.backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 1.0, alpha: 0.18)
                : UIColor(white: 1.0, alpha: 0.96)
        }.resolvedColor(with: traitCollection).cgColor
        layer.borderWidth = 1 / max(window?.screen.scale ?? UIScreen.main.scale, 1)
        layer.borderColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 1.0, alpha: 0.12)
                : UIColor(white: 0.0, alpha: 0.08)
        }.resolvedColor(with: traitCollection).cgColor
        let separatorColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 1.0, alpha: 0.08)
                : UIColor(white: 0.0, alpha: 0.07)
        }.resolvedColor(with: traitCollection).cgColor
        separatorSublayers.forEach { $0.backgroundColor = separatorColor }
        segmentViews.forEach { $0.updateColors() }
    }
}

private final class SegmentView: UIView {
    var isSelected = false {
        didSet { updateColors() }
    }

    private let imageView = UIImageView()
    private let titleLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        titleLabel.font = .systemFont(ofSize: 13, weight: .regular)
        titleLabel.textAlignment = .center
        imageView.contentMode = .center
        addSubview(imageView)
        addSubview(titleLabel)
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ segment: LuneSegmentedControl.Segment) {
        titleLabel.text = segment.title
        titleLabel.isHidden = segment.title == nil
        imageView.image = segment.image?.withRenderingMode(.alwaysTemplate)
        imageView.isHidden = segment.image == nil
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        titleLabel.frame = bounds.insetBy(dx: 8, dy: 0)
        imageView.frame = bounds
    }

    func updateColors() {
        let color: UIColor = isSelected ? .label : .secondaryLabel
        titleLabel.textColor = color
        imageView.tintColor = color
    }
}

//
//  CarouselScrubberView.swift
//  LunaDesignSystem
//
//  The scrub area under the cards: one small 9:16 thumbnail per card. Dragging
//  through it previews cards continuously (much faster than paging one by one);
//  releasing commits the index under the finger. A quick flick instead pages a
//  single card. The strip scrolls itself to keep the selection visible when
//  there are more thumbnails than fit.
//

import UIKit

public final class CarouselScrubberView: UIView {

    public static let preferredHeight: CGFloat = 68

    /// Continuous callback while a positional drag moves over the strip.
    public var onPreview: ((Int) -> Void)?
    /// The finger lifted after a positional drag (or a tap): commit this index.
    public var onCommit: ((Int) -> Void)?
    /// A quick flick: page by ±1.
    public var onPageStep: ((Int) -> Void)?

    private let thumbnailHeight: CGFloat = 46
    private var thumbnailWidth: CGFloat { thumbnailHeight * CardCarouselMetrics.cardAspectRatio }
    private let spacing: CGFloat = 5

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private var thumbnailViews: [UIImageView] = []
    private var selectedIndex = 0
    private var dragStartTime: CFTimeInterval = 0
    private var isDragging = false

    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        scrollView.showsHorizontalScrollIndicator = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        // The strip's own gestures do all the work; the scroll view is only a
        // programmatically-scrolled viewport.
        scrollView.panGestureRecognizer.isEnabled = false
        addSubview(scrollView)

        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    public override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.preferredHeight)
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        centerStripIfNarrow()
    }

    /// When every thumbnail fits, center the strip instead of leading-aligning it.
    private func centerStripIfNarrow() {
        let contentWidth = stack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width
        let slack = bounds.width - contentWidth
        scrollView.contentInset.left = max(0, slack / 2)
    }

    // MARK: - Content

    public func setThumbnailCount(_ count: Int) {
        while thumbnailViews.count > count {
            let view = thumbnailViews.removeLast()
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        while thumbnailViews.count < count {
            let view = UIImageView()
            view.contentMode = .scaleAspectFill
            view.clipsToBounds = true
            view.layer.cornerRadius = 5
            view.layer.cornerCurve = .continuous
            view.backgroundColor = .secondarySystemBackground
            view.layer.borderColor = UIColor.label.cgColor
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.widthAnchor.constraint(equalToConstant: thumbnailWidth),
                view.heightAnchor.constraint(equalToConstant: thumbnailHeight),
            ])
            stack.addArrangedSubview(view)
            thumbnailViews.append(view)
        }
        selectedIndex = min(selectedIndex, max(0, count - 1))
        applySelectionAppearance()
        setNeedsLayout()
    }

    public func setThumbnail(_ image: UIImage?, at index: Int) {
        guard thumbnailViews.indices.contains(index) else { return }
        thumbnailViews[index].image = image
    }

    public func setSelectedIndex(_ index: Int, animated: Bool) {
        guard thumbnailViews.indices.contains(index) else { return }
        selectedIndex = index
        applySelectionAppearance()
        let target = thumbnailViews[index]
        let frame = target.convert(target.bounds, to: scrollView).insetBy(dx: -30, dy: 0)
        scrollView.scrollRectToVisible(frame, animated: animated)
    }

    private func applySelectionAppearance() {
        for (index, view) in thumbnailViews.enumerated() {
            let selected = index == selectedIndex
            view.layer.borderWidth = selected ? 2 : 0
            view.transform = selected ? CGAffineTransform(scaleX: 1.12, y: 1.12) : .identity
            view.alpha = selected ? 1 : 0.72
        }
    }

    // MARK: - Gestures

    private func index(at location: CGPoint) -> Int {
        let inStrip = convert(location, to: stack)
        return CarouselScrubberMath.index(
            forLocationX: inStrip.x,
            thumbnailWidth: thumbnailWidth,
            spacing: spacing,
            count: thumbnailViews.count)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard !thumbnailViews.isEmpty else { return }
        onCommit?(index(at: gesture.location(in: self)))
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard !thumbnailViews.isEmpty else { return }
        switch gesture.state {
        case .began:
            dragStartTime = CACurrentMediaTime()
            isDragging = true
            preview(at: gesture.location(in: self))
        case .changed:
            preview(at: gesture.location(in: self))
        case .ended:
            isDragging = false
            let duration = CACurrentMediaTime() - dragStartTime
            if let step = CarouselScrubberMath.flickPageStep(
                translationX: gesture.translation(in: self).x,
                velocityX: gesture.velocity(in: self).x,
                duration: duration
            ) {
                onPageStep?(step)
            } else {
                onCommit?(index(at: gesture.location(in: self)))
            }
        case .cancelled, .failed:
            isDragging = false
            onCommit?(selectedIndex)
        default:
            break
        }
    }

    private func preview(at location: CGPoint) {
        let index = index(at: location)
        guard index != selectedIndex else { return }
        setSelectedIndex(index, animated: true)
        onPreview?(index)
    }
}

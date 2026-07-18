//
//  CarouselScrubberView.swift
//  LunaDesignSystem
//
//  The scrub area under the cards: one small preview per card. Dragging through
//  it previews cards continuously (much faster than paging one by one);
//  releasing commits the index under the finger. A quick flick instead pages a
//  single card. The strip scrolls itself to keep the selection visible when
//  there are more previews than fit.
//
//  Two styles: `.thumbnails` (small 9:16 image chips — Downloader) and
//  `.titles` (bigger text chips showing each card's title — Reader).
//

import UIKit

public final class CarouselScrubberView: UIView {

    /// What each strip item shows.
    public enum Style {
        /// Small 9:16 image chips (media thumbnails).
        case thumbnails
        /// Bigger chips showing the card's title text.
        case titles
    }

    /// Continuous callback while a positional drag moves over the strip.
    public var onPreview: ((Int) -> Void)?
    /// The finger lifted after a positional drag (or a tap): commit this index.
    public var onCommit: ((Int) -> Void)?
    /// A quick flick: page by ±1.
    public var onPageStep: ((Int) -> Void)?

    public let style: Style

    private var itemSize: CGSize {
        switch style {
        case .thumbnails:
            return CGSize(width: 46 * CardCarouselMetrics.cardAspectRatio, height: 46)
        case .titles:
            return CGSize(width: 92, height: 58)
        }
    }

    public var preferredHeight: CGFloat {
        itemSize.height + 22
    }

    private let spacing: CGFloat = 5

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private var itemViews: [ScrubberItemView] = []
    private var selectedIndex = 0
    private var dragStartTime: CFTimeInterval = 0

    public init(style: Style = .thumbnails) {
        self.style = style
        super.init(frame: .zero)
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
        CGSize(width: UIView.noIntrinsicMetric, height: preferredHeight)
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        centerStripIfNarrow()
    }

    /// When every item fits, center the strip instead of leading-aligning it.
    private func centerStripIfNarrow() {
        let contentWidth = stack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width
        let slack = bounds.width - contentWidth
        scrollView.contentInset.left = max(0, slack / 2)
    }

    // MARK: - Content

    public func setThumbnailCount(_ count: Int) {
        while itemViews.count > count {
            let view = itemViews.removeLast()
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        while itemViews.count < count {
            let view = ScrubberItemView(style: style, size: itemSize)
            stack.addArrangedSubview(view)
            itemViews.append(view)
        }
        selectedIndex = min(selectedIndex, max(0, count - 1))
        applySelectionAppearance()
        setNeedsLayout()
    }

    public func setThumbnail(_ image: UIImage?, at index: Int) {
        guard itemViews.indices.contains(index) else { return }
        itemViews[index].imageView.image = image
    }

    public func setTitle(_ title: String?, at index: Int) {
        guard itemViews.indices.contains(index) else { return }
        itemViews[index].titleLabel.text = title
    }

    public func setSelectedIndex(_ index: Int, animated: Bool) {
        guard itemViews.indices.contains(index) else { return }
        selectedIndex = index
        applySelectionAppearance()
        let target = itemViews[index]
        let frame = target.convert(target.bounds, to: scrollView).insetBy(dx: -30, dy: 0)
        scrollView.scrollRectToVisible(frame, animated: animated)
    }

    private func applySelectionAppearance() {
        for (index, view) in itemViews.enumerated() {
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
            thumbnailWidth: itemSize.width,
            spacing: spacing,
            count: itemViews.count)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard !itemViews.isEmpty else { return }
        onCommit?(index(at: gesture.location(in: self)))
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard !itemViews.isEmpty else { return }
        switch gesture.state {
        case .began:
            dragStartTime = CACurrentMediaTime()
            preview(at: gesture.location(in: self))
        case .changed:
            preview(at: gesture.location(in: self))
        case .ended:
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

/// One strip chip: an image (thumbnail style) or a small multi-line title
/// (titles style) on the card surface color.
private final class ScrubberItemView: UIView {
    let imageView = UIImageView()
    let titleLabel = UILabel()

    init(style: CarouselScrubberView.Style, size: CGSize) {
        super.init(frame: .zero)
        clipsToBounds = true
        layer.cornerRadius = style == .titles ? 8 : 5
        layer.cornerCurve = .continuous
        backgroundColor = .secondarySystemBackground
        layer.borderColor = UIColor.label.cgColor
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size.width),
            heightAnchor.constraint(equalToConstant: size.height),
        ])
        switch style {
        case .thumbnails:
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.frame = CGRect(origin: .zero, size: size)
            imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(imageView)
        case .titles:
            titleLabel.font = .systemFont(ofSize: 10, weight: .medium)
            titleLabel.textColor = .label
            titleLabel.numberOfLines = 3
            titleLabel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(titleLabel)
            NSLayoutConstraint.activate([
                titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
                titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
                titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
                titleLabel.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 4),
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

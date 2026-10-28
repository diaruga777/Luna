import UIKit

/// A quiet, top-to-bottom reading fill. Its host owns visibility and placement;
/// the fill follows the live scroll geometry, including restored positions and reflow.
public final class ReadingProgressEdgeView: UIView {
    public static let glowWidth: CGFloat = 14

    private weak var scrollView: UIScrollView?
    private var observations: [NSKeyValueObservation] = []
    private let fill = CAGradientLayer()
    private let endFade = CAGradientLayer()

    public override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear

        // A roughly 2pt ribbon dissolving sideways into a wider, very faint glow.
        // No unfilled track, outline, or bright point competes with the text.
        fill.startPoint = CGPoint(x: 0, y: 0.5)
        fill.endPoint = CGPoint(x: 1, y: 0.5)
        fill.locations = [0, 0.18, 0.36, 0.44, 0.56, 0.64, 0.82, 1]
        layer.addSublayer(fill)
        endFade.colors = [UIColor.clear.cgColor, UIColor.black.cgColor,
                          UIColor.black.cgColor, UIColor.clear.cgColor]
        fill.mask = endFade
        updateColors()
        registerForTraitChanges([LunaSkyTrait.self, UITraitUserInterfaceStyle.self]) {
            (self: Self, _: UITraitCollection) in self.updateColors()
        }
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    public func track(_ scrollView: UIScrollView?) {
        guard scrollView !== self.scrollView else { return }
        observations.removeAll()
        self.scrollView = scrollView
        if let scrollView {
            observations = [
                scrollView.observe(\.contentOffset) { [weak self] _, _ in self?.setNeedsLayout() },
                scrollView.observe(\.contentSize) { [weak self] _, _ in self?.setNeedsLayout() },
                scrollView.observe(\.bounds) { [weak self] _, _ in self?.setNeedsLayout() },
                scrollView.observe(\.adjustedContentInset) { [weak self] _, _ in self?.setNeedsLayout() },
            ]
        }
        setNeedsLayout()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard let scrollView else {
            fill.isHidden = true
            return
        }
        let insets = scrollView.adjustedContentInset
        let visibleHeight = scrollView.bounds.height - insets.top - insets.bottom
        let range = scrollView.contentSize.height - visibleHeight
        guard visibleHeight > 0, range > 0.5 else {
            fill.isHidden = true
            return
        }
        // Clamp rubber-banding: empty at the article's top, full at its bottom.
        let fraction = min(1, max(0, (scrollView.contentOffset.y + insets.top) / range))
        let height = bounds.height * fraction
        fill.isHidden = height <= 0
        fill.frame = CGRect(x: 0, y: 0, width: bounds.width, height: height)
        endFade.frame = fill.bounds
        let fade = min(0.5, 4 / max(height, 1))
        endFade.locations = [0, NSNumber(value: Double(fade)),
                             NSNumber(value: Double(1 - fade)), 1]
    }

    private func updateColors() {
        let tint = MoonHorizonStyle.sunlight.resolvedColor(with: traitCollection)
        fill.colors = [0, 0.025, 0.10, 0.32, 0.32, 0.10, 0.025, 0].map {
            tint.withAlphaComponent($0).cgColor
        }
    }
}

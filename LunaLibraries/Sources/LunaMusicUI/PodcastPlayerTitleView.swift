import UIKit

/// A single baseline with a fading trailing edge. Long episode titles are
/// readable in full without wrapping into the show name or the playback bar.
@MainActor final class PodcastPlayerTitleView: UIView {
    private let label = UILabel()
    private let fade = CAGradientLayer()
    private var layoutKey = ""
    var font: UIFont { get { label.font } set { label.font = newValue; setNeedsLayout() } }
    var text: String? {
        get { label.text }
        set {
            guard label.text != newValue else { return }
            label.text = newValue; accessibilityLabel = newValue; setNeedsLayout()
        }
    }
    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true; isAccessibilityElement = true; accessibilityTraits = .staticText
        label.textColor = .white; label.adjustsFontForContentSizeCategory = true
        addSubview(label); layer.mask = fade
        fade.startPoint = CGPoint(x: 0, y: 0.5); fade.endPoint = CGPoint(x: 1, y: 0.5)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func didMoveToWindow() { super.didMoveToWindow(); layoutKey = ""; setNeedsLayout() }
    override func layoutSubviews() {
        super.layoutSubviews()
        let fullWidth = ceil(label.sizeThatFits(CGSize(width: .greatestFiniteMagnitude, height: bounds.height)).width)
        let scrolling = fullWidth > bounds.width && !UIAccessibility.isReduceMotionEnabled && window != nil && bounds.width > 0
        label.lineBreakMode = scrolling ? .byClipping : .byTruncatingTail
        label.frame = CGRect(x: 0, y: 0, width: scrolling ? fullWidth : bounds.width, height: bounds.height)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fade.frame = bounds
        fade.colors = scrolling ? [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor] : [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.black.cgColor]
        fade.locations = [0, NSNumber(value: Double(max(0, 1 - 24 / max(1, bounds.width)))), 1]
        CATransaction.commit()
        let key = "\(text ?? "")|\(bounds.width)|\(font.pointSize)|\(scrolling)"
        guard key != layoutKey else { return }; layoutKey = key
        label.layer.removeAnimation(forKey: "titleScroll")
        guard scrolling else { return }
        let distance = fullWidth - bounds.width + 24
        let travel = Double(distance / 28)
        let duration = travel * 2 + 4
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.values = [0, 0, -distance, -distance, 0]
        animation.keyTimes = [0, NSNumber(value: 2 / duration), NSNumber(value: (2 + travel) / duration), NSNumber(value: (4 + travel) / duration), 1]
        animation.duration = duration; animation.repeatCount = .infinity
        label.layer.add(animation, forKey: "titleScroll")
    }
}

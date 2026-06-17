//
//  CatchUpCardView.swift
//  Clip
//

import UIKit

/// A swipeable catch-up card: hosts arbitrary content and tracks a horizontal drag,
/// rotating + tinting the card and fading in the action label in the corner. Past a
/// threshold (or a fast flick) it flies off and reports the action; otherwise it
/// springs back. Dragging LEFT = bump, RIGHT = mark read. The same fly-off is driven
/// by the bottom buttons via `performAction`.
final class CatchUpCardView: UIView, UIGestureRecognizerDelegate {

    enum Action { case bump, markRead }

    /// Fired once the card commits to an action (after the fly-off animation starts).
    var onAction: ((Action) -> Void)?

    /// Where the hosted content goes (the article reader nav, or a media view).
    let contentContainer = UIView()

    private let tintOverlay = UIView()
    private let bumpLabel = CatchUpCardView.cornerLabel(text: "BUMP", color: GlassStyle.readingAccent)
    private let readLabel = CatchUpCardView.cornerLabel(text: "READ", color: .systemGreen)

    private static let rotationPerWidth: CGFloat = 0.18   // radians at full-width drag

    init() {
        super.init(frame: .zero)
        backgroundColor = ReaderDepth.backgroundColor(for: 0)
        layer.cornerRadius = 22
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 20
        layer.shadowOffset = CGSize(width: 0, height: 8)

        contentContainer.layer.cornerRadius = 22
        contentContainer.layer.cornerCurve = .continuous
        contentContainer.clipsToBounds = true
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentContainer)

        tintOverlay.layer.cornerRadius = 22
        tintOverlay.layer.cornerCurve = .continuous
        tintOverlay.alpha = 0
        tintOverlay.isUserInteractionEnabled = false
        tintOverlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tintOverlay)

        for label in [readLabel, bumpLabel] {
            label.alpha = 0
            addSubview(label)
        }
        readLabel.translatesAutoresizingMaskIntoConstraints = false
        bumpLabel.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            contentContainer.topAnchor.constraint(equalTo: topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            tintOverlay.topAnchor.constraint(equalTo: topAnchor),
            tintOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
            tintOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            tintOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            // READ appears top-left when swiping right; BUMP top-right when left.
            readLabel.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            readLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            bumpLabel.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            bumpLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
        ])

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        addGestureRecognizer(pan)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private static func cornerLabel(text: String, color: UIColor) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 30, weight: .heavy)
        label.textColor = color
        label.layer.borderColor = color.cgColor
        label.layer.borderWidth = 3
        label.layer.cornerRadius = 8
        label.textAlignment = .center
        label.layer.masksToBounds = true
        // Padding via attributed-ish spacing: use intrinsic + insets through frame.
        label.setContentHuggingPriority(.required, for: .horizontal)
        return label
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Give the corner labels a little internal padding.
        for label in [readLabel, bumpLabel] {
            label.bounds.size.width = label.intrinsicContentSize.width + 20
            label.bounds.size.height = label.intrinsicContentSize.height + 8
        }
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: 22).cgPath
    }

    // MARK: - Drag

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: superview)
        switch gesture.state {
        case .changed:
            apply(translationX: translation.x)
        case .ended, .cancelled:
            let width = superview?.bounds.width ?? bounds.width
            let velocity = gesture.velocity(in: superview).x
            let pastThreshold = abs(translation.x) > width * 0.3 || abs(velocity) > 900
            if pastThreshold {
                performAction(translation.x < 0 ? .bump : .markRead)
            } else {
                springBack()
            }
        default:
            break
        }
    }

    private func apply(translationX tx: CGFloat) {
        let width = max(superview?.bounds.width ?? bounds.width, 1)
        let progress = min(abs(tx) / width, 1)
        transform = CGAffineTransform(translationX: tx, y: 0)
            .rotated(by: Self.rotationPerWidth * (tx / width) * 2)
        let swipingRight = tx > 0
        tintOverlay.backgroundColor = (swipingRight ? UIColor.systemGreen : GlassStyle.readingAccent)
            .withAlphaComponent(0.5)
        tintOverlay.alpha = progress * 0.6
        readLabel.alpha = swipingRight ? progress : 0
        bumpLabel.alpha = swipingRight ? 0 : progress
    }

    private func springBack() {
        UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0.4) {
            self.transform = .identity
            self.tintOverlay.alpha = 0
            self.readLabel.alpha = 0
            self.bumpLabel.alpha = 0
        }
    }

    /// Flies the card off in the action's direction, then reports it. Used by both
    /// the drag release and the bottom buttons.
    func performAction(_ action: Action) {
        let width = superview?.bounds.width ?? UIScreen.main.bounds.width
        let offX: CGFloat = action == .bump ? -width * 1.5 : width * 1.5
        UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseIn) {
            self.transform = CGAffineTransform(translationX: offX, y: 0)
                .rotated(by: Self.rotationPerWidth * (action == .bump ? -2 : 2))
            self.alpha = 0
        } completion: { _ in
            self.onAction?(action)
        }
    }

    // MARK: - UIGestureRecognizerDelegate

    /// Only claim clearly-horizontal drags, so vertical scrolling inside the card's
    /// content (the article reader) still works.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: self)
        return abs(velocity.x) > abs(velocity.y)
    }
}

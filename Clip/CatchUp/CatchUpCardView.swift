//
//  CatchUpCardView.swift
//  Clip
//

import UIKit

/// A swipeable catch-up card. A horizontal drag rotates + tints the card and fades
/// in a corner action badge:
///   • drag RIGHT → **Archive** (marks the item read),
///   • drag LEFT → **Keep** (does nothing to the item, just advances),
///   • drag LEFT and then UP → **Bump** (moves the item to the top of the list).
/// The left-then-up corner is used for Bump so a plain vertical drag still scrolls
/// the reader embedded in the card. Past a threshold (or a fast flick) the card flies
/// off and reports the action; otherwise it springs back. The bottom Keep/Archive
/// buttons drive the same fly-off via `performAction`.
final class CatchUpCardView: UIView, UIGestureRecognizerDelegate {

    enum Action { case keep, bump, archive, unlock }

    /// Which action the CURRENT drag position maps to (drives the live tint + badge).
    private enum Zone { case none, keep, bump, archive, unlock }

    /// Fired once the card commits to an action (after the fly-off animation starts).
    var onAction: ((Action) -> Void)?

    /// A LOCKED card (a paywalled item awaiting its archive unlock): the left
    /// action becomes **Unlock** (not Keep), and Bump (left-then-up) is disabled.
    /// Right is still Archive. Set before the card is shown.
    var isLocked = false

    /// Where the hosted content goes (the article reader, or a media view).
    let contentContainer = UIView()

    private let tintOverlay = UIView()
    private let archiveBadge = CatchUpCardView.cornerBadge(symbol: "checkmark", text: "Archive", color: .systemGreen)
    private let keepBadge = CatchUpCardView.cornerBadge(symbol: "tray.full.fill", text: "Keep", color: .systemGray)
    private let bumpBadge = CatchUpCardView.cornerBadge(symbol: "arrow.up", text: "Bump", color: GlassStyle.readingAccent)
    private let unlockBadge = CatchUpCardView.cornerBadge(symbol: "lock.open.fill", text: "Unlock", color: GlassStyle.readingAccent)

    private static let rotationPerWidth: CGFloat = 0.18   // radians at full-width drag
    /// How far UP (points) the drag must go (while left) to mean Bump.
    private static let upTrigger: CGFloat = 70
    private static let upCommit: CGFloat = 90

    private let glassBackdrop = UIVisualEffectView(effect: GlassStyle.barEffect())

    init() {
        super.init(frame: .zero)
        // The card itself is transparent — a liquid-glass backdrop fills it, so the
        // forehead / empty areas read as glass over the off-color screen.
        backgroundColor = .clear
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.22
        layer.shadowRadius = 20
        layer.shadowOffset = CGSize(width: 0, height: 8)

        glassBackdrop.translatesAutoresizingMaskIntoConstraints = false
        glassBackdrop.layer.cornerRadius = 22
        glassBackdrop.layer.cornerCurve = .continuous
        glassBackdrop.clipsToBounds = true
        glassBackdrop.layer.borderWidth = 0.5
        glassBackdrop.layer.borderColor = UIColor.separator.withAlphaComponent(0.6).cgColor
        addSubview(glassBackdrop)

        contentContainer.layer.cornerRadius = 22
        contentContainer.layer.cornerCurve = .continuous
        contentContainer.clipsToBounds = true
        contentContainer.backgroundColor = .clear
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentContainer)

        tintOverlay.layer.cornerRadius = 22
        tintOverlay.layer.cornerCurve = .continuous
        tintOverlay.alpha = 0
        tintOverlay.isUserInteractionEnabled = false
        tintOverlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tintOverlay)

        for badge in [archiveBadge, keepBadge, bumpBadge, unlockBadge] {
            badge.alpha = 0
            badge.translatesAutoresizingMaskIntoConstraints = false
            addSubview(badge)
        }

        NSLayoutConstraint.activate([
            glassBackdrop.topAnchor.constraint(equalTo: topAnchor),
            glassBackdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            glassBackdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            glassBackdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            tintOverlay.topAnchor.constraint(equalTo: topAnchor),
            tintOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
            tintOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            tintOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            // ARCHIVE appears top-left when swiping right; KEEP/BUMP top-right when
            // swiping left (Bump replaces Keep once the drag turns upward).
            archiveBadge.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            archiveBadge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            keepBadge.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            keepBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            bumpBadge.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            bumpBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            // Unlock shares Keep's top-right slot (it replaces Keep on a locked card).
            unlockBadge.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            unlockBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
        ])

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        addGestureRecognizer(pan)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// A corner action badge — a liquid-glass capsule hovering over the card, with a
    /// tinted SF Symbol + label inside (no outline, mixed case).
    private static func cornerBadge(symbol: String, text: String, color: UIColor) -> UIVisualEffectView {
        let pill = UIVisualEffectView(effect: GlassStyle.barEffect())
        if #available(iOS 26.0, *) {
            pill.cornerConfiguration = .capsule()
        } else {
            pill.layer.cornerRadius = 19
            pill.clipsToBounds = true
        }
        let icon = UIImageView(image: UIImage(systemName: symbol))
        icon.tintColor = color
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 20, weight: .bold)
        icon.contentMode = .center
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 22, weight: .bold)
        label.textColor = color
        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        pill.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: pill.contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: pill.contentView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: pill.contentView.topAnchor, constant: 9),
            stack.bottomAnchor.constraint(equalTo: pill.contentView.bottomAnchor, constant: -9),
        ])
        return pill
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: 22).cgPath
    }

    // MARK: - Drag

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: superview)
        switch gesture.state {
        case .changed:
            apply(translationX: translation.x, y: translation.y)
        case .ended, .cancelled:
            let width = superview?.bounds.width ?? bounds.width
            let velocity = gesture.velocity(in: superview)
            let horizontalCommit = abs(translation.x) > width * 0.3 || abs(velocity.x) > 900
            if translation.x > 0 && horizontalCommit {
                performAction(.archive)
            } else if translation.x < 0 && !isLocked && translation.y < -Self.upCommit {
                performAction(.bump)          // left, then up (disabled when locked)
            } else if translation.x < 0 && horizontalCommit {
                performAction(isLocked ? .unlock : .keep)
            } else {
                springBack()
            }
        default:
            break
        }
    }

    /// Liquid-glass effects (the card backdrop, the reader's glass header) re-render
    /// at the wrong scale under a rotation transform — they "balloon". Rasterizing the
    /// card's layer while rotated bakes the glass into a bitmap at identity scale, so
    /// the rotation just transforms that bitmap. Cleared when the card returns to rest.
    private func setRasterizedDuringRotation(_ on: Bool) {
        guard layer.shouldRasterize != on else { return }
        layer.rasterizationScale = window?.screen.scale ?? UIScreen.main.scale
        layer.shouldRasterize = on
    }

    private func zone(translationX tx: CGFloat, y ty: CGFloat) -> Zone {
        if tx > 0 { return .archive }
        if tx < 0 {
            if isLocked { return .unlock }
            return ty < -Self.upTrigger ? .bump : .keep
        }
        return .none
    }

    private func apply(translationX tx: CGFloat, y ty: CGFloat) {
        setRasterizedDuringRotation(tx != 0 || ty != 0)
        let width = max(superview?.bounds.width ?? bounds.width, 1)
        transform = CGAffineTransform(translationX: tx, y: ty)
            .rotated(by: Self.rotationPerWidth * (tx / width) * 2)

        archiveBadge.alpha = 0
        keepBadge.alpha = 0
        bumpBadge.alpha = 0
        unlockBadge.alpha = 0
        switch zone(translationX: tx, y: ty) {
        case .none:
            tintOverlay.alpha = 0
        case .archive:
            let progress = min(abs(tx) / width, 1)
            tintOverlay.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.5)
            tintOverlay.alpha = progress * 0.6
            archiveBadge.alpha = progress
        case .keep:
            let progress = min(abs(tx) / width, 1)
            tintOverlay.backgroundColor = UIColor.systemGray.withAlphaComponent(0.5)
            tintOverlay.alpha = progress * 0.6
            keepBadge.alpha = progress
        case .unlock:
            let progress = min(abs(tx) / width, 1)
            tintOverlay.backgroundColor = GlassStyle.readingAccent.withAlphaComponent(0.5)
            tintOverlay.alpha = progress * 0.6
            unlockBadge.alpha = progress
        case .bump:
            let progress = min(max(abs(tx), abs(ty)) / width, 1)
            tintOverlay.backgroundColor = GlassStyle.readingAccent.withAlphaComponent(0.5)
            tintOverlay.alpha = progress * 0.6
            bumpBadge.alpha = 1
        }
    }

    private func springBack() {
        UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0.4) {
            self.transform = .identity
            self.tintOverlay.alpha = 0
            self.archiveBadge.alpha = 0
            self.keepBadge.alpha = 0
            self.bumpBadge.alpha = 0
            self.unlockBadge.alpha = 0
        } completion: { _ in
            // Back at rest (identity) — drop the raster cache so glass goes live again.
            self.setRasterizedDuringRotation(false)
        }
    }

    /// Flies the card off in the action's direction, then reports it. Used by both
    /// the drag release and the bottom Keep/Archive buttons.
    func performAction(_ action: Action) {
        // Unlock doesn't fly off — it presents the archive flow and the card stays
        // (replaced in place once unlocked), so just spring back and report.
        if action == .unlock {
            springBack()
            onAction?(.unlock)
            return
        }
        // Stays rasterized through the fly-off (rotated the whole way, then removed).
        setRasterizedDuringRotation(true)
        let width = superview?.bounds.width ?? UIScreen.main.bounds.width
        let height = superview?.bounds.height ?? UIScreen.main.bounds.height
        let offset: CGPoint
        let rotation: CGFloat
        switch action {
        case .archive: offset = CGPoint(x: width * 1.5, y: 0); rotation = Self.rotationPerWidth * 2
        case .keep:    offset = CGPoint(x: -width * 1.5, y: 0); rotation = -Self.rotationPerWidth * 2
        case .bump:    offset = CGPoint(x: -width * 0.3, y: -height * 1.2); rotation = -Self.rotationPerWidth
        case .unlock:  return   // handled above (no fly-off)
        }
        UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseIn) {
            self.transform = CGAffineTransform(translationX: offset.x, y: offset.y).rotated(by: rotation)
            self.alpha = 0
        } completion: { _ in
            self.onAction?(action)
        }
    }

    // MARK: - UIGestureRecognizerDelegate

    /// Only claim clearly-horizontal drags, so a vertical scroll inside the card's
    /// content (the article reader) still works — and the Bump corner is reached by
    /// starting horizontally (left) and THEN turning up, which keeps the pan ours.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: self)
        return abs(velocity.x) > abs(velocity.y)
    }
}

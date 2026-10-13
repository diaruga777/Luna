//
//  FinishedReadingBadgeView.swift
//  LunaReaderUI
//

import LunaDesignSystem
import UIKit
import LunaModels

/// A persistent Liquid Glass completion pill shared by both reader modes.
public final class FinishedReadingBadgeView: UIView {
    public static let accessibilityIdentifier = "reader.finishedReadingBadge"
    public static let messageAccessibilityIdentifier = "reader.finishedReadingMessage"
    public static let pillHeight: CGFloat = 36

    private static let didExplainDefaultsKey = "reader.finishedReadingBadge.didExplain"
    private static let collapsedWidth: CGFloat = 88
    private static let expandedWidth: CGFloat = 154
    private static let automaticExpansionDelay: TimeInterval = 1.0
    private static let expandedDuration: TimeInterval = 2.0

    private let glassView: UIVisualEffectView
    private let checkLayer = CAShapeLayer()
    private let readLabel = UILabel()
    private let archiveLabel = UILabel()
    private var automaticExpansionWorkItem: DispatchWorkItem?
    private var collapseWorkItem: DispatchWorkItem?
    private var isExpanded = false
    private var isPullPrompt = false
    private var promptWidth: CGFloat = 0
    var onAccessibilityMarkRead: (() -> Void)?

    public override init(frame: CGRect) {
        let effectView: UIVisualEffectView
        if #available(iOS 26.0, *) {
            let glass = UIGlassEffect()
            glass.isInteractive = true
            glass.tintColor = LunaSurfacePalette.glassTint
            effectView = UIVisualEffectView(effect: glass)
        } else {
            effectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        }
        glassView = effectView
        super.init(frame: frame)
        isHidden = true
        clipsToBounds = false
        // `updateForegroundColor` resolves and caches a CGColor, and the
        // appearance rides `LunaSkyTrait` rather than `userInterfaceStyle`.
        registerForTraitChanges([LunaSkyTrait.self]) { (badge: FinishedReadingBadgeView, _) in
            badge.updateForegroundColor()
        }

        if #available(iOS 26.0, *) {
            glassView.cornerConfiguration = .capsule()
        } else {
            glassView.layer.cornerRadius = Self.pillHeight / 2
            glassView.layer.cornerCurve = .continuous
            glassView.clipsToBounds = true
        }
        glassView.isUserInteractionEnabled = false
        addSubview(glassView)

        checkLayer.fillColor = UIColor.clear.cgColor
        checkLayer.lineCap = .round
        checkLayer.lineJoin = .round
        checkLayer.lineWidth = 2.4
        glassView.contentView.layer.addSublayer(checkLayer)

        configure(label: readLabel, text: L10n.string("Reader_finishedBadge_readTitle"))
        glassView.contentView.addSubview(readLabel)

        configure(label: archiveLabel, text: L10n.string("Reader_finishedBadge_sentToArchiveTitle"))
        archiveLabel.textAlignment = .center
        archiveLabel.accessibilityIdentifier = Self.messageAccessibilityIdentifier
        archiveLabel.alpha = 0
        glassView.contentView.addSubview(archiveLabel)

        accessibilityIdentifier = Self.accessibilityIdentifier
        accessibilityLabel = L10n.string("Reader_finishedBadge_readTitle")
        accessibilityHint = L10n.string("Reader_finishedBadge_accessibilityHint")
        accessibilityTraits = .button
        isAccessibilityElement = true
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(pillTapped)))
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    public override func layoutSubviews() {
        super.layoutSubviews()
        guard glassView.layer.animationKeys()?.isEmpty != false else { return }
        glassView.frame = pillFrame(width: isPullPrompt ? promptWidth : (isExpanded ? Self.expandedWidth : Self.collapsedWidth))
        layoutPillContents()
    }

    public override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        !isHidden && glassView.frame.contains(point)
    }

    /// Shares the completion lane and glass surface with the final Read pill.
    /// UIKit owns all drag resistance and spring-back; this is only the affordance.
    func showPullPrompt(isArmed: Bool) {
        let text = L10n.string(isArmed
            ? "Reader_finishedBadge_releaseToReadTitle"
            : "Reader_finishedBadge_pullToReadTitle")
        isHidden = false
        guard !isPullPrompt || archiveLabel.text != text else { return }
        isPullPrompt = true
        checkLayer.isHidden = true
        readLabel.alpha = 0
        archiveLabel.alpha = 1
        archiveLabel.text = text
        promptWidth = archiveLabel.sizeThatFits(CGSize(width: 300, height: Self.pillHeight)).width + 28
        accessibilityLabel = text
        accessibilityHint = L10n.string("Reader_finishedBadge_markReadAccessibilityHint")
        setNeedsLayout()
    }

    public override func accessibilityActivate() -> Bool {
        if isPullPrompt {
            guard let onAccessibilityMarkRead else { return false }
            onAccessibilityMarkRead()
        } else {
            expand()
        }
        return true
    }

    /// Draws the check, reveals “Read,” and leaves the pill in place. On the
    /// first completion per install, the archive state expands after a beat.
    public func present() {
        cancelScheduledTransitions()
        let wasPullPrompt = isPullPrompt
        isPullPrompt = false
        archiveLabel.text = L10n.string("Reader_finishedBadge_sentToArchiveTitle")
        accessibilityLabel = L10n.string("Reader_finishedBadge_readTitle")
        accessibilityHint = L10n.string("Reader_finishedBadge_accessibilityHint")
        let shouldExplain = !UserDefaults.standard.bool(forKey: Self.didExplainDefaultsKey)
        if shouldExplain {
            UserDefaults.standard.set(true, forKey: Self.didExplainDefaultsKey)
        }

        isHidden = false
        alpha = 1
        isExpanded = false
        glassView.layer.removeAllAnimations()
        if wasPullPrompt && !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(
                withDuration: 0.32, delay: 0, usingSpringWithDamping: 0.84,
                initialSpringVelocity: 0, options: [.beginFromCurrentState, .allowUserInteraction]
            ) {
                self.glassView.frame = self.pillFrame(width: Self.collapsedWidth)
                self.layoutPillContents()
            }
        } else {
            glassView.frame = pillFrame(width: Self.collapsedWidth)
        }
        checkLayer.isHidden = false
        checkLayer.strokeEnd = 1
        // The label is already in its final position; only the checkmark draws.
        // Moving "Read" independently makes the compact pill look like its text
        // is slipping sideways as the reader settles at the end.
        readLabel.alpha = 1
        readLabel.transform = .identity
        archiveLabel.alpha = 0
        layoutPillContents()
        updateForegroundColor()

        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.toValue = 1
        draw.duration = 0.42
        draw.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        checkLayer.add(draw, forKey: "drawCheckmark")

        if shouldExplain {
            let work = DispatchWorkItem { [weak self] in self?.expand() }
            automaticExpansionWorkItem = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.automaticExpansionDelay, execute: work)
        }
        UIAccessibility.post(notification: .announcement, argument: L10n.string("Reader_finishedBadge_readTitle"))
    }

    public func resetForReuse() {
        cancelScheduledTransitions()
        layer.removeAllAnimations()
        glassView.layer.removeAllAnimations()
        checkLayer.removeAllAnimations()
        readLabel.layer.removeAllAnimations()
        archiveLabel.layer.removeAllAnimations()
        isExpanded = false
        isPullPrompt = false
        archiveLabel.text = L10n.string("Reader_finishedBadge_sentToArchiveTitle")
        accessibilityHint = L10n.string("Reader_finishedBadge_accessibilityHint")
        isHidden = true
        alpha = 1
        checkLayer.isHidden = false
        readLabel.alpha = 1
        readLabel.transform = .identity
        archiveLabel.alpha = 0
        accessibilityLabel = L10n.string("Reader_finishedBadge_readTitle")
    }

    private func configure(label: UILabel, text: String) {
        label.text = text
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = LunaColors.primaryText
    }

    private func pillFrame(width: CGFloat) -> CGRect {
        CGRect(
            x: (bounds.width - width) / 2,
            y: (bounds.height - Self.pillHeight) / 2,
            width: width,
            height: Self.pillHeight)
    }

    private func layoutPillContents() {
        let height = glassView.bounds.height
        let checkSize: CGFloat = 16
        let checkX: CGFloat = 17
        checkLayer.frame = CGRect(x: checkX, y: (height - checkSize) / 2, width: checkSize, height: checkSize)
        checkLayer.path = UIBezierPath.checkmark(in: checkLayer.bounds).cgPath
        readLabel.frame = CGRect(x: 42, y: 0, width: 40, height: height)
        archiveLabel.frame = glassView.bounds.insetBy(dx: 12, dy: 0)
    }

    private func updateForegroundColor() {
        let color = LunaColors.primaryText.resolvedColor(with: traitCollection)
        checkLayer.strokeColor = color.cgColor
        readLabel.textColor = color
        archiveLabel.textColor = color
    }

    @objc private func pillTapped() {
        expand()
    }

    private func expand() {
        guard !isHidden, !isPullPrompt else { return }
        automaticExpansionWorkItem?.cancel()
        automaticExpansionWorkItem = nil
        collapseWorkItem?.cancel()
        isExpanded = true
        accessibilityLabel = L10n.string("Reader_finishedBadge_sentToArchiveTitle")

        // The expanded status replaces the collapsed check-and-label content;
        // the glass surface itself remains continuously visible.
        checkLayer.isHidden = true
        UIView.animate(
            withDuration: 0.34, delay: 0,
            usingSpringWithDamping: 0.82, initialSpringVelocity: 0.2,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            self.glassView.frame = self.pillFrame(width: Self.expandedWidth)
            self.readLabel.alpha = 0
            self.archiveLabel.alpha = 1
            self.layoutPillContents()
        }

        let work = DispatchWorkItem { [weak self] in self?.collapse() }
        collapseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.expandedDuration, execute: work)
    }

    private func collapse() {
        guard isExpanded else { return }
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
        isExpanded = false
        accessibilityLabel = L10n.string("Reader_finishedBadge_readTitle")
        UIView.animate(
            withDuration: 0.32, delay: 0,
            usingSpringWithDamping: 0.84, initialSpringVelocity: 0.2,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            self.glassView.frame = self.pillFrame(width: Self.collapsedWidth)
            self.archiveLabel.alpha = 0
            self.layoutPillContents()
        } completion: { _ in
            guard !self.isExpanded else { return }
            self.checkLayer.isHidden = false
            self.readLabel.alpha = 1
        }
    }

    private func cancelScheduledTransitions() {
        automaticExpansionWorkItem?.cancel()
        automaticExpansionWorkItem = nil
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
    }

}

private extension UIBezierPath {
    static func checkmark(in bounds: CGRect) -> UIBezierPath {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: bounds.width * 0.12, y: bounds.height * 0.53))
        path.addLine(to: CGPoint(x: bounds.width * 0.41, y: bounds.height * 0.80))
        path.addLine(to: CGPoint(x: bounds.width * 0.90, y: bounds.height * 0.20))
        return path
    }
}

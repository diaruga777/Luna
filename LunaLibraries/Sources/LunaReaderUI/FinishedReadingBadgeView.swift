//
//  FinishedReadingBadgeView.swift
//  LunaReaderUI
//

import LunaDesignSystem
import UIKit

/// Short-lived completion acknowledgement shared by both reader modes.
public final class FinishedReadingBadgeView: UIView {
    public static let accessibilityIdentifier = "reader.finishedReadingBadge"
    public static let messageAccessibilityIdentifier = "reader.finishedReadingMessage"

    private static let didExplainDefaultsKey = "reader.finishedReadingBadge.didExplain"
    private static let visibleDuration: TimeInterval = 3.0

    private let checkButton = UIButton(type: .system)
    private let messageBackground = UIView()
    private let messageLabel = UILabel()
    private var hideWorkItem: DispatchWorkItem?
    private var presentationGeneration = 0

    public override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true

        var configuration = UIButton.Configuration.filled()
        configuration.image = UIImage(
            systemName: "checkmark",
            withConfiguration: UIImage.SymbolConfiguration(weight: .bold))
        configuration.baseBackgroundColor = .systemGreen
        configuration.baseForegroundColor = .white
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 11, leading: 11, bottom: 11, trailing: 11)
        checkButton.configuration = configuration
        checkButton.accessibilityIdentifier = Self.accessibilityIdentifier
        checkButton.accessibilityLabel = "Finished reading"
        checkButton.accessibilityHint = "Shows what happens to this article"
        checkButton.addTarget(self, action: #selector(checkTapped), for: .touchUpInside)
        addSubview(checkButton)

        messageBackground.layer.cornerRadius = 15
        messageBackground.layer.cornerCurve = .continuous
        messageBackground.clipsToBounds = true
        messageBackground.backgroundColor = LunaColors.secondaryBackground
        messageBackground.isUserInteractionEnabled = false
        messageBackground.alpha = 0
        messageBackground.transform = CGAffineTransform(scaleX: 0.88, y: 0.88)
        addSubview(messageBackground)

        messageLabel.text = "Finished reading, sending to archive"
        messageLabel.font = .preferredFont(forTextStyle: .footnote)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textColor = LunaColors.primaryText
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 1
        messageLabel.accessibilityIdentifier = Self.messageAccessibilityIdentifier
        messageBackground.addSubview(messageLabel)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let buttonSide: CGFloat = 44
        checkButton.frame = CGRect(
            x: (bounds.width - buttonSide) / 2, y: bounds.height - buttonSide - 2,
            width: buttonSide, height: buttonSide)
        let messageWidth = min(max(bounds.width - 32, 0), 250)
        messageBackground.frame = CGRect(
            x: (bounds.width - messageWidth) / 2, y: 0,
            width: messageWidth, height: 34)
        messageLabel.frame = messageBackground.bounds.insetBy(dx: 12, dy: 4)
    }

    /// Springs the check into view. The first presentation per app install also
    /// explains the pending archive automatically; later ones reveal it on tap.
    public func present() {
        hideWorkItem?.cancel()
        presentationGeneration += 1
        let shouldExplain = !UserDefaults.standard.bool(forKey: Self.didExplainDefaultsKey)
        if shouldExplain {
            UserDefaults.standard.set(true, forKey: Self.didExplainDefaultsKey)
        }

        isHidden = false
        alpha = 0
        checkButton.transform = CGAffineTransform(scaleX: 0.55, y: 0.55)
        setMessageVisible(shouldExplain, animated: false)
        UIView.animate(
            withDuration: 0.48, delay: 0,
            usingSpringWithDamping: 0.58, initialSpringVelocity: 0.8,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            self.alpha = 1
            self.checkButton.transform = .identity
        }
        scheduleHide()
        UIAccessibility.post(notification: .announcement, argument: "Finished reading")
    }

    public func resetForReuse() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        presentationGeneration += 1
        layer.removeAllAnimations()
        checkButton.layer.removeAllAnimations()
        messageBackground.layer.removeAllAnimations()
        isHidden = true
        alpha = 0
        checkButton.transform = .identity
        setMessageVisible(false, animated: false)
    }

    @objc private func checkTapped() {
        setMessageVisible(true, animated: true)
        scheduleHide()
    }

    private func setMessageVisible(_ visible: Bool, animated: Bool) {
        let changes = {
            self.messageBackground.alpha = visible ? 1 : 0
            self.messageBackground.transform = visible
                ? .identity : CGAffineTransform(scaleX: 0.88, y: 0.88)
        }
        if animated {
            UIView.animate(
                withDuration: 0.28, delay: 0,
                usingSpringWithDamping: 0.78, initialSpringVelocity: 0.4,
                options: [.beginFromCurrentState, .allowUserInteraction], animations: changes)
        } else {
            changes()
        }
    }

    private func scheduleHide() {
        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleDuration, execute: work)
    }

    private func dismiss() {
        hideWorkItem = nil
        let generation = presentationGeneration
        UIView.animate(
            withDuration: 0.24, delay: 0, options: [.beginFromCurrentState, .curveEaseIn]
        ) {
            self.alpha = 0
            self.checkButton.transform = CGAffineTransform(scaleX: 0.72, y: 0.72)
        } completion: { _ in
            guard self.presentationGeneration == generation else { return }
            self.isHidden = true
            self.checkButton.transform = .identity
            self.setMessageVisible(false, animated: false)
        }
    }

    #if DEBUG
    func dismissForTesting() { dismiss() }
    #endif
}

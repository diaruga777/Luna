//
//  OnboardingAnimationView.swift
//  Clip
//

import UIKit

/// A small looping illustration shown atop an onboarding step, depicting the
/// iOS change the step asks the user to make (flip a Settings toggle, press the
/// Action Button, receive a notification). Purely cosmetic; `start()` kicks the
/// loop when the step appears.
final class OnboardingAnimationView: UIView {

    enum Kind {
        case notification   // a banner sliding in
        case settingsToggle // a Settings row whose switch flips on
        case actionButton   // the Action Button pressed → "Saved" card
    }

    private let kind: Kind
    private let accent = GlassStyle.readingAccent

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 150).isActive = true
        widthAnchor.constraint(equalToConstant: 260).isActive = true
        clipsToBounds = true
        switch kind {
        case .notification: buildNotification()
        case .settingsToggle: buildToggle()
        case .actionButton: buildActionButton()
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Begins (or restarts) the looping animation. Safe to call repeatedly.
    func start() {
        switch kind {
        case .notification: animateNotification()
        case .settingsToggle: animateToggle()
        case .actionButton: animateActionButton()
        }
    }

    // MARK: - Notification banner

    private let banner = UIView()

    private func buildNotification() {
        banner.backgroundColor = .secondarySystemBackground
        banner.layer.cornerRadius = 16
        banner.layer.cornerCurve = .continuous
        banner.translatesAutoresizingMaskIntoConstraints = false

        let appIcon = UIImageView(image: UIImage(systemName: "book.fill"))
        appIcon.tintColor = .white
        appIcon.contentMode = .center
        appIcon.backgroundColor = accent
        appIcon.layer.cornerRadius = 9
        appIcon.layer.cornerCurve = .continuous
        appIcon.translatesAutoresizingMaskIntoConstraints = false

        let title = UILabel()
        title.text = "Click"
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        let bodyText = UILabel()
        bodyText.text = "htest shared an article"
        bodyText.font = .systemFont(ofSize: 13)
        bodyText.textColor = .secondaryLabel
        let textStack = UIStackView(arrangedSubviews: [title, bodyText])
        textStack.axis = .vertical
        textStack.translatesAutoresizingMaskIntoConstraints = false

        banner.addSubview(appIcon)
        banner.addSubview(textStack)
        addSubview(banner)
        NSLayoutConstraint.activate([
            banner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            banner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            banner.heightAnchor.constraint(equalToConstant: 62),
            banner.centerYAnchor.constraint(equalTo: centerYAnchor),
            appIcon.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 12),
            appIcon.centerYAnchor.constraint(equalTo: banner.centerYAnchor),
            appIcon.widthAnchor.constraint(equalToConstant: 36),
            appIcon.heightAnchor.constraint(equalToConstant: 36),
            textStack.leadingAnchor.constraint(equalTo: appIcon.trailingAnchor, constant: 12),
            textStack.centerYAnchor.constraint(equalTo: banner.centerYAnchor),
        ])
    }

    private func animateNotification() {
        banner.transform = CGAffineTransform(translationX: 0, y: -100)
        banner.alpha = 0
        UIView.animateKeyframes(
            withDuration: 3.0, delay: 0.2,
            options: [.repeat, .calculationModeCubic]
        ) {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.2) {
                self.banner.transform = .identity
                self.banner.alpha = 1
            }
            UIView.addKeyframe(withRelativeStartTime: 0.8, relativeDuration: 0.15) {
                self.banner.transform = CGAffineTransform(translationX: 0, y: -100)
                self.banner.alpha = 0
            }
        }
    }

    // MARK: - Settings toggle

    private let track = UIView()
    private let thumb = UIView()

    private func buildToggle() {
        let row = UIView()
        row.backgroundColor = .secondarySystemBackground
        row.layer.cornerRadius = 16
        row.layer.cornerCurve = .continuous
        row.translatesAutoresizingMaskIntoConstraints = false

        let label = UILabel()
        label.text = "Click"
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false

        track.backgroundColor = .systemGray3
        track.layer.cornerRadius = 15
        track.translatesAutoresizingMaskIntoConstraints = false
        thumb.backgroundColor = .white
        thumb.layer.cornerRadius = 13
        thumb.layer.shadowColor = UIColor.black.cgColor
        thumb.layer.shadowOpacity = 0.2
        thumb.layer.shadowRadius = 2
        thumb.layer.shadowOffset = CGSize(width: 0, height: 1)
        thumb.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(label)
        row.addSubview(track)
        track.addSubview(thumb)
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.heightAnchor.constraint(equalToConstant: 58),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            track.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            track.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            track.widthAnchor.constraint(equalToConstant: 51),
            track.heightAnchor.constraint(equalToConstant: 30),
        ])
        // Thumb laid out manually in layoutSubviews (frame-based for animation).
        thumb.frame = CGRect(x: 2, y: 2, width: 26, height: 26)
    }

    private func animateToggle() {
        // Reset to "off".
        track.backgroundColor = .systemGray3
        thumb.frame.origin.x = 2
        UIView.animateKeyframes(
            withDuration: 2.4, delay: 0.3, options: [.repeat]
        ) {
            UIView.addKeyframe(withRelativeStartTime: 0.1, relativeDuration: 0.2) {
                self.track.backgroundColor = self.accent
                self.thumb.frame.origin.x = 23
            }
            UIView.addKeyframe(withRelativeStartTime: 0.7, relativeDuration: 0.2) {
                self.track.backgroundColor = .systemGray3
                self.thumb.frame.origin.x = 2
            }
        }
    }

    // MARK: - Action Button

    private let pressRipple = UIView()
    private let savedCard = UIView()

    private func buildActionButton() {
        // A phone edge with the Action Button on the left.
        let phone = UIView()
        phone.layer.borderColor = UIColor.systemGray3.cgColor
        phone.layer.borderWidth = 3
        phone.layer.cornerRadius = 26
        phone.layer.cornerCurve = .continuous
        phone.translatesAutoresizingMaskIntoConstraints = false

        let button = UIView()
        button.backgroundColor = .systemGray
        button.layer.cornerRadius = 3
        button.translatesAutoresizingMaskIntoConstraints = false

        pressRipple.backgroundColor = accent.withAlphaComponent(0.35)
        pressRipple.layer.cornerRadius = 18
        pressRipple.alpha = 0
        pressRipple.translatesAutoresizingMaskIntoConstraints = false

        savedCard.backgroundColor = accent
        savedCard.layer.cornerRadius = 12
        savedCard.layer.cornerCurve = .continuous
        savedCard.alpha = 0
        savedCard.translatesAutoresizingMaskIntoConstraints = false
        let check = UIImageView(image: UIImage(systemName: "checkmark"))
        check.tintColor = .white
        check.contentMode = .center
        let savedLabel = UILabel()
        savedLabel.text = "Saved to Click"
        savedLabel.textColor = .white
        savedLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        let cardStack = UIStackView(arrangedSubviews: [check, savedLabel])
        cardStack.axis = .horizontal
        cardStack.spacing = 8
        cardStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(phone)
        phone.addSubview(button)
        phone.addSubview(pressRipple)
        savedCard.addSubview(cardStack)
        addSubview(savedCard)
        NSLayoutConstraint.activate([
            phone.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            phone.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            phone.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 70),
            phone.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -70),
            button.leadingAnchor.constraint(equalTo: phone.leadingAnchor, constant: -3),
            button.topAnchor.constraint(equalTo: phone.topAnchor, constant: 34),
            button.widthAnchor.constraint(equalToConstant: 6),
            button.heightAnchor.constraint(equalToConstant: 34),
            pressRipple.centerXAnchor.constraint(equalTo: phone.leadingAnchor),
            pressRipple.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            pressRipple.widthAnchor.constraint(equalToConstant: 36),
            pressRipple.heightAnchor.constraint(equalToConstant: 36),
            savedCard.centerXAnchor.constraint(equalTo: phone.centerXAnchor),
            savedCard.centerYAnchor.constraint(equalTo: phone.centerYAnchor),
            savedCard.heightAnchor.constraint(equalToConstant: 40),
            cardStack.leadingAnchor.constraint(equalTo: savedCard.leadingAnchor, constant: 12),
            cardStack.trailingAnchor.constraint(equalTo: savedCard.trailingAnchor, constant: -12),
            cardStack.centerYAnchor.constraint(equalTo: savedCard.centerYAnchor),
        ])
    }

    private func animateActionButton() {
        pressRipple.alpha = 0
        pressRipple.transform = CGAffineTransform(scaleX: 0.3, y: 0.3)
        savedCard.alpha = 0
        savedCard.transform = CGAffineTransform(translationX: 0, y: 14)
        UIView.animateKeyframes(
            withDuration: 3.0, delay: 0.3, options: [.repeat]
        ) {
            // Press ripple.
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.12) {
                self.pressRipple.alpha = 1
                self.pressRipple.transform = .identity
            }
            UIView.addKeyframe(withRelativeStartTime: 0.12, relativeDuration: 0.12) {
                self.pressRipple.alpha = 0
            }
            // Saved card pops in.
            UIView.addKeyframe(withRelativeStartTime: 0.22, relativeDuration: 0.15) {
                self.savedCard.alpha = 1
                self.savedCard.transform = .identity
            }
            UIView.addKeyframe(withRelativeStartTime: 0.82, relativeDuration: 0.12) {
                self.savedCard.alpha = 0
            }
        }
    }
}

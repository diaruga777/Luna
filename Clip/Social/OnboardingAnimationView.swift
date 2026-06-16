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
        // The phone facsimile is portrait, so its step gets a taller canvas.
        heightAnchor.constraint(equalToConstant: kind == .actionButton ? 230 : 150).isActive = true
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

    // MARK: - Action Button (portrait phone running Safari)

    private let pressRipple = UIView()
    private let savedToast = UIView()

    private func buildActionButton() {
        // Portrait phone.
        let phone = UIView()
        phone.backgroundColor = .systemBackground
        phone.layer.borderColor = UIColor.systemGray3.cgColor
        phone.layer.borderWidth = 3
        phone.layer.cornerRadius = 26
        phone.layer.cornerCurve = .continuous
        phone.clipsToBounds = true
        phone.translatesAutoresizingMaskIntoConstraints = false
        addSubview(phone)

        // The Action Button on the left edge.
        let button = UIView()
        button.backgroundColor = .systemGray
        button.layer.cornerRadius = 2.5
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)

        pressRipple.backgroundColor = accent.withAlphaComponent(0.35)
        pressRipple.layer.cornerRadius = 16
        pressRipple.alpha = 0
        pressRipple.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pressRipple)

        // A Safari facsimile inside the phone: a page, then a bottom address bar.
        let page = UIView()
        page.backgroundColor = .secondarySystemBackground
        page.translatesAutoresizingMaskIntoConstraints = false
        phone.addSubview(page)
        let headline = bar(width: 0.7, height: 9, color: .label.withAlphaComponent(0.7))
        let line1 = bar(width: 0.92, height: 5)
        let line2 = bar(width: 0.85, height: 5)
        let line3 = bar(width: 0.6, height: 5)
        let lines = UIStackView(arrangedSubviews: [headline, line1, line2, line3])
        lines.axis = .vertical
        lines.spacing = 7
        lines.alignment = .leading
        lines.setCustomSpacing(12, after: headline)
        lines.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(lines)

        let addressBar = UIView()
        addressBar.backgroundColor = .systemBackground
        addressBar.translatesAutoresizingMaskIntoConstraints = false
        phone.addSubview(addressBar)
        let urlPill = UIView()
        urlPill.backgroundColor = .secondarySystemBackground
        urlPill.layer.cornerRadius = 9
        urlPill.translatesAutoresizingMaskIntoConstraints = false
        let lock = UIImageView(image: UIImage(
            systemName: "lock.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 8)))
        lock.tintColor = .secondaryLabel
        let host = UILabel()
        host.text = "example.com"
        host.font = .systemFont(ofSize: 9, weight: .medium)
        host.textColor = .secondaryLabel
        let urlStack = UIStackView(arrangedSubviews: [lock, host])
        urlStack.spacing = 3
        urlStack.alignment = .center
        urlStack.translatesAutoresizingMaskIntoConstraints = false
        addressBar.addSubview(urlPill)
        urlPill.addSubview(urlStack)

        // "Saved to Click" toast inside the phone screen.
        savedToast.backgroundColor = accent
        savedToast.layer.cornerRadius = 11
        savedToast.layer.cornerCurve = .continuous
        savedToast.alpha = 0
        savedToast.translatesAutoresizingMaskIntoConstraints = false
        phone.addSubview(savedToast)
        let check = UIImageView(image: UIImage(
            systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold)))
        check.tintColor = .white
        let savedLabel = UILabel()
        savedLabel.text = "Saved to Click"
        savedLabel.textColor = .white
        savedLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        let toastStack = UIStackView(arrangedSubviews: [check, savedLabel])
        toastStack.spacing = 5
        toastStack.alignment = .center
        toastStack.translatesAutoresizingMaskIntoConstraints = false
        savedToast.addSubview(toastStack)

        NSLayoutConstraint.activate([
            phone.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            phone.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            phone.centerXAnchor.constraint(equalTo: centerXAnchor),
            phone.widthAnchor.constraint(equalTo: phone.heightAnchor, multiplier: 0.49),

            button.trailingAnchor.constraint(equalTo: phone.leadingAnchor, constant: 3),
            button.topAnchor.constraint(equalTo: phone.topAnchor, constant: 46),
            button.widthAnchor.constraint(equalToConstant: 5),
            button.heightAnchor.constraint(equalToConstant: 34),
            pressRipple.centerXAnchor.constraint(equalTo: phone.leadingAnchor),
            pressRipple.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            pressRipple.widthAnchor.constraint(equalToConstant: 32),
            pressRipple.heightAnchor.constraint(equalToConstant: 32),

            page.topAnchor.constraint(equalTo: phone.topAnchor),
            page.leadingAnchor.constraint(equalTo: phone.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: phone.trailingAnchor),
            addressBar.topAnchor.constraint(equalTo: page.bottomAnchor),
            addressBar.leadingAnchor.constraint(equalTo: phone.leadingAnchor),
            addressBar.trailingAnchor.constraint(equalTo: phone.trailingAnchor),
            addressBar.bottomAnchor.constraint(equalTo: phone.bottomAnchor),
            addressBar.heightAnchor.constraint(equalToConstant: 30),
            lines.topAnchor.constraint(equalTo: page.topAnchor, constant: 16),
            lines.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 12),
            lines.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -12),
            urlPill.centerYAnchor.constraint(equalTo: addressBar.centerYAnchor),
            urlPill.leadingAnchor.constraint(equalTo: addressBar.leadingAnchor, constant: 12),
            urlPill.trailingAnchor.constraint(equalTo: addressBar.trailingAnchor, constant: -12),
            urlPill.heightAnchor.constraint(equalToConstant: 18),
            urlStack.centerXAnchor.constraint(equalTo: urlPill.centerXAnchor),
            urlStack.centerYAnchor.constraint(equalTo: urlPill.centerYAnchor),

            savedToast.centerXAnchor.constraint(equalTo: page.centerXAnchor),
            savedToast.bottomAnchor.constraint(equalTo: page.bottomAnchor, constant: -10),
            savedToast.heightAnchor.constraint(equalToConstant: 28),
            toastStack.leadingAnchor.constraint(equalTo: savedToast.leadingAnchor, constant: 10),
            toastStack.trailingAnchor.constraint(equalTo: savedToast.trailingAnchor, constant: -10),
            toastStack.centerYAnchor.constraint(equalTo: savedToast.centerYAnchor),
        ])
    }

    /// A rounded gray "text line" bar, width as a fraction of its container.
    private func bar(width: CGFloat, height: CGFloat, color: UIColor = .systemGray3) -> UIView {
        let v = UIView()
        v.backgroundColor = color
        v.layer.cornerRadius = height / 2
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: height).isActive = true
        let parent = UIView()
        parent.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            v.topAnchor.constraint(equalTo: parent.topAnchor),
            v.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
            v.widthAnchor.constraint(equalTo: parent.widthAnchor, multiplier: width),
            parent.heightAnchor.constraint(equalToConstant: height),
        ])
        return parent
    }

    private func animateActionButton() {
        pressRipple.alpha = 0
        pressRipple.transform = CGAffineTransform(scaleX: 0.3, y: 0.3)
        savedToast.alpha = 0
        savedToast.transform = CGAffineTransform(translationX: 0, y: 12)
        UIView.animateKeyframes(withDuration: 3.0, delay: 0.4, options: [.repeat]) {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.1) {
                self.pressRipple.alpha = 1
                self.pressRipple.transform = .identity
            }
            UIView.addKeyframe(withRelativeStartTime: 0.1, relativeDuration: 0.1) {
                self.pressRipple.alpha = 0
            }
            UIView.addKeyframe(withRelativeStartTime: 0.22, relativeDuration: 0.13) {
                self.savedToast.alpha = 1
                self.savedToast.transform = .identity
            }
            UIView.addKeyframe(withRelativeStartTime: 0.85, relativeDuration: 0.12) {
                self.savedToast.alpha = 0
            }
        }
    }
}

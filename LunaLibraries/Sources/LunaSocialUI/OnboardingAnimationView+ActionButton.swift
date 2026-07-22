//
//  OnboardingAnimationView+ActionButton.swift
//  Luna
//

import LunaDesignSystem
import UIKit

extension OnboardingAnimationView {

    // MARK: - Action Button (portrait phone running Safari)

    func buildActionButton() {
        // Portrait phone.
        let phone = UIView()
        phone.backgroundColor = LunaColors.background
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
        page.backgroundColor = LunaColors.secondaryBackground
        page.translatesAutoresizingMaskIntoConstraints = false
        phone.addSubview(page)
        let headline = bar(width: 0.7, height: 9, color: LunaColors.primaryText.withAlphaComponent(0.7))
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
        addressBar.backgroundColor = LunaColors.background
        addressBar.translatesAutoresizingMaskIntoConstraints = false
        phone.addSubview(addressBar)
        let urlPill = UIView()
        urlPill.backgroundColor = LunaColors.secondaryBackground
        urlPill.layer.cornerRadius = 9
        urlPill.translatesAutoresizingMaskIntoConstraints = false
        let lock = UIImageView(image: UIImage(
            systemName: "lock.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 8)))
        lock.tintColor = LunaColors.secondaryText
        let host = UILabel()
        host.text = "example.com"
        host.font = .systemFont(ofSize: 9, weight: .medium)
        host.textColor = LunaColors.secondaryText
        let urlStack = UIStackView(arrangedSubviews: [lock, host])
        urlStack.spacing = 3
        urlStack.alignment = .center
        urlStack.translatesAutoresizingMaskIntoConstraints = false
        addressBar.addSubview(urlPill)
        urlPill.addSubview(urlStack)

        // Dynamic Island at the top of the phone: static black capsule hardware
        // that expands to reveal a confirmation when the Action Button is pressed.
        island.backgroundColor = .black
        island.translatesAutoresizingMaskIntoConstraints = false
        phone.addSubview(island)
        islandIcon.image = lunaAppIconImage()
        islandIcon.contentMode = .scaleAspectFit
        islandIcon.layer.cornerRadius = 2
        islandIcon.layer.cornerCurve = .continuous
        islandIcon.clipsToBounds = true
        islandIcon.alpha = 0
        islandIcon.translatesAutoresizingMaskIntoConstraints = false
        island.addSubview(islandIcon)
        islandCheck.tintColor = .systemGreen
        islandCheck.contentMode = .scaleAspectFit
        islandCheck.alpha = 0
        islandCheck.translatesAutoresizingMaskIntoConstraints = false
        island.addSubview(islandCheck)
        islandWidthConstraint = island.widthAnchor.constraint(equalToConstant: islandCompactSize.width)
        islandHeightConstraint = island.heightAnchor.constraint(equalToConstant: islandCompactSize.height)

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
            // Below the Dynamic Island's expanded extent (top 10 + height 17) so the
            // page headline never sits under the island.
            lines.topAnchor.constraint(equalTo: page.topAnchor, constant: 36),
            lines.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 12),
            lines.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -12),
            urlPill.centerYAnchor.constraint(equalTo: addressBar.centerYAnchor),
            urlPill.leadingAnchor.constraint(equalTo: addressBar.leadingAnchor, constant: 12),
            urlPill.trailingAnchor.constraint(equalTo: addressBar.trailingAnchor, constant: -12),
            urlPill.heightAnchor.constraint(equalToConstant: 18),
            urlStack.centerXAnchor.constraint(equalTo: urlPill.centerXAnchor),
            urlStack.centerYAnchor.constraint(equalTo: urlPill.centerYAnchor),

            island.centerXAnchor.constraint(equalTo: phone.centerXAnchor),
            island.topAnchor.constraint(equalTo: phone.topAnchor, constant: 10),
            islandWidthConstraint,
            islandHeightConstraint,
            islandIcon.leadingAnchor.constraint(equalTo: island.leadingAnchor, constant: 6),
            islandIcon.centerYAnchor.constraint(equalTo: island.centerYAnchor),
            islandIcon.widthAnchor.constraint(equalToConstant: 10),
            islandIcon.heightAnchor.constraint(equalToConstant: 10),
            islandCheck.trailingAnchor.constraint(equalTo: island.trailingAnchor, constant: -6),
            islandCheck.centerYAnchor.constraint(equalTo: island.centerYAnchor),
            islandCheck.widthAnchor.constraint(equalToConstant: 11),
            islandCheck.heightAnchor.constraint(equalToConstant: 11),
        ])
        island.layer.cornerRadius = islandCompactSize.height / 2
        island.layer.cornerCurve = .continuous
    }

    func animateActionButton() {
        pressRipple.alpha = 0
        pressRipple.transform = CGAffineTransform(scaleX: 0.3, y: 0.3)
        islandIcon.alpha = 0
        islandCheck.alpha = 0
        islandWidthConstraint.constant = islandCompactSize.width
        islandHeightConstraint.constant = islandCompactSize.height
        island.layer.cornerRadius = islandCompactSize.height / 2
        layoutIfNeeded()
        UIView.animateKeyframes(withDuration: 3.0, delay: 0.4, options: [.repeat]) {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.1) {
                self.pressRipple.alpha = 1
                self.pressRipple.transform = .identity
            }
            UIView.addKeyframe(withRelativeStartTime: 0.1, relativeDuration: 0.1) {
                self.pressRipple.alpha = 0
            }
            // The island expands into a wider capsule and reveals the confirmation.
            UIView.addKeyframe(withRelativeStartTime: 0.18, relativeDuration: 0.16) {
                self.islandWidthConstraint.constant = self.islandExpandedSize.width
                self.islandHeightConstraint.constant = self.islandExpandedSize.height
                self.island.layer.cornerRadius = self.islandExpandedSize.height / 2
                self.layoutIfNeeded()
            }
            UIView.addKeyframe(withRelativeStartTime: 0.30, relativeDuration: 0.12) {
                self.islandIcon.alpha = 1
                self.islandCheck.alpha = 1
            }
            // Hold, then contract back to the compact capsule.
            UIView.addKeyframe(withRelativeStartTime: 0.78, relativeDuration: 0.1) {
                self.islandIcon.alpha = 0
                self.islandCheck.alpha = 0
            }
            UIView.addKeyframe(withRelativeStartTime: 0.85, relativeDuration: 0.14) {
                self.islandWidthConstraint.constant = self.islandCompactSize.width
                self.islandHeightConstraint.constant = self.islandCompactSize.height
                self.island.layer.cornerRadius = self.islandCompactSize.height / 2
                self.layoutIfNeeded()
            }
        }
    }

}

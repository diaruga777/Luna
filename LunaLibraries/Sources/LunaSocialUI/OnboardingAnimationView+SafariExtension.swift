//
//  OnboardingAnimationView+SafariExtension.swift
//  Luna
//

import LunaDesignSystem
import UIKit

extension OnboardingAnimationView {

    // MARK: - Safari extension (Safari → page menu → Extensions → enable Luna)

    func buildSafariExtension() {
        let phone = UIView()
        phone.backgroundColor = .systemBackground
        phone.layer.borderColor = UIColor.systemGray3.cgColor
        phone.layer.borderWidth = 3
        phone.layer.cornerRadius = 30
        phone.layer.cornerCurve = .continuous
        phone.clipsToBounds = true
        phone.translatesAutoresizingMaskIntoConstraints = false
        addSubview(phone)

        // Safari page.
        let page = UIView()
        page.backgroundColor = .secondarySystemBackground
        page.translatesAutoresizingMaskIntoConstraints = false
        phone.addSubview(page)
        let headline = bar(width: 0.7, height: 9, color: .label.withAlphaComponent(0.7))
        let lines = UIStackView(arrangedSubviews: [
            headline, bar(width: 0.95, height: 5), bar(width: 0.9, height: 5), bar(width: 0.6, height: 5)])
        lines.axis = .vertical
        lines.spacing = 7
        lines.alignment = .fill
        lines.setCustomSpacing(12, after: headline)
        lines.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(lines)

        // Bottom address bar: page-menu button (left), URL pill, trailing icons.
        let addressBar = UIView()
        addressBar.backgroundColor = .systemBackground
        addressBar.translatesAutoresizingMaskIntoConstraints = false
        phone.addSubview(addressBar)

        let pageMenuButton = UIImageView(image: UIImage(
            systemName: "textformat.size", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14)))
        pageMenuButton.tintColor = accent
        pageMenuButton.contentMode = .center
        pageMenuButton.translatesAutoresizingMaskIntoConstraints = false
        addressBar.addSubview(pageMenuButton)

        let urlPill = UIView()
        urlPill.backgroundColor = .secondarySystemBackground
        urlPill.layer.cornerRadius = 9
        urlPill.layer.cornerCurve = .continuous
        urlPill.translatesAutoresizingMaskIntoConstraints = false
        addressBar.addSubview(urlPill)
        let urlPlaceholder = UIView()
        urlPlaceholder.backgroundColor = UIColor.label.withAlphaComponent(0.3)
        urlPlaceholder.layer.cornerRadius = 3
        urlPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        urlPill.addSubview(urlPlaceholder)

        let trailingIcons = UIStackView(arrangedSubviews: [toolbarIcon("book"), toolbarIcon("square.on.square")])
        trailingIcons.axis = .horizontal
        trailingIcons.spacing = 14
        trailingIcons.alignment = .center
        trailingIcons.translatesAutoresizingMaskIntoConstraints = false
        addressBar.addSubview(trailingIcons)

        sxMenuRipple.backgroundColor = accent.withAlphaComponent(0.3)
        sxMenuRipple.layer.cornerRadius = 15
        sxMenuRipple.alpha = 0
        sxMenuRipple.translatesAutoresizingMaskIntoConstraints = false
        addressBar.addSubview(sxMenuRipple)

        // Safari's bottom chrome ends above the device home indicator. Keeping the
        // safe-area strip inside the phone makes the address bar read as Safari UI
        // instead of looking like it is sitting underneath the system gesture bar.
        let homeIndicator = UIView()
        homeIndicator.backgroundColor = .label
        homeIndicator.layer.cornerRadius = 1.5
        homeIndicator.translatesAutoresizingMaskIntoConstraints = false
        addressBar.addSubview(homeIndicator)

        // Safari's page menu. It intentionally uses the same compact, bottom-sheet
        // form as Safari's `aA` menu, while keeping just the few rows needed to
        // explain the real path to extension management.
        configureSheetShell(sxMenuShell, cornerRadius: 14)
        phone.addSubview(sxMenuShell)
        let menuGrabber = sheetGrabber()
        sxMenuShell.addSubview(menuGrabber)
        let menuRows = UIStackView(arrangedSubviews: [
            literalActionRow(symbol: "textformat", text: "Website Settings"),
            literalActionRow(symbol: "doc.text.magnifyingglass", text: "Reader"),
            literalActionRow(symbol: "puzzlepiece.extension", text: "Manage Extensions"),
        ])
        menuRows.axis = .vertical
        menuRows.spacing = 4
        menuRows.translatesAutoresizingMaskIntoConstraints = false
        sxMenuShell.addSubview(menuRows)
        sxManageHighlight.backgroundColor = UIColor.systemGray.withAlphaComponent(0.28)
        sxManageHighlight.layer.cornerRadius = 8
        sxManageHighlight.alpha = 0
        sxManageHighlight.translatesAutoresizingMaskIntoConstraints = false
        sxMenuShell.insertSubview(sxManageHighlight, belowSubview: menuRows)
        let manageRow = menuRows.arrangedSubviews[2]

        // The extensions list panel: a "Luna" row with a real icon, label, and toggle.
        configureSheetShell(sxExtShell, cornerRadius: 14)
        phone.addSubview(sxExtShell)
        let extGrabber = sheetGrabber()
        sxExtShell.addSubview(extGrabber)
        let extTitle = UILabel()
        extTitle.text = "Manage Extensions"
        extTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        extTitle.textAlignment = .center
        extTitle.textColor = .label
        extTitle.translatesAutoresizingMaskIntoConstraints = false
        sxExtShell.addSubview(extTitle)

        let lunaIcon = UIImageView(image: lunaAppIconImage())
        lunaIcon.contentMode = .scaleAspectFit
        lunaIcon.layer.cornerRadius = 5
        lunaIcon.layer.cornerCurve = .continuous
        lunaIcon.clipsToBounds = true
        lunaIcon.translatesAutoresizingMaskIntoConstraints = false
        lunaIcon.widthAnchor.constraint(equalToConstant: 20).isActive = true
        lunaIcon.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let lunaLabel = UILabel()
        lunaLabel.text = "Luna"
        lunaLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        sxToggle = miniToggle()
        let lunaRow = UIView()
        lunaRow.translatesAutoresizingMaskIntoConstraints = false
        lunaRow.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let lunaRowStack = UIStackView(arrangedSubviews: [lunaIcon, lunaLabel, UIView(), sxToggle.track])
        lunaRowStack.alignment = .center
        lunaRowStack.spacing = 8
        lunaRowStack.translatesAutoresizingMaskIntoConstraints = false
        lunaRow.addSubview(lunaRowStack)
        sxExtShell.addSubview(lunaRow)

        NSLayoutConstraint.activate([
            phone.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            phone.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            phone.centerXAnchor.constraint(equalTo: centerXAnchor),
            phone.widthAnchor.constraint(equalTo: phone.heightAnchor, multiplier: 0.49),

            page.topAnchor.constraint(equalTo: phone.topAnchor),
            page.leadingAnchor.constraint(equalTo: phone.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: phone.trailingAnchor),
            page.bottomAnchor.constraint(equalTo: addressBar.topAnchor),
            lines.topAnchor.constraint(equalTo: page.topAnchor, constant: 18),
            lines.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 14),
            lines.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -14),

            addressBar.leadingAnchor.constraint(equalTo: phone.leadingAnchor),
            addressBar.trailingAnchor.constraint(equalTo: phone.trailingAnchor),
            addressBar.bottomAnchor.constraint(equalTo: phone.bottomAnchor),
            addressBar.heightAnchor.constraint(equalToConstant: 52),
            pageMenuButton.leadingAnchor.constraint(equalTo: addressBar.leadingAnchor, constant: 10),
            pageMenuButton.topAnchor.constraint(equalTo: addressBar.topAnchor, constant: 5),
            pageMenuButton.widthAnchor.constraint(equalToConstant: 26),
            pageMenuButton.heightAnchor.constraint(equalToConstant: 26),
            sxMenuRipple.centerXAnchor.constraint(equalTo: pageMenuButton.centerXAnchor),
            sxMenuRipple.centerYAnchor.constraint(equalTo: pageMenuButton.centerYAnchor),
            sxMenuRipple.widthAnchor.constraint(equalToConstant: 30),
            sxMenuRipple.heightAnchor.constraint(equalToConstant: 30),
            urlPill.leadingAnchor.constraint(equalTo: pageMenuButton.trailingAnchor, constant: 6),
            urlPill.trailingAnchor.constraint(equalTo: trailingIcons.leadingAnchor, constant: -8),
            urlPill.centerYAnchor.constraint(equalTo: pageMenuButton.centerYAnchor),
            urlPill.heightAnchor.constraint(equalToConstant: 18),
            urlPlaceholder.centerXAnchor.constraint(equalTo: urlPill.centerXAnchor),
            urlPlaceholder.centerYAnchor.constraint(equalTo: urlPill.centerYAnchor),
            urlPlaceholder.widthAnchor.constraint(equalToConstant: 40),
            urlPlaceholder.heightAnchor.constraint(equalToConstant: 6),
            trailingIcons.trailingAnchor.constraint(equalTo: addressBar.trailingAnchor, constant: -10),
            trailingIcons.centerYAnchor.constraint(equalTo: pageMenuButton.centerYAnchor),
            homeIndicator.centerXAnchor.constraint(equalTo: addressBar.centerXAnchor),
            homeIndicator.bottomAnchor.constraint(equalTo: addressBar.bottomAnchor, constant: -5),
            homeIndicator.widthAnchor.constraint(equalToConstant: 54),
            homeIndicator.heightAnchor.constraint(equalToConstant: 3),

            sxMenuShell.leadingAnchor.constraint(equalTo: phone.leadingAnchor),
            sxMenuShell.trailingAnchor.constraint(equalTo: phone.trailingAnchor),
            sxMenuShell.bottomAnchor.constraint(equalTo: addressBar.topAnchor),
            sxMenuShell.heightAnchor.constraint(equalTo: phone.heightAnchor, multiplier: 0.36),
            menuGrabber.topAnchor.constraint(equalTo: sxMenuShell.topAnchor, constant: 6),
            menuGrabber.centerXAnchor.constraint(equalTo: sxMenuShell.centerXAnchor),
            menuGrabber.widthAnchor.constraint(equalToConstant: 30),
            menuGrabber.heightAnchor.constraint(equalToConstant: 4),
            menuRows.topAnchor.constraint(equalTo: menuGrabber.bottomAnchor, constant: 8),
            menuRows.leadingAnchor.constraint(equalTo: sxMenuShell.leadingAnchor, constant: 10),
            menuRows.trailingAnchor.constraint(equalTo: sxMenuShell.trailingAnchor, constant: -10),
            sxManageHighlight.leadingAnchor.constraint(equalTo: manageRow.leadingAnchor, constant: -4),
            sxManageHighlight.trailingAnchor.constraint(equalTo: manageRow.trailingAnchor, constant: 4),
            sxManageHighlight.topAnchor.constraint(equalTo: manageRow.topAnchor, constant: -2),
            sxManageHighlight.bottomAnchor.constraint(equalTo: manageRow.bottomAnchor, constant: 2),

            sxExtShell.leadingAnchor.constraint(equalTo: phone.leadingAnchor),
            sxExtShell.trailingAnchor.constraint(equalTo: phone.trailingAnchor),
            sxExtShell.bottomAnchor.constraint(equalTo: addressBar.topAnchor),
            sxExtShell.heightAnchor.constraint(equalTo: phone.heightAnchor, multiplier: 0.36),
            extGrabber.topAnchor.constraint(equalTo: sxExtShell.topAnchor, constant: 6),
            extGrabber.centerXAnchor.constraint(equalTo: sxExtShell.centerXAnchor),
            extGrabber.widthAnchor.constraint(equalToConstant: 30),
            extGrabber.heightAnchor.constraint(equalToConstant: 4),
            extTitle.topAnchor.constraint(equalTo: extGrabber.bottomAnchor, constant: 8),
            extTitle.leadingAnchor.constraint(equalTo: sxExtShell.leadingAnchor, constant: 12),
            extTitle.trailingAnchor.constraint(equalTo: sxExtShell.trailingAnchor, constant: -12),
            lunaRow.topAnchor.constraint(equalTo: extTitle.bottomAnchor, constant: 10),
            lunaRow.leadingAnchor.constraint(equalTo: sxExtShell.leadingAnchor, constant: 12),
            lunaRow.trailingAnchor.constraint(equalTo: sxExtShell.trailingAnchor, constant: -12),
            lunaRowStack.leadingAnchor.constraint(equalTo: lunaRow.leadingAnchor),
            lunaRowStack.trailingAnchor.constraint(equalTo: lunaRow.trailingAnchor),
            lunaRowStack.centerYAnchor.constraint(equalTo: lunaRow.centerYAnchor),
        ])
    }

    func animateSafariExtension() {
        layoutIfNeeded()
        // Move hidden sheets beyond the phone's bottom edge, including Safari's
        // chrome and home-indicator strip. A shell translated by only its own
        // height remains visibly stacked over the URL bar.
        let offscreenDistance = sxMenuShell.bounds.height + 60
        let menuDrop = CGAffineTransform(translationX: 0, y: offscreenDistance)
        let extensionsDrop = CGAffineTransform(translationX: 0, y: offscreenDistance)

        func reset() {
            sxMenuShell.transform = menuDrop
            sxMenuShell.alpha = 1
            sxExtShell.transform = .identity
            sxExtShell.alpha = 0
            sxManageHighlight.alpha = 0
            sxMenuRipple.alpha = 0
            sxMenuRipple.transform = CGAffineTransform(scaleX: 0.3, y: 0.3)
            sxToggle.track.backgroundColor = .systemGray3
            sxToggle.thumb.frame.origin.x = 2
        }
        reset()

        UIView.animateKeyframes(withDuration: 6.8, delay: 0.4, options: [.repeat]) {
            // Tap the page-menu button.
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.04) {
                self.sxMenuRipple.alpha = 1
                self.sxMenuRipple.transform = .identity
            }
            UIView.addKeyframe(withRelativeStartTime: 0.04, relativeDuration: 0.04) {
                self.sxMenuRipple.alpha = 0
            }
            // The page-menu sheet slides up.
            UIView.addKeyframe(withRelativeStartTime: 0.08, relativeDuration: 0.14) {
                self.sxMenuShell.transform = .identity
            }
            // Tap "Manage Extensions".
            UIView.addKeyframe(withRelativeStartTime: 0.32, relativeDuration: 0.10) {
                self.sxManageHighlight.alpha = 1
            }
            // Safari replaces this level in place: dissolve the page menu into
            // Manage Extensions instead of dropping one sheet and raising another.
            UIView.addKeyframe(withRelativeStartTime: 0.42, relativeDuration: 0.14) {
                self.sxMenuShell.alpha = 0
                self.sxManageHighlight.alpha = 0
                self.sxExtShell.alpha = 1
            }
            // Flip the Luna toggle on.
            UIView.addKeyframe(withRelativeStartTime: 0.74, relativeDuration: 0.08) {
                self.sxToggle.track.backgroundColor = self.accent
                self.sxToggle.thumb.frame.origin.x = 16
            }
            // Dismiss the manager before the next loop starts, with no residual
            // page-menu panel visible behind it.
            UIView.addKeyframe(withRelativeStartTime: 0.92, relativeDuration: 0.08) {
                self.sxExtShell.transform = extensionsDrop
                self.sxExtShell.alpha = 0
                self.sxToggle.track.backgroundColor = .systemGray3
                self.sxToggle.thumb.frame.origin.x = 2
            }
        }
    }

}

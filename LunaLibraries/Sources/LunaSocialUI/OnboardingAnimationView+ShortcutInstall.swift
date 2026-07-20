//
//  OnboardingAnimationView+ShortcutInstall.swift
//  Luna
//

import LunaDesignSystem
import UIKit

extension OnboardingAnimationView {

    // MARK: - Shortcut install (Share sheet → Shortcuts app → install)

    /// A vertical (icon, caption) pair matching the Share sheet's app-icon row.
    private func iconWithCaption(_ icon: UIView, caption: UIView) -> UIView {
        let stack = UIStackView(arrangedSubviews: [icon, caption])
        stack.axis = .vertical
        stack.spacing = 4
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    /// A grey Share-sheet caption placeholder underneath an app icon.
    private func captionPlaceholder() -> UIView {
        let v = UIView()
        v.backgroundColor = UIColor.label.withAlphaComponent(0.3)
        v.layer.cornerRadius = 2.5
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 26).isActive = true
        v.heightAnchor.constraint(equalToConstant: 5).isActive = true
        return v
    }

    /// The actual current Shortcuts icon PNG, sourced from Apple's Shortcuts User
    /// Guide and bundled in the host app's asset catalog.
    private func shortcutsAppIcon() -> UIView {
        let icon = siShortcutIcon
        icon.layer.cornerRadius = 8
        icon.layer.cornerCurve = .continuous
        icon.clipsToBounds = true
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 30).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 30).isActive = true

        let image = UIImageView(image: UIImage(named: "ShortcutsAppIcon"))
        image.contentMode = .scaleAspectFit
        image.translatesAutoresizingMaskIntoConstraints = false
        icon.addSubview(image)
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: icon.leadingAnchor),
            image.trailingAnchor.constraint(equalTo: icon.trailingAnchor),
            image.topAnchor.constraint(equalTo: icon.topAnchor),
            image.bottomAnchor.constraint(equalTo: icon.bottomAnchor),
        ])
        return icon
    }

    func buildShortcutInstall() {
        let phone = UIView()
        phone.backgroundColor = .systemBackground
        phone.layer.borderColor = UIColor.systemGray3.cgColor
        phone.layer.borderWidth = 3
        phone.layer.cornerRadius = 26
        phone.layer.cornerCurve = .continuous
        phone.clipsToBounds = true
        phone.translatesAutoresizingMaskIntoConstraints = false
        addSubview(phone)

        // Begin on Luna's actual shortcut-onboarding step. The little static phone
        // inside this phone is the intentional one-level "mirror" of the guide;
        // it communicates what the user is looking at without recursively running
        // another animation inside itself.
        let page = UIView()
        page.backgroundColor = .secondarySystemBackground
        page.translatesAutoresizingMaskIntoConstraints = false
        phone.addSubview(page)
        let nestedPhone = UIView()
        nestedPhone.backgroundColor = .systemBackground
        nestedPhone.layer.cornerRadius = 10
        nestedPhone.layer.borderColor = UIColor.systemGray3.cgColor
        nestedPhone.layer.borderWidth = 1.5
        nestedPhone.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(nestedPhone)
        let nestedVisual = UIView()
        nestedVisual.backgroundColor = .systemGray3
        nestedVisual.layer.cornerRadius = 4
        nestedVisual.translatesAutoresizingMaskIntoConstraints = false
        nestedPhone.addSubview(nestedVisual)
        let nestedButton = UIView()
        nestedButton.backgroundColor = .systemGray3
        nestedButton.layer.cornerRadius = 4
        nestedButton.translatesAutoresizingMaskIntoConstraints = false
        nestedPhone.addSubview(nestedButton)
        let stepTitle = UIView()
        stepTitle.backgroundColor = .systemGray3
        stepTitle.layer.cornerRadius = 2
        stepTitle.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(stepTitle)
        let stepCopy = UIView()
        stepCopy.backgroundColor = .systemGray4
        stepCopy.layer.cornerRadius = 2
        stepCopy.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(stepCopy)

        // The real primary action shown on the onboarding step.
        let toolbar = UIView()
        toolbar.backgroundColor = accent
        toolbar.layer.cornerRadius = 9
        toolbar.layer.cornerCurve = .continuous
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        phone.addSubview(toolbar)
        let shareIcon = UILabel()
        shareIcon.text = "Install Shortcut"
        shareIcon.textColor = .white
        shareIcon.font = .systemFont(ofSize: 10, weight: .semibold)
        shareIcon.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(shareIcon)
        siShareRipple.backgroundColor = UIColor.white.withAlphaComponent(0.34)
        siShareRipple.layer.cornerRadius = 9
        siShareRipple.alpha = 0
        siShareRipple.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(siShareRipple)

        // Share sheet: grabber, then an app-icon row with captions.
        configureSheetShell(siShareSheet)
        phone.addSubview(siShareSheet)
        let grabber = sheetGrabber()
        siShareSheet.addSubview(grabber)

        // Three apps, not four: the fourth left no room between icons and forced
        // the one real caption ("Shortcuts") to truncate.
        let generic1 = iconWithCaption(axAppIcon(), caption: captionPlaceholder())
        let shortcutsCaption = UILabel()
        shortcutsCaption.text = "Shortcuts"
        shortcutsCaption.font = .systemFont(ofSize: 9, weight: .medium)
        shortcutsCaption.textColor = .label
        shortcutsCaption.setContentCompressionResistancePriority(.required, for: .horizontal)
        let shortcutsItem = iconWithCaption(shortcutsAppIcon(), caption: shortcutsCaption)
        let generic2 = iconWithCaption(axAppIcon(), caption: captionPlaceholder())
        let appsRow = UIStackView(arrangedSubviews: [generic1, shortcutsItem, generic2])
        appsRow.axis = .horizontal
        appsRow.distribution = .equalSpacing
        appsRow.alignment = .top
        appsRow.translatesAutoresizingMaskIntoConstraints = false
        siShareSheet.addSubview(appsRow)

        siShortcutRipple.backgroundColor = accent.withAlphaComponent(0.35)
        siShortcutRipple.layer.cornerRadius = 15
        siShortcutRipple.alpha = 0
        siShortcutRipple.translatesAutoresizingMaskIntoConstraints = false
        siShareSheet.insertSubview(siShortcutRipple, belowSubview: appsRow)

        let sheetRows = UIStackView(arrangedSubviews: [
            axActionRow(symbol: "doc.on.doc", placeholderWidth: 40),
            axActionRow(symbol: "printer", placeholderWidth: 42),
        ])
        sheetRows.axis = .vertical
        sheetRows.spacing = 4
        sheetRows.translatesAutoresizingMaskIntoConstraints = false
        siShareSheet.addSubview(sheetRows)

        NSLayoutConstraint.activate([
            phone.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            phone.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            phone.centerXAnchor.constraint(equalTo: centerXAnchor),
            phone.widthAnchor.constraint(equalTo: phone.heightAnchor, multiplier: 0.49),

            page.topAnchor.constraint(equalTo: phone.topAnchor),
            page.leadingAnchor.constraint(equalTo: phone.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: phone.trailingAnchor),
            page.bottomAnchor.constraint(equalTo: toolbar.topAnchor),
            nestedPhone.centerXAnchor.constraint(equalTo: page.centerXAnchor),
            nestedPhone.topAnchor.constraint(equalTo: page.topAnchor, constant: 26),
            nestedPhone.widthAnchor.constraint(equalToConstant: 58),
            nestedPhone.heightAnchor.constraint(equalToConstant: 76),
            nestedVisual.leadingAnchor.constraint(equalTo: nestedPhone.leadingAnchor, constant: 8),
            nestedVisual.trailingAnchor.constraint(equalTo: nestedPhone.trailingAnchor, constant: -8),
            nestedVisual.topAnchor.constraint(equalTo: nestedPhone.topAnchor, constant: 8),
            nestedVisual.heightAnchor.constraint(equalToConstant: 32),
            nestedButton.leadingAnchor.constraint(equalTo: nestedPhone.leadingAnchor, constant: 9),
            nestedButton.trailingAnchor.constraint(equalTo: nestedPhone.trailingAnchor, constant: -9),
            nestedButton.bottomAnchor.constraint(equalTo: nestedPhone.bottomAnchor, constant: -9),
            nestedButton.heightAnchor.constraint(equalToConstant: 7),
            stepTitle.topAnchor.constraint(equalTo: nestedPhone.bottomAnchor, constant: 12),
            stepTitle.centerXAnchor.constraint(equalTo: page.centerXAnchor),
            stepTitle.widthAnchor.constraint(equalToConstant: 82),
            stepTitle.heightAnchor.constraint(equalToConstant: 6),
            stepCopy.topAnchor.constraint(equalTo: stepTitle.bottomAnchor, constant: 5),
            stepCopy.centerXAnchor.constraint(equalTo: page.centerXAnchor),
            stepCopy.widthAnchor.constraint(equalToConstant: 66),
            stepCopy.heightAnchor.constraint(equalToConstant: 4),

            toolbar.leadingAnchor.constraint(equalTo: phone.leadingAnchor, constant: 14),
            toolbar.trailingAnchor.constraint(equalTo: phone.trailingAnchor, constant: -14),
            toolbar.bottomAnchor.constraint(equalTo: phone.bottomAnchor, constant: -14),
            toolbar.heightAnchor.constraint(equalToConstant: 32),
            shareIcon.centerXAnchor.constraint(equalTo: toolbar.centerXAnchor),
            shareIcon.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            siShareRipple.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            siShareRipple.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            siShareRipple.topAnchor.constraint(equalTo: toolbar.topAnchor),
            siShareRipple.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),

            siShareSheet.leadingAnchor.constraint(equalTo: phone.leadingAnchor),
            siShareSheet.trailingAnchor.constraint(equalTo: phone.trailingAnchor),
            siShareSheet.bottomAnchor.constraint(equalTo: phone.bottomAnchor),
            siShareSheet.heightAnchor.constraint(equalTo: phone.heightAnchor, multiplier: 0.6),
            grabber.topAnchor.constraint(equalTo: siShareSheet.topAnchor, constant: 7),
            grabber.centerXAnchor.constraint(equalTo: siShareSheet.centerXAnchor),
            grabber.widthAnchor.constraint(equalToConstant: 34),
            grabber.heightAnchor.constraint(equalToConstant: 5),
            appsRow.topAnchor.constraint(equalTo: grabber.bottomAnchor, constant: 14),
            appsRow.leadingAnchor.constraint(equalTo: siShareSheet.leadingAnchor, constant: 10),
            appsRow.trailingAnchor.constraint(equalTo: siShareSheet.trailingAnchor, constant: -10),
            siShortcutRipple.centerXAnchor.constraint(equalTo: shortcutsItem.centerXAnchor),
            siShortcutRipple.centerYAnchor.constraint(equalTo: siShortcutIcon.centerYAnchor),
            siShortcutRipple.widthAnchor.constraint(equalToConstant: 38),
            siShortcutRipple.heightAnchor.constraint(equalToConstant: 38),
            sheetRows.topAnchor.constraint(equalTo: appsRow.bottomAnchor, constant: 16),
            sheetRows.leadingAnchor.constraint(equalTo: siShareSheet.leadingAnchor, constant: 14),
            sheetRows.trailingAnchor.constraint(equalTo: siShareSheet.trailingAnchor, constant: -14),
        ])
    }

    func animateShortcutInstall() {
        layoutIfNeeded()
        let sheetDrop = CGAffineTransform(translationX: 0, y: siShareSheet.bounds.height + 8)

        func reset() {
            siShareSheet.transform = sheetDrop
            siShareRipple.alpha = 0
            siShareRipple.transform = CGAffineTransform(scaleX: 0.3, y: 0.3)
            siShortcutRipple.alpha = 0
            siShortcutRipple.transform = CGAffineTransform(scaleX: 0.3, y: 0.3)
            siShortcutIcon.transform = .identity
        }
        reset()

        UIView.animateKeyframes(withDuration: 5.5, delay: 0.4, options: [.repeat]) {
            // Tap the Share button.
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.05) {
                self.siShareRipple.alpha = 1
                self.siShareRipple.transform = .identity
            }
            UIView.addKeyframe(withRelativeStartTime: 0.07, relativeDuration: 0.07) {
                self.siShareRipple.alpha = 0
            }
            // Share sheet slides up.
            UIView.addKeyframe(withRelativeStartTime: 0.1, relativeDuration: 0.18) {
                self.siShareSheet.transform = .identity
            }
            // Tap the Shortcuts icon.
            UIView.addKeyframe(withRelativeStartTime: 0.5, relativeDuration: 0.06) {
                self.siShortcutRipple.alpha = 1
            }
            UIView.addKeyframe(withRelativeStartTime: 0.56, relativeDuration: 0.06) {
                self.siShortcutRipple.alpha = 0
                self.siShortcutIcon.transform = CGAffineTransform(scaleX: 1.12, y: 1.12)
            }
            UIView.addKeyframe(withRelativeStartTime: 0.62, relativeDuration: 0.08) {
                self.siShortcutIcon.transform = .identity
            }
            // Hold, then reset for a seamless loop.
            UIView.addKeyframe(withRelativeStartTime: 0.90, relativeDuration: 0.1) {
                reset()
            }
        }
    }

}

//
//  OnboardingAnimationView+ActionExtension.swift
//  Luna
//

import LunaDesignSystem
import UIKit

extension OnboardingAnimationView {

    // MARK: - Action extension (Safari → Share → "Save to Luna" → reader)

    func buildActionExtension() {
        let phone = UIView()
        phone.backgroundColor = LunaColors.background
        phone.layer.borderColor = UIColor.systemGray3.cgColor
        phone.layer.borderWidth = 3
        phone.layer.cornerRadius = 30
        phone.layer.cornerCurve = .continuous
        phone.clipsToBounds = true
        phone.translatesAutoresizingMaskIntoConstraints = false
        addSubview(phone)

        // Safari page: text lines + a bottom toolbar with the Share button.
        let page = UIView()
        page.backgroundColor = LunaColors.secondaryBackground
        page.translatesAutoresizingMaskIntoConstraints = false
        phone.addSubview(page)
        let headline = bar(width: 0.7, height: 9, color: LunaColors.primaryText.withAlphaComponent(0.7))
        let lines = UIStackView(arrangedSubviews: [
            headline, bar(width: 0.95, height: 5), bar(width: 0.9, height: 5),
            bar(width: 0.93, height: 5), bar(width: 0.6, height: 5)])
        lines.axis = .vertical
        lines.spacing = 7
        lines.alignment = .fill   // .fill so the bar wrappers get a width (else 0-wide/invisible)
        lines.setCustomSpacing(12, after: headline)
        lines.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(lines)

        // Safari bottom chrome: a URL pill above a row of toolbar icons
        // (back, forward, Share, book, tabs) — matching real Safari.
        let toolbar = UIView()
        toolbar.backgroundColor = LunaColors.background
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        phone.addSubview(toolbar)

        let urlPill = UIView()
        urlPill.backgroundColor = LunaColors.secondaryBackground
        urlPill.layer.cornerRadius = 9
        urlPill.layer.cornerCurve = .continuous
        urlPill.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(urlPill)
        // A grey placeholder bar stands in for the URL text — the animation uses
        // no literal text anywhere, just grey boxes where text would be.
        let urlPlaceholder = UIView()
        urlPlaceholder.backgroundColor = LunaColors.primaryText.withAlphaComponent(0.3)
        urlPlaceholder.layer.cornerRadius = 3
        urlPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        urlPill.addSubview(urlPlaceholder)

        let shareIcon = UIImageView(image: UIImage(
            systemName: "square.and.arrow.up", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15)))
        shareIcon.tintColor = accent   // the icon we tap
        shareIcon.contentMode = .center
        let icons = UIStackView(arrangedSubviews: [
            toolbarIcon("chevron.left"), toolbarIcon("chevron.right"),
            shareIcon, toolbarIcon("book"), toolbarIcon("square.on.square")])
        icons.axis = .horizontal
        icons.distribution = .equalSpacing
        icons.alignment = .center
        icons.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(icons)

        axShareRipple.backgroundColor = accent.withAlphaComponent(0.3)
        axShareRipple.layer.cornerRadius = 15
        axShareRipple.alpha = 0
        axShareRipple.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(axShareRipple)

        // Share sheet (slides up): grabber, app-icon row, then the scrolling actions.
        axShareSheet.backgroundColor = LunaColors.background
        axShareSheet.layer.cornerRadius = 18
        axShareSheet.layer.cornerCurve = .continuous
        axShareSheet.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        axShareSheet.layer.borderColor = LunaColors.separator.cgColor
        axShareSheet.layer.borderWidth = 0.5
        axShareSheet.clipsToBounds = true
        axShareSheet.translatesAutoresizingMaskIntoConstraints = false
        phone.addSubview(axShareSheet)

        let grabber = UIView()
        grabber.backgroundColor = .systemGray3
        grabber.layer.cornerRadius = 2.5
        grabber.translatesAutoresizingMaskIntoConstraints = false
        axShareSheet.addSubview(grabber)
        let appsRow = UIStackView(arrangedSubviews: (0..<4).map { _ in axAppIcon() })
        appsRow.axis = .horizontal
        appsRow.distribution = .equalSpacing
        appsRow.translatesAutoresizingMaskIntoConstraints = false
        axShareSheet.addSubview(appsRow)

        axRowScroll.clipsToBounds = true
        axRowScroll.translatesAutoresizingMaskIntoConstraints = false
        axShareSheet.addSubview(axRowScroll)

        axReadHighlight.backgroundColor = accent.withAlphaComponent(0.16)
        axReadHighlight.layer.cornerRadius = 8
        axReadHighlight.alpha = 0
        axReadHighlight.translatesAutoresizingMaskIntoConstraints = false

        axRowList.axis = .vertical
        axRowList.spacing = 4
        axRowList.translatesAutoresizingMaskIntoConstraints = false
        axRowScroll.addSubview(axReadHighlight)
        axRowScroll.addSubview(axRowList)
        // The Luna row sits low in the list, so the list must scroll up.
        let readRow = axQueueActionRow()
        for row in [axActionRow(symbol: "doc.on.doc", placeholderWidth: 34),
                    axActionRow(symbol: "eyeglasses", placeholderWidth: 82),
                    axActionRow(symbol: "plus.square.on.square", placeholderWidth: 94),
                    axActionRow(symbol: "pencil.tip.crop.circle", placeholderWidth: 50),
                    readRow,
                    axActionRow(symbol: "printer", placeholderWidth: 38)] {
            axRowList.addArrangedSubview(row)
        }

        // The action-extension UI (the Luna reader) — slides up over everything.
        axActionCard.backgroundColor = LunaColors.background
        axActionCard.layer.cornerRadius = 18
        axActionCard.layer.cornerCurve = .continuous
        axActionCard.clipsToBounds = true
        axActionCard.translatesAutoresizingMaskIntoConstraints = false
        phone.addSubview(axActionCard)
        let cardBar = UIView()
        cardBar.backgroundColor = LunaColors.secondaryBackground
        cardBar.translatesAutoresizingMaskIntoConstraints = false
        axActionCard.addSubview(cardBar)
        // A grey placeholder bar stands in for the "Done" button text.
        let donePlaceholder = UIView()
        donePlaceholder.backgroundColor = LunaColors.primaryText.withAlphaComponent(0.3)
        donePlaceholder.layer.cornerRadius = 3
        donePlaceholder.translatesAutoresizingMaskIntoConstraints = false
        cardBar.addSubview(donePlaceholder)
        let cardHeadline = bar(width: 0.8, height: 10, color: LunaColors.primaryText.withAlphaComponent(0.8))
        let cardLines = UIStackView(arrangedSubviews: [
            cardHeadline, bar(width: 0.96, height: 5), bar(width: 0.92, height: 5),
            bar(width: 0.95, height: 5), bar(width: 0.7, height: 5)])
        cardLines.axis = .vertical
        cardLines.spacing = 8
        cardLines.alignment = .fill   // .fill so the bar wrappers get a width (else invisible)
        cardLines.setCustomSpacing(13, after: cardHeadline)
        cardLines.translatesAutoresizingMaskIntoConstraints = false
        axActionCard.addSubview(cardLines)

        NSLayoutConstraint.activate([
            phone.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            phone.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            phone.centerXAnchor.constraint(equalTo: centerXAnchor),
            phone.widthAnchor.constraint(equalTo: phone.heightAnchor, multiplier: 0.49),

            page.topAnchor.constraint(equalTo: phone.topAnchor),
            page.leadingAnchor.constraint(equalTo: phone.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: phone.trailingAnchor),
            page.bottomAnchor.constraint(equalTo: toolbar.topAnchor),
            lines.topAnchor.constraint(equalTo: page.topAnchor, constant: 18),
            lines.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 14),
            lines.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -14),
            toolbar.leadingAnchor.constraint(equalTo: phone.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: phone.trailingAnchor),
            toolbar.bottomAnchor.constraint(equalTo: phone.bottomAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 54),
            urlPill.topAnchor.constraint(equalTo: toolbar.topAnchor, constant: 6),
            urlPill.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 12),
            urlPill.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -12),
            urlPill.heightAnchor.constraint(equalToConstant: 19),
            urlPlaceholder.centerXAnchor.constraint(equalTo: urlPill.centerXAnchor),
            urlPlaceholder.centerYAnchor.constraint(equalTo: urlPill.centerYAnchor),
            urlPlaceholder.widthAnchor.constraint(equalToConstant: 46),
            urlPlaceholder.heightAnchor.constraint(equalToConstant: 6),
            icons.topAnchor.constraint(equalTo: urlPill.bottomAnchor, constant: 6),
            icons.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 16),
            icons.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -16),
            icons.bottomAnchor.constraint(lessThanOrEqualTo: toolbar.bottomAnchor, constant: -4),
            axShareRipple.centerXAnchor.constraint(equalTo: shareIcon.centerXAnchor),
            axShareRipple.centerYAnchor.constraint(equalTo: shareIcon.centerYAnchor),
            axShareRipple.widthAnchor.constraint(equalToConstant: 30),
            axShareRipple.heightAnchor.constraint(equalToConstant: 30),

            axShareSheet.leadingAnchor.constraint(equalTo: phone.leadingAnchor),
            axShareSheet.trailingAnchor.constraint(equalTo: phone.trailingAnchor),
            axShareSheet.bottomAnchor.constraint(equalTo: phone.bottomAnchor),
            axShareSheet.heightAnchor.constraint(equalTo: phone.heightAnchor, multiplier: 0.66),
            grabber.topAnchor.constraint(equalTo: axShareSheet.topAnchor, constant: 7),
            grabber.centerXAnchor.constraint(equalTo: axShareSheet.centerXAnchor),
            grabber.widthAnchor.constraint(equalToConstant: 34),
            grabber.heightAnchor.constraint(equalToConstant: 5),
            appsRow.topAnchor.constraint(equalTo: grabber.bottomAnchor, constant: 12),
            appsRow.leadingAnchor.constraint(equalTo: axShareSheet.leadingAnchor, constant: 16),
            appsRow.trailingAnchor.constraint(equalTo: axShareSheet.trailingAnchor, constant: -16),
            axRowScroll.topAnchor.constraint(equalTo: appsRow.bottomAnchor, constant: 12),
            axRowScroll.leadingAnchor.constraint(equalTo: axShareSheet.leadingAnchor, constant: 10),
            axRowScroll.trailingAnchor.constraint(equalTo: axShareSheet.trailingAnchor, constant: -10),
            axRowScroll.bottomAnchor.constraint(equalTo: axShareSheet.bottomAnchor, constant: -8),
            axRowList.topAnchor.constraint(equalTo: axRowScroll.topAnchor),
            axRowList.leadingAnchor.constraint(equalTo: axRowScroll.leadingAnchor),
            axRowList.trailingAnchor.constraint(equalTo: axRowScroll.trailingAnchor),
            axReadHighlight.leadingAnchor.constraint(equalTo: readRow.leadingAnchor, constant: -4),
            axReadHighlight.trailingAnchor.constraint(equalTo: readRow.trailingAnchor, constant: 4),
            axReadHighlight.topAnchor.constraint(equalTo: readRow.topAnchor, constant: -2),
            axReadHighlight.bottomAnchor.constraint(equalTo: readRow.bottomAnchor, constant: 2),

            axActionCard.topAnchor.constraint(equalTo: phone.topAnchor),
            axActionCard.bottomAnchor.constraint(equalTo: phone.bottomAnchor),
            axActionCard.leadingAnchor.constraint(equalTo: phone.leadingAnchor),
            axActionCard.trailingAnchor.constraint(equalTo: phone.trailingAnchor),
            cardBar.topAnchor.constraint(equalTo: axActionCard.topAnchor),
            cardBar.leadingAnchor.constraint(equalTo: axActionCard.leadingAnchor),
            cardBar.trailingAnchor.constraint(equalTo: axActionCard.trailingAnchor),
            cardBar.heightAnchor.constraint(equalToConstant: 30),
            donePlaceholder.leadingAnchor.constraint(equalTo: cardBar.leadingAnchor, constant: 12),
            donePlaceholder.centerYAnchor.constraint(equalTo: cardBar.centerYAnchor),
            donePlaceholder.widthAnchor.constraint(equalToConstant: 26),
            donePlaceholder.heightAnchor.constraint(equalToConstant: 6),
            cardLines.topAnchor.constraint(equalTo: cardBar.bottomAnchor, constant: 16),
            cardLines.leadingAnchor.constraint(equalTo: axActionCard.leadingAnchor, constant: 16),
            cardLines.trailingAnchor.constraint(equalTo: axActionCard.trailingAnchor, constant: -16),
        ])
    }

    /// The Luna action-extension row: the app's current icon (leading) and real
    /// "Save to Luna" text (trailing), tinted in the app accent. This is the row the
    /// animation scrolls to and taps — so it gets the one bit of literal text.
    private func axQueueActionRow() -> UIView {
        let icon = UIImageView(image: lunaAppIconImage())
        icon.contentMode = .scaleAspectFit
        icon.layer.cornerRadius = 5
        icon.layer.cornerCurve = .continuous
        icon.clipsToBounds = true
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let label = UILabel()
        label.text = "Save to Luna"
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = accent
        return axActionRow(icon: icon, trailing: label)
    }

    func animateActionExtension() {
        layoutIfNeeded()
        let sheetDrop = CGAffineTransform(translationX: 0, y: axShareSheet.bounds.height + 8)
        let cardDrop = CGAffineTransform(translationX: 0, y: axActionCard.bounds.height + 8)
        // Scroll the list up so "Save to Luna" (the 5th of 6 rows) comes into view.
        let listScroll = CGAffineTransform(translationX: 0, y: -64)

        func reset() {
            axShareSheet.transform = sheetDrop
            axActionCard.transform = cardDrop
            axRowList.transform = .identity
            axReadHighlight.transform = .identity
            axReadHighlight.alpha = 0
            axShareRipple.alpha = 0
            axShareRipple.transform = CGAffineTransform(scaleX: 0.3, y: 0.3)
        }
        reset()

        UIView.animateKeyframes(withDuration: 6.5, delay: 0.4, options: [.repeat]) {
            // Tap Share.
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.05) {
                self.axShareRipple.alpha = 1
                self.axShareRipple.transform = .identity
            }
            UIView.addKeyframe(withRelativeStartTime: 0.05, relativeDuration: 0.05) {
                self.axShareRipple.alpha = 0
            }
            // Share sheet slides up.
            UIView.addKeyframe(withRelativeStartTime: 0.08, relativeDuration: 0.14) {
                self.axShareSheet.transform = .identity
            }
            // Scroll to the "Save to Luna" action. The highlight is anchored to the
            // row's pre-scroll layout frame, so it must take the SAME transform to
            // stay aligned with the (transformed) row.
            UIView.addKeyframe(withRelativeStartTime: 0.34, relativeDuration: 0.14) {
                self.axRowList.transform = listScroll
                self.axReadHighlight.transform = listScroll
            }
            // Tap it (highlight on the "Save to Luna" row).
            UIView.addKeyframe(withRelativeStartTime: 0.50, relativeDuration: 0.06) {
                self.axReadHighlight.alpha = 1
            }
            // Dismiss the share sheet before showing the action extension. The two
            // surfaces are separate system presentations, so letting one finish
            // leaving before the other enters avoids a visually impossible stack.
            UIView.addKeyframe(withRelativeStartTime: 0.58, relativeDuration: 0.10) {
                self.axShareSheet.transform = sheetDrop
                self.axReadHighlight.alpha = 0
            }
            // The Luna reader (action extension) then slides up into the now-clear
            // Safari window.
            UIView.addKeyframe(withRelativeStartTime: 0.70, relativeDuration: 0.14) {
                self.axActionCard.transform = .identity
            }
            // Hold, then reset for a seamless loop.
            UIView.addKeyframe(withRelativeStartTime: 0.90, relativeDuration: 0.1) {
                self.axActionCard.transform = cardDrop
                self.axShareSheet.transform = sheetDrop
                self.axRowList.transform = .identity
                self.axReadHighlight.transform = .identity
                self.axReadHighlight.alpha = 0
            }
        }
    }

}

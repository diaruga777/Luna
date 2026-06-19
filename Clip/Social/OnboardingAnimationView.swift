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
        case notification     // a banner sliding in
        case settingsToggle   // a Settings row whose switch flips on
        case actionButton     // the Action Button pressed → "Saved" card
        case actionExtension  // Safari → Share → "Read in Queue" action → reader
    }

    private let kind: Kind
    private let accent = GlassStyle.readingAccent

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        // The phone facsimiles are portrait, so they get taller canvases; the
        // action-extension demo is the largest (≈ half the screen).
        let height: CGFloat
        switch kind {
        case .actionExtension: height = 360
        case .actionButton: height = 230
        default: height = 150
        }
        heightAnchor.constraint(equalToConstant: height).isActive = true
        widthAnchor.constraint(equalToConstant: kind == .actionExtension ? 220 : 260).isActive = true
        clipsToBounds = true
        switch kind {
        case .notification: buildNotification()
        case .settingsToggle: buildToggle()
        case .actionButton: buildActionButton()
        case .actionExtension: buildActionExtension()
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Begins (or restarts) the looping animation. Safe to call repeatedly.
    func start() {
        switch kind {
        case .notification: animateNotification()
        case .settingsToggle: animateToggle()
        case .actionButton: animateActionButton()
        case .actionExtension: animateActionExtension()
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
        title.text = "Queue"
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
        label.text = "Queue"
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

        // "Saved to Queue" toast inside the phone screen.
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
        savedLabel.text = "Saved to Queue"
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

    // MARK: - Action extension (Safari → Share → "Read in Queue" → reader)

    private let axShareRipple = UIView()
    private let axShareSheet = UIView()
    private let axRowScroll = UIView()   // clips the scrolling action list
    private let axRowList = UIStackView()
    private let axReadHighlight = UIView()
    private let axActionCard = UIView()

    private func buildActionExtension() {
        let phone = UIView()
        phone.backgroundColor = .systemBackground
        phone.layer.borderColor = UIColor.systemGray3.cgColor
        phone.layer.borderWidth = 3
        phone.layer.cornerRadius = 30
        phone.layer.cornerCurve = .continuous
        phone.clipsToBounds = true
        phone.translatesAutoresizingMaskIntoConstraints = false
        addSubview(phone)

        // Safari page: text lines + a bottom toolbar with the Share button.
        let page = UIView()
        page.backgroundColor = .secondarySystemBackground
        page.translatesAutoresizingMaskIntoConstraints = false
        phone.addSubview(page)
        let headline = bar(width: 0.7, height: 9, color: .label.withAlphaComponent(0.7))
        let lines = UIStackView(arrangedSubviews: [
            headline, bar(width: 0.95, height: 5), bar(width: 0.9, height: 5),
            bar(width: 0.93, height: 5), bar(width: 0.6, height: 5)])
        lines.axis = .vertical
        lines.spacing = 7
        lines.alignment = .leading
        lines.setCustomSpacing(12, after: headline)
        lines.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(lines)

        let toolbar = UIView()
        toolbar.backgroundColor = .systemBackground
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        phone.addSubview(toolbar)
        let shareIcon = UIImageView(image: UIImage(
            systemName: "square.and.arrow.up", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16)))
        shareIcon.tintColor = accent
        shareIcon.contentMode = .center
        shareIcon.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(shareIcon)

        axShareRipple.backgroundColor = accent.withAlphaComponent(0.3)
        axShareRipple.layer.cornerRadius = 16
        axShareRipple.alpha = 0
        axShareRipple.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(axShareRipple)

        // Share sheet (slides up): grabber, app-icon row, then the scrolling actions.
        axShareSheet.backgroundColor = .systemBackground
        axShareSheet.layer.cornerRadius = 18
        axShareSheet.layer.cornerCurve = .continuous
        axShareSheet.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        axShareSheet.layer.borderColor = UIColor.separator.cgColor
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
        // The "Read in Queue" row sits low in the list, so the list must scroll up.
        let readRow = axActionRow(symbol: "book.fill", title: "Read in Queue", highlighted: true)
        for row in [axActionRow(symbol: "doc.on.doc", title: "Copy"),
                    axActionRow(symbol: "eyeglasses", title: "Add to Reading List"),
                    axActionRow(symbol: "plus.square.on.square", title: "Add to Home Screen"),
                    axActionRow(symbol: "pencil.tip.crop.circle", title: "Markup"),
                    readRow,
                    axActionRow(symbol: "printer", title: "Print")] {
            axRowList.addArrangedSubview(row)
        }

        // The action-extension UI (the Queue reader) — slides up over everything.
        axActionCard.backgroundColor = .systemBackground
        axActionCard.layer.cornerRadius = 18
        axActionCard.layer.cornerCurve = .continuous
        axActionCard.clipsToBounds = true
        axActionCard.translatesAutoresizingMaskIntoConstraints = false
        phone.addSubview(axActionCard)
        let cardBar = UIView()
        cardBar.backgroundColor = .secondarySystemBackground
        cardBar.translatesAutoresizingMaskIntoConstraints = false
        axActionCard.addSubview(cardBar)
        let doneLabel = UILabel()
        doneLabel.text = "Done"
        doneLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        doneLabel.textColor = accent
        doneLabel.translatesAutoresizingMaskIntoConstraints = false
        cardBar.addSubview(doneLabel)
        let cardHeadline = bar(width: 0.8, height: 10, color: .label.withAlphaComponent(0.8))
        let cardLines = UIStackView(arrangedSubviews: [
            cardHeadline, bar(width: 0.96, height: 5), bar(width: 0.92, height: 5),
            bar(width: 0.95, height: 5), bar(width: 0.7, height: 5)])
        cardLines.axis = .vertical
        cardLines.spacing = 8
        cardLines.alignment = .leading
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
            toolbar.heightAnchor.constraint(equalToConstant: 34),
            shareIcon.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            shareIcon.centerXAnchor.constraint(equalTo: toolbar.centerXAnchor),
            axShareRipple.centerXAnchor.constraint(equalTo: shareIcon.centerXAnchor),
            axShareRipple.centerYAnchor.constraint(equalTo: shareIcon.centerYAnchor),
            axShareRipple.widthAnchor.constraint(equalToConstant: 32),
            axShareRipple.heightAnchor.constraint(equalToConstant: 32),

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
            doneLabel.leadingAnchor.constraint(equalTo: cardBar.leadingAnchor, constant: 12),
            doneLabel.centerYAnchor.constraint(equalTo: cardBar.centerYAnchor),
            cardLines.topAnchor.constraint(equalTo: cardBar.bottomAnchor, constant: 16),
            cardLines.leadingAnchor.constraint(equalTo: axActionCard.leadingAnchor, constant: 16),
            cardLines.trailingAnchor.constraint(equalTo: axActionCard.trailingAnchor, constant: -16),
        ])
    }

    /// A small grey app-icon circle for the share sheet's top row.
    private func axAppIcon() -> UIView {
        let icon = UIView()
        icon.backgroundColor = .systemGray4
        icon.layer.cornerRadius = 11
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 30).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return icon
    }

    /// A share-sheet action row: icon + label, ~28pt tall (Queue's row is tinted).
    private func axActionRow(symbol: String, title: String, highlighted: Bool = false) -> UIView {
        let row = UIView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let color: UIColor = highlighted ? accent : .label
        let icon = UIImageView(image: UIImage(
            systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 12)))
        icon.tintColor = color
        icon.contentMode = .center
        icon.translatesAutoresizingMaskIntoConstraints = false
        let label = UILabel()
        label.text = title
        label.font = .systemFont(ofSize: 12, weight: highlighted ? .semibold : .regular)
        label.textColor = color
        let stack = UIStackView(arrangedSubviews: [label, UIView(), icon])
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 18),
            stack.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    private func animateActionExtension() {
        layoutIfNeeded()
        let sheetDrop = CGAffineTransform(translationX: 0, y: axShareSheet.bounds.height + 8)
        let cardDrop = CGAffineTransform(translationX: 0, y: axActionCard.bounds.height + 8)
        // Scroll the list up so "Read in Queue" (the 5th of 6 rows) comes into view.
        let listScroll = CGAffineTransform(translationX: 0, y: -64)

        func reset() {
            axShareSheet.transform = sheetDrop
            axActionCard.transform = cardDrop
            axRowList.transform = .identity
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
            // Scroll to the "Read in Queue" action.
            UIView.addKeyframe(withRelativeStartTime: 0.34, relativeDuration: 0.14) {
                self.axRowList.transform = listScroll
            }
            // Tap it (highlight).
            UIView.addKeyframe(withRelativeStartTime: 0.50, relativeDuration: 0.06) {
                self.axReadHighlight.alpha = 1
            }
            // The Queue reader (action extension) slides up.
            UIView.addKeyframe(withRelativeStartTime: 0.58, relativeDuration: 0.14) {
                self.axActionCard.transform = .identity
            }
            // Hold, then reset for a seamless loop.
            UIView.addKeyframe(withRelativeStartTime: 0.90, relativeDuration: 0.1) {
                self.axActionCard.transform = cardDrop
                self.axShareSheet.transform = sheetDrop
                self.axRowList.transform = .identity
                self.axReadHighlight.alpha = 0
            }
        }
    }
}

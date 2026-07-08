//
//  OnboardingAnimationView.swift
//  Luna
//

import LunaDesignSystem
import UIKit

/// A small looping illustration shown atop an onboarding step, depicting the
/// iOS change the step asks the user to make (enable the Safari extension, install
/// or assign the Action Button shortcut, receive a notification). Purely cosmetic;
/// `start()` lazily builds the illustration and kicks the loop when the step appears.
public final class OnboardingAnimationView: UIView {

    public enum Kind {
        case notification         // a banner sliding in
        case actionButton         // the Action Button pressed → Dynamic Island confirmation
        case actionExtension      // Safari → Share → "Save to Luna" action → reader
        case safariExtension      // Safari → page-menu → Manage Extensions → enable Luna
        case shortcutInstall      // Share sheet → Shortcuts app → install bundled shortcut
        case actionButtonSettings // Settings > Action Button → pick Shortcut → "Send To Luna"

        /// The length, in seconds, of exactly one repeating cycle of this kind's
        /// animation (i.e. the `duration:` passed to its `animateKeyframes` call,
        /// not counting the one-time initial delay before the loop starts). A
        /// video recorder can wait out the initial delay plus one loop, then
        /// capture exactly `loopDuration` seconds for a seamless clip.
        public var loopDuration: TimeInterval {
            switch self {
            case .notification: return 3.0
            case .actionButton: return 3.0
            case .actionExtension: return 6.5
            case .safariExtension: return 6.8
            case .shortcutInstall: return 5.5
            case .actionButtonSettings: return 7.0
            }
        }
    }

    private let kind: Kind
    private let accent = GlassStyle.readingAccent
    private var didBuildIllustration = false

    public init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        // The phone facsimiles are portrait, so they get taller canvases; the
        // action-extension demo is the largest (≈ half the screen).
        let height: CGFloat
        let width: CGFloat
        switch kind {
        case .actionExtension: height = 360; width = 220
        case .safariExtension: height = 360; width = 220
        case .shortcutInstall: height = 300; width = 220
        case .actionButtonSettings: height = 300; width = 280
        case .actionButton: height = 230; width = 260
        default: height = 150; width = 260
        }
        heightAnchor.constraint(equalToConstant: height).isActive = true
        widthAnchor.constraint(equalToConstant: width).isActive = true
        clipsToBounds = true
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    /// Begins (or restarts) the looping animation. Safe to call repeatedly.
    public func start() {
        buildIfNeeded()
        resetAnimationTree()
        switch kind {
        case .notification: animateNotification()
        case .actionButton: animateActionButton()
        case .actionExtension: animateActionExtension()
        case .safariExtension: animateSafariExtension()
        case .shortcutInstall: animateShortcutInstall()
        case .actionButtonSettings: animateActionButtonSettings()
        }
    }

    /// Stops any repeating UIKit animations before a step is hidden or restarted.
    /// Re-entering onboarding from Safari/Settings can otherwise stack multiple
    /// keyframe loops on the same phone mockup.
    public func stop() {
        resetAnimationTree()
    }

    private func resetAnimationTree() {
        func clear(_ view: UIView) {
            view.layer.removeAllAnimations()
            view.subviews.forEach(clear)
        }
        clear(self)
    }

    private func buildIfNeeded() {
        guard !didBuildIllustration else { return }
        didBuildIllustration = true
        switch kind {
        case .notification: buildNotification()
        case .actionButton: buildActionButton()
        case .actionExtension: buildActionExtension()
        case .safariExtension: buildSafariExtension()
        case .shortcutInstall: buildShortcutInstall()
        case .actionButtonSettings: buildActionButtonSettings()
        }
        setNeedsLayout()
        layoutIfNeeded()
    }

    private func lunaAppIconImage() -> UIImage? {
        let identifier = Bundle.main.bundleIdentifier ?? ""
        let appIconName: String
        if identifier.contains(".downloader") {
            appIconName = "Luna Downloader"
        } else if identifier.contains(".pricetracker") {
            appIconName = "Luna Price Tracker"
        } else {
            appIconName = "Luna Reader"
        }
        return UIImage(named: appIconName)
    }

    // MARK: - Notification banner

    private let banner = UIView()

    private func buildNotification() {
        banner.backgroundColor = .secondarySystemBackground
        banner.layer.cornerRadius = 16
        banner.layer.cornerCurve = .continuous
        banner.translatesAutoresizingMaskIntoConstraints = false

        let appIcon = UIImageView(image: lunaAppIconImage())
        appIcon.contentMode = .scaleAspectFit
        appIcon.layer.cornerRadius = 9
        appIcon.layer.cornerCurve = .continuous
        appIcon.clipsToBounds = true
        appIcon.translatesAutoresizingMaskIntoConstraints = false

        let title = UILabel()
        title.text = "Luna"
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

    // MARK: - Action Button (portrait phone running Safari)

    private let pressRipple = UIView()
    private let island = UIView()
    private let islandIcon = UIImageView()
    private let islandCheck = UIImageView(image: UIImage(
        systemName: "checkmark.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)))
    private var islandWidthConstraint: NSLayoutConstraint!
    private var islandHeightConstraint: NSLayoutConstraint!
    private let islandCompactSize = CGSize(width: 34, height: 10)
    private let islandExpandedSize = CGSize(width: 74, height: 17)

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

    // MARK: - Action extension (Safari → Share → "Save to Luna" → reader)

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
        lines.alignment = .fill   // .fill so the bar wrappers get a width (else 0-wide/invisible)
        lines.setCustomSpacing(12, after: headline)
        lines.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(lines)

        // Safari bottom chrome: a URL pill above a row of toolbar icons
        // (back, forward, Share, book, tabs) — matching real Safari.
        let toolbar = UIView()
        toolbar.backgroundColor = .systemBackground
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        phone.addSubview(toolbar)

        let urlPill = UIView()
        urlPill.backgroundColor = .secondarySystemBackground
        urlPill.layer.cornerRadius = 9
        urlPill.layer.cornerCurve = .continuous
        urlPill.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(urlPill)
        // A grey placeholder bar stands in for the URL text — the animation uses
        // no literal text anywhere, just grey boxes where text would be.
        let urlPlaceholder = UIView()
        urlPlaceholder.backgroundColor = UIColor.label.withAlphaComponent(0.3)
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
        // A grey placeholder bar stands in for the "Done" button text.
        let donePlaceholder = UIView()
        donePlaceholder.backgroundColor = UIColor.label.withAlphaComponent(0.3)
        donePlaceholder.layer.cornerRadius = 3
        donePlaceholder.translatesAutoresizingMaskIntoConstraints = false
        cardBar.addSubview(donePlaceholder)
        let cardHeadline = bar(width: 0.8, height: 10, color: .label.withAlphaComponent(0.8))
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

    /// A grey Safari-toolbar icon (back/forward/book/tabs).
    private func toolbarIcon(_ symbol: String) -> UIImageView {
        let icon = UIImageView(image: UIImage(
            systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 14)))
        icon.tintColor = .secondaryLabel
        icon.contentMode = .center
        return icon
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

    /// A generic share-sheet action row: a leading SF icon and a trailing grey
    /// text-placeholder bar, ~28pt tall (no literal text). `placeholderWidth`
    /// varies per row so the list reads like distinct actions.
    private func axActionRow(symbol: String, placeholderWidth: CGFloat) -> UIView {
        let icon = UIImageView(image: UIImage(
            systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 12)))
        icon.tintColor = .label
        icon.contentMode = .center
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        let labelPlaceholder = UIView()
        labelPlaceholder.backgroundColor = UIColor.label.withAlphaComponent(0.35)
        labelPlaceholder.layer.cornerRadius = 3
        labelPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        labelPlaceholder.widthAnchor.constraint(equalToConstant: placeholderWidth).isActive = true
        labelPlaceholder.heightAnchor.constraint(equalToConstant: 6).isActive = true
        return axActionRow(icon: icon, trailing: labelPlaceholder)
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

    /// Lays out one share-sheet action row: leading icon, flexible gap, trailing
    /// text element (grey bar or real label), 28pt tall.
    private func axActionRow(icon: UIView, trailing: UIView) -> UIView {
        let row = UIView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let stack = UIStackView(arrangedSubviews: [icon, UIView(), trailing])
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(stack)
        NSLayoutConstraint.activate([
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
            // The Luna reader (action extension) slides up.
            UIView.addKeyframe(withRelativeStartTime: 0.58, relativeDuration: 0.14) {
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

    // MARK: - Shared sheet-chrome helpers

    /// Styles an (already-instantiated) view as a rounded, top-cornered card
    /// matching the system share-sheet / menu chrome used by several of the
    /// illustrations below.
    private func configureSheetShell(_ v: UIView, cornerRadius: CGFloat = 18) {
        v.backgroundColor = .systemBackground
        v.layer.cornerRadius = cornerRadius
        v.layer.cornerCurve = .continuous
        v.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        v.layer.borderColor = UIColor.separator.cgColor
        v.layer.borderWidth = 0.5
        v.clipsToBounds = true
        v.translatesAutoresizingMaskIntoConstraints = false
    }

    /// A new rounded, top-cornered sheet card (see `configureSheetShell`).
    private func sheetShell(cornerRadius: CGFloat = 18) -> UIView {
        let v = UIView()
        configureSheetShell(v, cornerRadius: cornerRadius)
        return v
    }

    /// The small horizontal grabber at the top of a sheet.
    private func sheetGrabber() -> UIView {
        let g = UIView()
        g.backgroundColor = .systemGray3
        g.layer.cornerRadius = 2.5
        g.translatesAutoresizingMaskIntoConstraints = false
        return g
    }

    /// A literal (non-placeholder) share-sheet-style row: an SF Symbol leading
    /// icon and a real text label, used for the handful of rows the new
    /// illustrations call out by name (e.g. "Manage Extensions").
    private func literalActionRow(symbol: String, text: String, tint: UIColor = .label) -> UIView {
        let icon = UIImageView(image: UIImage(
            systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 12)))
        icon.tintColor = tint
        icon.contentMode = .center
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = tint
        return axActionRow(icon: icon, trailing: label)
    }

    /// A small on/off toggle track+thumb pair, styled like `buildToggle`'s but
    /// sized for use inside a compact row (rather than a full Settings row).
    private func miniToggle() -> (track: UIView, thumb: UIView) {
        let track = UIView()
        track.backgroundColor = .systemGray3
        track.layer.cornerRadius = 9
        track.translatesAutoresizingMaskIntoConstraints = false
        track.widthAnchor.constraint(equalToConstant: 32).isActive = true
        track.heightAnchor.constraint(equalToConstant: 18).isActive = true
        let thumb = UIView()
        thumb.backgroundColor = .white
        thumb.layer.cornerRadius = 7
        thumb.layer.shadowColor = UIColor.black.cgColor
        thumb.layer.shadowOpacity = 0.2
        thumb.layer.shadowRadius = 1.5
        thumb.layer.shadowOffset = CGSize(width: 0, height: 1)
        thumb.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(thumb)
        thumb.frame = CGRect(x: 2, y: 2, width: 14, height: 14)
        return (track, thumb)
    }

    // MARK: - Safari extension (Safari → page-menu → Manage Extensions → enable Luna)

    private let sxMenuRipple = UIView()
    private let sxMenuShell = UIView()
    private let sxManageHighlight = UIView()
    private let sxExtShell = UIView()
    private var sxToggle: (track: UIView, thumb: UIView)!

    private func buildSafariExtension() {
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

        // The page-menu sheet (grey rows + literal "Manage Extensions").
        configureSheetShell(sxMenuShell, cornerRadius: 14)
        phone.addSubview(sxMenuShell)
        let menuGrabber = sheetGrabber()
        sxMenuShell.addSubview(menuGrabber)
        let menuRows = UIStackView(arrangedSubviews: [
            axActionRow(symbol: "doc.text.magnifyingglass", placeholderWidth: 90),
            axActionRow(symbol: "gearshape", placeholderWidth: 110),
            literalActionRow(symbol: "puzzlepiece.extension", text: "Manage Extensions"),
        ])
        menuRows.axis = .vertical
        menuRows.spacing = 4
        menuRows.translatesAutoresizingMaskIntoConstraints = false
        sxMenuShell.addSubview(menuRows)
        sxManageHighlight.backgroundColor = accent.withAlphaComponent(0.16)
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
        let extTitle = bar(width: 0.4, height: 8, color: .label.withAlphaComponent(0.6))
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
            addressBar.heightAnchor.constraint(equalToConstant: 40),
            pageMenuButton.leadingAnchor.constraint(equalTo: addressBar.leadingAnchor, constant: 10),
            pageMenuButton.centerYAnchor.constraint(equalTo: addressBar.centerYAnchor),
            pageMenuButton.widthAnchor.constraint(equalToConstant: 26),
            pageMenuButton.heightAnchor.constraint(equalToConstant: 26),
            sxMenuRipple.centerXAnchor.constraint(equalTo: pageMenuButton.centerXAnchor),
            sxMenuRipple.centerYAnchor.constraint(equalTo: pageMenuButton.centerYAnchor),
            sxMenuRipple.widthAnchor.constraint(equalToConstant: 30),
            sxMenuRipple.heightAnchor.constraint(equalToConstant: 30),
            urlPill.leadingAnchor.constraint(equalTo: pageMenuButton.trailingAnchor, constant: 6),
            urlPill.trailingAnchor.constraint(equalTo: trailingIcons.leadingAnchor, constant: -8),
            urlPill.centerYAnchor.constraint(equalTo: addressBar.centerYAnchor),
            urlPill.heightAnchor.constraint(equalToConstant: 18),
            urlPlaceholder.centerXAnchor.constraint(equalTo: urlPill.centerXAnchor),
            urlPlaceholder.centerYAnchor.constraint(equalTo: urlPill.centerYAnchor),
            urlPlaceholder.widthAnchor.constraint(equalToConstant: 40),
            urlPlaceholder.heightAnchor.constraint(equalToConstant: 6),
            trailingIcons.trailingAnchor.constraint(equalTo: addressBar.trailingAnchor, constant: -10),
            trailingIcons.centerYAnchor.constraint(equalTo: addressBar.centerYAnchor),

            sxMenuShell.leadingAnchor.constraint(equalTo: phone.leadingAnchor),
            sxMenuShell.trailingAnchor.constraint(equalTo: phone.trailingAnchor),
            sxMenuShell.bottomAnchor.constraint(equalTo: addressBar.topAnchor),
            sxMenuShell.heightAnchor.constraint(equalTo: phone.heightAnchor, multiplier: 0.34),
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
            sxExtShell.heightAnchor.constraint(equalTo: phone.heightAnchor, multiplier: 0.34),
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

    private func animateSafariExtension() {
        layoutIfNeeded()
        let menuDrop = CGAffineTransform(translationX: 0, y: sxMenuShell.bounds.height + 8)
        let menuExitLeft = CGAffineTransform(translationX: -sxMenuShell.bounds.width - 8, y: 0)
        let extIn = CGAffineTransform(translationX: sxExtShell.bounds.width + 8, y: 0)

        func reset() {
            sxMenuShell.transform = menuDrop
            sxExtShell.transform = extIn
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
            UIView.addKeyframe(withRelativeStartTime: 0.34, relativeDuration: 0.06) {
                self.sxManageHighlight.alpha = 1
            }
            // The extensions list panel slides in over the menu.
            UIView.addKeyframe(withRelativeStartTime: 0.42, relativeDuration: 0.14) {
                self.sxMenuShell.transform = menuExitLeft
                self.sxExtShell.transform = .identity
            }
            // Flip the Luna toggle on.
            UIView.addKeyframe(withRelativeStartTime: 0.58, relativeDuration: 0.1) {
                self.sxToggle.track.backgroundColor = self.accent
                self.sxToggle.thumb.frame.origin.x = 16
            }
            // Hold, then reset for a seamless loop.
            UIView.addKeyframe(withRelativeStartTime: 0.90, relativeDuration: 0.1) {
                reset()
            }
        }
    }

    // MARK: - Shortcut install (Share sheet → Shortcuts app → install)

    private let siShareRipple = UIView()
    private let siShareSheet = UIView()
    private let siShortcutIcon = UIView()
    private let siShortcutRipple = UIView()

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

    /// A Shortcuts-app icon facsimile: a blue-to-purple gradient rounded square
    /// with a white two-diamond motif approximated by two overlapping rotated
    /// rounded squares (the real glyph has no exact SF Symbol match).
    private func shortcutsAppIcon() -> UIView {
        let icon = siShortcutIcon
        icon.layer.cornerRadius = 8
        icon.layer.cornerCurve = .continuous
        icon.clipsToBounds = true
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 30).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 30).isActive = true

        let gradient = CAGradientLayer()
        gradient.colors = [UIColor.systemBlue.cgColor, UIColor.systemPurple.cgColor]
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        gradient.frame = CGRect(x: 0, y: 0, width: 30, height: 30)
        icon.layer.insertSublayer(gradient, at: 0)

        func diamond(size: CGFloat, alpha: CGFloat) -> UIView {
            let d = UIView()
            d.backgroundColor = UIColor.white.withAlphaComponent(alpha)
            d.layer.cornerRadius = size * 0.22
            d.layer.cornerCurve = .continuous
            d.transform = CGAffineTransform(rotationAngle: .pi / 4)
            d.translatesAutoresizingMaskIntoConstraints = false
            d.widthAnchor.constraint(equalToConstant: size).isActive = true
            d.heightAnchor.constraint(equalToConstant: size).isActive = true
            return d
        }
        let back = diamond(size: 15, alpha: 0.55)
        let front = diamond(size: 10, alpha: 0.95)
        icon.addSubview(back)
        icon.addSubview(front)
        NSLayoutConstraint.activate([
            back.centerXAnchor.constraint(equalTo: icon.centerXAnchor, constant: -2),
            back.centerYAnchor.constraint(equalTo: icon.centerYAnchor, constant: -2),
            front.centerXAnchor.constraint(equalTo: icon.centerXAnchor, constant: 3),
            front.centerYAnchor.constraint(equalTo: icon.centerYAnchor, constant: 3),
        ])
        return icon
    }

    private func buildShortcutInstall() {
        let phone = UIView()
        phone.backgroundColor = .systemBackground
        phone.layer.borderColor = UIColor.systemGray3.cgColor
        phone.layer.borderWidth = 3
        phone.layer.cornerRadius = 26
        phone.layer.cornerCurve = .continuous
        phone.clipsToBounds = true
        phone.translatesAutoresizingMaskIntoConstraints = false
        addSubview(phone)

        // A generic "file" card standing in for the bundled .shortcut file.
        let page = UIView()
        page.backgroundColor = .secondarySystemBackground
        page.translatesAutoresizingMaskIntoConstraints = false
        phone.addSubview(page)
        let fileCard = UIView()
        fileCard.backgroundColor = .systemBackground
        fileCard.layer.cornerRadius = 10
        fileCard.layer.cornerCurve = .continuous
        fileCard.layer.borderColor = UIColor.separator.cgColor
        fileCard.layer.borderWidth = 0.5
        fileCard.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(fileCard)
        let fileIcon = UIImageView(image: UIImage(
            systemName: "app.connected.to.app.below.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 22)))
        fileIcon.tintColor = accent
        fileIcon.contentMode = .center
        fileIcon.translatesAutoresizingMaskIntoConstraints = false
        fileCard.addSubview(fileIcon)
        let fileNamePlaceholder = bar(width: 0.6, height: 6)
        fileNamePlaceholder.translatesAutoresizingMaskIntoConstraints = false
        fileNamePlaceholder.widthAnchor.constraint(equalToConstant: 60).isActive = true
        fileCard.addSubview(fileNamePlaceholder)

        // Bottom toolbar with a single centered Share button.
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
        siShareRipple.backgroundColor = accent.withAlphaComponent(0.3)
        siShareRipple.layer.cornerRadius = 15
        siShareRipple.alpha = 0
        siShareRipple.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(siShareRipple)

        // Share sheet: grabber, then an app-icon row with captions.
        configureSheetShell(siShareSheet)
        phone.addSubview(siShareSheet)
        let grabber = sheetGrabber()
        siShareSheet.addSubview(grabber)

        let generic1 = iconWithCaption(axAppIcon(), caption: captionPlaceholder())
        let generic2 = iconWithCaption(axAppIcon(), caption: captionPlaceholder())
        let shortcutsCaption = UILabel()
        shortcutsCaption.text = "Shortcuts"
        shortcutsCaption.font = .systemFont(ofSize: 9, weight: .medium)
        shortcutsCaption.textColor = .label
        let shortcutsItem = iconWithCaption(shortcutsAppIcon(), caption: shortcutsCaption)
        let generic3 = iconWithCaption(axAppIcon(), caption: captionPlaceholder())
        let appsRow = UIStackView(arrangedSubviews: [generic1, generic2, shortcutsItem, generic3])
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
            phone.widthAnchor.constraint(equalTo: phone.heightAnchor, multiplier: 0.6),

            page.topAnchor.constraint(equalTo: phone.topAnchor),
            page.leadingAnchor.constraint(equalTo: phone.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: phone.trailingAnchor),
            page.bottomAnchor.constraint(equalTo: toolbar.topAnchor),
            fileCard.centerXAnchor.constraint(equalTo: page.centerXAnchor),
            fileCard.centerYAnchor.constraint(equalTo: page.centerYAnchor, constant: -10),
            fileCard.widthAnchor.constraint(equalToConstant: 100),
            fileCard.heightAnchor.constraint(equalToConstant: 74),
            fileIcon.topAnchor.constraint(equalTo: fileCard.topAnchor, constant: 10),
            fileIcon.centerXAnchor.constraint(equalTo: fileCard.centerXAnchor),
            fileNamePlaceholder.bottomAnchor.constraint(equalTo: fileCard.bottomAnchor, constant: -12),
            fileNamePlaceholder.centerXAnchor.constraint(equalTo: fileCard.centerXAnchor),

            toolbar.leadingAnchor.constraint(equalTo: phone.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: phone.trailingAnchor),
            toolbar.bottomAnchor.constraint(equalTo: phone.bottomAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 44),
            shareIcon.centerXAnchor.constraint(equalTo: toolbar.centerXAnchor),
            shareIcon.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            siShareRipple.centerXAnchor.constraint(equalTo: shareIcon.centerXAnchor),
            siShareRipple.centerYAnchor.constraint(equalTo: shareIcon.centerYAnchor),
            siShareRipple.widthAnchor.constraint(equalToConstant: 30),
            siShareRipple.heightAnchor.constraint(equalToConstant: 30),

            siShareSheet.leadingAnchor.constraint(equalTo: phone.leadingAnchor),
            siShareSheet.trailingAnchor.constraint(equalTo: phone.trailingAnchor),
            siShareSheet.bottomAnchor.constraint(equalTo: phone.bottomAnchor),
            siShareSheet.heightAnchor.constraint(equalTo: phone.heightAnchor, multiplier: 0.6),
            grabber.topAnchor.constraint(equalTo: siShareSheet.topAnchor, constant: 7),
            grabber.centerXAnchor.constraint(equalTo: siShareSheet.centerXAnchor),
            grabber.widthAnchor.constraint(equalToConstant: 34),
            grabber.heightAnchor.constraint(equalToConstant: 5),
            appsRow.topAnchor.constraint(equalTo: grabber.bottomAnchor, constant: 14),
            appsRow.leadingAnchor.constraint(equalTo: siShareSheet.leadingAnchor, constant: 14),
            appsRow.trailingAnchor.constraint(equalTo: siShareSheet.trailingAnchor, constant: -14),
            siShortcutRipple.centerXAnchor.constraint(equalTo: shortcutsItem.centerXAnchor),
            siShortcutRipple.centerYAnchor.constraint(equalTo: siShortcutIcon.centerYAnchor),
            siShortcutRipple.widthAnchor.constraint(equalToConstant: 38),
            siShortcutRipple.heightAnchor.constraint(equalToConstant: 38),
            sheetRows.topAnchor.constraint(equalTo: appsRow.bottomAnchor, constant: 16),
            sheetRows.leadingAnchor.constraint(equalTo: siShareSheet.leadingAnchor, constant: 14),
            sheetRows.trailingAnchor.constraint(equalTo: siShareSheet.trailingAnchor, constant: -14),
        ])
    }

    private func animateShortcutInstall() {
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
            UIView.addKeyframe(withRelativeStartTime: 0.05, relativeDuration: 0.05) {
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

    // MARK: - Action Button Settings (Settings > Action Button carousel)

    // This illustration mocks a fixed, always-dark iOS screen (the Settings >
    // Action Button picker), independent of the device's own light/dark mode —
    // it's meant to be recorded standalone to video. So, unlike every other
    // illustration in this file, its colors are explicit fixed values rather
    // than the adaptive `.label`/`.systemBackground` family.
    private let absCardStep: CGFloat = 78
    private let absCarouselStack = UIStackView()
    private let absCardPrev = UIView()
    private let absCardShortcut = UIView()
    private let absCardNext = UIView()
    private let absChooseRow = UIView()
    private let absRowRipple = UIView()
    private let absOptionsSheet = UIView()
    private let absSendHighlight = UIView()
    private let absCheckmark = UIImageView(image: UIImage(
        systemName: "checkmark.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)))

    /// A carousel option card, styled for the fixed-dark Action Button screen.
    /// Placeholder cards get a grey caption bar; the literal "Shortcut" card
    /// gets a real white caption.
    private func absOptionCard(_ card: UIView, symbol: String, literalCaption: String?) -> UIView {
        card.backgroundColor = UIColor(white: 0.18, alpha: 1)
        card.layer.cornerRadius = 14
        card.layer.cornerCurve = .continuous
        card.translatesAutoresizingMaskIntoConstraints = false
        card.widthAnchor.constraint(equalToConstant: 64).isActive = true
        card.heightAnchor.constraint(equalToConstant: 90).isActive = true

        let icon = UIImageView(image: UIImage(
            systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .medium)))
        icon.tintColor = literalCaption == nil ? UIColor.white.withAlphaComponent(0.55) : .white
        icon.contentMode = .center
        icon.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(icon)

        let caption: UIView
        if let literalCaption {
            let label = UILabel()
            label.text = literalCaption
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .white
            label.translatesAutoresizingMaskIntoConstraints = false
            caption = label
        } else {
            let placeholder = UIView()
            placeholder.backgroundColor = UIColor.white.withAlphaComponent(0.3)
            placeholder.layer.cornerRadius = 2.5
            placeholder.translatesAutoresizingMaskIntoConstraints = false
            placeholder.widthAnchor.constraint(equalToConstant: 34).isActive = true
            placeholder.heightAnchor.constraint(equalToConstant: 5).isActive = true
            caption = placeholder
        }
        card.addSubview(caption)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            icon.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            caption.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            caption.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
        ])
        return card
    }

    /// A share-sheet-style row using the fixed white/grey palette (rather than
    /// `.label`) so it stays legible against the always-dark screen.
    private func darkActionRow(icon symbol: String, placeholderWidth: CGFloat) -> UIView {
        let icon = UIImageView(image: UIImage(
            systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 12)))
        icon.tintColor = .white
        icon.contentMode = .center
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        let placeholder = UIView()
        placeholder.backgroundColor = UIColor.white.withAlphaComponent(0.3)
        placeholder.layer.cornerRadius = 3
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.widthAnchor.constraint(equalToConstant: placeholderWidth).isActive = true
        placeholder.heightAnchor.constraint(equalToConstant: 6).isActive = true
        return axActionRow(icon: icon, trailing: placeholder)
    }

    private func buildActionButtonSettings() {
        let darkScreen = UIView()
        darkScreen.backgroundColor = UIColor(white: 0.06, alpha: 1)
        darkScreen.layer.cornerRadius = 22
        darkScreen.layer.cornerCurve = .continuous
        darkScreen.clipsToBounds = true
        darkScreen.translatesAutoresizingMaskIntoConstraints = false
        addSubview(darkScreen)

        // A side-on iPhone silhouette with the Action Button glowing on its edge.
        let phoneSilhouette = UIView()
        phoneSilhouette.backgroundColor = UIColor(white: 0.1, alpha: 1)
        phoneSilhouette.layer.cornerRadius = 16
        phoneSilhouette.layer.cornerCurve = .continuous
        phoneSilhouette.layer.borderColor = UIColor.white.withAlphaComponent(0.25).cgColor
        phoneSilhouette.layer.borderWidth = 1.5
        phoneSilhouette.translatesAutoresizingMaskIntoConstraints = false
        darkScreen.addSubview(phoneSilhouette)
        let actionButtonNub = UIView()
        actionButtonNub.backgroundColor = accent
        actionButtonNub.layer.cornerRadius = 2.5
        actionButtonNub.layer.shadowColor = accent.cgColor
        actionButtonNub.layer.shadowOpacity = 0.9
        actionButtonNub.layer.shadowRadius = 4
        actionButtonNub.layer.shadowOffset = .zero
        actionButtonNub.translatesAutoresizingMaskIntoConstraints = false
        darkScreen.addSubview(actionButtonNub)

        // The carousel: three option cards clipped to a viewport, panned so the
        // center one reads as the selected option.
        let carouselClip = UIView()
        carouselClip.clipsToBounds = true
        carouselClip.translatesAutoresizingMaskIntoConstraints = false
        darkScreen.addSubview(carouselClip)

        _ = absOptionCard(absCardPrev, symbol: "switch.2", literalCaption: nil)
        _ = absOptionCard(absCardShortcut, symbol: "bolt.fill", literalCaption: "Shortcut")
        _ = absOptionCard(absCardNext, symbol: "textformat.size", literalCaption: nil)
        absCarouselStack.addArrangedSubview(absCardPrev)
        absCarouselStack.addArrangedSubview(absCardShortcut)
        absCarouselStack.addArrangedSubview(absCardNext)
        absCarouselStack.axis = .horizontal
        absCarouselStack.spacing = 14
        absCarouselStack.alignment = .center
        absCarouselStack.translatesAutoresizingMaskIntoConstraints = false
        carouselClip.addSubview(absCarouselStack)

        // "Choose a Shortcut…" row, fades in below the carousel.
        absChooseRow.translatesAutoresizingMaskIntoConstraints = false
        darkScreen.addSubview(absChooseRow)
        let chooseLabel = UILabel()
        chooseLabel.text = "Choose a Shortcut…"
        chooseLabel.font = .systemFont(ofSize: 13, weight: .medium)
        chooseLabel.textColor = .white
        let chooseChevron = UIImageView(image: UIImage(
            systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)))
        chooseChevron.tintColor = UIColor.white.withAlphaComponent(0.5)
        let chooseStack = UIStackView(arrangedSubviews: [chooseLabel, chooseChevron])
        chooseStack.spacing = 6
        chooseStack.alignment = .center
        chooseStack.translatesAutoresizingMaskIntoConstraints = false
        absChooseRow.addSubview(chooseStack)
        absRowRipple.backgroundColor = accent.withAlphaComponent(0.35)
        absRowRipple.layer.cornerRadius = 12
        absRowRipple.alpha = 0
        absRowRipple.translatesAutoresizingMaskIntoConstraints = false
        absChooseRow.addSubview(absRowRipple)

        // The options sheet (slides up): grey rows + literal "Send To Luna".
        absOptionsSheet.backgroundColor = UIColor(white: 0.14, alpha: 1)
        absOptionsSheet.layer.cornerRadius = 16
        absOptionsSheet.layer.cornerCurve = .continuous
        absOptionsSheet.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        absOptionsSheet.clipsToBounds = true
        absOptionsSheet.translatesAutoresizingMaskIntoConstraints = false
        darkScreen.addSubview(absOptionsSheet)
        let sheetGrabberView = sheetGrabber()
        sheetGrabberView.backgroundColor = UIColor.white.withAlphaComponent(0.3)
        absOptionsSheet.addSubview(sheetGrabberView)

        let lunaIcon = UIImageView(image: lunaAppIconImage())
        lunaIcon.contentMode = .scaleAspectFit
        lunaIcon.layer.cornerRadius = 5
        lunaIcon.layer.cornerCurve = .continuous
        lunaIcon.clipsToBounds = true
        lunaIcon.translatesAutoresizingMaskIntoConstraints = false
        lunaIcon.widthAnchor.constraint(equalToConstant: 20).isActive = true
        lunaIcon.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let lunaLabel = UILabel()
        lunaLabel.text = "Send To Luna"
        lunaLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        lunaLabel.textColor = .white
        absCheckmark.tintColor = .systemGreen
        absCheckmark.alpha = 0
        absCheckmark.translatesAutoresizingMaskIntoConstraints = false
        absCheckmark.widthAnchor.constraint(equalToConstant: 13).isActive = true
        absCheckmark.heightAnchor.constraint(equalToConstant: 13).isActive = true
        // The checkmark sits alongside the label (not pinned separately) so it
        // never overlaps the trailing-flush label text when it fades in.
        let sendTrailing = UIStackView(arrangedSubviews: [lunaLabel, absCheckmark])
        sendTrailing.spacing = 6
        sendTrailing.alignment = .center
        let sendRow = axActionRow(icon: lunaIcon, trailing: sendTrailing)

        let sheetRows = UIStackView(arrangedSubviews: [
            darkActionRow(icon: "moon.fill", placeholderWidth: 70),
            darkActionRow(icon: "camera.fill", placeholderWidth: 60),
            sendRow,
        ])
        sheetRows.axis = .vertical
        sheetRows.spacing = 4
        sheetRows.translatesAutoresizingMaskIntoConstraints = false
        absOptionsSheet.addSubview(sheetRows)
        absSendHighlight.backgroundColor = accent.withAlphaComponent(0.2)
        absSendHighlight.layer.cornerRadius = 8
        absSendHighlight.alpha = 0
        absSendHighlight.translatesAutoresizingMaskIntoConstraints = false
        absOptionsSheet.insertSubview(absSendHighlight, belowSubview: sheetRows)

        NSLayoutConstraint.activate([
            darkScreen.topAnchor.constraint(equalTo: topAnchor),
            darkScreen.bottomAnchor.constraint(equalTo: bottomAnchor),
            darkScreen.leadingAnchor.constraint(equalTo: leadingAnchor),
            darkScreen.trailingAnchor.constraint(equalTo: trailingAnchor),

            phoneSilhouette.leadingAnchor.constraint(equalTo: darkScreen.leadingAnchor, constant: 16),
            phoneSilhouette.topAnchor.constraint(equalTo: darkScreen.topAnchor, constant: 20),
            phoneSilhouette.widthAnchor.constraint(equalToConstant: 46),
            phoneSilhouette.heightAnchor.constraint(equalToConstant: 118),
            actionButtonNub.trailingAnchor.constraint(equalTo: phoneSilhouette.leadingAnchor, constant: 2),
            actionButtonNub.centerYAnchor.constraint(equalTo: phoneSilhouette.topAnchor, constant: 30),
            actionButtonNub.widthAnchor.constraint(equalToConstant: 4),
            actionButtonNub.heightAnchor.constraint(equalToConstant: 24),

            carouselClip.leadingAnchor.constraint(equalTo: phoneSilhouette.trailingAnchor, constant: 14),
            carouselClip.trailingAnchor.constraint(equalTo: darkScreen.trailingAnchor, constant: -16),
            carouselClip.centerYAnchor.constraint(equalTo: phoneSilhouette.centerYAnchor),
            carouselClip.heightAnchor.constraint(equalToConstant: 96),
            absCarouselStack.centerXAnchor.constraint(equalTo: carouselClip.centerXAnchor),
            absCarouselStack.centerYAnchor.constraint(equalTo: carouselClip.centerYAnchor),

            absChooseRow.topAnchor.constraint(equalTo: phoneSilhouette.bottomAnchor, constant: 16),
            absChooseRow.centerXAnchor.constraint(equalTo: darkScreen.centerXAnchor),
            absChooseRow.heightAnchor.constraint(equalToConstant: 24),
            chooseStack.leadingAnchor.constraint(equalTo: absChooseRow.leadingAnchor, constant: 8),
            chooseStack.trailingAnchor.constraint(equalTo: absChooseRow.trailingAnchor, constant: -8),
            chooseStack.centerYAnchor.constraint(equalTo: absChooseRow.centerYAnchor),
            absRowRipple.leadingAnchor.constraint(equalTo: absChooseRow.leadingAnchor),
            absRowRipple.trailingAnchor.constraint(equalTo: absChooseRow.trailingAnchor),
            absRowRipple.topAnchor.constraint(equalTo: absChooseRow.topAnchor),
            absRowRipple.bottomAnchor.constraint(equalTo: absChooseRow.bottomAnchor),

            absOptionsSheet.leadingAnchor.constraint(equalTo: darkScreen.leadingAnchor),
            absOptionsSheet.trailingAnchor.constraint(equalTo: darkScreen.trailingAnchor),
            absOptionsSheet.bottomAnchor.constraint(equalTo: darkScreen.bottomAnchor),
            absOptionsSheet.heightAnchor.constraint(equalTo: darkScreen.heightAnchor, multiplier: 0.44),
            sheetGrabberView.topAnchor.constraint(equalTo: absOptionsSheet.topAnchor, constant: 8),
            sheetGrabberView.centerXAnchor.constraint(equalTo: absOptionsSheet.centerXAnchor),
            sheetGrabberView.widthAnchor.constraint(equalToConstant: 34),
            sheetGrabberView.heightAnchor.constraint(equalToConstant: 5),
            sheetRows.topAnchor.constraint(equalTo: sheetGrabberView.bottomAnchor, constant: 12),
            sheetRows.leadingAnchor.constraint(equalTo: absOptionsSheet.leadingAnchor, constant: 14),
            sheetRows.trailingAnchor.constraint(equalTo: absOptionsSheet.trailingAnchor, constant: -14),
            absSendHighlight.leadingAnchor.constraint(equalTo: sendRow.leadingAnchor, constant: -4),
            absSendHighlight.trailingAnchor.constraint(equalTo: sendRow.trailingAnchor, constant: 4),
            absSendHighlight.topAnchor.constraint(equalTo: sendRow.topAnchor, constant: -2),
            absSendHighlight.bottomAnchor.constraint(equalTo: sendRow.bottomAnchor, constant: 2),
        ])
    }

    private func animateActionButtonSettings() {
        layoutIfNeeded()
        let sheetDrop = CGAffineTransform(translationX: 0, y: absOptionsSheet.bounds.height + 8)
        let carouselAtPrev = CGAffineTransform(translationX: absCardStep, y: 0)

        func reset() {
            absCarouselStack.transform = carouselAtPrev
            absCardShortcut.transform = CGAffineTransform(scaleX: 0.85, y: 0.85)
            absCardShortcut.alpha = 0.55
            absCardPrev.transform = .identity
            absCardPrev.alpha = 1
            absChooseRow.alpha = 0
            absChooseRow.transform = CGAffineTransform(translationX: 0, y: 6)
            absRowRipple.alpha = 0
            absOptionsSheet.transform = sheetDrop
            absSendHighlight.alpha = 0
            absCheckmark.alpha = 0
        }
        reset()

        UIView.animateKeyframes(withDuration: 7.0, delay: 0.4, options: [.repeat]) {
            // The carousel swipes from the neighboring option to "Shortcut".
            UIView.addKeyframe(withRelativeStartTime: 0.05, relativeDuration: 0.2) {
                self.absCarouselStack.transform = .identity
                self.absCardShortcut.transform = .identity
                self.absCardShortcut.alpha = 1
                self.absCardPrev.transform = CGAffineTransform(scaleX: 0.85, y: 0.85)
                self.absCardPrev.alpha = 0.55
            }
            // "Choose a Shortcut…" fades in below.
            UIView.addKeyframe(withRelativeStartTime: 0.30, relativeDuration: 0.1) {
                self.absChooseRow.alpha = 1
                self.absChooseRow.transform = .identity
            }
            // Tap it.
            UIView.addKeyframe(withRelativeStartTime: 0.44, relativeDuration: 0.05) {
                self.absRowRipple.alpha = 1
            }
            UIView.addKeyframe(withRelativeStartTime: 0.49, relativeDuration: 0.05) {
                self.absRowRipple.alpha = 0
            }
            // The picker sheet slides up.
            UIView.addKeyframe(withRelativeStartTime: 0.52, relativeDuration: 0.16) {
                self.absOptionsSheet.transform = .identity
            }
            // Highlight + confirm "Send To Luna".
            UIView.addKeyframe(withRelativeStartTime: 0.74, relativeDuration: 0.1) {
                self.absSendHighlight.alpha = 1
                self.absCheckmark.alpha = 1
            }
            // Hold, then reset for a seamless loop.
            UIView.addKeyframe(withRelativeStartTime: 0.92, relativeDuration: 0.08) {
                reset()
            }
        }
    }
}

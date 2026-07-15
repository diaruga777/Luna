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

    /// The Luna app identity shown in the miniature system UI. Live onboarding
    /// derives this from the host app by default; the guide-video recorder passes
    /// each case explicitly so every standalone app gets a matching PiP clip.
    public enum AppIcon: CaseIterable {
        case reader
        case downloader
        case priceTracker

        public static var currentBundle: AppIcon {
            let identifier = Bundle.main.bundleIdentifier ?? ""
            if identifier.contains(".downloader") { return .downloader }
            if identifier.contains(".pricetracker") { return .priceTracker }
            return .reader
        }

        fileprivate var assetName: String {
            switch self {
            case .reader: return "AppIconImageReader"
            case .downloader: return "AppIconImageDownloader"
            case .priceTracker: return "AppIconImagePriceTracker"
            }
        }

        /// Stable suffix used by the build-time recorder and the bundled guide
        /// filenames (for example, `SafariExtensionGuideDownloader.mp4`).
        public var guideVideoSuffix: String {
            switch self {
            case .reader: return "Reader"
            case .downloader: return "Downloader"
            case .priceTracker: return "PriceTracker"
            }
        }
    }

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
            case .actionButtonSettings: return 10.5
            }
        }
    }

    private let kind: Kind
    private let appIcon: AppIcon
    private let accent = GlassStyle.lunaBrandAccent
    private var didBuildIllustration = false

    /// True while this view's loop is meant to be animating (set by `start()`, cleared
    /// by `stop()`) — distinct from whether CAAnimations are actually PRESENT, since
    /// UIKit silently strips repeating keyframe animations when the app backgrounds.
    /// Gates the foreground restart below so a view that was never started (e.g. an
    /// off-screen onboarding step preloaded but not yet reached) doesn't spontaneously
    /// start animating just because the app came back to the foreground.
    private var isRunning = false
    private var foregroundObserver: NSObjectProtocol?

    public init(kind: Kind, appIcon: AppIcon = .currentBundle) {
        self.kind = kind
        self.appIcon = appIcon
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
        case .actionButtonSettings: height = 360; width = 220
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
        isRunning = true
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
        isRunning = false
        resetAnimationTree()
    }

    /// `UIView.animateKeyframes(..., options: [.repeat])` loops are removed by UIKit
    /// when the app backgrounds, so simply returning to onboarding shows a frozen
    /// mockup — nothing re-adds the CAAnimations on its own. Restart from scratch
    /// (`start()` resets the animation tree first, so this can't stack loops) whenever
    /// the app becomes active while this view is both in a window and was actually
    /// running before the app backgrounded.
    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            installForegroundObserverIfNeeded()
        } else {
            removeForegroundObserver()
        }
    }

    private func installForegroundObserverIfNeeded() {
        guard foregroundObserver == nil else { return }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.isRunning, self.window != nil else { return }
            self.start()
        }
    }

    private func removeForegroundObserver() {
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
        foregroundObserver = nil
    }

    deinit {
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
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
        // MUST load the plain `AppIconImage<App>` imageset: app icon sets cannot be
        // loaded through `UIImage(named:)`. These imagesets mirror the standard app
        // icons precisely for in-UI use.
        return UIImage(named: appIcon.assetName)
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

    // MARK: - Safari extension (Safari → page menu → Extensions → enable Luna)

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

    private func animateSafariExtension() {
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

    // MARK: - Action Button Settings (Settings > Action Button)

    // This illustration is a deliberately simplified version of the real dark
    // Settings > Action Button screen. It stays fixed-dark so the recorded guide
    // looks consistent in PiP, independent of the host app's appearance.
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

    private func legacyBuildActionButtonSettings() {
        let darkScreen = UIView()
        darkScreen.backgroundColor = UIColor(white: 0.06, alpha: 1)
        darkScreen.layer.cornerRadius = 22
        darkScreen.layer.cornerCurve = .continuous
        darkScreen.clipsToBounds = true
        darkScreen.translatesAutoresizingMaskIntoConstraints = false
        addSubview(darkScreen)

        // Settings-style navigation and instruction copy establish the screen as
        // a Settings page before the compact Action Button carousel appears.
        let settingsBack = UILabel()
        settingsBack.text = "‹ Settings"
        settingsBack.font = .systemFont(ofSize: 11, weight: .medium)
        settingsBack.textColor = UIColor.white.withAlphaComponent(0.68)
        settingsBack.translatesAutoresizingMaskIntoConstraints = false
        darkScreen.addSubview(settingsBack)
        let settingsTitle = UILabel()
        settingsTitle.text = "Action Button"
        settingsTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        settingsTitle.textColor = .white
        settingsTitle.translatesAutoresizingMaskIntoConstraints = false
        darkScreen.addSubview(settingsTitle)
        let settingsInstruction = UILabel()
        settingsInstruction.text = "Swipe to choose an action"
        settingsInstruction.font = .systemFont(ofSize: 11)
        settingsInstruction.textColor = UIColor.white.withAlphaComponent(0.62)
        settingsInstruction.translatesAutoresizingMaskIntoConstraints = false
        darkScreen.addSubview(settingsInstruction)

        // A small side-on iPhone silhouette represents the physical Action Button.
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

        // The carousel: three option cards clipped to a wide viewport, panned so
        // the center one reads as the selected Settings action without truncating
        // the card caption at either edge.
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

        // "Choose a Shortcut…" is the real follow-up row after selecting Shortcut.
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

        // Settings pushes a separate shortcut-picker page. Model it as a full
        // opaque screen that moves in from the right — not as a partially-overlaid
        // sheet — so controls from both pages never occupy the same visual space.
        absOptionsSheet.backgroundColor = UIColor(white: 0.14, alpha: 1)
        absOptionsSheet.clipsToBounds = true
        absOptionsSheet.translatesAutoresizingMaskIntoConstraints = false
        darkScreen.addSubview(absOptionsSheet)
        let pickerBack = UILabel()
        pickerBack.text = "‹ Action Button"
        pickerBack.font = .systemFont(ofSize: 11, weight: .medium)
        pickerBack.textColor = UIColor.white.withAlphaComponent(0.68)
        pickerBack.translatesAutoresizingMaskIntoConstraints = false
        absOptionsSheet.addSubview(pickerBack)
        let pickerTitle = UILabel()
        pickerTitle.text = "Shortcuts"
        pickerTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        pickerTitle.textColor = .white
        pickerTitle.translatesAutoresizingMaskIntoConstraints = false
        absOptionsSheet.addSubview(pickerTitle)

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

            settingsBack.leadingAnchor.constraint(equalTo: darkScreen.leadingAnchor, constant: 14),
            settingsBack.topAnchor.constraint(equalTo: darkScreen.topAnchor, constant: 12),
            settingsTitle.centerXAnchor.constraint(equalTo: darkScreen.centerXAnchor),
            settingsTitle.topAnchor.constraint(equalTo: darkScreen.topAnchor, constant: 12),
            settingsInstruction.centerXAnchor.constraint(equalTo: darkScreen.centerXAnchor),
            settingsInstruction.topAnchor.constraint(equalTo: settingsTitle.bottomAnchor, constant: 6),

            phoneSilhouette.centerXAnchor.constraint(equalTo: darkScreen.centerXAnchor),
            phoneSilhouette.topAnchor.constraint(equalTo: settingsInstruction.bottomAnchor, constant: 8),
            phoneSilhouette.widthAnchor.constraint(equalToConstant: 34),
            phoneSilhouette.heightAnchor.constraint(equalToConstant: 52),
            actionButtonNub.trailingAnchor.constraint(equalTo: phoneSilhouette.leadingAnchor, constant: 2),
            actionButtonNub.centerYAnchor.constraint(equalTo: phoneSilhouette.topAnchor, constant: 17),
            actionButtonNub.widthAnchor.constraint(equalToConstant: 4),
            actionButtonNub.heightAnchor.constraint(equalToConstant: 16),

            carouselClip.topAnchor.constraint(equalTo: phoneSilhouette.bottomAnchor, constant: 8),
            carouselClip.leadingAnchor.constraint(equalTo: darkScreen.leadingAnchor, constant: 16),
            carouselClip.trailingAnchor.constraint(equalTo: darkScreen.trailingAnchor, constant: -16),
            carouselClip.heightAnchor.constraint(equalToConstant: 96),
            absCarouselStack.centerXAnchor.constraint(equalTo: carouselClip.centerXAnchor),
            absCarouselStack.centerYAnchor.constraint(equalTo: carouselClip.centerYAnchor),

            absChooseRow.topAnchor.constraint(equalTo: carouselClip.bottomAnchor, constant: 8),
            absChooseRow.leadingAnchor.constraint(equalTo: darkScreen.leadingAnchor, constant: 20),
            absChooseRow.trailingAnchor.constraint(equalTo: darkScreen.trailingAnchor, constant: -20),
            absChooseRow.heightAnchor.constraint(equalToConstant: 28),
            chooseStack.leadingAnchor.constraint(equalTo: absChooseRow.leadingAnchor, constant: 8),
            chooseStack.trailingAnchor.constraint(equalTo: absChooseRow.trailingAnchor, constant: -8),
            chooseStack.centerYAnchor.constraint(equalTo: absChooseRow.centerYAnchor),
            absRowRipple.leadingAnchor.constraint(equalTo: absChooseRow.leadingAnchor),
            absRowRipple.trailingAnchor.constraint(equalTo: absChooseRow.trailingAnchor),
            absRowRipple.topAnchor.constraint(equalTo: absChooseRow.topAnchor),
            absRowRipple.bottomAnchor.constraint(equalTo: absChooseRow.bottomAnchor),

            absOptionsSheet.leadingAnchor.constraint(equalTo: darkScreen.leadingAnchor),
            absOptionsSheet.trailingAnchor.constraint(equalTo: darkScreen.trailingAnchor),
            absOptionsSheet.topAnchor.constraint(equalTo: darkScreen.topAnchor),
            absOptionsSheet.bottomAnchor.constraint(equalTo: darkScreen.bottomAnchor),
            pickerBack.leadingAnchor.constraint(equalTo: absOptionsSheet.leadingAnchor, constant: 14),
            pickerBack.topAnchor.constraint(equalTo: absOptionsSheet.topAnchor, constant: 12),
            pickerTitle.centerXAnchor.constraint(equalTo: absOptionsSheet.centerXAnchor),
            pickerTitle.topAnchor.constraint(equalTo: absOptionsSheet.topAnchor, constant: 12),
            sheetRows.topAnchor.constraint(equalTo: pickerTitle.bottomAnchor, constant: 28),
            sheetRows.leadingAnchor.constraint(equalTo: absOptionsSheet.leadingAnchor, constant: 14),
            sheetRows.trailingAnchor.constraint(equalTo: absOptionsSheet.trailingAnchor, constant: -14),
            absSendHighlight.leadingAnchor.constraint(equalTo: sendRow.leadingAnchor, constant: -4),
            absSendHighlight.trailingAnchor.constraint(equalTo: sendRow.trailingAnchor, constant: 4),
            absSendHighlight.topAnchor.constraint(equalTo: sendRow.topAnchor, constant: -2),
            absSendHighlight.bottomAnchor.constraint(equalTo: sendRow.bottomAnchor, constant: 2),
        ])
    }

    private func legacyAnimateActionButtonSettings() {
        layoutIfNeeded()
        let pickerOffscreen = CGAffineTransform(
            translationX: absOptionsSheet.bounds.width + 8, y: 0)
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
            absOptionsSheet.transform = pickerOffscreen
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
            // Push to the dedicated shortcut-picker page after the tap feedback has
            // finished. The opaque page enters beside — never over — the Settings
            // controls, matching a simplified Settings navigation transition.
            UIView.addKeyframe(withRelativeStartTime: 0.56, relativeDuration: 0.16) {
                self.absOptionsSheet.transform = .identity
            }
            // Highlight + confirm "Send To Luna".
            UIView.addKeyframe(withRelativeStartTime: 0.78, relativeDuration: 0.10) {
                self.absSendHighlight.alpha = 1
                self.absCheckmark.alpha = 1
            }
            // Navigate back offscreen before the next loop, rather than snapping a
            // visible picker over the original Settings controls.
            UIView.addKeyframe(withRelativeStartTime: 0.94, relativeDuration: 0.06) {
                self.absOptionsSheet.transform = pickerOffscreen
                self.absSendHighlight.alpha = 0
                self.absCheckmark.alpha = 0
                self.absCarouselStack.transform = carouselAtPrev
                self.absCardShortcut.transform = CGAffineTransform(scaleX: 0.85, y: 0.85)
                self.absCardShortcut.alpha = 0.55
                self.absCardPrev.transform = .identity
                self.absCardPrev.alpha = 1
                self.absChooseRow.alpha = 0
                self.absChooseRow.transform = CGAffineTransform(translationX: 0, y: 6)
            }
        }
    }

    // MARK: - Current Action Button guide (accurate Settings → Safari sequence)

    private let abSettingsScreen = UIView()
    private let abRootSettingsScreen = UIView()
    private let abActionButtonRowHighlight = UIView()
    private let abSafariScreen = UIView()
    private let abActionCapsule = UIView()
    // The carousel is two horizontally-sliding glyph strips sharing one set of
    // slot positions: a dim strip on the Settings screen and a white copy inside
    // the clipping capsule. Panning both one slot moves each glyph between the
    // side positions and the capsule window, exactly like the real screen.
    private let abOuterGlyphStrip = UIView()
    private let abInnerGlyphStrip = UIView()
    private let abCarouselStep: CGFloat = 64
    private let abDotControls = UIView()
    private let abDotShortcut = UIView()
    private let abControlsTitle = UILabel()
    private let abControlsSubtitle = UILabel()
    private let abShortcutTitle = UILabel()
    private let abShortcutSubtitle = UILabel()
    private let abChooseButton = UIView()
    private let abLunaChoice = UIView()
    private let abHardwareButton = UIView()
    private let abPressRipple = UIView()
    private let abIsland = UIView()
    private let abIslandIcon = UIImageView()
    private let abIslandCheck = UIImageView(image: UIImage(
        systemName: "checkmark.circle.fill",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)))
    private var abIslandWidth: NSLayoutConstraint!
    private var abIslandHeight: NSLayoutConstraint!

    /// One carousel glyph at the Action Button screen's standard symbol size.
    private func abCarouselGlyph(_ symbol: String, tint: UIColor) -> UIImageView {
        let glyph = UIImageView(image: UIImage(
            systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)))
        glyph.tintColor = tint
        glyph.translatesAutoresizingMaskIntoConstraints = false
        return glyph
    }

    /// Recreates the current full-height Action Button Settings presentation from
    /// the device references: circular back button, tall titanium phone, large
    /// illuminated hardware control, neighboring action glyphs, page dots, and the
    /// selected shortcut. The second page is Safari so the guide demonstrates the
    /// complete job rather than ending as soon as Settings is configured.
    private func buildActionButtonSettings() {
        let phone = UIView()
        phone.backgroundColor = .systemGray4
        phone.layer.borderColor = UIColor.systemGray3.cgColor
        phone.layer.borderWidth = 3
        phone.layer.cornerRadius = 30
        phone.layer.cornerCurve = .continuous
        phone.clipsToBounds = true
        phone.translatesAutoresizingMaskIntoConstraints = false
        addSubview(phone)

        abSettingsScreen.backgroundColor = .systemBackground
        abSettingsScreen.translatesAutoresizingMaskIntoConstraints = false
        phone.addSubview(abSettingsScreen)

        let time = UILabel()
        time.text = "9:41"
        time.font = .systemFont(ofSize: 8, weight: .semibold)
        time.translatesAutoresizingMaskIntoConstraints = false
        abSettingsScreen.addSubview(time)
        let statusIsland = UIView()
        statusIsland.backgroundColor = .black
        statusIsland.layer.cornerRadius = 6
        statusIsland.translatesAutoresizingMaskIntoConstraints = false
        abSettingsScreen.addSubview(statusIsland)
        let status = UIImageView(image: UIImage(
            systemName: "wifi", withConfiguration: UIImage.SymbolConfiguration(pointSize: 7, weight: .bold)))
        status.tintColor = .label
        status.translatesAutoresizingMaskIntoConstraints = false
        abSettingsScreen.addSubview(status)

        let backCircle = UIView()
        backCircle.backgroundColor = .tertiarySystemFill
        backCircle.layer.cornerRadius = 13
        backCircle.translatesAutoresizingMaskIntoConstraints = false
        abSettingsScreen.addSubview(backCircle)
        let backChevron = UIImageView(image: UIImage(
            systemName: "chevron.left", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)))
        backChevron.tintColor = .label
        backChevron.translatesAutoresizingMaskIntoConstraints = false
        backCircle.addSubview(backChevron)

        let device = UIView()
        device.backgroundColor = .secondarySystemBackground
        device.layer.cornerRadius = 42
        device.layer.cornerCurve = .continuous
        device.layer.borderColor = UIColor.separator.cgColor
        device.layer.borderWidth = 1
        device.translatesAutoresizingMaskIntoConstraints = false
        abSettingsScreen.addSubview(device)
        let deviceGlow = UIView()
        deviceGlow.backgroundColor = UIColor.systemGray.withAlphaComponent(0.22)
        deviceGlow.layer.cornerRadius = 32
        deviceGlow.translatesAutoresizingMaskIntoConstraints = false
        device.addSubview(deviceGlow)

        // Slots left→right: the previous action, Controls (starts in the capsule
        // window), Shortcut, then Accessibility waiting one slot further out.
        let carouselSymbols = ["flashlight.on.fill", "switch.2", "square.stack.3d.up.fill", "accessibility"]
        abOuterGlyphStrip.translatesAutoresizingMaskIntoConstraints = false
        abSettingsScreen.addSubview(abOuterGlyphStrip)

        // The capsule is a sibling of (not inside) `device` so it stacks above the
        // dim strip; fully opaque so that strip never ghosts through, and clipping
        // so the white strip only shows through the capsule window.
        abActionCapsule.backgroundColor = accent
        abActionCapsule.layer.cornerRadius = 25
        abActionCapsule.layer.cornerCurve = .continuous
        abActionCapsule.layer.borderColor = accent.withAlphaComponent(0.65).cgColor
        abActionCapsule.layer.borderWidth = 3
        abActionCapsule.clipsToBounds = true
        abActionCapsule.translatesAutoresizingMaskIntoConstraints = false
        abSettingsScreen.addSubview(abActionCapsule)
        abInnerGlyphStrip.translatesAutoresizingMaskIntoConstraints = false
        abActionCapsule.addSubview(abInnerGlyphStrip)

        var glyphConstraints: [NSLayoutConstraint] = []
        for (index, symbol) in carouselSymbols.enumerated() {
            let offset = CGFloat(index - 1) * abCarouselStep
            let outer = abCarouselGlyph(symbol, tint: .tertiaryLabel)
            abOuterGlyphStrip.addSubview(outer)
            let inner = abCarouselGlyph(symbol, tint: .white)
            abInnerGlyphStrip.addSubview(inner)
            glyphConstraints += [
                outer.centerXAnchor.constraint(equalTo: abOuterGlyphStrip.centerXAnchor, constant: offset),
                outer.centerYAnchor.constraint(equalTo: abOuterGlyphStrip.centerYAnchor),
                inner.centerXAnchor.constraint(equalTo: abInnerGlyphStrip.centerXAnchor, constant: offset),
                inner.centerYAnchor.constraint(equalTo: abInnerGlyphStrip.centerYAnchor),
            ]
        }
        NSLayoutConstraint.activate(glyphConstraints)

        let dots = UIStackView()
        dots.axis = .horizontal
        dots.spacing = 5
        dots.translatesAutoresizingMaskIntoConstraints = false
        for index in 0..<10 {
            let dot: UIView
            switch index {
            case 7: dot = abDotControls
            case 8: dot = abDotShortcut
            default: dot = UIView()
            }
            dot.backgroundColor = index == 7 ? .label : .tertiaryLabel
            dot.layer.cornerRadius = 2.5
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 5).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 5).isActive = true
            dots.addArrangedSubview(dot)
        }
        abSettingsScreen.addSubview(dots)

        // Titles and subtitles come as per-page pairs crossfaded by alpha: setting
        // `.text` inside a keyframe block applies immediately at setup (text is
        // not animatable), so a single mutated label never visibly changes pages.
        func configurePageTitle(_ label: UILabel, _ text: String) {
            label.text = text
            label.font = .systemFont(ofSize: 19, weight: .bold)
            label.textAlignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            abSettingsScreen.addSubview(label)
        }
        func configurePageSubtitle(_ label: UILabel, _ text: String) {
            label.text = text
            label.font = .systemFont(ofSize: 9)
            label.textColor = .secondaryLabel
            label.textAlignment = .center
            label.numberOfLines = 2
            label.translatesAutoresizingMaskIntoConstraints = false
            abSettingsScreen.addSubview(label)
        }
        configurePageTitle(abControlsTitle, "Controls")
        configurePageSubtitle(abControlsSubtitle, "Quickly access your favorite Control.")
        configurePageTitle(abShortcutTitle, "Shortcut")
        configurePageSubtitle(abShortcutSubtitle, "Open an app or run your\nfavorite shortcut.")

        // The choose button belongs to the Shortcut page only; it fades in after
        // the carousel lands there, so its label never needs to change.
        abChooseButton.backgroundColor = .systemBlue
        abChooseButton.layer.cornerRadius = 12
        abChooseButton.translatesAutoresizingMaskIntoConstraints = false
        abSettingsScreen.addSubview(abChooseButton)
        let abChooseLabel = UILabel()
        abChooseLabel.text = "Choose a Shortcut…"
        abChooseLabel.textColor = .white
        abChooseLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        abChooseLabel.translatesAutoresizingMaskIntoConstraints = false
        abChooseButton.addSubview(abChooseLabel)

        abLunaChoice.backgroundColor = .tertiarySystemFill
        abLunaChoice.layer.cornerRadius = 12
        abLunaChoice.translatesAutoresizingMaskIntoConstraints = false
        abSettingsScreen.addSubview(abLunaChoice)
        let lunaIcon = UIImageView(image: lunaAppIconImage())
        lunaIcon.layer.cornerRadius = 4
        lunaIcon.clipsToBounds = true
        lunaIcon.translatesAutoresizingMaskIntoConstraints = false
        let lunaName = UILabel()
        lunaName.text = "Send To Luna"
        lunaName.font = .systemFont(ofSize: 10, weight: .semibold)
        let lunaStack = UIStackView(arrangedSubviews: [lunaIcon, lunaName])
        lunaStack.spacing = 6
        lunaStack.alignment = .center
        lunaStack.translatesAutoresizingMaskIntoConstraints = false
        abLunaChoice.addSubview(lunaStack)

        // Root Settings page shown first, matching the real navigation path. It
        // pushes left after a visible tap on Action Button.
        abRootSettingsScreen.backgroundColor = .systemGroupedBackground
        abRootSettingsScreen.translatesAutoresizingMaskIntoConstraints = false
        phone.addSubview(abRootSettingsScreen)
        let rootTime = UILabel()
        rootTime.text = "9:41"
        rootTime.font = .systemFont(ofSize: 8, weight: .semibold)
        rootTime.translatesAutoresizingMaskIntoConstraints = false
        abRootSettingsScreen.addSubview(rootTime)
        let rootIsland = UIView()
        rootIsland.backgroundColor = .black
        rootIsland.layer.cornerRadius = 6
        rootIsland.translatesAutoresizingMaskIntoConstraints = false
        abRootSettingsScreen.addSubview(rootIsland)
        let rootStatus = UIImageView(image: UIImage(
            systemName: "wifi", withConfiguration: UIImage.SymbolConfiguration(pointSize: 7, weight: .bold)))
        rootStatus.tintColor = .label
        rootStatus.translatesAutoresizingMaskIntoConstraints = false
        abRootSettingsScreen.addSubview(rootStatus)
        let rootTitle = UILabel()
        rootTitle.text = "Settings"
        rootTitle.font = .systemFont(ofSize: 17, weight: .bold)
        rootTitle.textAlignment = .center
        rootTitle.translatesAutoresizingMaskIntoConstraints = false
        abRootSettingsScreen.addSubview(rootTitle)

        func rootRow(symbol: String, title: String, color: UIColor) -> UIView {
            let row = UIView()
            row.translatesAutoresizingMaskIntoConstraints = false
            row.heightAnchor.constraint(equalToConstant: 29).isActive = true
            let tile = UIView()
            tile.backgroundColor = color
            tile.layer.cornerRadius = 5
            tile.translatesAutoresizingMaskIntoConstraints = false
            let icon = UIImageView(image: UIImage(
                systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)))
            icon.tintColor = .white
            icon.translatesAutoresizingMaskIntoConstraints = false
            tile.addSubview(icon)
            let label = UILabel()
            label.text = title
            label.font = .systemFont(ofSize: 11)
            label.translatesAutoresizingMaskIntoConstraints = false
            let chevron = UIImageView(image: UIImage(
                systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 8, weight: .semibold)))
            chevron.tintColor = .tertiaryLabel
            chevron.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(tile)
            row.addSubview(label)
            row.addSubview(chevron)
            let divider = UIView()
            divider.backgroundColor = .separator
            divider.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(divider)
            NSLayoutConstraint.activate([
                tile.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 8), tile.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                tile.widthAnchor.constraint(equalToConstant: 20), tile.heightAnchor.constraint(equalToConstant: 20),
                icon.centerXAnchor.constraint(equalTo: tile.centerXAnchor), icon.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
                label.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 8), label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                chevron.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -8), chevron.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                divider.leadingAnchor.constraint(equalTo: label.leadingAnchor), divider.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                divider.bottomAnchor.constraint(equalTo: row.bottomAnchor), divider.heightAnchor.constraint(equalToConstant: 0.5),
            ])
            return row
        }

        let connectivityGroup = UIView()
        connectivityGroup.backgroundColor = .secondarySystemGroupedBackground
        connectivityGroup.layer.cornerRadius = 12
        connectivityGroup.clipsToBounds = true
        connectivityGroup.translatesAutoresizingMaskIntoConstraints = false
        abRootSettingsScreen.addSubview(connectivityGroup)
        let connectivityRows = UIStackView(arrangedSubviews: [
            // Wi-Fi, not Bluetooth: SF Symbols has no Bluetooth rune, and every
            // bolt stand-in reads as the Messenger logo at this size.
            rootRow(symbol: "wifi", title: "Wi-Fi", color: .systemBlue),
            rootRow(symbol: "antenna.radiowaves.left.and.right", title: "Cellular", color: .systemGreen),
            rootRow(symbol: "battery.100percent", title: "Battery", color: .systemGreen),
        ])
        connectivityRows.axis = .vertical
        connectivityRows.translatesAutoresizingMaskIntoConstraints = false
        connectivityGroup.addSubview(connectivityRows)

        let systemGroup = UIView()
        systemGroup.backgroundColor = .secondarySystemGroupedBackground
        systemGroup.layer.cornerRadius = 12
        systemGroup.clipsToBounds = true
        systemGroup.translatesAutoresizingMaskIntoConstraints = false
        abRootSettingsScreen.addSubview(systemGroup)
        let generalRow = rootRow(symbol: "gear", title: "General", color: .systemGray)
        let accessibilityRow = rootRow(symbol: "accessibility", title: "Accessibility", color: .systemBlue)
        let actionButtonRow = rootRow(symbol: "button.horizontal.top.press", title: "Action Button", color: .systemBlue)
        let appearanceRow = rootRow(symbol: "circle.lefthalf.filled", title: "Appearance", color: .black)
        let systemRows = UIStackView(arrangedSubviews: [generalRow, accessibilityRow, actionButtonRow, appearanceRow])
        systemRows.axis = .vertical
        systemRows.translatesAutoresizingMaskIntoConstraints = false
        systemGroup.addSubview(systemRows)
        abActionButtonRowHighlight.backgroundColor = .systemGray.withAlphaComponent(0.28)
        abActionButtonRowHighlight.layer.cornerRadius = 6
        abActionButtonRowHighlight.alpha = 0
        abActionButtonRowHighlight.translatesAutoresizingMaskIntoConstraints = false
        systemGroup.insertSubview(abActionButtonRowHighlight, belowSubview: systemRows)

        // Safari page used after setup: gray-box website, correct bottom safe-area
        // order, physical-button feedback, and a Dynamic Island save confirmation.
        abSafariScreen.backgroundColor = .secondarySystemBackground
        abSafariScreen.translatesAutoresizingMaskIntoConstraints = false
        phone.addSubview(abSafariScreen)
        let webLines = UIStackView(arrangedSubviews: [
            bar(width: 0.72, height: 10, color: .label.withAlphaComponent(0.65)),
            bar(width: 0.94, height: 5), bar(width: 0.86, height: 5),
            bar(width: 0.91, height: 5), bar(width: 0.64, height: 5),
        ])
        webLines.axis = .vertical
        webLines.spacing = 8
        webLines.alignment = .fill
        webLines.setCustomSpacing(15, after: webLines.arrangedSubviews[0])
        webLines.translatesAutoresizingMaskIntoConstraints = false
        abSafariScreen.addSubview(webLines)
        let safariChrome = UIView()
        safariChrome.backgroundColor = .systemBackground
        safariChrome.translatesAutoresizingMaskIntoConstraints = false
        abSafariScreen.addSubview(safariChrome)
        let urlPill = UIView()
        urlPill.backgroundColor = .secondarySystemBackground
        urlPill.layer.cornerRadius = 10
        urlPill.translatesAutoresizingMaskIntoConstraints = false
        safariChrome.addSubview(urlPill)
        let urlText = UILabel()
        urlText.text = "example.com"
        urlText.font = .systemFont(ofSize: 8, weight: .medium)
        urlText.textColor = .secondaryLabel
        urlText.translatesAutoresizingMaskIntoConstraints = false
        urlPill.addSubview(urlText)
        let chromeIcons = UIStackView(arrangedSubviews: [toolbarIcon("chevron.left"), toolbarIcon("chevron.right"),
                                                          toolbarIcon("square.and.arrow.up"), toolbarIcon("square.on.square")])
        chromeIcons.axis = .horizontal
        chromeIcons.distribution = .equalSpacing
        chromeIcons.translatesAutoresizingMaskIntoConstraints = false
        safariChrome.addSubview(chromeIcons)
        let home = UIView()
        home.backgroundColor = .label
        home.layer.cornerRadius = 1.5
        home.translatesAutoresizingMaskIntoConstraints = false
        safariChrome.addSubview(home)
        abHardwareButton.backgroundColor = .systemGray
        abHardwareButton.layer.cornerRadius = 2
        abHardwareButton.translatesAutoresizingMaskIntoConstraints = false
        abSafariScreen.addSubview(abHardwareButton)
        abPressRipple.backgroundColor = accent.withAlphaComponent(0.38)
        abPressRipple.layer.cornerRadius = 22
        abPressRipple.translatesAutoresizingMaskIntoConstraints = false
        abSafariScreen.addSubview(abPressRipple)

        abIsland.backgroundColor = .black
        abIsland.layer.cornerRadius = 6
        abIsland.translatesAutoresizingMaskIntoConstraints = false
        abSafariScreen.addSubview(abIsland)
        abIslandIcon.image = lunaAppIconImage()
        abIslandIcon.contentMode = .scaleAspectFit
        abIslandIcon.layer.cornerRadius = 3
        abIslandIcon.clipsToBounds = true
        abIslandIcon.translatesAutoresizingMaskIntoConstraints = false
        abIsland.addSubview(abIslandIcon)
        abIslandCheck.tintColor = .systemGreen
        abIslandCheck.contentMode = .scaleAspectFit
        abIslandCheck.translatesAutoresizingMaskIntoConstraints = false
        abIsland.addSubview(abIslandCheck)
        abIslandWidth = abIsland.widthAnchor.constraint(equalToConstant: 34)
        abIslandHeight = abIsland.heightAnchor.constraint(equalToConstant: 12)

        NSLayoutConstraint.activate([
            phone.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            phone.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            phone.centerXAnchor.constraint(equalTo: centerXAnchor),
            phone.widthAnchor.constraint(equalTo: phone.heightAnchor, multiplier: 0.49),
            abSettingsScreen.leadingAnchor.constraint(equalTo: phone.leadingAnchor),
            abSettingsScreen.trailingAnchor.constraint(equalTo: phone.trailingAnchor),
            abSettingsScreen.topAnchor.constraint(equalTo: phone.topAnchor),
            abSettingsScreen.bottomAnchor.constraint(equalTo: phone.bottomAnchor),
            time.leadingAnchor.constraint(equalTo: abSettingsScreen.leadingAnchor, constant: 14),
            time.topAnchor.constraint(equalTo: abSettingsScreen.topAnchor, constant: 10),
            statusIsland.centerXAnchor.constraint(equalTo: abSettingsScreen.centerXAnchor),
            statusIsland.topAnchor.constraint(equalTo: abSettingsScreen.topAnchor, constant: 8),
            statusIsland.widthAnchor.constraint(equalToConstant: 46), statusIsland.heightAnchor.constraint(equalToConstant: 13),
            status.trailingAnchor.constraint(equalTo: abSettingsScreen.trailingAnchor, constant: -14),
            status.centerYAnchor.constraint(equalTo: time.centerYAnchor),
            backCircle.leadingAnchor.constraint(equalTo: abSettingsScreen.leadingAnchor, constant: 10),
            backCircle.topAnchor.constraint(equalTo: abSettingsScreen.topAnchor, constant: 34),
            backCircle.widthAnchor.constraint(equalToConstant: 26), backCircle.heightAnchor.constraint(equalToConstant: 26),
            backChevron.centerXAnchor.constraint(equalTo: backCircle.centerXAnchor), backChevron.centerYAnchor.constraint(equalTo: backCircle.centerYAnchor),
            device.centerXAnchor.constraint(equalTo: abSettingsScreen.centerXAnchor),
            device.topAnchor.constraint(equalTo: abSettingsScreen.topAnchor, constant: 70),
            device.widthAnchor.constraint(equalToConstant: 80), device.heightAnchor.constraint(equalToConstant: 134),
            deviceGlow.centerXAnchor.constraint(equalTo: device.centerXAnchor), deviceGlow.centerYAnchor.constraint(equalTo: device.centerYAnchor),
            deviceGlow.widthAnchor.constraint(equalToConstant: 66), deviceGlow.heightAnchor.constraint(equalToConstant: 120),
            abActionCapsule.centerXAnchor.constraint(equalTo: device.centerXAnchor), abActionCapsule.centerYAnchor.constraint(equalTo: device.centerYAnchor),
            abActionCapsule.widthAnchor.constraint(equalToConstant: 48), abActionCapsule.heightAnchor.constraint(equalToConstant: 76),
            abOuterGlyphStrip.centerXAnchor.constraint(equalTo: abActionCapsule.centerXAnchor),
            abOuterGlyphStrip.centerYAnchor.constraint(equalTo: abActionCapsule.centerYAnchor),
            abOuterGlyphStrip.widthAnchor.constraint(equalToConstant: 0), abOuterGlyphStrip.heightAnchor.constraint(equalToConstant: 0),
            abInnerGlyphStrip.centerXAnchor.constraint(equalTo: abActionCapsule.centerXAnchor),
            abInnerGlyphStrip.centerYAnchor.constraint(equalTo: abActionCapsule.centerYAnchor),
            abInnerGlyphStrip.widthAnchor.constraint(equalToConstant: 0), abInnerGlyphStrip.heightAnchor.constraint(equalToConstant: 0),
            dots.centerXAnchor.constraint(equalTo: abSettingsScreen.centerXAnchor), dots.topAnchor.constraint(equalTo: device.bottomAnchor, constant: 9),
            abControlsTitle.centerXAnchor.constraint(equalTo: abSettingsScreen.centerXAnchor), abControlsTitle.topAnchor.constraint(equalTo: dots.bottomAnchor, constant: 9),
            abShortcutTitle.centerXAnchor.constraint(equalTo: abSettingsScreen.centerXAnchor), abShortcutTitle.topAnchor.constraint(equalTo: dots.bottomAnchor, constant: 9),
            abControlsSubtitle.centerXAnchor.constraint(equalTo: abSettingsScreen.centerXAnchor), abControlsSubtitle.topAnchor.constraint(equalTo: abControlsTitle.bottomAnchor, constant: 4),
            abControlsSubtitle.leadingAnchor.constraint(greaterThanOrEqualTo: abSettingsScreen.leadingAnchor, constant: 10),
            abControlsSubtitle.trailingAnchor.constraint(lessThanOrEqualTo: abSettingsScreen.trailingAnchor, constant: -10),
            abShortcutSubtitle.centerXAnchor.constraint(equalTo: abSettingsScreen.centerXAnchor), abShortcutSubtitle.topAnchor.constraint(equalTo: abControlsTitle.bottomAnchor, constant: 4),
            abShortcutSubtitle.leadingAnchor.constraint(greaterThanOrEqualTo: abSettingsScreen.leadingAnchor, constant: 10),
            abShortcutSubtitle.trailingAnchor.constraint(lessThanOrEqualTo: abSettingsScreen.trailingAnchor, constant: -10),
            abChooseButton.centerXAnchor.constraint(equalTo: abSettingsScreen.centerXAnchor), abChooseButton.topAnchor.constraint(equalTo: abShortcutSubtitle.bottomAnchor, constant: 9),
            abChooseButton.widthAnchor.constraint(equalToConstant: 112), abChooseButton.heightAnchor.constraint(equalToConstant: 26),
            abChooseLabel.centerXAnchor.constraint(equalTo: abChooseButton.centerXAnchor), abChooseLabel.centerYAnchor.constraint(equalTo: abChooseButton.centerYAnchor),
            abLunaChoice.centerXAnchor.constraint(equalTo: abChooseButton.centerXAnchor), abLunaChoice.centerYAnchor.constraint(equalTo: abChooseButton.centerYAnchor),
            abLunaChoice.widthAnchor.constraint(equalTo: abChooseButton.widthAnchor), abLunaChoice.heightAnchor.constraint(equalTo: abChooseButton.heightAnchor),
            lunaStack.centerXAnchor.constraint(equalTo: abLunaChoice.centerXAnchor), lunaStack.centerYAnchor.constraint(equalTo: abLunaChoice.centerYAnchor),
            lunaIcon.widthAnchor.constraint(equalToConstant: 18), lunaIcon.heightAnchor.constraint(equalToConstant: 18),

            abRootSettingsScreen.leadingAnchor.constraint(equalTo: phone.leadingAnchor), abRootSettingsScreen.trailingAnchor.constraint(equalTo: phone.trailingAnchor),
            abRootSettingsScreen.topAnchor.constraint(equalTo: phone.topAnchor), abRootSettingsScreen.bottomAnchor.constraint(equalTo: phone.bottomAnchor),
            rootTime.leadingAnchor.constraint(equalTo: abRootSettingsScreen.leadingAnchor, constant: 14), rootTime.topAnchor.constraint(equalTo: abRootSettingsScreen.topAnchor, constant: 10),
            rootIsland.centerXAnchor.constraint(equalTo: abRootSettingsScreen.centerXAnchor), rootIsland.topAnchor.constraint(equalTo: abRootSettingsScreen.topAnchor, constant: 8),
            rootIsland.widthAnchor.constraint(equalToConstant: 46), rootIsland.heightAnchor.constraint(equalToConstant: 13),
            rootStatus.trailingAnchor.constraint(equalTo: abRootSettingsScreen.trailingAnchor, constant: -14), rootStatus.centerYAnchor.constraint(equalTo: rootTime.centerYAnchor),
            rootTitle.centerXAnchor.constraint(equalTo: abRootSettingsScreen.centerXAnchor), rootTitle.topAnchor.constraint(equalTo: abRootSettingsScreen.topAnchor, constant: 34),
            connectivityGroup.topAnchor.constraint(equalTo: rootTitle.bottomAnchor, constant: 12),
            connectivityGroup.leadingAnchor.constraint(equalTo: abRootSettingsScreen.leadingAnchor, constant: 10),
            connectivityGroup.trailingAnchor.constraint(equalTo: abRootSettingsScreen.trailingAnchor, constant: -10),
            connectivityRows.leadingAnchor.constraint(equalTo: connectivityGroup.leadingAnchor), connectivityRows.trailingAnchor.constraint(equalTo: connectivityGroup.trailingAnchor),
            connectivityRows.topAnchor.constraint(equalTo: connectivityGroup.topAnchor), connectivityRows.bottomAnchor.constraint(equalTo: connectivityGroup.bottomAnchor),
            systemGroup.topAnchor.constraint(equalTo: connectivityGroup.bottomAnchor, constant: 12),
            systemGroup.leadingAnchor.constraint(equalTo: connectivityGroup.leadingAnchor), systemGroup.trailingAnchor.constraint(equalTo: connectivityGroup.trailingAnchor),
            systemRows.leadingAnchor.constraint(equalTo: systemGroup.leadingAnchor), systemRows.trailingAnchor.constraint(equalTo: systemGroup.trailingAnchor),
            systemRows.topAnchor.constraint(equalTo: systemGroup.topAnchor), systemRows.bottomAnchor.constraint(equalTo: systemGroup.bottomAnchor),
            abActionButtonRowHighlight.leadingAnchor.constraint(equalTo: actionButtonRow.leadingAnchor, constant: 3),
            abActionButtonRowHighlight.trailingAnchor.constraint(equalTo: actionButtonRow.trailingAnchor, constant: -3),
            abActionButtonRowHighlight.topAnchor.constraint(equalTo: actionButtonRow.topAnchor, constant: 2),
            abActionButtonRowHighlight.bottomAnchor.constraint(equalTo: actionButtonRow.bottomAnchor, constant: -2),

            abSafariScreen.leadingAnchor.constraint(equalTo: phone.leadingAnchor), abSafariScreen.trailingAnchor.constraint(equalTo: phone.trailingAnchor),
            abSafariScreen.topAnchor.constraint(equalTo: phone.topAnchor), abSafariScreen.bottomAnchor.constraint(equalTo: phone.bottomAnchor),
            webLines.topAnchor.constraint(equalTo: abSafariScreen.topAnchor, constant: 48),
            webLines.leadingAnchor.constraint(equalTo: abSafariScreen.leadingAnchor, constant: 14), webLines.trailingAnchor.constraint(equalTo: abSafariScreen.trailingAnchor, constant: -14),
            safariChrome.leadingAnchor.constraint(equalTo: abSafariScreen.leadingAnchor), safariChrome.trailingAnchor.constraint(equalTo: abSafariScreen.trailingAnchor),
            safariChrome.bottomAnchor.constraint(equalTo: abSafariScreen.bottomAnchor), safariChrome.heightAnchor.constraint(equalToConstant: 72),
            urlPill.topAnchor.constraint(equalTo: safariChrome.topAnchor, constant: 5), urlPill.leadingAnchor.constraint(equalTo: safariChrome.leadingAnchor, constant: 12),
            urlPill.trailingAnchor.constraint(equalTo: safariChrome.trailingAnchor, constant: -12), urlPill.heightAnchor.constraint(equalToConstant: 22),
            urlText.centerXAnchor.constraint(equalTo: urlPill.centerXAnchor), urlText.centerYAnchor.constraint(equalTo: urlPill.centerYAnchor),
            chromeIcons.topAnchor.constraint(equalTo: urlPill.bottomAnchor, constant: 7), chromeIcons.leadingAnchor.constraint(equalTo: safariChrome.leadingAnchor, constant: 18),
            chromeIcons.trailingAnchor.constraint(equalTo: safariChrome.trailingAnchor, constant: -18), chromeIcons.heightAnchor.constraint(equalToConstant: 16),
            home.centerXAnchor.constraint(equalTo: safariChrome.centerXAnchor), home.bottomAnchor.constraint(equalTo: safariChrome.bottomAnchor, constant: -5),
            home.widthAnchor.constraint(equalToConstant: 56), home.heightAnchor.constraint(equalToConstant: 3),
            abHardwareButton.leadingAnchor.constraint(equalTo: abSafariScreen.leadingAnchor, constant: -1), abHardwareButton.topAnchor.constraint(equalTo: abSafariScreen.topAnchor, constant: 72),
            abHardwareButton.widthAnchor.constraint(equalToConstant: 5), abHardwareButton.heightAnchor.constraint(equalToConstant: 30),
            abPressRipple.centerXAnchor.constraint(equalTo: abHardwareButton.centerXAnchor), abPressRipple.centerYAnchor.constraint(equalTo: abHardwareButton.centerYAnchor),
            abPressRipple.widthAnchor.constraint(equalToConstant: 44), abPressRipple.heightAnchor.constraint(equalToConstant: 44),
            abIsland.centerXAnchor.constraint(equalTo: abSafariScreen.centerXAnchor), abIsland.topAnchor.constraint(equalTo: abSafariScreen.topAnchor, constant: 9),
            abIslandWidth, abIslandHeight,
            abIslandIcon.leadingAnchor.constraint(equalTo: abIsland.leadingAnchor, constant: 8), abIslandIcon.centerYAnchor.constraint(equalTo: abIsland.centerYAnchor),
            abIslandIcon.widthAnchor.constraint(equalToConstant: 14), abIslandIcon.heightAnchor.constraint(equalToConstant: 14),
            abIslandCheck.trailingAnchor.constraint(equalTo: abIsland.trailingAnchor, constant: -8), abIslandCheck.centerYAnchor.constraint(equalTo: abIsland.centerYAnchor),
            abIslandCheck.widthAnchor.constraint(equalToConstant: 16), abIslandCheck.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    private func animateActionButtonSettings() {
        layoutIfNeeded()
        let screenWidth = abSettingsScreen.bounds.width
        let pageOffscreen = CGAffineTransform(translationX: screenWidth + 8, y: 0)
        let settingsCardLeft = CGAffineTransform(
            translationX: -screenWidth * 0.27, y: 0).scaledBy(x: 0.55, y: 0.55)
        let safariCardRight = CGAffineTransform(
            translationX: screenWidth * 0.27, y: 0).scaledBy(x: 0.55, y: 0.55)

        func reset() {
            abRootSettingsScreen.transform = .identity
            abRootSettingsScreen.alpha = 1
            abActionButtonRowHighlight.alpha = 0
            abSettingsScreen.transform = pageOffscreen
            abSettingsScreen.layer.cornerRadius = 0
            abSettingsScreen.clipsToBounds = true
            abOuterGlyphStrip.transform = .identity
            abInnerGlyphStrip.transform = .identity
            abDotControls.backgroundColor = .label
            abDotShortcut.backgroundColor = .tertiaryLabel
            abControlsTitle.alpha = 1
            abControlsSubtitle.alpha = 1
            abShortcutTitle.alpha = 0
            abShortcutSubtitle.alpha = 0
            abChooseButton.alpha = 0
            abChooseButton.transform = .identity
            abLunaChoice.alpha = 0
            abLunaChoice.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
            abSafariScreen.transform = pageOffscreen
            abSafariScreen.layer.cornerRadius = 18
            abSafariScreen.clipsToBounds = true
            abHardwareButton.backgroundColor = .systemGray
            abHardwareButton.transform = .identity
            abPressRipple.alpha = 0
            abPressRipple.transform = CGAffineTransform(scaleX: 0.25, y: 0.25)
            abIslandWidth.constant = 34
            abIslandHeight.constant = 12
            abIsland.layer.cornerRadius = 6
            abIslandIcon.alpha = 0
            abIslandCheck.alpha = 0
            abIslandCheck.transform = CGAffineTransform(scaleX: 0.3, y: 0.3)
            layoutIfNeeded()
        }
        reset()

        // Snapshot/layout tests intentionally disable UIKit animations. Preserve
        // the useful first frame (Settings root) instead of synchronously applying
        // every keyframe and leaving only the gray app-switcher background.
        guard UIView.areAnimationsEnabled else { return }

        UIView.animateKeyframes(withDuration: 10.5, delay: 0.4, options: [.repeat, .calculationModeCubic]) {
            // Tap Action Button on the Settings root.
            UIView.addKeyframe(withRelativeStartTime: 0.07, relativeDuration: 0.06) {
                self.abActionButtonRowHighlight.alpha = 1
            }
            UIView.addKeyframe(withRelativeStartTime: 0.13, relativeDuration: 0.10) {
                self.abActionButtonRowHighlight.alpha = 0
                self.abRootSettingsScreen.transform = CGAffineTransform(translationX: -screenWidth * 0.34, y: 0)
                self.abRootSettingsScreen.alpha = 0
                self.abSettingsScreen.transform = .identity
            }
            // Swipe the carousel one slot: both glyph strips pan together, so
            // Controls slides out of the capsule window into the dim side slot
            // while Shortcut slides in — the way real Settings pans — and the
            // page dot advances with it.
            UIView.addKeyframe(withRelativeStartTime: 0.28, relativeDuration: 0.12) {
                let pan = CGAffineTransform(translationX: -self.abCarouselStep, y: 0)
                self.abOuterGlyphStrip.transform = pan
                self.abInnerGlyphStrip.transform = pan
                self.abDotControls.backgroundColor = .tertiaryLabel
                self.abDotShortcut.backgroundColor = .label
                self.abControlsTitle.alpha = 0
                self.abControlsSubtitle.alpha = 0
            }
            // Only once the carousel has landed on Shortcut do its title,
            // subtitle, and the "Choose a Shortcut…" button belong on screen.
            UIView.addKeyframe(withRelativeStartTime: 0.36, relativeDuration: 0.06) {
                self.abShortcutTitle.alpha = 1
                self.abShortcutSubtitle.alpha = 1
            }
            UIView.addKeyframe(withRelativeStartTime: 0.40, relativeDuration: 0.05) {
                self.abChooseButton.alpha = 1
            }
            // Choose the installed Luna shortcut.
            UIView.addKeyframe(withRelativeStartTime: 0.46, relativeDuration: 0.06) {
                self.abChooseButton.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
            }
            UIView.addKeyframe(withRelativeStartTime: 0.52, relativeDuration: 0.07) {
                self.abChooseButton.alpha = 0
                self.abChooseButton.transform = .identity
                self.abLunaChoice.alpha = 1
                self.abLunaChoice.transform = .identity
            }
            // iOS multitasking transition: both apps become inset cards over the
            // gray switcher background, Settings exits left as Safari enters from
            // the right, then Safari expands to the full device screen.
            UIView.addKeyframe(withRelativeStartTime: 0.62, relativeDuration: 0.05) {
                self.abSettingsScreen.transform = settingsCardLeft
                self.abSettingsScreen.layer.cornerRadius = 18
                self.abSafariScreen.transform = safariCardRight
            }
            // Explicitly pin the same values across the hold. UIKit otherwise
            // interpolates across an empty keyframe gap toward the next state.
            UIView.addKeyframe(withRelativeStartTime: 0.67, relativeDuration: 0.08) {
                self.abSettingsScreen.transform = settingsCardLeft
                self.abSettingsScreen.layer.cornerRadius = 18
                self.abSafariScreen.transform = safariCardRight
                self.abSafariScreen.layer.cornerRadius = 18
            }
            UIView.addKeyframe(withRelativeStartTime: 0.75, relativeDuration: 0.08) {
                self.abSettingsScreen.transform = CGAffineTransform(
                    translationX: -screenWidth * 1.05, y: 0).scaledBy(x: 0.84, y: 0.84)
                self.abSafariScreen.transform = .identity
                self.abSafariScreen.layer.cornerRadius = 0
            }
            // Press the physical Action Button: the button itself depresses and
            // lights up in the accent while a wide ripple blooms outward, so the
            // press registers instead of reading as a faint blink.
            UIView.addKeyframe(withRelativeStartTime: 0.84, relativeDuration: 0.03) {
                self.abHardwareButton.backgroundColor = self.accent
                self.abHardwareButton.transform = CGAffineTransform(translationX: 1.5, y: 0)
                self.abPressRipple.alpha = 1
                self.abPressRipple.transform = .identity
            }
            UIView.addKeyframe(withRelativeStartTime: 0.87, relativeDuration: 0.04) {
                self.abPressRipple.alpha = 0
                self.abPressRipple.transform = CGAffineTransform(scaleX: 1.5, y: 1.5)
            }
            UIView.addKeyframe(withRelativeStartTime: 0.90, relativeDuration: 0.03) {
                self.abHardwareButton.backgroundColor = .systemGray
                self.abHardwareButton.transform = .identity
            }
            // The Dynamic Island expands into an oversized confirmation — larger
            // than real usage, deliberately, so the checkmark is unmissable —
            // and the checkmark pops in with a small overshoot.
            UIView.addKeyframe(withRelativeStartTime: 0.85, relativeDuration: 0.05) {
                self.abIslandWidth.constant = 84
                self.abIslandHeight.constant = 26
                self.abIsland.layer.cornerRadius = 13
                self.layoutIfNeeded()
            }
            UIView.addKeyframe(withRelativeStartTime: 0.90, relativeDuration: 0.03) {
                self.abIslandIcon.alpha = 1
                self.abIslandCheck.alpha = 1
                self.abIslandCheck.transform = CGAffineTransform(scaleX: 1.25, y: 1.25)
            }
            UIView.addKeyframe(withRelativeStartTime: 0.93, relativeDuration: 0.03) {
                self.abIslandCheck.transform = .identity
            }
            // Pin Safari (and the confirmation) in place through the hold: cubic
            // keyframe interpolation otherwise starts drifting toward the exit
            // keyframe early and drags the checkmark offscreen mid-confirmation.
            UIView.addKeyframe(withRelativeStartTime: 0.93, relativeDuration: 0.05) {
                self.abSafariScreen.transform = .identity
                self.abIslandIcon.alpha = 1
                self.abIslandCheck.alpha = 1
            }
            UIView.addKeyframe(withRelativeStartTime: 0.98, relativeDuration: 0.02) {
                self.abSafariScreen.transform = CGAffineTransform(translationX: -screenWidth, y: 0)
                self.abIslandIcon.alpha = 0
                self.abIslandCheck.alpha = 0
            }
        }
    }
}

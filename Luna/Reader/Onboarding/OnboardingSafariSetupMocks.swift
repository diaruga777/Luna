//
//  OnboardingSafariSetupMocks.swift
//  Luna
//

import UIKit

/// Timing for the mock "enable the extension" pass the Safari demonstration
/// plays over the buried article: page menu, Manage Extensions, toggle, wipe.
enum OnboardingExtensionEnableTiming {
    /// The buried page registers before the chrome starts moving.
    static let pageHoldDuration: TimeInterval = 0.9
    static let menuAppearDuration: TimeInterval = 0.34
    /// The menu rests before it starts hunting for Manage Extensions.
    static let menuHoldBeforeScroll: TimeInterval = 0.6
    static let menuScrollDuration: TimeInterval = 0.5
    /// The found row stays highlighted long enough to read.
    static let rowHighlightHold: TimeInterval = 0.5
    static let sheetPresentDuration: TimeInterval = 0.45
    static let toggleDelay: TimeInterval = 0.55
    static let toggleDuration: TimeInterval = 0.3
    /// The switched-on state registers before the sheet leaves.
    static let sheetDismissDelay: TimeInterval = 0.6
    static let sheetDismissDuration: TimeInterval = 0.4
}

/// The Safari page menu — the popover the address bar's page button opens —
/// with a list that scrolls down to "Manage Extensions".
final class OnboardingSafariMenuPopoverView: UIView {
    private static let rowHeight: CGFloat = 44
    private static let visibleHeight: CGFloat = 312
    private static let menuWidth: CGFloat = 264

    private let scrollView = UIScrollView()
    private var manageExtensionsRow: UIView?
    private var manageExtensionsRowTop: CGFloat = 0

    init() {
        super.init(frame: CGRect(
            x: 0, y: 0,
            width: Self.menuWidth,
            height: Self.visibleHeight))
        isUserInteractionEnabled = false
        accessibilityIdentifier = "onboarding.safari.pageMenu"
        backgroundColor = UIColor(white: 0.99, alpha: 1)
        layer.cornerRadius = 13
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.30
        layer.shadowRadius = 34
        layer.shadowOffset = CGSize(width: 0, height: 10)

        scrollView.frame = bounds
        scrollView.isScrollEnabled = false
        scrollView.layer.cornerRadius = 13
        scrollView.layer.cornerCurve = .continuous
        scrollView.clipsToBounds = true
        addSubview(scrollView)

        let rows: [(title: String, symbol: String, isTarget: Bool)] = [
            ("Add to Reading List", "eyeglasses", false),
            ("Add Bookmark", "book", false),
            ("Show Reader", "doc.plaintext", false),
            ("Translate", "character.bubble", false),
            ("Listen to Page", "speaker.wave.2", false),
            ("Hide Distracting Items", "eye.slash", false),
            ("Website Settings", "gearshape", false),
            ("Manage Extensions", "puzzlepiece.extension", true),
            ("Move to Tab Group", "square.grid.2x2", false),
            ("Add to Home Screen", "plus.app", false),
        ]
        for (index, row) in rows.enumerated() {
            let rowView = UIView(frame: CGRect(
                x: 0,
                y: CGFloat(index) * Self.rowHeight,
                width: Self.menuWidth,
                height: Self.rowHeight))
            let title = UILabel(frame: CGRect(
                x: 16, y: 0, width: Self.menuWidth - 66, height: Self.rowHeight))
            title.text = row.title
            title.font = .systemFont(ofSize: 17)
            title.textColor = UIColor(white: 0.08, alpha: 1)
            rowView.addSubview(title)
            let symbol = UIImageView(image: UIImage(
                systemName: row.symbol,
                withConfiguration: UIImage.SymbolConfiguration(
                    pointSize: 16, weight: .regular)))
            symbol.tintColor = UIColor(white: 0.10, alpha: 1)
            symbol.contentMode = .center
            symbol.frame = CGRect(
                x: Self.menuWidth - 46, y: 0, width: 30, height: Self.rowHeight)
            rowView.addSubview(symbol)
            if index < rows.count - 1 {
                let separator = UIView(frame: CGRect(
                    x: 16,
                    y: Self.rowHeight - 0.5,
                    width: Self.menuWidth - 16,
                    height: 0.5))
                separator.backgroundColor = UIColor(white: 0.86, alpha: 1)
                rowView.addSubview(separator)
            }
            if row.isTarget {
                rowView.accessibilityIdentifier =
                    "onboarding.safari.pageMenu.manageExtensions"
                manageExtensionsRow = rowView
                manageExtensionsRowTop = rowView.frame.minY
            }
            scrollView.addSubview(rowView)
        }
        scrollView.contentSize = CGSize(
            width: Self.menuWidth,
            height: CGFloat(rows.count) * Self.rowHeight)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Grows out of the page button the way Safari's menu does.
    func present(
        anchoredAbove anchor: CGPoint,
        in host: UIView,
        completion: @escaping () -> Void
    ) {
        let x = min(max(anchor.x - 28, 10), host.bounds.width - Self.menuWidth - 10)
        frame = CGRect(
            x: x,
            y: anchor.y - Self.visibleHeight - 12,
            width: Self.menuWidth,
            height: Self.visibleHeight)
        host.addSubview(self)

        if UIAccessibility.isReduceMotionEnabled {
            alpha = 0
            UIView.animate(withDuration: 0.2, animations: {
                self.alpha = 1
            }) { _ in completion() }
            return
        }

        // Scale up from the corner nearest the button.
        let anchorInSelf = CGPoint(
            x: (anchor.x - frame.minX) / frame.width,
            y: 1)
        setAnchorPoint(anchorInSelf)
        transform = CGAffineTransform(scaleX: 0.10, y: 0.10)
        alpha = 0
        UIView.animate(
            withDuration: OnboardingExtensionEnableTiming.menuAppearDuration,
            delay: 0,
            usingSpringWithDamping: 0.80,
            initialSpringVelocity: 0.3,
            options: [.curveEaseOut, .beginFromCurrentState]
        ) {
            self.transform = .identity
            self.alpha = 1
        } completion: { _ in
            completion()
        }
    }

    /// Runs the quick hunt down the list and lights the row up.
    func scrollToManageExtensions(completion: @escaping () -> Void) {
        let target = max(
            0,
            min(manageExtensionsRowTop - Self.visibleHeight + Self.rowHeight * 1.6,
                scrollView.contentSize.height - Self.visibleHeight))
        UIView.animate(
            withDuration: UIAccessibility.isReduceMotionEnabled
                ? 0.2
                : OnboardingExtensionEnableTiming.menuScrollDuration,
            delay: 0,
            options: [.curveEaseInOut, .beginFromCurrentState]
        ) {
            self.scrollView.contentOffset = CGPoint(x: 0, y: target)
        } completion: { _ in
            UIView.animate(withDuration: 0.14) {
                self.manageExtensionsRow?.backgroundColor =
                    UIColor(white: 0.85, alpha: 1)
            } completion: { _ in
                completion()
            }
        }
    }

    func dismiss(completion: @escaping () -> Void = {}) {
        UIView.animate(
            withDuration: 0.18,
            delay: 0,
            options: [.curveEaseIn, .beginFromCurrentState]
        ) {
            self.alpha = 0
            if !UIAccessibility.isReduceMotionEnabled {
                self.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
            }
        } completion: { _ in
            self.removeFromSuperview()
            completion()
        }
    }

    /// Moves the layer anchor without moving the view on screen.
    private func setAnchorPoint(_ point: CGPoint) {
        let newOrigin = CGPoint(
            x: bounds.width * point.x,
            y: bounds.height * point.y)
        let oldOrigin = CGPoint(
            x: bounds.width * layer.anchorPoint.x,
            y: bounds.height * layer.anchorPoint.y)
        layer.anchorPoint = point
        layer.position = CGPoint(
            x: layer.position.x + newOrigin.x - oldOrigin.x,
            y: layer.position.y + newOrigin.y - oldOrigin.y)
    }
}

/// The Manage Extensions bottom sheet: the current app's icon and name with
/// the permission toggle that flips on.
final class OnboardingManageExtensionsSheetView: UIView {
    private static let cardHeight: CGFloat = 252

    private let scrim = UIView()
    private let card = UIView()
    private let grabber = UIView()
    private let title = UILabel()
    private let appRow = UIView()
    private let appIcon = UIImageView(image: OnboardingAppIcon.image())
    private let appName = UILabel()
    private let toggle = OnboardingMockSwitchView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityIdentifier = "onboarding.safari.manageExtensionsSheet"

        scrim.backgroundColor = UIColor.black.withAlphaComponent(0.32)
        scrim.alpha = 0
        addSubview(scrim)

        card.backgroundColor = UIColor(white: 0.99, alpha: 1)
        card.layer.cornerRadius = 24
        card.layer.cornerCurve = .continuous
        card.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        addSubview(card)

        grabber.backgroundColor = UIColor(white: 0.80, alpha: 1)
        grabber.layer.cornerRadius = 2.5
        card.addSubview(grabber)

        title.text = "Manage Extensions"
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = UIColor(white: 0.08, alpha: 1)
        title.textAlignment = .center
        card.addSubview(title)

        appRow.backgroundColor = .white
        appRow.layer.cornerRadius = 12
        appRow.layer.cornerCurve = .continuous
        appRow.layer.borderWidth = 0.5
        appRow.layer.borderColor = UIColor(white: 0.88, alpha: 1).cgColor
        card.addSubview(appRow)

        appIcon.contentMode = .scaleAspectFill
        appIcon.layer.cornerRadius = 7
        appIcon.layer.cornerCurve = .continuous
        appIcon.clipsToBounds = true
        appRow.addSubview(appIcon)

        appName.text = "Luna"
        appName.font = .systemFont(ofSize: 17)
        appName.textColor = UIColor(white: 0.08, alpha: 1)
        appRow.addSubview(appName)

        toggle.accessibilityIdentifier =
            "onboarding.safari.manageExtensionsToggle"
        appRow.addSubview(toggle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrim.frame = bounds
        // Transform-safe placement: the card slides via its transform.
        card.bounds = CGRect(
            x: 0, y: 0, width: bounds.width, height: Self.cardHeight + 40)
        card.center = CGPoint(
            x: bounds.midX,
            y: bounds.height - Self.cardHeight + card.bounds.height / 2)

        grabber.bounds = CGRect(x: 0, y: 0, width: 36, height: 5)
        grabber.center = CGPoint(x: card.bounds.midX, y: 10.5)
        title.frame = CGRect(
            x: 0, y: 24, width: card.bounds.width, height: 22)
        appRow.frame = CGRect(
            x: 16, y: 66, width: card.bounds.width - 32, height: 64)
        appIcon.frame = CGRect(x: 16, y: 17.5, width: 29, height: 29)
        appName.frame = CGRect(x: 57, y: 0, width: 160, height: 64)
        toggle.frame = CGRect(
            x: appRow.bounds.width - 51 - 16,
            y: (64 - 31) / 2,
            width: 51,
            height: 31)
    }

    var offscreenTranslation: CGFloat { Self.cardHeight }

    func present(completion: @escaping () -> Void) {
        layoutIfNeeded()
        if UIAccessibility.isReduceMotionEnabled {
            alpha = 0
            UIView.animate(withDuration: 0.2, animations: {
                self.alpha = 1
                self.scrim.alpha = 1
            }) { _ in completion() }
            return
        }
        card.transform = CGAffineTransform(
            translationX: 0, y: offscreenTranslation)
        UIView.animate(
            withDuration: OnboardingExtensionEnableTiming.sheetPresentDuration,
            delay: 0,
            usingSpringWithDamping: 0.88,
            initialSpringVelocity: 0.3,
            options: [.curveEaseOut, .beginFromCurrentState]
        ) {
            self.card.transform = .identity
        } completion: { _ in
            completion()
        }
        UIView.animate(withDuration: 0.26) {
            self.scrim.alpha = 1
        }
    }

    func turnOnToggle(completion: @escaping () -> Void) {
        toggle.setOn {
            completion()
        }
    }

    func dismiss(completion: @escaping () -> Void) {
        if UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.2, animations: {
                self.alpha = 0
            }) { _ in
                self.removeFromSuperview()
                completion()
            }
            return
        }
        UIView.animate(
            withDuration: OnboardingExtensionEnableTiming.sheetDismissDuration,
            delay: 0,
            options: [.curveEaseIn, .beginFromCurrentState]
        ) {
            self.card.transform = CGAffineTransform(
                translationX: 0, y: self.offscreenTranslation)
            self.scrim.alpha = 0
        } completion: { _ in
            self.removeFromSuperview()
            completion()
        }
    }
}

/// A pixel-faithful stand-in for UISwitch that can be flipped on cue.
final class OnboardingMockSwitchView: UIView {
    private let knob = UIView()
    private(set) var isOn = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = UIColor(white: 0.90, alpha: 1)
        layer.cornerRadius = 15.5

        knob.backgroundColor = .white
        knob.layer.cornerRadius = 13.5
        knob.layer.shadowColor = UIColor.black.cgColor
        knob.layer.shadowOpacity = 0.25
        knob.layer.shadowRadius = 4
        knob.layer.shadowOffset = CGSize(width: 0, height: 2)
        addSubview(knob)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        knob.bounds = CGRect(x: 0, y: 0, width: 27, height: 27)
        knob.center = CGPoint(
            x: isOn ? bounds.width - 15.5 : 15.5,
            y: bounds.midY)
    }

    func setOn(completion: @escaping () -> Void) {
        guard !isOn else {
            completion()
            return
        }
        isOn = true
        UIView.animate(
            withDuration: UIAccessibility.isReduceMotionEnabled
                ? 0.1
                : OnboardingExtensionEnableTiming.toggleDuration,
            delay: 0,
            usingSpringWithDamping: 0.85,
            initialSpringVelocity: 0.4,
            options: [.curveEaseOut, .beginFromCurrentState]
        ) {
            // The light-appearance system green — the app pins dark app-wide,
            // so the dynamic color would resolve wrong here.
            self.backgroundColor = UIColor(
                red: 0.20, green: 0.78, blue: 0.35, alpha: 1)
            self.knob.center = CGPoint(
                x: self.bounds.width - 15.5,
                y: self.bounds.midY)
        } completion: { _ in
            completion()
        }
    }
}

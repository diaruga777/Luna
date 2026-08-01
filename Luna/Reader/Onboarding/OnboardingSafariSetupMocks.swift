//
//  OnboardingSafariSetupMocks.swift
//  Luna
//

import LunaDesignSystem
import UIKit

/// Timing for the mock "enable the extension" pass the Safari demonstration
/// plays over the buried article: the Manage Extensions sheet, its toggle, and
/// the wipe that leaves with it.
enum OnboardingExtensionEnableTiming {
    /// The buried page registers before the sheet slides up.
    static let pageHoldDuration: TimeInterval = 0.9
    static let sheetPresentDuration: TimeInterval = 0.3
    /// The sheet rests, read, before the switch moves.
    static let toggleDelay: TimeInterval = 0.3
    static let toggleDuration: TimeInterval = 0.22
    static let sheetDismissDuration: TimeInterval = 0.25
}

/// The Manage Extensions bottom sheet: the running app's icon and name — which
/// is how Safari lists its extension — with the permission toggle that flips on.
/// The sheet's title and that name are the page's too: the mock page lists this
/// sheet as the step that reaches it, so both read from the same places.
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

    init(
        frame: CGRect,
        configuration: OnboardingSurfaceConfiguration = .current
    ) {
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

        title.text = OnboardingSafariExtensionCopy.manageExtensionsTitle
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

        appName.text = configuration.app.displayName
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
        // Transform-safe placement: the card slides via its transform. On a wide
        // screen the sheet keeps a sheet's width and centres, the way a real
        // iPad action sheet does, rather than becoming a bar with one toggle
        // stranded at its far end.
        let sheetWidth = min(bounds.width, LunaLayout.readableWidth)
        card.bounds = CGRect(
            x: 0, y: 0, width: sheetWidth, height: Self.cardHeight + 40)
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
    /// The light-appearance system green — the app pins dark app-wide, so the
    /// dynamic color would resolve wrong on Safari's white chrome. Shared with
    /// the mock page's own picture of this switch.
    static let onColor = UIColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1)

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
            self.backgroundColor = Self.onColor
            self.knob.center = CGPoint(
                x: self.bounds.width - 15.5,
                y: self.bounds.midY)
        } completion: { _ in
            completion()
        }
    }
}

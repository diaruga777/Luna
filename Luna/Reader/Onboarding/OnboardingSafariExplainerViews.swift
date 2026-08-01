//
//  OnboardingSafariExplainerViews.swift
//  Luna
//

import LunaDesignSystem
import UIKit

/// One enable step on the mock `luna.app` page: the piece of Safari chrome it
/// points at, drawn at chrome scale, and the line of copy beside it.
///
/// The visuals are the real artwork, never a stand-in: the page-menu chip
/// carries `SafariBottomBar.pageMenuSymbol` — the exact symbol the mock browser
/// bar draws in its address field, a few points below on the same screen — and
/// the last step carries the app's own icon beside the switch the Manage
/// Extensions sheet flips.
final class OnboardingSafariEnableStepRowView: UIView {
    /// Two lines of 15pt copy — the longest step wraps on a narrow phone — and
    /// tall enough that a chrome chip beside it reads as a button rather than a
    /// bullet.
    static let preferredHeight: CGFloat = 38
    /// The leading column every step's visual occupies. Sized by the widest of
    /// them (the app's icon and switch) so all three lines of copy start on one
    /// vertical.
    static let visualColumnWidth: CGFloat = 70
    static let visualToTextGap: CGFloat = 14

    private let visual: UIView
    private let label = UILabel()

    init(step: OnboardingSafariExtensionCopy.Step) {
        visual = OnboardingSafariChromeVisualView(chrome: step.chrome)
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        addSubview(visual)

        label.text = step.text
        label.font = .systemFont(ofSize: 15, weight: .regular)
        label.textColor = .white
        label.numberOfLines = 2
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.85
        label.isAccessibilityElement = false
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        let visualSize = visual.intrinsicContentSize
        visual.frame = CGRect(
            x: 0,
            y: ((bounds.height - visualSize.height) / 2).rounded(),
            width: visualSize.width,
            height: visualSize.height)
        let textX = Self.visualColumnWidth + Self.visualToTextGap
        label.frame = CGRect(
            x: textX,
            y: 0,
            width: max(bounds.width - textX, 0),
            height: bounds.height)
    }
}

/// A step's chrome, at chrome scale: the light capsule Safari puts its page
/// menu in, the puzzle-piece row that menu offers, or the app's own icon beside
/// the switch that turns it on. Deliberately light against the page's dark
/// neutral grey — these are pictures of Safari's UI, not the page's own type.
final class OnboardingSafariChromeVisualView: UIView {
    private static let height: CGFloat = 30
    private static let chipWidth: CGFloat = 46
    private static let appIconSide: CGFloat = 28
    private static let switchSize = CGSize(width: 34, height: 20)
    private static let appVisualSpacing: CGFloat = 8

    /// The symbol this visual draws, when it draws one: the page-menu step
    /// must show the very symbol the browser bar below it does.
    let symbolName: String?

    private let chrome: OnboardingSafariExtensionCopy.Step.Chrome
    private let plate = UIView()
    private let glyph = UIImageView()
    private let appIcon = UIImageView(image: OnboardingAppIcon.image())
    private let switchTrack = UIView()
    private let switchKnob = UIView()

    override var intrinsicContentSize: CGSize {
        switch chrome {
        case .pageMenu, .manageExtensions:
            return CGSize(width: Self.chipWidth, height: Self.height)
        case .app:
            return CGSize(
                width: Self.appIconSide + Self.appVisualSpacing
                    + Self.switchSize.width,
                height: Self.height)
        }
    }

    init(chrome: OnboardingSafariExtensionCopy.Step.Chrome) {
        self.chrome = chrome
        switch chrome {
        case .pageMenu: symbolName = SafariBottomBar.pageMenuSymbol
        case .manageExtensions: symbolName = "puzzlepiece.extension.fill"
        case .app: symbolName = nil
        }
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        switch chrome {
        case .pageMenu, .manageExtensions:
            configureChip()
        case .app:
            configureAppRow()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func configureChip() {
        plate.backgroundColor = OnboardingSafariPagePalette.paper
        // Safari's address field is a capsule; the menu row it opens is not.
        plate.layer.cornerRadius = chrome == .pageMenu ? Self.height / 2 : 9
        plate.layer.cornerCurve = .continuous
        addSubview(plate)

        glyph.image = symbolName.flatMap {
            UIImage(
                systemName: $0,
                withConfiguration: UIImage.SymbolConfiguration(
                    pointSize: 15, weight: .semibold))
        }
        glyph.tintColor = OnboardingSafariPagePalette.ink
        glyph.contentMode = .center
        plate.addSubview(glyph)
    }

    private func configureAppRow() {
        appIcon.contentMode = .scaleAspectFill
        appIcon.layer.cornerRadius = 7
        appIcon.layer.cornerCurve = .continuous
        appIcon.clipsToBounds = true
        addSubview(appIcon)

        // The switch is already on: the step is what the setting looks like
        // once you've done it, not a control to work.
        switchTrack.backgroundColor = OnboardingMockSwitchView.onColor
        switchTrack.layer.cornerRadius = Self.switchSize.height / 2
        switchKnob.backgroundColor = .white
        switchKnob.layer.cornerRadius = (Self.switchSize.height - 4) / 2
        switchTrack.addSubview(switchKnob)
        addSubview(switchTrack)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        switch chrome {
        case .pageMenu, .manageExtensions:
            plate.frame = bounds
            glyph.frame = plate.bounds
        case .app:
            appIcon.frame = CGRect(
                x: 0,
                y: ((bounds.height - Self.appIconSide) / 2).rounded(),
                width: Self.appIconSide,
                height: Self.appIconSide)
            switchTrack.frame = CGRect(
                x: appIcon.frame.maxX + Self.appVisualSpacing,
                y: ((bounds.height - Self.switchSize.height) / 2).rounded(),
                width: Self.switchSize.width,
                height: Self.switchSize.height)
            let knobSide = Self.switchSize.height - 4
            switchKnob.frame = CGRect(
                x: switchTrack.bounds.width - knobSide - 2,
                y: 2,
                width: knobSide,
                height: knobSide)
        }
    }
}

/// The extension's call to action, inlined at the bottom of the page's own
/// content rather than floating over it on a card: the prominent Safari action
/// — which wears the launch eclipse corona, positioned by the page — and the
/// quiet skip beneath it.
final class OnboardingSafariActionsView: UIView {
    static let activateHeight: CGFloat = 52
    /// A full touch target, not just the label's height.
    static let skipHeight: CGFloat = 44
    /// Room enough that the corona around the Safari button has faded well
    /// down before it reaches the skip label.
    static let interActionGap: CGFloat = 18
    static var preferredHeight: CGFloat {
        activateHeight + interActionGap + skipHeight
    }
    private static let minimumActivateWidth: CGFloat = 214

    var onActivate: (() -> Void)?
    var onSkip: (() -> Void)?

    let activateButton = UIButton(type: .system)
    let skipButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "onboarding.safari.page.actions"

        activateButton.configuration = GlassStyle.actionButtonConfiguration(
            title: "Activate Safari",
            symbol: "safari.fill",
            prominent: true)
        activateButton.accessibilityLabel = "Activate Safari"
        activateButton.accessibilityIdentifier = "onboarding.safari.page.activate"
        activateButton.addTarget(
            self, action: #selector(activateTapped), for: .touchUpInside)
        addSubview(activateButton)

        var skipConfiguration = UIButton.Configuration.plain()
        skipConfiguration.title = "Skip"
        skipConfiguration.baseForegroundColor =
            UIColor.white.withAlphaComponent(0.7)
        skipConfiguration.contentInsets = NSDirectionalEdgeInsets(
            top: 8, leading: 14, bottom: 8, trailing: 14)
        skipConfiguration.titleTextAttributesTransformer =
            UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.font = .systemFont(ofSize: 16, weight: .medium)
                return outgoing
            }
        skipButton.configuration = skipConfiguration
        skipButton.accessibilityLabel = "Skip"
        skipButton.accessibilityIdentifier = "onboarding.safari.page.skip"
        skipButton.addTarget(
            self, action: #selector(skipTapped), for: .touchUpInside)
        addSubview(skipButton)

        // Buried under the clutter — and later behind the wave's own occluder —
        // these are invisible but still in the hierarchy, and the clutter is
        // NON-interactive, so a tap at their position would otherwise reach a
        // button nobody can see. They stay inert until the page is clean.
        setActionsEnabled(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        let activateSize = activateButton.sizeThatFits(
            CGSize(width: bounds.width, height: Self.activateHeight))
        let activateWidth = min(
            bounds.width, max(Self.minimumActivateWidth, activateSize.width))
        activateButton.frame = CGRect(
            x: ((bounds.width - activateWidth) / 2).rounded(),
            y: 0,
            width: activateWidth,
            height: Self.activateHeight)
        let skipSize = skipButton.sizeThatFits(
            CGSize(width: bounds.width, height: Self.skipHeight))
        let skipWidth = min(bounds.width, max(80, skipSize.width))
        skipButton.frame = CGRect(
            x: ((bounds.width - skipWidth) / 2).rounded(),
            y: Self.activateHeight + Self.interActionGap,
            width: skipWidth,
            height: Self.skipHeight)
    }

    func setActionsEnabled(_ enabled: Bool) {
        activateButton.isUserInteractionEnabled = enabled
        skipButton.isUserInteractionEnabled = enabled
    }

    @objc private func activateTapped() {
        setActionsEnabled(false)
        onActivate?()
    }

    @objc private func skipTapped() {
        setActionsEnabled(false)
        onSkip?()
    }
}

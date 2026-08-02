//
//  OnboardingShortcutRunEffects.swift
//  Luna
//

import LunaDesignSystem
import LunaModels
import UIKit

/// Shared timing for the mock shortcut run the Messages demonstration plays
/// after its ripple: Dynamic Island expansion, progress, the staged tap, and
/// the mock action-extension sheet over the conversation.
enum OnboardingShortcutRunTiming {
    static let islandExpandDelay: TimeInterval = 0.30
    static let islandExpandDuration: TimeInterval = 0.52
    /// The link bubble's arc up into the expanding island.
    static let bubbleFlightDuration: TimeInterval = 0.68
    static let islandProgressDuration: TimeInterval = 1.35
    /// The finished ring rests a moment before the staged finger arrives.
    static let islandTapDelay: TimeInterval = 0.45
    static let mockTapDuration: TimeInterval = 0.58
    static let islandCollapseDuration: TimeInterval = 0.30
    /// The Safari-to-Messages hop after setup completes or is skipped.
    static let appSwitchDuration: TimeInterval = 0.85
    static let sheetPresentDuration: TimeInterval = 0.55
    static let sheetDismissDuration: TimeInterval = 0.38
    /// The mock extension sheet rests long enough to register as "it's saved".
    static let extensionSheetHoldDuration: TimeInterval = 1.0
    static let followUpMessageDelay: TimeInterval = 0.55
    /// The skip-out arrives well after the shortcut-install message: offering
    /// the way out in the same breath as the thing being asked for reads as
    /// the app not believing its own pitch. The install pill gets its corona
    /// loop to itself for a couple of beats first.
    static let skipMessageDelay: TimeInterval = 2.6
}

/// The compact-expanded Dynamic Island treatment iOS shows while an Action
/// Button shortcut runs: the black capsule widens around the hardware island
/// with the app's icon on the left and a progress ring on the right.
final class OnboardingDynamicIslandRunView: UIView {
    private let iconView = UIImageView()
    private let ring = OnboardingIslandProgressRingView()
    private var restingFrame = CGRect.zero
    private var expandedFrame = CGRect.zero

    /// The hardware island's approximate resting capsule. On devices without
    /// an island the mock still plays in the same top-center position.
    static func restingIslandFrame(in bounds: CGRect) -> CGRect {
        let size = CGSize(width: 126, height: 37)
        return CGRect(
            x: (bounds.width - size.width) / 2,
            y: 11,
            width: size.width,
            height: size.height)
    }

    init(appIcon: UIImage?) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        accessibilityIdentifier =
            OnboardingStrings.Accessibility.messagesDynamicIsland.value()
        backgroundColor = .black
        layer.cornerCurve = .continuous

        iconView.image = appIcon
        iconView.contentMode = .scaleAspectFill
        iconView.layer.cornerRadius = 8
        iconView.layer.cornerCurve = .continuous
        iconView.clipsToBounds = true
        iconView.alpha = 0
        addSubview(iconView)

        ring.alpha = 0
        addSubview(ring)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = min(bounds.height / 2, 38)
        let iconSide: CGFloat = min(bounds.height - 24, 44)
        iconView.frame = CGRect(
            x: 16,
            y: (bounds.height - iconSide) / 2,
            width: iconSide,
            height: iconSide)
        iconView.layer.cornerRadius = iconSide * 0.24
        let ringSide: CGFloat = min(bounds.height - 30, 36)
        ring.frame = CGRect(
            x: bounds.width - ringSide - 18,
            y: (bounds.height - ringSide) / 2,
            width: ringSide,
            height: ringSide)
    }

    /// Mounts at the hardware island's capsule and inflates the way the
    /// system's expanded treatment does — growing downward, getting taller
    /// and wider around the fixed cutout.
    func expand(in host: UIView, completion: @escaping () -> Void) {
        restingFrame = Self.restingIslandFrame(in: host.bounds)
        let expandedWidth = min(host.bounds.width - 44, 340)
        expandedFrame = CGRect(
            x: restingFrame.midX - expandedWidth / 2,
            y: restingFrame.minY,
            width: expandedWidth,
            height: 76)
        frame = restingFrame
        host.addSubview(self)

        if UIAccessibility.isReduceMotionEnabled {
            alpha = 0
            frame = expandedFrame
            layoutIfNeeded()
            UIView.animate(withDuration: 0.20) {
                self.alpha = 1
                self.iconView.alpha = 1
                self.ring.alpha = 1
            } completion: { _ in completion() }
            return
        }

        layoutIfNeeded()
        UIView.animate(
            withDuration: OnboardingShortcutRunTiming.islandExpandDuration,
            delay: 0,
            usingSpringWithDamping: 0.72,
            initialSpringVelocity: 0.2,
            options: [.curveEaseOut, .beginFromCurrentState]
        ) {
            self.frame = self.expandedFrame
            self.layoutIfNeeded()
        } completion: { _ in completion() }
        UIView.animate(
            withDuration: 0.24,
            delay: OnboardingShortcutRunTiming.islandExpandDuration * 0.4,
            options: [.curveEaseOut, .beginFromCurrentState]
        ) {
            self.iconView.alpha = 1
            self.ring.alpha = 1
        }
    }

    /// Fills the progress ring. Completion is scheduled on the shared
    /// onboarding clock so debug slow motion stays in sync.
    func runProgress(completion: @escaping () -> Void) {
        let duration = UIAccessibility.isReduceMotionEnabled
            ? 0.3
            : OnboardingShortcutRunTiming.islandProgressDuration
        ring.animateFill(duration: duration)
        DispatchQueue.main.asyncAfter(
            deadline: .now() + OnboardingAnimationClock.delay(duration)
        ) {
            completion()
        }
    }

    /// The center of the progress ring in the host's coordinate space — where
    /// the staged finger lands.
    func tapTarget(in host: UIView) -> CGPoint {
        host.convert(CGPoint(x: ring.frame.midX, y: ring.frame.midY), from: self)
    }

    /// A quick swallow: the capsule puffs as the flying bubble disappears
    /// behind it.
    func absorb() {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        UIView.animate(
            withDuration: 0.14,
            delay: 0,
            options: [.curveEaseOut, .beginFromCurrentState]
        ) {
            self.transform = CGAffineTransform(scaleX: 1.05, y: 1.05)
        } completion: { _ in
            UIView.animate(
                withDuration: 0.34,
                delay: 0,
                usingSpringWithDamping: 0.55,
                initialSpringVelocity: 0.4,
                options: [.beginFromCurrentState]
            ) {
                self.transform = .identity
            }
        }
    }

    func pressDown() {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        UIView.animate(
            withDuration: 0.12,
            delay: 0,
            options: [.curveEaseOut, .beginFromCurrentState]
        ) {
            self.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
        }
    }

    func release() {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        UIView.animate(
            withDuration: 0.30,
            delay: 0,
            usingSpringWithDamping: 0.6,
            initialSpringVelocity: 0.4,
            options: [.beginFromCurrentState]
        ) {
            self.transform = .identity
        }
    }

    /// Shrinks back into the hardware island and fades.
    func collapse(completion: @escaping () -> Void) {
        let changes = {
            self.frame = self.restingFrame
            self.iconView.alpha = 0
            self.ring.alpha = 0
            self.layoutIfNeeded()
        }
        UIView.animate(
            withDuration: UIAccessibility.isReduceMotionEnabled
                ? 0.15
                : OnboardingShortcutRunTiming.islandCollapseDuration,
            delay: 0,
            options: [.curveEaseIn, .beginFromCurrentState],
            animations: changes
        ) { _ in
            self.removeFromSuperview()
            completion()
        }
    }
}

/// The island's trailing progress circle.
final class OnboardingIslandProgressRingView: UIView {
    private let track = CAShapeLayer()
    private let progress = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        for shape in [track, progress] {
            shape.fillColor = UIColor.clear.cgColor
            shape.lineWidth = 4.5
            shape.lineCap = .round
            layer.addSublayer(shape)
        }
        track.strokeColor = UIColor.white.withAlphaComponent(0.28).cgColor
        progress.strokeColor = UIColor.white.cgColor
        progress.strokeEnd = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        let path = UIBezierPath(
            arcCenter: CGPoint(x: bounds.midX, y: bounds.midY),
            radius: (min(bounds.width, bounds.height) - 4.5) / 2,
            startAngle: -.pi / 2,
            endAngle: .pi * 1.5,
            clockwise: true).cgPath
        track.frame = bounds
        progress.frame = bounds
        track.path = path
        progress.path = path
    }

    func animateFill(duration: TimeInterval) {
        let fill = CABasicAnimation(keyPath: "strokeEnd")
        fill.fromValue = 0
        fill.toValue = 1
        fill.duration = duration
        fill.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        progress.strokeEnd = 1
        progress.add(
            fill,
            forKey: OnboardingStrings.AnimationKeys.ringFill.value())
    }
}

/// A staged fingertip: a soft translucent disc that lands, presses, and lifts.
final class OnboardingMockTapIndicatorView: UIView {
    override init(frame: CGRect) {
        super.init(frame: CGRect(x: 0, y: 0, width: 54, height: 54))
        isUserInteractionEnabled = false
        accessibilityIdentifier =
            OnboardingStrings.Accessibility.messagesMockTap.value()
        backgroundColor = UIColor.white.withAlphaComponent(0.38)
        layer.cornerRadius = 27
        layer.borderWidth = 1
        layer.borderColor = UIColor.white.withAlphaComponent(0.7).cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.30
        layer.shadowRadius = 10
        layer.shadowOffset = .zero
        alpha = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Lands on `point`, squeezing `pressTarget` while down.
    func play(
        at point: CGPoint,
        in host: UIView,
        pressing island: OnboardingDynamicIslandRunView?,
        completion: @escaping () -> Void
    ) {
        center = point
        host.addSubview(self)

        if UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.15, animations: { self.alpha = 1 }) { _ in
                UIView.animate(
                    withDuration: 0.15,
                    delay: 0.2,
                    animations: { self.alpha = 0 }
                ) { _ in
                    self.removeFromSuperview()
                    completion()
                }
            }
            return
        }

        transform = CGAffineTransform(scaleX: 1.6, y: 1.6)
        UIView.animate(
            withDuration: 0.16,
            delay: 0,
            options: [.curveEaseOut]
        ) {
            self.alpha = 0.95
            self.transform = .identity
        } completion: { _ in
            island?.pressDown()
            UIView.animate(
                withDuration: 0.22,
                delay: 0.14,
                options: [.curveEaseIn]
            ) {
                self.alpha = 0
                self.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
            } completion: { _ in
                island?.release()
                self.removeFromSuperview()
                completion()
            }
        }
    }
}

/// The mock "Read in Luna" action-extension presentation: the standard
/// extension sheet slides up over the conversation with the scrolling reader
/// inside, showing the same article the Safari mock just cleaned up.
///
/// The header matches the real extension's compact reader chrome
/// (`ReaderViewController` under a nav controller): Done on the left, the mode
/// switcher in the title slot, read-aloud on the right. It uses the SAME
/// `LunaSegmentedControl` and `ReaderModeIcons` the reader does, so the mock
/// can't drift from the screen it is impersonating. Two segments, not three:
/// the action extension persists no page archive, so `.original` is never
/// offered there (`ReaderViewController.baseModes`).
final class OnboardingActionExtensionSheetView: UIView {
    private let scrim = UIView()
    private let card = UIView()
    private let grabber = UIView()
    private let doneChip = UILabel()
    private let modeControl = LunaSegmentedControl()
    private let audioButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let bylineLabel = UILabel()
    private let eclipseImage = UIImageView()
    private let bodyLabel = UILabel()
    private let bottomFade = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityIdentifier =
            OnboardingStrings.Accessibility.messagesExtensionSheet.value()

        scrim.backgroundColor = UIColor.black.withAlphaComponent(0.42)
        scrim.alpha = 0
        addSubview(scrim)

        card.backgroundColor = .black
        card.layer.cornerRadius = 24
        card.layer.cornerCurve = .continuous
        card.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        card.clipsToBounds = true
        addSubview(card)

        grabber.backgroundColor = UIColor.white.withAlphaComponent(0.28)
        grabber.layer.cornerRadius = 2.5
        card.addSubview(grabber)

        // A nav-bar Done: plain tinted text on the leading edge, not a chip.
        doneChip.text = OnboardingStrings.Instruction.done.value()
        doneChip.font = .systemFont(ofSize: 17, weight: .semibold)
        doneChip.textColor = GlassStyle.readingAccent
        doneChip.textAlignment = .left
        card.addSubview(doneChip)

        for (index, mode) in Self.extensionReaderModes.enumerated() {
            modeControl.insertSegment(
                with: ReaderModeIcons.image(for: mode), at: index, animated: false)
        }
        // The extension opens in the scrolling reader unless its own last-used
        // mode says otherwise; the demonstration always shows that first open.
        modeControl.selectedSegmentIndex = 0
        card.addSubview(modeControl)

        // Read-aloud rests off, exactly as it does on a freshly opened article.
        audioButton.setImage(
            UIImage(systemName: "speaker.slash"), for: .normal)
        audioButton.tintColor = GlassStyle.readingAccent
        card.addSubview(audioButton)

        titleLabel.text = OnboardingLunaArticleCopy.title
        titleLabel.font = .systemFont(ofSize: 27, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 2
        card.addSubview(titleLabel)

        bylineLabel.text = OnboardingLunaArticleCopy.byline
        bylineLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        bylineLabel.textColor = UIColor.white.withAlphaComponent(0.55)
        card.addSubview(bylineLabel)

        if let path = Bundle.main.path(
            forResource: "LunaEclipseComposite", ofType: "jpg")
        {
            eclipseImage.image = UIImage(contentsOfFile: path)
        }
        eclipseImage.contentMode = .scaleAspectFill
        eclipseImage.layer.cornerRadius = 12
        eclipseImage.layer.cornerCurve = .continuous
        eclipseImage.clipsToBounds = true
        card.addSubview(eclipseImage)

        let style = NSMutableParagraphStyle()
        style.lineSpacing = 5
        bodyLabel.attributedText = NSAttributedString(
            string: OnboardingLunaArticleCopy.plainText,
            attributes: [
                .font: UIFont.systemFont(ofSize: 17),
                .foregroundColor: UIColor.white.withAlphaComponent(0.92),
                .paragraphStyle: style,
            ])
        bodyLabel.numberOfLines = 0
        card.addSubview(bodyLabel)

        // The article continues past the sheet; a fade says "scrollable".
        bottomFade.colors = [
            UIColor.black.withAlphaComponent(0).cgColor,
            UIColor.black.cgColor,
        ]
        bottomFade.locations = [0, 1]
        card.layer.addSublayer(bottomFade)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The top edge of the presented card.
    private static let cardTop: CGFloat = 66

    /// What the action extension's reader offers. It persists no page archive,
    /// so `.original` never appears there.
    private static let extensionReaderModes: [ReadingListItem.ReaderMode] =
        [.scroll, .rsvp]

    override func layoutSubviews() {
        super.layoutSubviews()
        scrim.frame = bounds
        // The card animates via its transform (present/dismiss slides), and a
        // layout pass can land mid-animation — setting `frame` on a
        // transformed view corrupts its geometry (that read as the sheet
        // "popping" to the top mid-dismiss). bounds+center are transform-safe.
        card.bounds = CGRect(
            x: 0,
            y: 0,
            width: bounds.width,
            height: bounds.height - Self.cardTop)
        card.center = CGPoint(
            x: bounds.midX,
            y: Self.cardTop + card.bounds.height / 2)
        grabber.frame = CGRect(
            x: (card.bounds.width - 36) / 2, y: 6, width: 36, height: 5)
        let inset: CGFloat = 24
        let width = card.bounds.width - inset * 2
        // One nav-bar row: Done leading, mode switcher centred, audio trailing.
        let barMidY: CGFloat = 34
        doneChip.frame = CGRect(x: 16, y: barMidY - 12, width: 70, height: 24)
        let modeSize = modeControl.intrinsicContentSize
        modeControl.frame = CGRect(
            x: (card.bounds.width - modeSize.width) / 2,
            y: barMidY - modeSize.height / 2,
            width: modeSize.width,
            height: modeSize.height)
        audioButton.frame = CGRect(
            x: card.bounds.width - 16 - 34, y: barMidY - 17,
            width: 34, height: 34)
        titleLabel.frame = CGRect(
            x: inset, y: barMidY + 26, width: width, height: 66)
        bylineLabel.frame = CGRect(
            x: inset, y: titleLabel.frame.maxY + 6, width: width, height: 18)
        eclipseImage.frame = CGRect(
            x: inset,
            y: bylineLabel.frame.maxY + 14,
            width: width,
            height: (width * 708 / 1920).rounded())
        bodyLabel.frame = CGRect(
            x: inset,
            y: eclipseImage.frame.maxY + 14,
            width: width,
            height: card.bounds.height - eclipseImage.frame.maxY - 14)
        bottomFade.frame = CGRect(
            x: 0,
            y: card.bounds.height - 96,
            width: card.bounds.width,
            height: 96)
    }

    func present(completion: @escaping () -> Void) {
        layoutIfNeeded()
        if UIAccessibility.isReduceMotionEnabled {
            alpha = 0
            UIView.animate(withDuration: 0.22, animations: {
                self.alpha = 1
                self.scrim.alpha = 1
            }) { _ in completion() }
            return
        }
        card.transform = CGAffineTransform(
            translationX: 0, y: bounds.height - Self.cardTop)
        UIView.animate(
            withDuration: OnboardingShortcutRunTiming.sheetPresentDuration,
            delay: 0,
            usingSpringWithDamping: 0.88,
            initialSpringVelocity: 0.3,
            options: [.curveEaseOut, .beginFromCurrentState]
        ) {
            self.card.transform = .identity
        } completion: { _ in
            completion()
        }
        UIView.animate(withDuration: 0.30) {
            self.scrim.alpha = 1
        }
    }

    func dismiss(completion: @escaping () -> Void) {
        if UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.22, animations: {
                self.alpha = 0
            }) { _ in completion() }
            return
        }
        UIView.animate(
            withDuration: OnboardingShortcutRunTiming.sheetDismissDuration,
            delay: 0,
            options: [.curveEaseIn, .beginFromCurrentState]
        ) {
            self.card.transform = CGAffineTransform(
                translationX: 0, y: self.bounds.height - Self.cardTop)
            self.scrim.alpha = 0
        } completion: { _ in
            completion()
        }
    }
}

/// The mock app switcher: two full-screen snapshots become side-by-side cards,
/// slide across, and the incoming one grows back to full screen.
final class OnboardingAppSwitcherView: UIView {
    private let fromCard = UIImageView()
    private let toCard = UIImageView()
    private static let cardCornerRadius: CGFloat = 42
    private static let cardScale: CGFloat = 0.58
    private static let cardSlide: CGFloat = 0.85

    init(frame: CGRect, from: UIImage, to: UIImage) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityIdentifier = OnboardingStrings.Accessibility.messagesAppSwitcher.value()
        backgroundColor = .black

        for (card, image) in [(fromCard, from), (toCard, to)] {
            card.image = image
            card.frame = bounds
            card.contentMode = .scaleToFill
            card.clipsToBounds = true
            card.layer.cornerCurve = .continuous
            addSubview(card)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The outgoing screen shrinks and exits left; the incoming one slides in
    /// from the right and fills the screen.
    func playForward(completion: @escaping () -> Void) {
        play(from: fromCard, to: toCard, direction: 1, completion: completion)
    }

    /// The reverse hop, back to the original screen.
    func playBackward(completion: @escaping () -> Void) {
        play(from: toCard, to: fromCard, direction: -1, completion: completion)
    }

    private func play(
        from outgoing: UIImageView,
        to incoming: UIImageView,
        direction: CGFloat,
        completion: @escaping () -> Void
    ) {
        bringSubviewToFront(incoming)

        if UIAccessibility.isReduceMotionEnabled {
            incoming.transform = .identity
            incoming.alpha = 0
            outgoing.transform = .identity
            outgoing.alpha = 1
            UIView.animate(withDuration: 0.25, animations: {
                incoming.alpha = 1
            }) { _ in completion() }
            return
        }

        let scale = Self.cardScale
        let slide = bounds.width * Self.cardSlide * direction
        let shrink = CGAffineTransform(scaleX: scale, y: scale)

        outgoing.alpha = 1
        outgoing.transform = .identity
        outgoing.layer.cornerRadius = 0
        incoming.alpha = 1
        incoming.transform = CGAffineTransform(translationX: slide, y: 0)
            .scaledBy(x: scale, y: scale)
        incoming.layer.cornerRadius = Self.cardCornerRadius

        animateCornerRadius(of: outgoing, to: Self.cardCornerRadius, duration: 0.28)
        UIView.animateKeyframes(
            withDuration: OnboardingShortcutRunTiming.appSwitchDuration,
            delay: 0,
            options: [.calculationModeCubic]
        ) {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.38) {
                outgoing.transform = shrink
            }
            UIView.addKeyframe(withRelativeStartTime: 0.24, relativeDuration: 0.52) {
                outgoing.transform = CGAffineTransform(
                    translationX: -slide, y: 0
                ).scaledBy(x: scale, y: scale)
                incoming.transform = shrink
            }
            UIView.addKeyframe(withRelativeStartTime: 0.66, relativeDuration: 0.34) {
                incoming.transform = .identity
            }
        } completion: { _ in
            outgoing.alpha = 0
            completion()
        }
        animateCornerRadius(
            of: incoming,
            to: 0,
            duration: 0.30,
            delay: OnboardingShortcutRunTiming.appSwitchDuration * 0.66)
    }

    private func animateCornerRadius(
        of card: UIImageView,
        to radius: CGFloat,
        duration: CFTimeInterval,
        delay: CFTimeInterval = 0
    ) {
        let corner = CABasicAnimation(keyPath: "cornerRadius")
        corner.fromValue = card.layer.cornerRadius
        corner.toValue = radius
        corner.duration = duration
        corner.beginTime = delay == 0 ? 0 : CACurrentMediaTime() + delay
        corner.fillMode = .both
        corner.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        card.layer.cornerRadius = radius
        card.layer.add(
            corner,
            forKey: OnboardingStrings.AnimationKeys.switcherCorner.value())
    }
}

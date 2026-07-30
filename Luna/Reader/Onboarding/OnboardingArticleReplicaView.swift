//
//  OnboardingArticleReplicaView.swift
//  Luna
//

import LunaDesignSystem
import UIKit

private enum OnboardingArticleReplicaPalette {
    static let background = UIColor(
        red: 0.31, green: 0.32, blue: 0.34, alpha: 1)
    static let popover = UIColor(white: 0.12, alpha: 0.985)
}

enum OnboardingArticleReplicaTiming {
    static let headlineRevealDuration: TimeInterval = 1.05
    static let bodyRevealDuration: TimeInterval = 0.92
    static let componentDelay: TimeInterval = 0.22
    static let popoverDuration: TimeInterval = 0.48
    static let shatterDuration: TimeInterval = 0.86
}

/// Luna's fictional Safari article. It is native instead of HTML so the
/// glyph-level eclipse reveals begin only once the full-screen takeover has
/// completed; preloading the Safari replica cannot consume the sequence.
final class OnboardingArticleReplicaView: UIView {
    static let fullArticleText = """
    Your article, your browsing history, and every page you save stay private. Luna strips away subscription popups, sticky ads, autoplay distractions, and the clutter that gets between you and the story. Unlock supported articles, keep clean copies for flights and dead zones, search everything you have saved, and return to the exact piece you wanted without retracing your browsing history. Read in a calm scrolling view or switch to the RSVP speed reader when you want to move quickly. Inline web sections preserve the useful context of the original page while the focused reader keeps the surrounding noise out of your way. Save links from Safari, Messages, the Share Sheet, Shortcuts, or the Action Button; organise them once and find them on every return. Send finished articles to Kindle, preserve useful documents, and keep the original link close whenever you need it. Luna handles ordinary stories, paywalled articles, PDFs, and other documents in the same reading list, so research does not disappear across a pile of open tabs. Search your collection instead of your browser history, revisit a clean offline copy on the train or in the air, and choose the reading pace that suits the moment. The extension works where you already browse, and one press is enough to move something worth keeping into a quieter place. Nothing needs an account just to build your own reading list, and the pages you keep remain yours to revisit offline.
    """

    var onSetUpSafari: (() -> Void)?
    var onSkipForNow: (() -> Void)?

    private let appIcon = MoonRevealImageView(
        image: OnboardingAppIcon.image()
            ?? UIImage(systemName: "moon.stars.fill"),
        occluderColor: OnboardingArticleReplicaPalette.background)
    private let headline = MoonRevealLineView(
        text: "A better way to read on the web",
        font: UIFont.systemFont(ofSize: 29, weight: .bold),
        textAlignment: .left,
        numberOfLines: 2,
        minimumScaleFactor: 0.82,
        occluderColor: OnboardingArticleReplicaPalette.background)
    private let byline = MoonRevealLineView(
        text: "A safari extension • by Luna",
        font: .systemFont(ofSize: 13, weight: .semibold),
        textAlignment: .left,
        numberOfLines: 1,
        minimumScaleFactor: 0.9,
        occluderColor: OnboardingArticleReplicaPalette.background)
    private let body = MoonRevealLineView(
        text: "",
        font: .systemFont(ofSize: 17, weight: .regular),
        textAlignment: .left,
        numberOfLines: 0,
        minimumScaleFactor: 1,
        lineSpacing: 5,
        occluderColor: OnboardingArticleReplicaPalette.background)
    private let banner = OnboardingAnnoyingBannerView()
    private let popover = UIView()
    private let popoverTitle = UILabel()
    private let popoverText = UILabel()
    private let setupButton = UIButton(type: .system)
    private let skipButton = UIButton(type: .system)
    private var didStart = false
    private var hasShatteredClutter = false
    private var fittedArticlePrefix = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = OnboardingArticleReplicaPalette.background
        accessibilityIdentifier = "onboarding.safari.lunaArticle"

        appIcon.accessibilityIdentifier = "onboarding.safari.article.appIcon"
        headline.accessibilityIdentifier = "onboarding.safari.article.headline"
        body.accessibilityIdentifier = "onboarding.safari.article.body"
        banner.accessibilityIdentifier = "onboarding.safari.article.banner"
        popover.accessibilityIdentifier = "onboarding.safari.article.popover"
        popoverTitle.accessibilityIdentifier = "onboarding.safari.article.popoverTitle"
        popoverText.accessibilityIdentifier = "onboarding.safari.article.popoverText"

        addSubview(appIcon)
        addSubview(headline)

        byline.accessibilityIdentifier = "onboarding.safari.article.byline"
        addSubview(byline)
        addSubview(body)

        popover.backgroundColor = OnboardingArticleReplicaPalette.popover
        popover.layer.cornerRadius = 30
        popover.layer.cornerCurve = .continuous
        popover.layer.borderWidth = 2
        popover.layer.borderColor = UIColor.white.withAlphaComponent(0.34).cgColor
        popover.layer.shadowColor = UIColor.black.cgColor
        popover.layer.shadowOpacity = 0.72
        popover.layer.shadowRadius = 30
        popover.layer.shadowOffset = CGSize(width: 0, height: 18)

        popoverTitle.text = "Automatically remove subscription popups"
        popoverTitle.font = .systemFont(ofSize: 27, weight: .bold)
        popoverTitle.textColor = .white
        popoverTitle.textAlignment = .center
        popoverTitle.numberOfLines = 2
        popoverTitle.adjustsFontSizeToFitWidth = true
        popoverTitle.minimumScaleFactor = 0.82
        popover.addSubview(popoverTitle)

        popover.addSubview(banner)

        popoverText.text =
            "Offline and private, Luna’s extension makes a better internet"
        popoverText.font = .systemFont(ofSize: 20, weight: .medium)
        popoverText.textColor = .white
        popoverText.textAlignment = .center
        popoverText.numberOfLines = 3
        popoverText.adjustsFontSizeToFitWidth = true
        popoverText.minimumScaleFactor = 0.88
        popover.addSubview(popoverText)

        setupButton.configuration = GlassStyle.actionButtonConfiguration(
            title: "Activate now",
            symbol: "safari.fill",
            prominent: true)
        setupButton.accessibilityLabel = "Activate now"
        setupButton.accessibilityIdentifier = "onboarding.safari.article.setupButton"
        setupButton.addTarget(
            self, action: #selector(setUpSafariTapped), for: .touchUpInside)
        popover.addSubview(setupButton)

        var skipConfiguration = UIButton.Configuration.plain()
        skipConfiguration.title = "Skip for now"
        skipConfiguration.baseForegroundColor = UIColor.white.withAlphaComponent(0.62)
        skipConfiguration.contentInsets = NSDirectionalEdgeInsets(
            top: 8, leading: 14, bottom: 8, trailing: 14)
        skipConfiguration.titleTextAttributesTransformer =
            UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.font = .systemFont(ofSize: 16, weight: .medium)
                return outgoing
            }
        skipButton.configuration = skipConfiguration
        skipButton.accessibilityLabel = "Skip for now"
        skipButton.accessibilityIdentifier = "onboarding.safari.article.skipButton"
        skipButton.addTarget(
            self, action: #selector(skipForNowTapped), for: .touchUpInside)
        popover.addSubview(skipButton)
        addSubview(popover)

        popover.alpha = 0
        popover.transform = CGAffineTransform(
            translationX: 0, y: 26).scaledBy(x: 0.72, y: 0.72)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        let horizontalInset: CGFloat = 24
        let contentWidth = bounds.width - horizontalInset * 2
        let browserChromeTop = bounds.height
            - SafariBottomBar.chromeHeight
            - 34
        let urlBarTop = browserChromeTop + 7

        appIcon.frame = CGRect(x: horizontalInset, y: 31, width: 68, height: 68)
        headline.frame = CGRect(
            x: appIcon.frame.maxX + 16,
            y: 27,
            width: bounds.width - appIcon.frame.maxX - horizontalInset - 16,
            height: 78)
        byline.frame = CGRect(
            x: horizontalInset,
            y: max(appIcon.frame.maxY, headline.frame.maxY) + 12,
            width: contentWidth,
            height: 22)
        let bodyY = byline.frame.maxY + 14
        let bodyBottom = urlBarTop - 8
        body.frame = CGRect(
            x: horizontalInset,
            y: bodyY,
            width: contentWidth,
            height: max(bodyBottom - bodyY, 44))
        popover.frame = CGRect(
            x: 16,
            y: 140,
            width: bounds.width - 32,
            height: min(510, max(440, urlBarTop - 170)))
        popoverTitle.frame = CGRect(
            x: 24, y: 25, width: popover.bounds.width - 48, height: 76)
        banner.frame = CGRect(
            x: 24,
            y: popoverTitle.frame.maxY + 14,
            width: popover.bounds.width - 48,
            height: 68)
        popoverText.frame = CGRect(
            x: 28,
            y: banner.frame.maxY + 22,
            width: popover.bounds.width - 56,
            height: 92)
        let skipSize = skipButton.sizeThatFits(CGSize(
            width: popover.bounds.width - 48, height: 48))
        skipButton.frame = CGRect(
            x: 24,
            y: popover.bounds.height - max(40, skipSize.height) - 18,
            width: popover.bounds.width - 48,
            height: max(40, skipSize.height))
        let buttonSize = setupButton.sizeThatFits(CGSize(
            width: popover.bounds.width - 48, height: 64))
        let buttonWidth = min(
            popover.bounds.width - 48,
            max(154, buttonSize.width))
        setupButton.frame = CGRect(
            x: (popover.bounds.width - buttonWidth) / 2,
            y: skipButton.frame.minY - max(54, buttonSize.height) - 8,
            width: buttonWidth,
            height: max(54, buttonSize.height))

        if !hasShatteredClutter {
            let prefix = Self.prefix(
                of: Self.fullArticleText,
                fitting: body.bounds.size,
                font: .systemFont(ofSize: 17, weight: .regular))
            if prefix != fittedArticlePrefix {
                fittedArticlePrefix = prefix
                body.setText(prefix)
            }
        }
    }

    func start(completion: @escaping () -> Void) {
        guard !didStart else {
            completion()
            return
        }
        didStart = true
        layoutIfNeeded()

        appIcon.reveal(
            duration: OnboardingArticleReplicaTiming.headlineRevealDuration)
        headline.reveal(
            duration: OnboardingArticleReplicaTiming.headlineRevealDuration
        ) { [weak self] in
            self?.afterComponentDelay {
                guard let self else { return }
                self.byline.reveal(
                    duration: OnboardingArticleReplicaTiming.bodyRevealDuration,
                    completion: {})
                self.body.reveal(
                    duration: OnboardingArticleReplicaTiming.bodyRevealDuration
                ) { [weak self] in
                    self?.afterComponentDelay {
                        self?.showPopover(completion: completion)
                    }
                }
            }
        }
    }

    private func showPopover(completion: @escaping () -> Void) {
        UIView.animate(
            withDuration: UIAccessibility.isReduceMotionEnabled
                ? 0.2 : OnboardingArticleReplicaTiming.popoverDuration,
            delay: 0,
            usingSpringWithDamping: 0.7,
            initialSpringVelocity: 0.35,
            options: [.curveEaseOut, .beginFromCurrentState]
        ) {
            self.popover.alpha = 1
            self.popover.transform = .identity
        } completion: { _ in
            completion()
        }
    }

    /// A radial wave reaches the composite obstruction, turning it into image
    /// tiles that keep the front's momentum as they scatter and dissolve.
    func shatterClutter(
        waveOriginInWindow: CGPoint,
        window: UIWindow,
        completion: @escaping () -> Void
    ) {
        guard !hasShatteredClutter else {
            completion()
            return
        }
        hasShatteredClutter = true
        setupButton.isUserInteractionEnabled = false
        skipButton.isUserInteractionEnabled = false
        let origin = convert(waveOriginInWindow, from: window)
        let ring = makeCleanupWave(origin: origin)
        layer.addSublayer(ring)

        let popupFinish = shatter(
            popover, columns: 6, rows: 8, waveOrigin: origin)
        DispatchQueue.main.asyncAfter(deadline: .now() + popupFinish) {
            ring.removeFromSuperlayer()
            self.body.setText(Self.fullArticleText)
            self.setNeedsLayout()
            self.layoutIfNeeded()
            completion()
        }
    }

    func restoreSetupPrompt() {
        hasShatteredClutter = false
        body.setText(fittedArticlePrefix)
        popover.isHidden = false
        popover.alpha = 1
        popover.transform = .identity
        setupButton.isUserInteractionEnabled = true
        skipButton.isUserInteractionEnabled = true
        setNeedsLayout()
    }

    private func makeCleanupWave(origin: CGPoint) -> CAShapeLayer {
        let farthest = hypot(
            max(origin.x, bounds.width - origin.x),
            max(origin.y, bounds.height - origin.y))
        let ring = CAShapeLayer()
        ring.bounds = bounds
        ring.anchorPoint = CGPoint(
            x: origin.x / max(bounds.width, 1),
            y: origin.y / max(bounds.height, 1))
        ring.position = origin
        ring.fillColor = UIColor.clear.cgColor
        ring.strokeColor = UIColor.white.withAlphaComponent(0.72).cgColor
        ring.lineWidth = 4
        ring.path = UIBezierPath(
            ovalIn: CGRect(
                x: origin.x - farthest,
                y: origin.y - farthest,
                width: farthest * 2,
                height: farthest * 2)).cgPath
        ring.transform = CATransform3DMakeScale(0.001, 0.001, 1)
        ring.opacity = 0

        let scale = CABasicAnimation(keyPath: "transform")
        scale.fromValue = CATransform3DMakeScale(0.001, 0.001, 1)
        scale.toValue = CATransform3DIdentity
        scale.duration = OnboardingArticleReplicaTiming.shatterDuration
        scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 0.9, 0]
        fade.keyTimes = [0, 0.2, 1]
        fade.duration = scale.duration
        ring.add(scale, forKey: "cleanupWaveScale")
        ring.add(fade, forKey: "cleanupWaveFade")
        return ring
    }

    @discardableResult
    private func shatter(
        _ target: UIView,
        columns: Int,
        rows: Int,
        waveOrigin: CGPoint
    ) -> TimeInterval {
        guard let snapshot = snapshot(of: target), let image = snapshot.cgImage
        else {
            target.isHidden = true
            return 0
        }
        let targetFrame = convert(target.bounds, from: target)
        let maximumDistance = hypot(bounds.width, bounds.height)
        var pieces: [(UIView, TimeInterval, CGAffineTransform)] = []

        for row in 0..<rows {
            for column in 0..<columns {
                let unit = CGRect(
                    x: CGFloat(column) / CGFloat(columns),
                    y: CGFloat(row) / CGFloat(rows),
                    width: 1 / CGFloat(columns),
                    height: 1 / CGFloat(rows))
                let frame = CGRect(
                    x: targetFrame.minX + unit.minX * targetFrame.width,
                    y: targetFrame.minY + unit.minY * targetFrame.height,
                    width: unit.width * targetFrame.width + 0.5,
                    height: unit.height * targetFrame.height + 0.5)
                let piece = UIView(frame: frame)
                piece.isUserInteractionEnabled = false
                piece.layer.contents = image
                piece.layer.contentsGravity = .resize
                piece.layer.contentsRect = unit
                piece.layer.contentsScale = snapshot.scale
                piece.layer.cornerRadius = 1.5
                addSubview(piece)

                let delta = CGPoint(
                    x: frame.midX - waveOrigin.x,
                    y: frame.midY - waveOrigin.y)
                let distance = max(hypot(delta.x, delta.y), 1)
                let delay = TimeInterval(distance / maximumDistance)
                    * OnboardingArticleReplicaTiming.shatterDuration * 0.68
                let direction = CGPoint(
                    x: delta.x / distance,
                    y: delta.y / distance)
                let parity: CGFloat = (row + column).isMultiple(of: 2) ? 1 : -1
                let transform = CGAffineTransform(
                    translationX: direction.x * 86 + 42,
                    y: direction.y * 86 + parity * 18)
                    .rotated(by: parity * (0.28 + CGFloat(column % 3) * 0.11))
                    .scaledBy(x: 0.72, y: 0.72)
                pieces.append((piece, delay, transform))
            }
        }

        let firstDelay = pieces.map(\.1).min() ?? 0
        DispatchQueue.main.asyncAfter(deadline: .now() + firstDelay) {
            target.isHidden = true
        }
        let pieceDuration = OnboardingArticleReplicaTiming.shatterDuration * 0.54
        for (piece, delay, transform) in pieces {
            UIView.animate(
                withDuration: UIAccessibility.isReduceMotionEnabled
                    ? 0.18 : pieceDuration,
                delay: UIAccessibility.isReduceMotionEnabled ? 0 : delay,
                options: [.curveEaseOut, .beginFromCurrentState]
            ) {
                piece.transform = transform
                piece.alpha = 0
            } completion: { _ in
                piece.removeFromSuperview()
            }
        }
        return (pieces.map(\.1).max() ?? 0) + pieceDuration
    }

    private func snapshot(of view: UIView) -> UIImage? {
        guard view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = traitCollection.displayScale
        format.opaque = false
        return UIGraphicsImageRenderer(
            bounds: view.bounds, format: format
        ).image { context in
            view.layer.render(in: context.cgContext)
        }
    }

    private static func prefix(
        of text: String,
        fitting size: CGSize,
        font: UIFont
    ) -> String {
        let words = text.split(separator: " ")
        guard !words.isEmpty, size.width > 0, size.height > 0 else { return "" }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: {
                let style = NSMutableParagraphStyle()
                style.lineSpacing = 5
                return style
            }(),
        ]
        var lower = 0
        var upper = words.count
        while lower < upper {
            let candidateCount = (lower + upper + 1) / 2
            let candidate = words.prefix(candidateCount).joined(separator: " ")
            let measured = (candidate as NSString).boundingRect(
                with: CGSize(width: size.width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes,
                context: nil)
            if measured.height <= size.height {
                lower = candidateCount
            } else {
                upper = candidateCount - 1
            }
        }
        return words.prefix(lower).joined(separator: " ")
    }

    @objc private func setUpSafariTapped() {
        setupButton.isUserInteractionEnabled = false
        skipButton.isUserInteractionEnabled = false
        onSetUpSafari?()
    }

    @objc private func skipForNowTapped() {
        setupButton.isUserInteractionEnabled = false
        skipButton.isUserInteractionEnabled = false
        onSkipForNow?()
    }

    private func afterComponentDelay(_ action: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(
            deadline: .now() + OnboardingAnimationClock.delay(
                OnboardingArticleReplicaTiming.componentDelay),
            execute: action)
    }
}

/// The article icon uses the same descending lunar edge as the nearby title.
/// Its image alpha is geometrically excluded inside the moon, while a narrow
/// luminous rim echoes the title's glyph-edge bloom.
private final class MoonRevealImageView: UIView {
    private let imageView = UIImageView()
    private let moonLayer = CAShapeLayer()
    private let revealMaskLayer = CAShapeLayer()
    private let rimLayer = CAShapeLayer()
    private let occluderColor: UIColor
    private var initialCircleFrame = CGRect.zero
    private var didReveal = false

    init(image: UIImage?, occluderColor: UIColor) {
        self.occluderColor = occluderColor
        super.init(frame: .zero)
        clipsToBounds = true
        isAccessibilityElement = false
        accessibilityLabel = "Luna"

        imageView.image = image
        imageView.contentMode = .scaleAspectFill
        imageView.layer.cornerRadius = 17
        imageView.layer.cornerCurve = .continuous
        imageView.clipsToBounds = true
        addSubview(imageView)

        revealMaskLayer.fillColor = UIColor.white.cgColor
        revealMaskLayer.fillRule = .evenOdd
        imageView.layer.mask = revealMaskLayer

        moonLayer.fillColor = occluderColor.cgColor
        layer.addSublayer(moonLayer)

        rimLayer.fillColor = UIColor.clear.cgColor
        rimLayer.strokeColor = UIColor.white.withAlphaComponent(0.88).cgColor
        rimLayer.lineWidth = 2.5
        rimLayer.shadowColor = UIColor.white.cgColor
        rimLayer.shadowOpacity = 0.9
        rimLayer.shadowRadius = 7
        rimLayer.shadowOffset = .zero
        layer.addSublayer(rimLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
        guard !didReveal, bounds.width > 0, bounds.height > 0 else { return }
        prepareLayers()
    }

    func reveal(duration: TimeInterval, completion: @escaping () -> Void = {}) {
        guard !didReveal else {
            completion()
            return
        }
        layoutIfNeeded()
        didReveal = true
        let travel = bounds.maxY + 6 - initialCircleFrame.minY
        let finalCircle = initialCircleFrame.offsetBy(dx: 0, dy: travel)
        let transform = CATransform3DMakeTranslation(0, travel, 0)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        moonLayer.transform = transform
        rimLayer.transform = transform
        revealMaskLayer.path = revealPath(excluding: finalCircle)
        CATransaction.commit()

        let resolvedDuration = UIAccessibility.isReduceMotionEnabled ? 0.24 : duration
        for layer in [moonLayer, rimLayer] {
            let animation = CABasicAnimation(keyPath: "transform")
            animation.fromValue = CATransform3DIdentity
            animation.toValue = transform
            animation.duration = resolvedDuration
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            layer.add(animation, forKey: "moonReveal")
        }

        let maskAnimation = CABasicAnimation(keyPath: "path")
        maskAnimation.fromValue = revealPath(excluding: initialCircleFrame)
        maskAnimation.toValue = revealPath(excluding: finalCircle)
        maskAnimation.duration = resolvedDuration
        maskAnimation.timingFunction = CAMediaTimingFunction(name: .linear)
        revealMaskLayer.add(maskAnimation, forKey: "moonReveal")

        DispatchQueue.main.asyncAfter(
            deadline: .now() + OnboardingAnimationClock.delay(resolvedDuration)
        ) {
            self.imageView.layer.mask = nil
            self.moonLayer.removeFromSuperlayer()
            self.rimLayer.removeFromSuperlayer()
            self.isAccessibilityElement = true
            completion()
        }
    }

    private func prepareLayers() {
        let diameter = max(bounds.width * 8, 1_200)
        let radius = diameter / 2
        let halfWidth = bounds.width / 2
        let sagitta = radius - sqrt(max(radius * radius - halfWidth * halfWidth, 0))
        initialCircleFrame = CGRect(
            x: bounds.midX - radius,
            y: 4 - sagitta,
            width: diameter,
            height: diameter)
        let circle = UIBezierPath(ovalIn: initialCircleFrame).cgPath
        moonLayer.frame = bounds
        moonLayer.path = circle
        moonLayer.transform = CATransform3DIdentity
        rimLayer.frame = bounds
        rimLayer.path = circle
        rimLayer.transform = CATransform3DIdentity
        revealMaskLayer.frame = bounds
        revealMaskLayer.path = revealPath(excluding: initialCircleFrame)
    }

    private func revealPath(excluding circleFrame: CGRect) -> CGPath {
        let path = UIBezierPath(rect: bounds)
        path.append(UIBezierPath(ovalIn: circleFrame))
        path.usesEvenOddFillRule = true
        return path.cgPath
    }
}

private final class OnboardingAnnoyingBannerView: UIView {
    private let gradient = CAGradientLayer()
    private let radialStripes = CAShapeLayer()
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        clipsToBounds = true
        layer.borderWidth = 2
        layer.borderColor = UIColor.white.withAlphaComponent(0.92).cgColor

        gradient.colors = [
            UIColor(red: 1, green: 0.08, blue: 0.38, alpha: 1).cgColor,
            UIColor(red: 1, green: 0.55, blue: 0.02, alpha: 1).cgColor,
            UIColor(red: 0.95, green: 0.1, blue: 0.72, alpha: 1).cgColor,
        ]
        gradient.startPoint = CGPoint(x: 0, y: 0.25)
        gradient.endPoint = CGPoint(x: 1, y: 0.75)
        layer.insertSublayer(gradient, at: 0)

        radialStripes.fillColor = UIColor.white.withAlphaComponent(0.22).cgColor
        layer.insertSublayer(radialStripes, above: gradient)

        label.text = "And annoying ads"
        label.font = .systemFont(ofSize: 20, weight: .heavy)
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 2
        label.accessibilityIdentifier = "onboarding.safari.article.bannerText"
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = bounds
        layoutRadialStripes()
        label.frame = bounds.insetBy(dx: 20, dy: 8)
    }

    private func layoutRadialStripes() {
        let side = max(bounds.width, bounds.height) * 2.4
        radialStripes.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        radialStripes.position = CGPoint(x: bounds.midX, y: bounds.midY)

        let center = CGPoint(x: side / 2, y: side / 2)
        let radius = side * 0.7
        let stripeCount = 24
        let angle = CGFloat.pi * 2 / CGFloat(stripeCount)
        let path = UIBezierPath()
        for index in stride(from: 0, to: stripeCount, by: 2) {
            let start = -CGFloat.pi / 2 + CGFloat(index) * angle
            path.move(to: center)
            path.addArc(
                withCenter: center,
                radius: radius,
                startAngle: start,
                endAngle: start + angle,
                clockwise: true)
            path.close()
        }
        radialStripes.path = path.cgPath
    }

}

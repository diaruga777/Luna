//
//  OnboardingArticleReplicaView.swift
//  Luna
//

import LunaDesignSystem
import UIKit

private enum OnboardingArticleReplicaPalette {
    static let background = OnboardingPalette.background
    static let popover = UIColor(white: 0.12, alpha: 0.985)
}

enum OnboardingArticleReplicaTiming {
    static let headlineRevealDuration: TimeInterval = 1.05
    static let bodyRevealDuration: TimeInterval = 0.92
    static let componentDelay: TimeInterval = 0.22
    static let bannerDuration: TimeInterval = 0.52
    static let popoverDuration: TimeInterval = 0.48
    static let popoverTextRevealDuration: TimeInterval = 0.82
    static let shatterDuration: TimeInterval = 0.86
}

/// Luna's fictional Safari article. It is native instead of HTML so the
/// glyph-level eclipse reveals begin only once the full-screen takeover has
/// completed; preloading the Safari replica cannot consume the sequence.
final class OnboardingArticleReplicaView: UIView {
    static let fullArticleText = """
    Your article, your browsing history, and every page you save stay private. Luna strips away subscription popups, sticky ads, autoplay distractions, and the clutter that gets between you and the story. Unlock supported articles, keep clean copies for flights and dead zones, search everything you have saved, and return to the exact piece you wanted without retracing your browsing history. Read in a calm scrolling view or switch to the RSVP speed reader when you want to move quickly. Save links from Safari, Messages, the Share Sheet, Shortcuts, or the Action Button; organise them once and find them on every return. Send finished articles to Kindle, preserve useful documents, and keep the original link close whenever you need it. Nothing needs an account just to build your own reading list, and the pages you keep remain yours to revisit offline.
    """

    var onSetUpSafari: (() -> Void)?

    private let appIcon = UIImageView()
    private let byline = UILabel()
    private let headline = MoonRevealLineView(
        text: "A quieter way to read the web",
        font: UIFont.systemFont(ofSize: 29, weight: .bold),
        textAlignment: .left,
        numberOfLines: 2,
        minimumScaleFactor: 0.82,
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
    private let popoverAside = UILabel()
    private let popoverText = MoonRevealLineView(
        text: "Luna eliminates annoyances so you can read the things you want. Offline, private, one click away.",
        font: .systemFont(ofSize: 21, weight: .medium),
        textAlignment: .center,
        numberOfLines: 5,
        minimumScaleFactor: 0.86,
        occluderColor: OnboardingArticleReplicaPalette.popover)
    private let setupButton = UIButton(type: .system)
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

        appIcon.image = OnboardingAppIcon.image()
            ?? UIImage(systemName: "moon.stars.fill")
        appIcon.contentMode = .scaleAspectFill
        appIcon.layer.cornerRadius = 17
        appIcon.layer.cornerCurve = .continuous
        appIcon.clipsToBounds = true
        addSubview(appIcon)
        addSubview(headline)

        byline.text = "LUNA READER  ·  6 MIN READ"
        byline.font = .systemFont(ofSize: 11, weight: .bold)
        byline.textColor = UIColor.white.withAlphaComponent(0.58)
        byline.adjustsFontForContentSizeCategory = true
        addSubview(byline)
        addSubview(body)
        addSubview(banner)

        popover.backgroundColor = OnboardingArticleReplicaPalette.popover
        popover.layer.cornerRadius = 30
        popover.layer.cornerCurve = .continuous
        popover.layer.borderWidth = 2
        popover.layer.borderColor = UIColor.white.withAlphaComponent(0.34).cgColor
        popover.layer.shadowColor = UIColor.black.cgColor
        popover.layer.shadowOpacity = 0.72
        popover.layer.shadowRadius = 30
        popover.layer.shadowOffset = CGSize(width: 0, height: 18)

        popoverTitle.text = "Subscribe to keep reading"
        popoverTitle.font = .systemFont(ofSize: 29, weight: .bold)
        popoverTitle.textColor = .white
        popoverTitle.textAlignment = .center
        popoverTitle.adjustsFontSizeToFitWidth = true
        popoverTitle.minimumScaleFactor = 0.82
        popover.addSubview(popoverTitle)

        popoverAside.text = "…or not"
        popoverAside.font = .systemFont(ofSize: 19, weight: .semibold)
        popoverAside.textColor = UIColor.white.withAlphaComponent(0.74)
        popoverAside.textAlignment = .left
        popover.addSubview(popoverAside)

        popover.addSubview(popoverText)

        setupButton.configuration = GlassStyle.actionButtonConfiguration(
            title: "Set up Safari",
            symbol: "safari.fill",
            prominent: true)
        setupButton.accessibilityLabel = "Set up Safari"
        setupButton.accessibilityIdentifier = "onboarding.safari.article.setupButton"
        setupButton.addTarget(
            self, action: #selector(setUpSafariTapped), for: .touchUpInside)
        popover.addSubview(setupButton)
        addSubview(popover)

        // `isHidden` is deliberate: a transform alone can briefly expose the
        // banner while the preloaded view receives its first layout pass.
        banner.isHidden = true
        banner.alpha = 0
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
        let bannerHeight: CGFloat = 76
        let bannerY = urlBarTop - 8 - bannerHeight

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
            height: 18)
        let bodyY = byline.frame.maxY + 14
        let bodyBottom = hasShatteredClutter ? urlBarTop - 8 : bannerY - 16
        body.frame = CGRect(
            x: horizontalInset,
            y: bodyY,
            width: contentWidth,
            height: max(bodyBottom - bodyY, 44))
        banner.frame = CGRect(
            x: 15,
            y: bannerY,
            width: bounds.width - 30,
            height: bannerHeight)
        popover.frame = CGRect(
            x: 16,
            y: 151,
            width: bounds.width - 32,
            height: min(474, max(390, banner.frame.minY - 175)))
        popoverTitle.frame = CGRect(
            x: 24, y: 27, width: popover.bounds.width - 48, height: 44)
        popoverAside.frame = CGRect(
            x: 28, y: popoverTitle.frame.maxY + 18,
            width: popover.bounds.width - 56, height: 28)
        popoverText.frame = CGRect(
            x: 28,
            y: popoverAside.frame.maxY + 25,
            width: popover.bounds.width - 56,
            height: 150)
        let buttonSize = setupButton.sizeThatFits(CGSize(
            width: popover.bounds.width - 48, height: 64))
        let buttonWidth = min(
            popover.bounds.width - 48,
            max(154, buttonSize.width))
        setupButton.frame = CGRect(
            x: (popover.bounds.width - buttonWidth) / 2,
            y: popover.bounds.height - max(54, buttonSize.height) - 28,
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

        headline.reveal(
            duration: OnboardingArticleReplicaTiming.headlineRevealDuration
        ) { [weak self] in
            self?.afterComponentDelay {
                guard let self else { return }
                self.body.reveal(
                    duration: OnboardingArticleReplicaTiming.bodyRevealDuration
                ) { [weak self] in
                    self?.afterComponentDelay {
                        self?.slideBannerIn(completion: completion)
                    }
                }
            }
        }
    }

    private func slideBannerIn(completion: @escaping () -> Void) {
        banner.prepareForReveal()
        UIView.animate(
            withDuration: UIAccessibility.isReduceMotionEnabled
                ? 0.2 : OnboardingArticleReplicaTiming.bannerDuration,
            delay: 0,
            usingSpringWithDamping: 0.72,
            initialSpringVelocity: 0.55,
            options: [.curveEaseOut, .beginFromCurrentState]
        ) {
            self.banner.transform = .identity
        } completion: { [weak self] _ in
            self?.afterComponentDelay {
                self?.showPopover(completion: completion)
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
        } completion: { [weak self] _ in
            self?.afterComponentDelay {
                guard let self else { return }
                self.popoverText.reveal(
                    duration: OnboardingArticleReplicaTiming.popoverTextRevealDuration
                ) { [weak self] in
                    self?.afterComponentDelay {
                        self?.banner.stopAnimating()
                        completion()
                    }
                }
            }
        }
    }

    /// A left-edge wave reaches each obstruction at a different instant. The
    /// original views turn into image tiles at that front, then the tiles keep
    /// the wave's momentum as they scatter and dissolve.
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
        banner.stopAnimating()
        let origin = convert(waveOriginInWindow, from: window)
        let ring = makeCleanupWave(origin: origin)
        layer.addSublayer(ring)

        let popupFinish = shatter(
            popover, columns: 6, rows: 8, waveOrigin: origin)
        let bannerFinish = shatter(
            banner, columns: 8, rows: 2, waveOrigin: origin)
        let finishDelay = max(popupFinish, bannerFinish)
        DispatchQueue.main.asyncAfter(deadline: .now() + finishDelay) {
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
        banner.isHidden = false
        banner.alpha = 1
        banner.transform = .identity
        popover.isHidden = false
        popover.alpha = 1
        popover.transform = .identity
        setupButton.isUserInteractionEnabled = true
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
        onSetUpSafari?()
    }

    private func afterComponentDelay(_ action: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(
            deadline: .now() + OnboardingAnimationClock.delay(
                OnboardingArticleReplicaTiming.componentDelay),
            execute: action)
    }
}

private final class OnboardingAnnoyingBannerView: UIView {
    private let gradient = CAGradientLayer()
    private let radialStripes = CAShapeLayer()
    private let label = UILabel()
    private let close = UILabel()

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

        label.text = "Get rid of annoying ads!"
        label.font = .systemFont(ofSize: 21, weight: .heavy)
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 2
        label.accessibilityIdentifier = "onboarding.safari.article.bannerText"
        addSubview(label)

        close.text = "×"
        close.font = .systemFont(ofSize: 19, weight: .bold)
        close.textColor = UIColor.white.withAlphaComponent(0.9)
        close.textAlignment = .center
        addSubview(close)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = bounds
        layoutRadialStripes()
        label.frame = bounds.insetBy(dx: 34, dy: 8)
        close.frame = CGRect(x: bounds.width - 31, y: 5, width: 24, height: 24)
    }

    func prepareForReveal() {
        isHidden = false
        alpha = 1
        transform = CGAffineTransform(
            translationX: max(bounds.width + 40, 460), y: 0)
        startStripeRotationIfNeeded()
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

    private func startStripeRotationIfNeeded() {
        guard !UIAccessibility.isReduceMotionEnabled,
              radialStripes.animation(forKey: "radialStripeRotation") == nil
        else { return }
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = CGFloat.pi * 2
        rotation.duration = 7
        rotation.repeatCount = .infinity
        rotation.timingFunction = CAMediaTimingFunction(name: .linear)
        radialStripes.add(rotation, forKey: "radialStripeRotation")
    }

    func stopAnimating() {
        radialStripes.removeAnimation(forKey: "radialStripeRotation")
    }
}

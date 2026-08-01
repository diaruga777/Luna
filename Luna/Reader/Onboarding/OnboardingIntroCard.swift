//
//  OnboardingIntroCard.swift
//  Luna
//

import LunaDesignSystem
import UIKit
import UniformTypeIdentifiers

enum OnboardingAppIcon {
    static func image(bundle: Bundle = .main) -> UIImage? {
        let icons = bundle.object(forInfoDictionaryKey: "CFBundleIcons")
            as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        let iconFiles = primary?["CFBundleIconFiles"] as? [String] ?? []
        for name in iconFiles.reversed() {
            if let image = UIImage(named: name, in: bundle, compatibleWith: nil) {
                return image
            }
            guard let resources = bundle.resourceURL,
                  let entries = try? FileManager.default.contentsOfDirectory(
                    at: resources,
                    includingPropertiesForKeys: nil)
            else { continue }
            let candidates = entries.filter {
                $0.pathExtension == "png"
                    && $0.deletingPathExtension().lastPathComponent.hasPrefix(name)
            }
            if let path = candidates.first?.path,
               let image = UIImage(contentsOfFile: path)
            {
                return image
            }
        }
        return nil
    }
}

enum OnboardingIntroTiming {
    /// A brief settling beat after the splash starts its (near-instant) fade —
    /// enough to separate the reveal from the launch itself while still
    /// reading as immediate.
    static let firstLineDelay: TimeInterval = 0.15
    /// Both sentences use the same deliberate top-down lunar sweep.
    static let lineRevealDuration: TimeInterval = 1.55
    /// A short reading beat keeps the two sentences distinct without making the
    /// second feel like a separate stage.
    static let interLineDelay: TimeInterval = 0.15
}

final class OnboardingIntroCardContentViewController: CardContentViewController {
    var onSafari: (() -> Void)?
    var onShortcut: (() -> Void)?
    var onPaste: ((String) -> Void)?
    /// Fired when the first line's reveal completes — the host preloads the
    /// demonstration in the reading pause, never inside a reveal's own turn.
    var onFirstLineRevealed: (() -> Void)?

    private let firstLine: MoonRevealLineView
    private let secondLine: MoonRevealLineView
    private let safariButton = UIButton(type: .system)
    private let shortcutButton = UIButton(type: .system)
    private let pasteButton = OnboardingPasteControl()
    private let buttonStack = UIStackView()
    private var didStart = false
    private var safariCompleted = false
    private var shortcutCompleted = false

    init(
        firstLine: String,
        secondLine: String,
        supportingText _: String
    ) {
        self.firstLine = MoonRevealLineView(text: firstLine)
        self.secondLine = MoonRevealLineView(text: secondLine)
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.addSubview(firstLine)
        view.addSubview(secondLine)

        configure(
            safariButton,
            title: "Remove popups and walls for me",
            symbol: "safari.fill",
            action: #selector(safariTapped))
        configure(
            shortcutButton,
            title: "Save on-screen links with the Action Button",
            symbol: "bolt.fill",
            action: #selector(shortcutTapped))
        shortcutButton.configuration?.titleLineBreakMode = .byWordWrapping
        var shortcutAttributes = AttributeContainer()
        shortcutAttributes.font = .systemFont(ofSize: 13, weight: .semibold)
        shortcutButton.configuration?.attributedTitle = AttributedString(
            "Save on-screen links with the Action Button",
            attributes: shortcutAttributes)
        shortcutButton.titleLabel?.numberOfLines = 2
        if let shortcutIcon = UIImage(
            contentsOfFile: Bundle.main.path(
                forResource: "ShortcutsAppIcon", ofType: "png") ?? "")
        {
            shortcutButton.configuration?.image = Self.buttonIcon(shortcutIcon)
        }
        // Setup evidence is supplied before the carousel asks this controller
        // for its view, so restore completed artwork after configuring buttons.
        update(safariButton, completed: safariCompleted, symbol: "safari.fill")
        update(shortcutButton, completed: shortcutCompleted, symbol: "bolt.fill")

        pasteButton.onPaste = { [weak self] value in self?.onPaste?(value) }

        buttonStack.axis = .vertical
        buttonStack.spacing = 10
        buttonStack.alignment = .fill
        buttonStack.distribution = .fillEqually
        for action in [safariButton, shortcutButton, pasteButton] {
            action.alpha = 0
            action.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
            action.isUserInteractionEnabled = false
            if let button = action as? UIButton { button.isEnabled = false }
            buttonStack.addArrangedSubview(action)
        }
        view.addSubview(buttonStack)

        pasteConfiguration = UIPasteConfiguration(
            acceptableTypeIdentifiers: [
                UTType.url.identifier,
                UTType.plainText.identifier,
            ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let inset: CGFloat = 24
        let lineHeight: CGFloat = 44
        let gap: CGFloat = 3
        let contentTop = AppOnboardingLayout.contentTop(in: view.bounds)
        firstLine.frame = CGRect(
            x: inset, y: contentTop,
            width: view.bounds.width - inset * 2, height: lineHeight)
        secondLine.frame = CGRect(
            x: inset, y: firstLine.frame.maxY + gap,
            width: view.bounds.width - inset * 2, height: lineHeight)
        let stackWidth = view.bounds.width - inset * 2
        let buttonHeight: CGFloat = 56
        buttonStack.frame = CGRect(
            x: inset,
            y: view.bounds.height - buttonHeight * 3 - buttonStack.spacing * 2 - 24,
            width: stackWidth,
            height: buttonHeight * 3 + buttonStack.spacing * 2)
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        view.layoutIfNeeded()
        DispatchQueue.main.asyncAfter(
            deadline: .now() + OnboardingAnimationClock.delay(
                OnboardingIntroTiming.firstLineDelay)
        ) { [weak self] in
            guard let self else { return }
            self.revealFirstLine()
        }
    }

    private func revealFirstLine() {
        firstLine.reveal(
            duration: OnboardingIntroTiming.lineRevealDuration
        ) { [weak self] in
            guard let self else { return }
            self.onFirstLineRevealed?()
            DispatchQueue.main.asyncAfter(
                deadline: .now() + OnboardingAnimationClock.delay(
                    OnboardingIntroTiming.interLineDelay)
            ) { [weak self] in
                guard let self else { return }
                self.secondLine.reveal(
                    duration: OnboardingIntroTiming.lineRevealDuration
                ) { [weak self] in
                    guard let self else { return }
                    UIView.animate(
                        withDuration: 0.38,
                        delay: 0.16,
                        options: [.curveEaseOut, .beginFromCurrentState]
                    ) {
                        for action in self.buttonStack.arrangedSubviews {
                            action.alpha = 1
                            action.transform = .identity
                        }
                    } completion: { _ in
                        self.setActionsEnabled(true)
                        UIAccessibility.post(
                            notification: .layoutChanged,
                            argument: self.safariButton)
                    }
                }
            }
        }
    }

    func setCompleted(safari: Bool, shortcut: Bool) {
        safariCompleted = safari
        shortcutCompleted = shortcut
        update(safariButton, completed: safari, symbol: "safari.fill")
        update(shortcutButton, completed: shortcut, symbol: "bolt.fill")
    }

    func setActionsEnabled(_ enabled: Bool) {
        safariButton.isUserInteractionEnabled = true
        shortcutButton.isUserInteractionEnabled = true
        safariButton.isEnabled = enabled && !safariCompleted
        shortcutButton.isEnabled = enabled && !shortcutCompleted
        pasteButton.isUserInteractionEnabled = enabled
    }

    func setPasteLoading() {
        pasteButton.setState(.loading)
        safariButton.isEnabled = false
        shortcutButton.isEnabled = false
    }

    func setPasteError(_ message: String) {
        pasteButton.setState(.failure(message))
        safariButton.isEnabled = !safariCompleted
        shortcutButton.isEnabled = !shortcutCompleted
    }

    func resetPaste() {
        pasteButton.setState(.idle)
        safariButton.isEnabled = !safariCompleted
        shortcutButton.isEnabled = !shortcutCompleted
    }

    override func paste(itemProviders: [NSItemProvider]) {
        if let provider = itemProviders.first(where: {
            $0.canLoadObject(ofClass: URL.self)
        }) {
            _ = provider.loadObject(ofClass: URL.self) { [weak self] url, _ in
                guard let url else { return }
                DispatchQueue.main.async { self?.onPaste?(url.absoluteString) }
            }
            return
        }
        guard let provider = itemProviders.first(where: {
            $0.canLoadObject(ofClass: NSString.self)
        }) else {
            setPasteError("article URLs only")
            return
        }
        _ = provider.loadObject(ofClass: NSString.self) { [weak self] value, _ in
            guard let value = value as? NSString else { return }
            DispatchQueue.main.async { self?.onPaste?(value as String) }
        }
    }

    private func configure(
        _ button: UIButton,
        title: String,
        symbol: String,
        action: Selector
    ) {
        button.configuration = GlassStyle.actionButtonConfiguration(
            title: title, symbol: symbol, prominent: true)
        button.configuration?.baseBackgroundColor =
            LunaSurfacePalette.baseColor.withAlphaComponent(0.24)
        button.configuration?.imagePlacement = .leading
        button.configuration?.titleLineBreakMode = .byTruncatingTail
        button.accessibilityLabel = title
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    private func update(_ button: UIButton, completed: Bool, symbol: String) {
        button.isEnabled = !completed
        if completed {
            button.configuration?.image = UIImage(systemName: "checkmark.circle.fill")
            button.configuration?.baseForegroundColor = UIColor.white.withAlphaComponent(0.42)
            button.configuration?.baseBackgroundColor = UIColor.white.withAlphaComponent(0.08)
            button.accessibilityValue = "Completed"
        } else {
            button.configuration?.image = UIImage(systemName: symbol)
            if button === shortcutButton,
               let path = Bundle.main.path(forResource: "ShortcutsAppIcon", ofType: "png")
            {
                button.configuration?.image = UIImage(contentsOfFile: path).map {
                    Self.buttonIcon($0)
                }
            }
            button.configuration?.baseForegroundColor = LunaColors.primaryText
            button.configuration?.baseBackgroundColor =
                LunaSurfacePalette.baseColor.withAlphaComponent(0.24)
            button.accessibilityValue = nil
        }
    }

    @objc private func safariTapped() {
        setActionsEnabled(false)
        onSafari?()
    }

    @objc private func shortcutTapped() {
        setActionsEnabled(false)
        onShortcut?()
    }

    private static func buttonIcon(_ image: UIImage) -> UIImage {
        let size = CGSize(width: 22, height: 22)
        return UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }.withRenderingMode(.alwaysOriginal)
    }
}

private final class OnboardingPasteControl: UIView {
    enum State {
        case idle
        case loading
        case failure(String)
    }

    var onPaste: ((String) -> Void)?

    private let control: UIPasteControl
    private let surface = UIView()
    private let icon = UIImageView()
    private let label = UILabel()

    override init(frame: CGRect) {
        let configuration = UIPasteControl.Configuration()
        configuration.displayMode = .iconOnly
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor =
            LunaSurfacePalette.baseColor.withAlphaComponent(0.24)
        configuration.baseForegroundColor = .clear
        control = UIPasteControl(configuration: configuration)
        super.init(frame: frame)

        accessibilityIdentifier = "onboarding.intro.paste"
        control.target = nil
        control.accessibilityLabel = "Paste a url"
        // UIPasteControl remains the full-size hit target and native paste
        // dispatcher; its private artwork sits beneath our stateful surface.
        control.layer.opacity = 0
        addSubview(control)

        surface.backgroundColor =
            LunaSurfacePalette.baseColor.withAlphaComponent(0.34)
        surface.isUserInteractionEnabled = false
        surface.layer.zPosition = 10
        addSubview(surface)

        icon.image = UIImage(systemName: "doc.on.clipboard")
        icon.tintColor = LunaColors.primaryText
        icon.contentMode = .scaleAspectFit
        icon.isUserInteractionEnabled = false
        icon.layer.zPosition = 11
        addSubview(icon)

        label.text = "Paste a url"
        label.textColor = LunaColors.primaryText
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textAlignment = .center
        label.isUserInteractionEnabled = false
        label.layer.zPosition = 11
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let target = next as? UIViewController {
                control.target = target
                break
            }
            responder = next
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        control.frame = bounds
        surface.frame = bounds
        surface.layer.cornerRadius = bounds.height / 2
        let contentWidth = min(bounds.width - 32, 210)
        let iconSide: CGFloat = 20
        let gap: CGFloat = 8
        let labelSize = label.sizeThatFits(CGSize(
            width: contentWidth - iconSide - gap, height: bounds.height))
        let totalWidth = iconSide + gap + labelSize.width
        icon.frame = CGRect(
            x: (bounds.width - totalWidth) / 2,
            y: (bounds.height - iconSide) / 2,
            width: iconSide,
            height: iconSide)
        label.frame = CGRect(
            x: icon.frame.maxX + gap,
            y: 0,
            width: labelSize.width,
            height: bounds.height)
    }

    func setState(_ state: State) {
        switch state {
        case .idle:
            label.text = "Paste a url"
            icon.image = UIImage(systemName: "doc.on.clipboard")
            surface.backgroundColor =
                LunaSurfacePalette.baseColor.withAlphaComponent(0.34)
            control.isEnabled = true
        case .loading:
            label.text = "Loading page…"
            icon.image = UIImage(systemName: "arrow.triangle.2.circlepath")
            surface.backgroundColor =
                LunaSurfacePalette.baseColor.withAlphaComponent(0.22)
            control.isEnabled = false
        case .failure(let message):
            label.text = message
            icon.image = UIImage(systemName: "exclamationmark.triangle.fill")
            surface.backgroundColor = LunaColors.errorAccent
            control.isEnabled = true
        }
        control.accessibilityLabel = label.text
        setNeedsLayout()
    }
}

/// A borderless black circle hides the unrevealed text against the black card.
/// Its exact outer edge also drives a raster light pass clipped to the glyph
/// alpha. Every newly exposed antialiased glyph pixel becomes an additive white
/// emitter with stacked near, middle, and wide halos, then cools rapidly back
/// to normal white as the edge moves away.
final class MoonRevealLineView: UIView {
    private let clippedContent = UIView()
    private let finalLabel = UILabel()
    private let illuminationMaskLabel = UILabel()
    private let moonLayer = CAShapeLayer()
    private let revealMaskLayer = CAShapeLayer()
    private let pixelBloomView = GlyphPixelBloomView()
    private let lineSpacing: CGFloat
    private let occluderColor: UIColor
    /// The intro's moon descends; the article's bottom-to-top wave asks for
    /// the mirror: the circle covers everything ABOVE its bottom arc and
    /// climbs, exposing the view from the bottom up with the same light.
    private let sweepsUpward: Bool
    private var didStartReveal = false
    private var initialCircleFrame = CGRect.zero
    private var edgeSagitta: CGFloat = 0
    private(set) var isFullyRevealed: Bool

    /// The distance the front travels while crossing this view: from the
    /// wide arc's edge first touching the top to its highest point clearing
    /// the bottom. A shared sweep divides this by its front speed so every
    /// element's edge moves at exactly the front's own pace.
    var revealFrontCrossingDistance: CGFloat {
        bounds.height + 2 + edgeSagitta
    }

    var occluderHasVisibleChrome: Bool {
        moonLayer.borderWidth > 0
            || moonLayer.lineWidth > 0
            || moonLayer.strokeColor != nil
            || moonLayer.shadowOpacity > 0
    }

    var occluderIsFullyOpaque: Bool {
        moonLayer.opacity == 1
            && moonLayer.fillColor?.alpha == 1
            && revealMaskLayer.fillColor?.alpha == 1
    }

    var usesGlyphEdgeIllumination: Bool {
        pixelBloomView.usesRasterizedGlyphPixels
            && pixelBloomView.usesStackedAdditiveHalos
    }

    init(
        text: String,
        initiallyRevealed: Bool = false,
        font: UIFont = .systemFont(ofSize: 25, weight: .semibold),
        textAlignment: NSTextAlignment = .center,
        numberOfLines: Int = 1,
        minimumScaleFactor: CGFloat = 0.72,
        lineSpacing: CGFloat = 0,
        occluderColor: UIColor = .black,
        sweepsUpward: Bool = false
    ) {
        self.lineSpacing = lineSpacing
        self.occluderColor = occluderColor
        self.sweepsUpward = sweepsUpward
        self.isFullyRevealed = initiallyRevealed
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        clipsToBounds = false
        isAccessibilityElement = initiallyRevealed
        accessibilityLabel = text

        clippedContent.clipsToBounds = true
        clippedContent.isUserInteractionEnabled = false
        addSubview(clippedContent)

        for label in [finalLabel, illuminationMaskLabel] {
            label.font = font
            label.textColor = .white
            label.textAlignment = textAlignment
            label.numberOfLines = numberOfLines
            label.lineBreakMode = .byWordWrapping
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = minimumScaleFactor
            label.isAccessibilityElement = false
            apply(text: text, to: label)
        }
        clippedContent.addSubview(finalLabel)

        guard !initiallyRevealed else { return }
        installOcclusion()
    }

    private func installOcclusion() {
        moonLayer.fillColor = occluderColor.cgColor
        moonLayer.opacity = 1
        moonLayer.strokeColor = nil
        moonLayer.lineWidth = 0
        moonLayer.shadowOpacity = 0
        clippedContent.layer.addSublayer(moonLayer)

        // The ordinary text is geometrically absent inside the circle. This is
        // stronger than painting black over subpixel-antialiased white glyphs:
        // there is no covered glyph alpha available to bleed through.
        revealMaskLayer.fillColor = UIColor.white.cgColor
        revealMaskLayer.fillRule = .evenOdd
        revealMaskLayer.opacity = 1
        finalLabel.layer.mask = revealMaskLayer

        // This view owns a padded backing store so the light is not cropped to
        // the label bounds. Its source image is the actual rasterized glyph
        // alpha, not a whole-label or whole-word approximation.
        pixelBloomView.isUserInteractionEnabled = false
        addSubview(pixelBloomView)
    }

    /// Returns an already-visible line to its occluded state so `reveal` can
    /// play again — the cleanup pass re-reveals content that loaded plainly.
    func prepareToRevealAgain() {
        guard isFullyRevealed || didStartReveal else { return }
        isFullyRevealed = false
        didStartReveal = false
        isAccessibilityElement = false
        installOcclusion()
        setNeedsLayout()
        layoutIfNeeded()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        clippedContent.frame = bounds
        finalLabel.frame = bounds
        guard !isFullyRevealed, !didStartReveal, bounds.width > 0, bounds.height > 0
        else { return }
        prepareRevealLayers()
    }

    func reveal(duration: TimeInterval, completion: @escaping () -> Void) {
        guard !isFullyRevealed else {
            completion()
            return
        }
        guard !didStartReveal else { return }
        didStartReveal = true
        layoutIfNeeded()
        let travel = revealFrontCrossingDistance
        let signedTravel = sweepsUpward ? -travel : travel
        let resolvedDuration = UIAccessibility.isReduceMotionEnabled ? 0.24 : duration
        let transform = CATransform3DMakeTranslation(0, signedTravel, 0)
        let finalCircleFrame = initialCircleFrame.offsetBy(dx: 0, dy: signedTravel)
        let initialRevealPath = revealPath(excluding: initialCircleFrame)
        let finalRevealPath = revealPath(excluding: finalCircleFrame)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        moonLayer.transform = transform
        revealMaskLayer.path = finalRevealPath
        CATransaction.commit()

        // No explicit beginTime: a zero beginTime is stamped when the
        // animation reaches the render tree, so a rendering backlog can never
        // start the sweep already partway through its duration.
        let moonAnimation = CABasicAnimation(keyPath: "transform")
        moonAnimation.fromValue = CATransform3DIdentity
        moonAnimation.toValue = transform
        moonAnimation.duration = resolvedDuration
        moonAnimation.timingFunction = CAMediaTimingFunction(name: .linear)
        moonAnimation.isRemovedOnCompletion = true
        moonLayer.add(moonAnimation, forKey: "moonReveal")

        // The bloom's cooling distance rides the front's speed: however fast
        // the edge travels, every glyph spends the same TIME brightened and
        // fading back as the intro line's glyphs do — the article-body sweep
        // is ~9× faster than the intro's, so its bands stretch ~9× further.
        // The light's position is slaved to the moon layer's presentation
        // translation, so it can never run ahead of or behind the mask edge.
        let frontSpeed = travel / CGFloat(max(resolvedDuration, 0.001))
        pixelBloomView.reveal(
            circleTravel: signedTravel,
            duration: OnboardingAnimationClock.displayLinkDuration(
                resolvedDuration),
            edgeBandScale: max(
                1, frontSpeed / GlyphPixelBloomView.referenceFrontSpeed),
            offsetProvider: { [weak moonLayer] in
                moonLayer?.presentation().map { CGFloat($0.transform.m42) }
            })

        let revealAnimation = CABasicAnimation(keyPath: "path")
        revealAnimation.fromValue = initialRevealPath
        revealAnimation.toValue = finalRevealPath
        revealAnimation.duration = resolvedDuration
        revealAnimation.timingFunction = CAMediaTimingFunction(name: .linear)
        revealAnimation.isRemovedOnCompletion = true
        revealMaskLayer.add(revealAnimation, forKey: "opaqueGlyphReveal")

        DispatchQueue.main.asyncAfter(
            deadline: .now() + OnboardingAnimationClock.delay(resolvedDuration)
        ) { [weak self] in
            guard let self else { return }
            self.isFullyRevealed = true
            self.isAccessibilityElement = true
            self.finalLabel.layer.mask = nil
            self.moonLayer.removeFromSuperlayer()
            self.pixelBloomView.stop()
            self.pixelBloomView.removeFromSuperview()
            completion()
        }
    }

    func setText(_ text: String) {
        apply(text: text, to: finalLabel)
        apply(text: text, to: illuminationMaskLabel)
        accessibilityLabel = text
        if !didStartReveal {
            setNeedsLayout()
        }
    }

    private func apply(text: String, to label: UILabel) {
        guard lineSpacing > 0 else {
            label.attributedText = nil
            label.text = text
            return
        }
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.alignment = label.textAlignment
        style.lineBreakMode = label.lineBreakMode
        label.attributedText = NSAttributedString(
            string: text,
            attributes: [
                .font: label.font as Any,
                .foregroundColor: label.textColor as Any,
                .paragraphStyle: style,
            ])
    }

    private func prepareRevealLayers() {
        // A very large circle makes the segment crossing the text nearly
        // horizontal while preserving a real circular distance field.
        let diameter = max(bounds.width * 8, 1_200)
        let radius = diameter / 2
        let halfWidth = bounds.width / 2
        let sagitta = radius - sqrt(max(radius * radius - halfWidth * halfWidth, 0))
        edgeSagitta = sagitta
        // At the line's extreme left/right the edge begins one point outside
        // the view (above for the descending moon, below for the climbing
        // one), so no antialiased pixel leaks out early and the reveal
        // starts exactly as its front reaches the view.
        let initialTop = sweepsUpward
            ? bounds.height + 1 + sagitta - diameter
            : -1 - sagitta
        let circleFrame = CGRect(
            x: bounds.midX - radius,
            y: initialTop,
            width: diameter,
            height: diameter)
        initialCircleFrame = circleFrame
        let circlePath = UIBezierPath(ovalIn: circleFrame).cgPath

        moonLayer.frame = bounds
        moonLayer.path = circlePath
        moonLayer.transform = CATransform3DIdentity

        revealMaskLayer.frame = finalLabel.bounds
        revealMaskLayer.path = revealPath(excluding: circleFrame)

        illuminationMaskLabel.frame = bounds
        illuminationMaskLabel.layoutIfNeeded()

        let padding = GlyphPixelBloomView.renderPadding
        pixelBloomView.frame = bounds.insetBy(dx: -padding, dy: -padding)
        pixelBloomView.configure(
            glyphLabel: illuminationMaskLabel,
            glyphFrame: CGRect(
                x: padding,
                y: padding,
                width: bounds.width,
                height: bounds.height),
            circleFrame: circleFrame.offsetBy(dx: padding, dy: padding),
            scale: traitCollection.displayScale)
    }

    private func revealPath(excluding circleFrame: CGRect) -> CGPath {
        let path = UIBezierPath(rect: bounds)
        path.append(UIBezierPath(ovalIn: circleFrame))
        path.usesEvenOddFillRule = true
        return path.cgPath
    }
}

/// Draws the transient light separately from the ordinary text.
///
/// The emitter is rebuilt at display cadence by intersecting the descending
/// circle's narrow trailing bands with a native-scale raster of the glyphs.
/// Quartz shadows are then applied to that exact alpha image in additive passes.
/// Keeping the padded result in its own view lets the glow illuminate pixels
/// around the letters instead of being clipped back to the text mask.
///
/// Internal (not private): the mock Safari article's images ride the same
/// light pass, fed a raster of the image instead of glyph alpha.
final class GlyphPixelBloomView: UIView {
    struct EdgeBand {
        let inner: CGFloat
        let outer: CGFloat
        let alpha: CGFloat
    }

    struct HaloPass {
        let radius: CGFloat
        let alpha: CGFloat
    }

    static let renderPadding: CGFloat = 42

    /// The intro line's edge speed (its travel over its reveal duration).
    /// Faster sweeps scale the falloff distances up by speed/reference so a
    /// glyph's brighten-and-cool takes the same TIME at any front speed.
    static let referenceFrontSpeed: CGFloat = 46

    private static let edgeFalloff = [
        EdgeBand(inner: 0, outer: 1.75, alpha: 1.00),
        EdgeBand(inner: 1.75, outer: 4.00, alpha: 0.72),
        EdgeBand(inner: 4.00, outer: 7.25, alpha: 0.32),
        EdgeBand(inner: 7.25, outer: 10.50, alpha: 0.09),
    ]

    // Several optically additive passes are intentional. A single CALayer
    // shadow reads as soft text; stacked scales produce a clipped white core,
    // a dense local flare that erases legibility, and a broad low-frequency
    // wash like the first visible edge of the sun.
    private static let haloPasses = [
        HaloPass(radius: 30, alpha: 0.72),
        HaloPass(radius: 30, alpha: 0.72),
        HaloPass(radius: 18, alpha: 0.90),
        HaloPass(radius: 18, alpha: 0.90),
        HaloPass(radius: 10, alpha: 1.00),
        HaloPass(radius: 10, alpha: 1.00),
        HaloPass(radius: 5, alpha: 1.00),
        HaloPass(radius: 2, alpha: 1.00),
    ]

    private var glyphImage: UIImage?
    private var glyphFrame = CGRect.zero
    private var initialCircleFrame = CGRect.zero
    private var circleTravel: CGFloat = 0
    private var progress: CGFloat = 0
    private var revealStartTime: CFTimeInterval = 0
    private var revealDuration: CFTimeInterval = 0
    private var displayLink: CADisplayLink?
    private var emitterRenderer: UIGraphicsImageRenderer?
    private var edgeSagitta: CGFloat = 0
    private var edgeBandScale: CGFloat = 1
    private var rasterScale: CGFloat = 1
    private var offsetProvider: (() -> CGFloat?)?
    private var didSampleOffset = false
    /// Per-pass alpha for the additive passes. Thin glyph strokes want the
    /// full 1 — their saturation to a white core is the intro's look. A
    /// dense raster (a photograph) saturates even its mid-tones under eight
    /// additive passes and reads as a white slab; its owner lowers the gain
    /// so only genuinely bright pixels reach white heat.
    private var emitterGain: CGFloat = 1

    var usesRasterizedGlyphPixels: Bool {
        glyphImage != nil && !glyphFrame.isEmpty
    }

    var usesStackedAdditiveHalos: Bool {
        Self.haloPasses.count >= 3
            && Self.haloPasses.first?.radius == 30
            && Self.haloPasses.last?.radius == 2
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        displayLink?.invalidate()
    }

    func configure(
        glyphLabel: UILabel,
        glyphFrame: CGRect,
        circleFrame: CGRect,
        scale: CGFloat
    ) {
        let glyphFormat = UIGraphicsImageRendererFormat()
        glyphFormat.scale = scale
        glyphFormat.opaque = false
        let glyphRenderer = UIGraphicsImageRenderer(
            size: glyphLabel.bounds.size,
            format: glyphFormat)
        configure(
            raster: glyphRenderer.image { _ in
                glyphLabel.drawText(in: glyphLabel.bounds)
            },
            rasterFrame: glyphFrame,
            circleFrame: circleFrame,
            scale: scale)
    }

    /// The general emitter form: any raster works as the light source — the
    /// additive passes brighten wherever it has luminance, so an image's
    /// bright pixels flare exactly the way glyph alpha does.
    func configure(
        raster: UIImage,
        rasterFrame: CGRect,
        circleFrame: CGRect,
        scale: CGFloat
    ) {
        glyphImage = raster
        glyphFrame = rasterFrame
        initialCircleFrame = circleFrame
        rasterScale = scale
        progress = 0

        let radius = circleFrame.width / 2
        let halfWidth = bounds.width / 2
        edgeSagitta = radius - sqrt(max(radius * radius - halfWidth * halfWidth, 0))
        setNeedsDisplay()
    }

    /// The widest cooling distance for the current front speed.
    private var scaledFalloffReach: CGFloat {
        (Self.edgeFalloff.last?.outer ?? 12) * edgeBandScale
    }

    /// The emitting band: everything within the falloff distance outside the
    /// edge, plus the bow of the near-flat arc across the view's width.
    private var stripHeight: CGFloat {
        scaledFalloffReach + edgeSagitta + 12
    }

    private func currentStripRect() -> CGRect {
        // The bands trail the moving edge: above a descending circle's top
        // arc, below a climbing one's bottom arc.
        let circle = initialCircleFrame.offsetBy(
            dx: 0, dy: circleTravel * progress)
        let y = circleTravel < 0
            ? circle.maxY - edgeSagitta - 8
            : circle.minY - scaledFalloffReach - 4
        return CGRect(
            x: 0,
            y: y,
            width: bounds.width,
            height: stripHeight)
    }

    /// `offsetProvider` slaves the light to the occluder itself: it returns
    /// the moon layer's current *presentation* translation, so the emitting
    /// band sits exactly on the rendered edge no matter how the clocks
    /// drift — light lagging its own mask is what read as "the text appears,
    /// then brightens in chunks". Without a provider the band falls back to
    /// wall-clock progress anchored at the first display-link tick.
    func reveal(
        circleTravel: CGFloat,
        duration: CFTimeInterval,
        edgeBandScale: CGFloat = 1,
        emitterGain: CGFloat = 1,
        offsetProvider: (() -> CGFloat?)? = nil
    ) {
        stop()
        self.circleTravel = circleTravel
        self.edgeBandScale = max(edgeBandScale, 1)
        self.emitterGain = min(max(emitterGain, 0.05), 1)
        self.offsetProvider = offsetProvider
        didSampleOffset = false
        revealDuration = max(duration, 0.001)
        // Anchored by the first display-link tick, not by this call: when a
        // heavy transaction separates the call from the first rendered frame,
        // a wall-clock anchor would start the light already cooled.
        revealStartTime = 0
        progress = 0

        // Only a strip around the circle's leading edge ever emits light (the
        // bands hug the edge), so the per-frame render is a strip, not the
        // whole view. A view-height emitter made the display link collapse on
        // article-length text: whole lines never got their bright moment
        // because the frame rate fell to a handful of samples. The strip is
        // sized here because the falloff reach depends on the front's speed.
        let emitterFormat = UIGraphicsImageRendererFormat()
        emitterFormat.scale = rasterScale
        emitterFormat.opaque = false
        emitterRenderer = UIGraphicsImageRenderer(
            size: CGSize(width: bounds.width, height: stripHeight),
            format: emitterFormat)
        setNeedsDisplay()

        let displayLink = CADisplayLink(
            target: self,
            selector: #selector(drawNextRevealFrame(_:)))
        displayLink.preferredFrameRateRange = CAFrameRateRange(
            minimum: 30,
            maximum: 120,
            preferred: 60)
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        offsetProvider = nil
    }

    override func draw(_ rect: CGRect) {
        guard let emitter = makeEmitterImage(),
              let context = UIGraphicsGetCurrentContext()
        else { return }

        context.saveGState()
        context.setBlendMode(.plusLighter)
        for halo in Self.haloPasses {
            context.saveGState()
            context.setShadow(
                offset: .zero,
                blur: halo.radius,
                color: UIColor.white
                    .withAlphaComponent(halo.alpha * emitterGain).cgColor)
            emitter.image.draw(
                in: emitter.rect,
                blendMode: .plusLighter,
                alpha: emitterGain)
            context.restoreGState()
        }
        context.restoreGState()
    }

    @objc private func drawNextRevealFrame(_ link: CADisplayLink) {
        if revealStartTime == 0 { revealStartTime = link.timestamp }
        let previousStrip = currentStripRect()
        if let offsetProvider {
            if let offset = offsetProvider() {
                didSampleOffset = true
                // Signed travel: an upward sweep translates negatively, and
                // the ratio of matching signs keeps progress in 0...1.
                let divisor = abs(circleTravel) >= 1
                    ? circleTravel
                    : (circleTravel < 0 ? -1 : 1)
                progress = min(max(offset / divisor, 0), 1)
            } else {
                // nil before the occluder's animation is committed, and again
                // after it is removed: not-yet-started vs finished.
                progress = didSampleOffset ? 1 : 0
            }
        } else {
            let elapsed = link.timestamp - revealStartTime
            progress = min(max(CGFloat(elapsed / revealDuration), 0), 1)
        }
        // Redraw covers where the glow was and where it is now — the widest
        // halo included — so old light is cleared without repainting the view.
        let glowReach = (Self.haloPasses.map(\.radius).max() ?? 30) + 4
        setNeedsDisplay(
            previousStrip
                .union(currentStripRect())
                .insetBy(dx: -glowReach, dy: -glowReach))
        if progress >= 1 {
            stop()
        }
    }

    private func makeEmitterImage() -> (image: UIImage, rect: CGRect)? {
        guard let glyphImage, let emitterRenderer else { return nil }
        let circleFrame = initialCircleFrame.offsetBy(
            dx: 0,
            dy: circleTravel * progress)
        let strip = currentStripRect()

        let image = emitterRenderer.image { rendererContext in
            let context = rendererContext.cgContext
            context.translateBy(x: -strip.minX, y: -strip.minY)
            for band in Self.edgeFalloff {
                context.saveGState()
                let ring = UIBezierPath(
                    ovalIn: circleFrame.insetBy(
                        dx: -band.outer * edgeBandScale,
                        dy: -band.outer * edgeBandScale))
                ring.append(UIBezierPath(
                    ovalIn: circleFrame.insetBy(
                        dx: -band.inner * edgeBandScale,
                        dy: -band.inner * edgeBandScale)))
                ring.usesEvenOddFillRule = true
                context.addPath(ring.cgPath)
                context.clip(using: .evenOdd)
                glyphImage.draw(
                    in: glyphFrame,
                    blendMode: .normal,
                    alpha: band.alpha)
                context.restoreGState()
            }
        }
        return (image, strip)
    }
}

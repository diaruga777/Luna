//
//  SafariReplicaViewController.swift
//  Luna
//

import CoreImage
import LunaDesignSystem
import UIKit
import WebKit

/// A deliberately noninteractive Safari facsimile used only by Reader
/// onboarding. The real page bytes are local; the browser chrome remains
/// native UIKit so it has the current OS's typography, glass, safe-area and
/// status-bar behavior.
@MainActor
final class SafariReplicaViewController: UIViewController {
    var onSetUpSafari: (() -> Void)?
    var onInstallShortcut: (() -> Void)?
    var onSetActionButton: (() -> Void)?
    var onSetUpLater: (() -> Void)?

    private let webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isUserInteractionEnabled = false
        view.scrollView.isScrollEnabled = false
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.backgroundColor = .white
        view.isOpaque = true
        return view
    }()

    private let browserBar = SafariBottomBar()
    private var instructionOverlay: DemoInstructionOverlay?
    private var actionCue: ActionButtonPressCue?
    private var waveAnimator: LiquidScreenWaveAnimator?
    private var didBeginDemonstration = false

    override var preferredStatusBarStyle: UIStatusBarStyle { .darkContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white
        configureBrowser()
        loadOfflinePage()
    }

    private func configureBrowser() {
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        browserBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(browserBar)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            browserBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            browserBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            browserBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            browserBar.heightAnchor.constraint(
                equalToConstant: SafariBottomBar.chromeHeight + 34),
        ])
    }

    private func loadOfflinePage() {
        guard let url = Bundle.main.url(
            forResource: "LunaWikipedia", withExtension: "html")
        else {
            webView.loadHTMLString(Self.fallbackHTML, baseURL: nil)
            return
        }
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    /// Starts only after the incoming card has expanded to the screen. Keeping
    /// the timeline explicit prevents the Action Button cue from playing while
    /// the browser is still changing geometry.
    func beginDemonstration() {
        guard !didBeginDemonstration else { return }
        didBeginDemonstration = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            self?.playActionButtonCue()
        }
    }

    private func playActionButtonCue() {
        guard let window = view.window else { return }
        let cue = ActionButtonPressCue()
        actionCue = cue
        window.addSubview(cue)
        cue.layout(in: window)
        cue.play { [weak self, weak cue] in
            cue?.removeFromSuperview()
            self?.actionCue = nil
            self?.playLiquidWave()
        }
    }

    private func playLiquidWave() {
        guard let window = view.window else {
            showSafariPrompt()
            return
        }
        let animator = LiquidScreenWaveAnimator(window: window)
        waveAnimator = animator
        animator.play(originY: window.safeAreaInsets.top + 104) { [weak self] in
            self?.waveAnimator = nil
            self?.showSafariPrompt()
        }
    }

    func showSafariPrompt() {
        setInstruction(
            title: "Press the Action Button to save\nRead offline later",
            actions: [
                .init(
                    title: "Set up Safari",
                    image: UIImage(systemName: "safari.fill"),
                    prominent: true,
                    action: { [weak self] in self?.onSetUpSafari?() }),
            ])
    }

    func showShortcutAndActionSetup() {
        setInstruction(
            title: nil,
            actions: [
                .init(
                    title: "Install Shortcut",
                    image: OnboardingSystemIcons.shortcuts,
                    prominent: true,
                    action: { [weak self] in self?.onInstallShortcut?() }),
                .init(
                    title: "Set action button",
                    image: OnboardingSystemIcons.actionButton,
                    prominent: false,
                    action: { [weak self] in self?.onSetActionButton?() }),
            ])
    }

    func showWaitingForActionButton() {
        setInstruction(
            title: "Press the action button to finish",
            actions: [
                .init(
                    title: "Set up later",
                    image: UIImage(systemName: "clock"),
                    prominent: false,
                    action: { [weak self] in self?.onSetUpLater?() }),
            ])
    }

    func dismissInstructions(animated: Bool, completion: @escaping () -> Void) {
        guard let overlay = instructionOverlay else {
            completion()
            return
        }
        instructionOverlay = nil
        let changes = {
            overlay.alpha = 0
            overlay.transform = CGAffineTransform(scaleX: 0.97, y: 0.97)
        }
        if animated, !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(
                withDuration: 0.28, delay: 0,
                options: [.curveEaseInOut],
                animations: changes,
                completion: { _ in
                    overlay.removeFromSuperview()
                    completion()
                })
        } else {
            changes()
            overlay.removeFromSuperview()
            completion()
        }
    }

    private func setInstruction(
        title: String?,
        actions: [DemoInstructionOverlay.Action]
    ) {
        let overlay = instructionOverlay ?? DemoInstructionOverlay()
        overlay.configure(title: title, actions: actions)
        if instructionOverlay == nil {
            instructionOverlay = overlay
            overlay.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(overlay)
            NSLayoutConstraint.activate([
                overlay.topAnchor.constraint(equalTo: view.topAnchor),
                overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            overlay.alpha = 0
            overlay.transform = CGAffineTransform(scaleX: 0.97, y: 0.97)
            UIView.animate(
                withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.34,
                delay: 0,
                options: [.curveEaseOut, .beginFromCurrentState]
            ) {
                overlay.alpha = 1
                overlay.transform = .identity
            }
        }
    }

    private static let fallbackHTML = """
    <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
    <style>body{font:17px -apple-system;margin:24px;color:#202122}h1{font:36px Georgia}</style>
    <h1>Luna</h1><p><b>Luna</b> commonly refers to Earth’s Moon and the ancient
    Roman personification of the Moon.</p><h2>Offline</h2>
    <p>This page is bundled with Luna Reader for its onboarding demonstration.</p>
    """
}

// MARK: - Safari chrome

private final class SafariBottomBar: UIView {
    static let chromeHeight: CGFloat = 58

    private let backdrop = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialLight))
    private let backForward = UIVisualEffectView(effect: GlassStyle.barEffect())
    private let address = UIVisualEffectView(effect: GlassStyle.barEffect())
    private let more = UIVisualEffectView(effect: GlassStyle.barEffect())

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear

        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.alpha = 0.78
        addSubview(backdrop)

        for glass in [backForward, address, more] {
            glass.translatesAutoresizingMaskIntoConstraints = false
            if #available(iOS 26.0, *) {
                glass.cornerConfiguration = .capsule()
            } else {
                glass.layer.cornerRadius = 23
                glass.layer.cornerCurve = .continuous
                glass.clipsToBounds = true
            }
            addSubview(glass)
        }

        let back = icon("chevron.backward", alpha: 0.32)
        let forward = icon("chevron.forward", alpha: 0.16)
        let nav = UIStackView(arrangedSubviews: [back, forward])
        nav.axis = .horizontal
        nav.alignment = .center
        nav.distribution = .fillEqually
        nav.translatesAutoresizingMaskIntoConstraints = false
        backForward.contentView.addSubview(nav)

        let page = icon("text.justify.leading", alpha: 0.86)
        let host = UILabel()
        host.text = "en.wikipedia.org"
        host.font = .systemFont(ofSize: 16, weight: .semibold)
        host.textColor = UIColor(white: 0.10, alpha: 1)
        host.textAlignment = .center
        let reload = icon("arrow.clockwise", alpha: 0.82)
        let addressStack = UIStackView(arrangedSubviews: [page, host, reload])
        addressStack.axis = .horizontal
        addressStack.alignment = .center
        addressStack.spacing = 9
        addressStack.translatesAutoresizingMaskIntoConstraints = false
        address.contentView.addSubview(addressStack)
        page.widthAnchor.constraint(equalToConstant: 21).isActive = true
        reload.widthAnchor.constraint(equalToConstant: 21).isActive = true

        let ellipsis = icon("ellipsis", alpha: 0.9)
        ellipsis.translatesAutoresizingMaskIntoConstraints = false
        more.contentView.addSubview(ellipsis)

        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: topAnchor, constant: -12),
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),

            backForward.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 30),
            backForward.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            backForward.widthAnchor.constraint(equalToConstant: 76),
            backForward.heightAnchor.constraint(equalToConstant: 46),

            address.leadingAnchor.constraint(equalTo: backForward.trailingAnchor, constant: 8),
            address.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            address.heightAnchor.constraint(equalToConstant: 46),

            more.leadingAnchor.constraint(equalTo: address.trailingAnchor, constant: 8),
            more.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -30),
            more.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            more.widthAnchor.constraint(equalToConstant: 46),
            more.heightAnchor.constraint(equalToConstant: 46),

            nav.topAnchor.constraint(equalTo: backForward.contentView.topAnchor),
            nav.leadingAnchor.constraint(equalTo: backForward.contentView.leadingAnchor, constant: 4),
            nav.trailingAnchor.constraint(equalTo: backForward.contentView.trailingAnchor, constant: -4),
            nav.bottomAnchor.constraint(equalTo: backForward.contentView.bottomAnchor),

            addressStack.topAnchor.constraint(equalTo: address.contentView.topAnchor),
            addressStack.leadingAnchor.constraint(equalTo: address.contentView.leadingAnchor, constant: 13),
            addressStack.trailingAnchor.constraint(equalTo: address.contentView.trailingAnchor, constant: -13),
            addressStack.bottomAnchor.constraint(equalTo: address.contentView.bottomAnchor),

            ellipsis.centerXAnchor.constraint(equalTo: more.contentView.centerXAnchor),
            ellipsis.centerYAnchor.constraint(equalTo: more.contentView.centerYAnchor),
            ellipsis.widthAnchor.constraint(equalToConstant: 24),
            ellipsis.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func icon(_ symbol: String, alpha: CGFloat) -> UIImageView {
        let view = UIImageView(image: UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)))
        view.tintColor = UIColor(white: 0.06, alpha: alpha)
        view.contentMode = .center
        return view
    }
}

// MARK: - Instruction overlay

private final class DemoInstructionOverlay: UIView {
    struct Action {
        let title: String
        let image: UIImage?
        let prominent: Bool
        let action: () -> Void
    }

    private let scrim = UIView()
    private let panel = UIVisualEffectView(effect: GlassStyle.barEffect())
    private let titleLabel = UILabel()
    private let actionStack = UIStackView()
    private var buttons: [UIButton] = []
    private var handlers: [() -> Void] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        scrim.backgroundColor = UIColor.black.withAlphaComponent(0.64)
        scrim.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrim)

        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.layer.cornerRadius = 28
        panel.layer.cornerCurve = .continuous
        panel.clipsToBounds = true
        addSubview(panel)

        titleLabel.font = .systemFont(ofSize: 26, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        titleLabel.adjustsFontForContentSizeCategory = true

        actionStack.axis = .vertical
        actionStack.alignment = .fill
        actionStack.spacing = 12

        let content = UIStackView(arrangedSubviews: [titleLabel, actionStack])
        content.axis = .vertical
        content.spacing = 28
        content.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView.addSubview(content)

        NSLayoutConstraint.activate([
            scrim.topAnchor.constraint(equalTo: topAnchor),
            scrim.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrim.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrim.bottomAnchor.constraint(equalTo: bottomAnchor),

            panel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            panel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 120),

            content.topAnchor.constraint(equalTo: panel.contentView.topAnchor, constant: 28),
            content.leadingAnchor.constraint(equalTo: panel.contentView.leadingAnchor, constant: 22),
            content.trailingAnchor.constraint(equalTo: panel.contentView.trailingAnchor, constant: -22),
            content.bottomAnchor.constraint(equalTo: panel.contentView.bottomAnchor, constant: -24),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(title: String?, actions: [Action]) {
        titleLabel.text = title
        titleLabel.isHidden = title == nil
        buttons.forEach {
            actionStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        buttons = []
        handlers = actions.map(\.action)

        for (index, action) in actions.enumerated() {
            let button = UIButton(type: .system)
            var config = GlassStyle.actionButtonConfiguration(
                title: action.title,
                symbol: "circle",
                prominent: action.prominent)
            config.image = action.image
            config.imagePlacement = .trailing
            button.configuration = config
            button.tag = index
            button.addTarget(self, action: #selector(actionTapped(_:)), for: .touchUpInside)
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
            button.accessibilityLabel = action.title
            actionStack.addArrangedSubview(button)
            buttons.append(button)
        }
    }

    @objc private func actionTapped(_ sender: UIButton) {
        guard handlers.indices.contains(sender.tag) else { return }
        handlers[sender.tag]()
    }
}

// MARK: - Action Button cue

private final class ActionButtonPressCue: UIVisualEffectView {
    private let rim = CAShapeLayer()
    private let glow = UIView()

    init() {
        super.init(effect: GlassStyle.barEffect())
        isUserInteractionEnabled = false
        if #available(iOS 26.0, *) {
            cornerConfiguration = .capsule()
        } else {
            layer.cornerRadius = 19
            layer.cornerCurve = .continuous
            clipsToBounds = true
        }
        alpha = 0
        transform = CGAffineTransform(scaleX: 0.62, y: 0.62)

        glow.backgroundColor = LunaSurfacePalette.baseColor(for: .reader)
            .withAlphaComponent(0.88)
        glow.layer.cornerRadius = 3
        contentView.addSubview(glow)

        rim.fillColor = UIColor.clear.cgColor
        rim.strokeColor = UIColor.white.withAlphaComponent(0.72).cgColor
        rim.lineWidth = 1
        layer.addSublayer(rim)
        layer.shadowColor = LunaSurfacePalette.baseColor(for: .reader).cgColor
        layer.shadowOpacity = 0
        layer.shadowRadius = 14
        layer.shadowOffset = .zero
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func layout(in window: UIWindow) {
        frame = CGRect(
            x: -8,
            y: window.safeAreaInsets.top + 68,
            width: 38,
            height: 78)
        glow.frame = CGRect(x: 23, y: 26, width: 6, height: 26)
        rim.frame = bounds
        rim.path = UIBezierPath(
            roundedRect: bounds.insetBy(dx: 1, dy: 1),
            cornerRadius: bounds.width / 2).cgPath
    }

    func play(completion: @escaping () -> Void) {
        UIView.animateKeyframes(
            withDuration: UIAccessibility.isReduceMotionEnabled ? 0.25 : 0.82,
            delay: 0,
            options: [.calculationModeCubic]
        ) {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.26) {
                self.alpha = 1
                self.transform = .identity
                self.layer.shadowOpacity = 0.85
            }
            UIView.addKeyframe(withRelativeStartTime: 0.26, relativeDuration: 0.24) {
                self.transform = CGAffineTransform(scaleX: 0.88, y: 0.92)
                self.glow.transform = CGAffineTransform(scaleX: 1.2, y: 0.72)
            }
            UIView.addKeyframe(withRelativeStartTime: 0.50, relativeDuration: 0.50) {
                self.alpha = 0
                self.transform = CGAffineTransform(scaleX: 1.18, y: 1.08)
                self.glow.transform = .identity
                self.layer.shadowOpacity = 0
            }
        } completion: { _ in completion() }
    }
}

// MARK: - Whole-screen liquid wave

/// A moving Core Image displacement strip over a window snapshot. Rendering a
/// single snapshot through CIBumpDistortionLinear means the wave deforms every
/// source pixel it crosses (including the status bar and browser chrome), then
/// removes itself to reveal the untouched live hierarchy underneath.
@MainActor
private final class LiquidScreenWaveAnimator {
    private weak var window: UIWindow?
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var overlay: UIImageView?
    private var source: CIImage?
    private var displayLink: CADisplayLink?
    private var startedAt: CFTimeInterval = 0
    private var completion: (() -> Void)?
    private var originY: CGFloat = 0
    private let duration: CFTimeInterval = 1.18

    init(window: UIWindow) {
        self.window = window
    }

    func play(originY: CGFloat, completion: @escaping () -> Void) {
        guard let window, let snapshot = snapshot(window: window),
              let cgImage = snapshot.cgImage else {
            completion()
            return
        }
        self.originY = originY
        self.completion = completion
        source = CIImage(cgImage: cgImage)

        let imageView = UIImageView(frame: window.bounds)
        imageView.image = snapshot
        imageView.contentMode = .scaleToFill
        imageView.isUserInteractionEnabled = false
        window.addSubview(imageView)
        overlay = imageView

        startedAt = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        if #available(iOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: 20, maximum: 30, preferred: 30)
        }
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func snapshot(window: UIWindow) -> UIImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale
        format.opaque = true
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let source, let overlay, let window else {
            finish()
            return
        }
        let progress = min(max((link.timestamp - startedAt) / duration, 0), 1)
        let scale = window.screen.scale
        let extent = source.extent
        let front = CGFloat(-0.15 + progress * 1.30) * extent.width
        let amplitude = sin(CGFloat(progress) * .pi) * 24 * scale
        let radius = 64 * scale
        let centerY = extent.height - originY * scale

        guard let filter = CIFilter(
            name: "CIBumpDistortionLinear",
            parameters: [
                kCIInputImageKey: source.clampedToExtent(),
                kCIInputCenterKey: CIVector(x: front, y: centerY),
                kCIInputRadiusKey: radius,
                kCIInputScaleKey: amplitude,
                kCIInputAngleKey: CGFloat.pi / 2,
            ]),
            let output = filter.outputImage?.cropped(to: extent),
            let rendered = context.createCGImage(output, from: extent)
        else {
            finish()
            return
        }
        overlay.image = UIImage(cgImage: rendered, scale: scale, orientation: .up)
        if progress >= 1 { finish() }
    }

    private func finish() {
        displayLink?.invalidate()
        displayLink = nil
        overlay?.removeFromSuperview()
        overlay = nil
        source = nil
        let completion = completion
        self.completion = nil
        completion?()
    }
}

// MARK: - System icon artwork

private enum OnboardingSystemIcons {
    static let shortcuts: UIImage? = {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = false
        return UIGraphicsImageRenderer(
            size: CGSize(width: 24, height: 24), format: format
        ).image { context in
            let cg = context.cgContext
            cg.translateBy(x: 12, y: 12)
            cg.rotate(by: .pi / 4)
            drawShortcutTile(
                in: cg, rect: CGRect(x: -7.5, y: -10, width: 15, height: 15),
                colors: [
                    UIColor(red: 1, green: 0.27, blue: 0.58, alpha: 1),
                    UIColor(red: 0.68, green: 0.22, blue: 0.95, alpha: 1),
                ])
            drawShortcutTile(
                in: cg, rect: CGRect(x: -7.5, y: -5, width: 15, height: 15),
                colors: [
                    UIColor(red: 0.14, green: 0.80, blue: 0.78, alpha: 1),
                    UIColor(red: 0.13, green: 0.42, blue: 0.98, alpha: 1),
                ])
        }.withRenderingMode(.alwaysOriginal)
    }()

    static let actionButton: UIImage? = UIImage(
        systemName: "button.programmable",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        ?? UIImage(systemName: "smallcircle.filled.circle")

    private static func drawShortcutTile(
        in context: CGContext, rect: CGRect, colors: [UIColor]
    ) {
        let path = UIBezierPath(roundedRect: rect, cornerRadius: 4).cgPath
        context.saveGState()
        context.addPath(path)
        context.clip()
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors.map(\.cgColor) as CFArray,
            locations: [0, 1]) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: rect.minX, y: rect.minY),
                end: CGPoint(x: rect.maxX, y: rect.maxY),
                options: [])
        }
        context.restoreGState()
    }
}

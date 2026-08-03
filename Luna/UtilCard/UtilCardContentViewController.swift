//
//  UtilCardContentViewController.swift
//  Luna
//

import LunaDesignSystem
import LunaModels
import LunaStorage
import LunaURLClassification
import LunaWeekly
import UIKit
import UniformTypeIdentifiers

/// The permanent first card in every Luna deck. It is the first-launch
/// onboarding surface and, on later launches, a compact home for Safari
/// history. Its launch mode is deliberately immutable: finishing setup keeps
/// the onboarding controls in place until the next app launch.
final class UtilCardContentViewController: CardContentViewController {
    typealias SaveHandler = (
        _ urlString: String,
        _ source: CaptureSource,
        _ sourceView: UIView,
        _ completion: @escaping (Bool) -> Void
    ) -> Void

    static var setupJourneyLauncher: ((UIViewController, OnboardingDemoSource) -> Void)?

    /// The slot the Save of the Week row occupies when there is one. Kept as a
    /// constant because the two layout branches both have to reclaim exactly
    /// this much when the slot is empty.
    private static let weeklyRowHeight: CGFloat = 82

    private let showsOnboarding: Bool
    private let configuration: OnboardingSurfaceConfiguration
    private let saveHandler: SaveHandler
    private let onboardingStore: AppOnboardingStore

    private let headline: OnboardingIntroHeadlineView?
    private let weeklyHost: WeeklySaveRowHost
    private let safariButton = UIButton(type: .system)
    private let saveSetupButton = UIButton(type: .system)
    private let pasteRow = OnboardingPasteRow()
    private var recentRows: [UtilURLRow] = []
    private var didStartHeadline = false
    private var observers: [NSObjectProtocol] = []

    init(
        showsOnboarding: Bool,
        configuration: OnboardingSurfaceConfiguration = .current,
        onboardingStore: AppOnboardingStore = .shared,
        weeklyStore: WeeklySaveStore = .shared,
        app: LunaApp = .current,
        now: @escaping () -> Date = Date.init,
        saveHandler: @escaping SaveHandler
    ) {
        self.showsOnboarding = showsOnboarding
        self.configuration = configuration
        self.onboardingStore = onboardingStore
        self.saveHandler = saveHandler
        weeklyHost = WeeklySaveRowHost(store: weeklyStore, app: app, now: now)
        headline = showsOnboarding
            ? OnboardingIntroHeadlineView(copy: configuration.introCopy)
            : nil
        super.init()
        pasteConfiguration = UIPasteConfiguration(
            acceptableTypeIdentifiers: [
                UTType.url.identifier,
                UTType.plainText.identifier,
            ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.accessibilityIdentifier = "utilCard"

        if let headline { view.addSubview(headline) }
        view.addSubview(weeklyHost)
        view.addSubview(pasteRow)

        weeklyHost.onSave = { [weak self] urlString, sourceView in
            self?.save(urlString, source: .manual, sourceView: sourceView)
        }
        weeklyHost.onPresenceChange = { [weak self] in self?.view.setNeedsLayout() }
        weeklyHost.isHidden = weeklyHost.isEmpty

        if showsOnboarding {
            configureSetupButtons()
            view.addSubview(safariButton)
            view.addSubview(saveSetupButton)
            updateSetupButtonStates()
        } else {
            rebuildRecentRows()
        }

        observers.append(NotificationCenter.default.addObserver(
            forName: RecentURLMatcher.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            guard self?.showsOnboarding == false else { return }
            self?.rebuildRecentRows()
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: AppOnboardingStore.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            guard self?.showsOnboarding == true else { return }
            self?.updateSetupButtonStates()
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in RecentURLMatcher.shared.refresh() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: WeeklySaveStore.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.weeklySaveDidChange()
        })

        RecentURLMatcher.shared.refresh()
    }

    /// The store gained, replaced, or lost a value. Presence changes reflow the
    /// card; a same-slot replacement is the host's own business.
    private func weeklySaveDidChange() {
        let wasHidden = weeklyHost.isHidden
        weeklyHost.reload(animated: !UIAccessibility.isReduceMotionEnabled)
        let shouldHide = weeklyHost.isEmpty
        guard wasHidden != shouldHide else { return }
        if UIAccessibility.isReduceMotionEnabled {
            weeklyHost.isHidden = shouldHide
            weeklyHost.alpha = 1
            view.setNeedsLayout()
            view.layoutIfNeeded()
            return
        }
        if shouldHide {
            UIView.animate(withDuration: 0.24, delay: 0, options: [.curveEaseOut]) {
                self.weeklyHost.alpha = 0
            } completion: { _ in
                self.weeklyHost.isHidden = true
                self.weeklyHost.alpha = 1
                self.view.setNeedsLayout()
                UIView.animate(withDuration: 0.24, delay: 0, options: [.curveEaseOut]) {
                    self.view.layoutIfNeeded()
                }
            }
            return
        }
        weeklyHost.isHidden = false
        weeklyHost.alpha = 0
        view.setNeedsLayout()
        UIView.animate(withDuration: 0.24, delay: 0, options: [.curveEaseOut]) {
            self.view.layoutIfNeeded()
            self.weeklyHost.alpha = 1
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let inset: CGFloat = 20
        let width = max(0, view.bounds.width - inset * 2)
        let pasteHeight = OnboardingIntroActionMetrics.pasteRowHeight
        pasteRow.frame = CGRect(
            x: inset,
            y: view.bounds.height - pasteHeight - 20,
            width: width,
            height: pasteHeight)

        // No live entry means no slot: the setup buttons (or the recent rows)
        // move up into the space the row would have taken.
        let weeklyVisible = !weeklyHost.isEmpty

        if let headline {
            headline.frame = CGRect(
                x: inset,
                y: 28,
                width: width,
                height: headline.height)
            weeklyHost.frame = CGRect(
                x: inset,
                y: headline.frame.maxY + 24,
                width: width,
                height: Self.weeklyRowHeight)
            safariButton.frame = CGRect(
                x: inset,
                y: weeklyVisible
                    ? weeklyHost.frame.maxY + 18
                    : headline.frame.maxY + 24,
                width: width,
                height: 54)
            saveSetupButton.frame = CGRect(
                x: inset,
                y: safariButton.frame.maxY + 10,
                width: width,
                height: 54)
            return
        }

        weeklyHost.frame = CGRect(
            x: inset, y: 24, width: width, height: Self.weeklyRowHeight)
        var nextY = weeklyVisible ? weeklyHost.frame.maxY + 10 : 24
        let availableBottom = pasteRow.frame.minY - 12
        for row in recentRows {
            let fits = nextY + 74 <= availableBottom
            row.isHidden = !fits
            if fits {
                row.frame = CGRect(x: inset, y: nextY, width: width, height: 74)
                nextY = row.frame.maxY + 9
            }
        }
    }

    override func cardDidBecomeCentered() {
        super.cardDidBecomeCentered()
        weeklyHost.cardDidBecomeCentered()
        guard let headline, !didStartHeadline else { return }
        didStartHeadline = true
        view.layoutIfNeeded()
        DispatchQueue.main.asyncAfter(
            deadline: .now() + OnboardingAnimationClock.delay(
                OnboardingIntroTiming.firstLineDelay)
        ) { [weak headline] in
            guard let headline else { return }
            headline.revealFirstBeat(
                duration: OnboardingIntroTiming.lineRevealDuration
            ) {
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + OnboardingAnimationClock.delay(
                        OnboardingIntroTiming.interLineDelay)
                ) {
                    headline.revealSecondBeat(
                        duration: OnboardingIntroTiming.lineRevealDuration,
                        completion: {})
                }
            }
        }
    }

    override func cardDidLeaveCenter() {
        super.cardDidLeaveCenter()
        weeklyHost.cardDidLeaveCenter()
    }

    override func paste(itemProviders: [NSItemProvider]) {
        if let provider = itemProviders.first(where: {
            $0.canLoadObject(ofClass: URL.self)
        }) {
            _ = provider.loadObject(ofClass: URL.self) { [weak self] url, _ in
                guard let url else { return }
                DispatchQueue.main.async { self?.handlePastedValue(url.absoluteString) }
            }
            return
        }
        guard let provider = itemProviders.first(where: {
            $0.canLoadObject(ofClass: NSString.self)
        }) else {
            pasteRow.setState(.failure(L10n.string("Invalid URL")))
            return
        }
        _ = provider.loadObject(ofClass: NSString.self) { [weak self] value, _ in
            guard let value = value as? NSString else { return }
            DispatchQueue.main.async { self?.handlePastedValue(value as String) }
        }
    }

    private func handlePastedValue(_ value: String) {
        pasteRow.showPastedValue(value)
        guard let url = URLUnwrapper.ingestURL(from: value, allowBareHost: true) else {
            pasteRow.setState(.failure(L10n.string("Invalid URL")))
            return
        }
        pasteRow.setState(.loading)
        saveHandler(url.absoluteString, .paste, pasteRow) { [weak self] succeeded in
            self?.pasteRow.setState(
                succeeded ? .success : .failure(L10n.string("Unable to save URL")))
        }
    }

    private func save(_ urlString: String, source: CaptureSource, sourceView: UIView) {
        saveHandler(urlString, source, sourceView) { _ in }
    }

    private func configureSetupButtons() {
        configure(
            safariButton,
            title: OnboardingStrings.Intro.safariAction.value(),
            symbol: "safari.fill",
            action: #selector(safariTapped))
        let title = configuration.saveSetupMode == .actionButtonShortcut
            ? OnboardingStrings.Intro.shortcutAction.value()
            : OnboardingStrings.Intro.shareAction.value()
        configure(
            saveSetupButton,
            title: title,
            symbol: configuration.saveSetupMode == .actionButtonShortcut
                ? "bolt.fill" : "square.and.arrow.up",
            action: #selector(saveSetupTapped))
    }

    private func configure(
        _ button: UIButton,
        title: String,
        symbol: String,
        action: Selector
    ) {
        button.configuration = GlassStyle.actionButtonConfiguration(
            title: title,
            symbol: symbol,
            prominent: true,
            tint: LunaSurfacePalette.baseColor)
        button.configuration?.baseBackgroundColor =
            LunaSurfacePalette.baseColor.withAlphaComponent(0.24)
        button.configuration?.titleLineBreakMode = .byWordWrapping
        button.titleLabel?.numberOfLines = 2
        button.accessibilityLabel = title
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    private func updateSetupButtonStates() {
        applyFinished(onboardingStore.hasFinishedSafariSetup, to: safariButton)
        applyFinished(onboardingStore.hasFinishedSaveSetup, to: saveSetupButton)
    }

    private func applyFinished(_ finished: Bool, to button: UIButton) {
        button.isEnabled = !finished
        button.configuration?.image = UIImage(
            systemName: finished ? "checkmark.circle.fill"
                : (button === safariButton ? "safari.fill"
                    : configuration.saveSetupMode == .actionButtonShortcut
                        ? "bolt.fill" : "square.and.arrow.up"))
        button.configuration?.baseForegroundColor = finished
            ? UIColor.white.withAlphaComponent(0.42)
            : LunaColors.primaryText
        button.configuration?.baseBackgroundColor = finished
            ? UIColor.white.withAlphaComponent(0.08)
            : LunaSurfacePalette.baseColor.withAlphaComponent(0.24)
        button.accessibilityValue = finished
            ? OnboardingStrings.Intro.completed.value()
            : nil
    }

    @objc private func safariTapped() {
        Self.setupJourneyLauncher?(self, .safari)
    }

    @objc private func saveSetupTapped() {
        Self.setupJourneyLauncher?(self, .messages)
    }

    private func rebuildRecentRows() {
        for row in recentRows { row.removeFromSuperview() }
        recentRows = RecentURLMatcher.shared.matches.map { preview in
            let row = UtilURLRow(style: .recent)
            row.configure(preview)
            row.onTap = { [weak self, weak row] in
                guard let self, let row else { return }
                self.save(preview.urlString, source: .manual, sourceView: row)
            }
            view.addSubview(row)
            return row
        }
        view.setNeedsLayout()
    }

}

/// A black URL row with a narrow Liquid Glass rim. The weekly recommendation
/// tints that rim with the running app's palette; ordinary history rows leave
/// the glass neutral.
final class UtilURLRow: UIControl {
    enum Style: Equatable { case saveOfTheWeek, recent }

    /// Shared by the row, its glass rim, and the slot that clips a replacement
    /// slide, so all three round by the same amount.
    static let cornerRadius: CGFloat = 16

    private let style: Style
    private let thumbnail = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let border: UtilURLRowGlassBorder
    private var previewKind: RecentURLPreview.Kind?
    var onTap: (() -> Void)?

    init(style: Style) {
        self.style = style
        border = UtilURLRowGlassBorder(
            tint: style == .saveOfTheWeek ? LunaSurfacePalette.baseColor : nil)
        super.init(frame: .zero)
        accessibilityIdentifier = style == .saveOfTheWeek
            ? "utilCard.saveOfTheWeek"
            : "utilCard.recent"
        isAccessibilityElement = true
        backgroundColor = UIColor(white: 0.025, alpha: 1)
        layer.cornerRadius = Self.cornerRadius
        layer.cornerCurve = .continuous
        clipsToBounds = true

        thumbnail.contentMode = .scaleAspectFill
        thumbnail.clipsToBounds = true
        thumbnail.layer.cornerRadius = 11
        thumbnail.layer.cornerCurve = .continuous
        thumbnail.tintColor = LunaColors.secondaryText
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = LunaColors.primaryText
        titleLabel.numberOfLines = 2
        subtitleLabel.font = .systemFont(ofSize: 12, weight: .regular)
        subtitleLabel.textColor = LunaColors.secondaryText
        subtitleLabel.lineBreakMode = .byTruncatingMiddle

        addSubview(thumbnail)
        addSubview(titleLabel)
        addSubview(subtitleLabel)
        addSubview(border)
        thumbnail.isAccessibilityElement = false
        titleLabel.isAccessibilityElement = false
        subtitleLabel.isAccessibilityElement = false
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
        accessibilityTraits = .button
        accessibilityHint = L10n.string("Saves as a full card")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// - Parameter weeklyLabel: The "… of the week/month" phrase, which is per
    ///   app and per age tier (`WeeklySaveLabels`). Ignored by history rows.
    func configure(_ preview: RecentURLPreview, weeklyLabel: String? = nil) {
        previewKind = preview.kind
        thumbnail.image = preview.image ?? UIImage(
            systemName: preview.kind == .media ? "play.rectangle.fill"
                : preview.kind == .product ? "bag.fill" : "safari.fill")
        titleLabel.text = preview.title
        let host = URL(string: preview.urlString)?.host ?? preview.subtitle ?? preview.urlString
        subtitleLabel.text = style == .saveOfTheWeek
            ? host + "  •  " + (weeklyLabel ?? WeeklySaveLabels.subtitle(monthTier: false))
            : host
        accessibilityLabel = [titleLabel.text, subtitleLabel.text]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    /// How far the row's CONTENT trails its shell during a cycle slide. The
    /// shell travels a full row width; the thumbnail and labels lag behind it
    /// by this much, which is what gives the swap depth instead of reading as
    /// one flat rectangle sliding.
    func setContentParallax(_ translationX: CGFloat) {
        let transform = CGAffineTransform(translationX: translationX, y: 0)
        thumbnail.transform = transform
        titleLabel.transform = transform
        subtitleLabel.transform = transform
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Frames are meaningless under a transform, so the parallax offset is
        // lifted off, the real geometry applied, and the offset put back.
        let parallax = thumbnail.transform
        thumbnail.transform = .identity
        titleLabel.transform = .identity
        subtitleLabel.transform = .identity
        defer {
            thumbnail.transform = parallax
            titleLabel.transform = parallax
            subtitleLabel.transform = parallax
        }
        let imageSide = min(52, max(42, bounds.height - 22))
        thumbnail.frame = CGRect(
            x: 11,
            y: (bounds.height - imageSide) / 2,
            width: imageSide,
            height: imageSide)
        let labelX = thumbnail.frame.maxX + 11
        let labelWidth = max(0, bounds.width - labelX - 12)
        titleLabel.frame = CGRect(
            x: labelX,
            y: 13,
            width: labelWidth,
            height: max(22, bounds.height - 40))
        subtitleLabel.frame = CGRect(
            x: labelX,
            y: bounds.height - 27,
            width: labelWidth,
            height: 16)
        border.frame = bounds
    }

    @objc private func tapped() { onTap?() }
}

@MainActor
extension UtilURLRow: UtilCardSaveTransitionArtworkProviding {
    func makeUtilCardSaveTransitionArtwork(
        in coordinateView: UIView
    ) -> UtilCardSaveTransitionArtwork? {
        guard let previewKind, let title = titleLabel.text else { return nil }
        layoutIfNeeded()

        let thumbnailCopy = UIImageView(image: thumbnail.image)
        thumbnailCopy.frame = thumbnail.convert(thumbnail.bounds, to: coordinateView)
        thumbnailCopy.contentMode = thumbnail.contentMode
        thumbnailCopy.tintColor = thumbnail.tintColor
        thumbnailCopy.clipsToBounds = true
        thumbnailCopy.layer.cornerRadius = thumbnail.layer.cornerRadius
        thumbnailCopy.layer.cornerCurve = .continuous

        let titleCopy = UILabel()
        titleCopy.text = title
        titleCopy.frame = titleLabel.convert(titleLabel.bounds, to: coordinateView)
        titleCopy.font = titleLabel.font
        titleCopy.textColor = titleLabel.textColor
        titleCopy.numberOfLines = titleLabel.numberOfLines

        let subtitleCopy = UILabel()
        subtitleCopy.text = subtitleLabel.text
        subtitleCopy.frame = subtitleLabel.convert(subtitleLabel.bounds, to: coordinateView)
        subtitleCopy.font = subtitleLabel.font
        subtitleCopy.textColor = subtitleLabel.textColor

        return UtilCardSaveTransitionArtwork(
            kind: previewKind,
            sourceFrame: convert(bounds, to: coordinateView),
            backgroundColor: backgroundColor ?? .black,
            cornerRadius: layer.cornerRadius,
            thumbnail: thumbnailCopy,
            title: titleCopy,
            subtitle: subtitleCopy)
    }
}

private final class UtilURLRowGlassBorder: UIVisualEffectView {
    private let rimMaskView = UIView()
    private let maskLayer = CAShapeLayer()
    private let highlight = CAShapeLayer()
    private let tint: UIColor?

    init(tint: UIColor?) {
        self.tint = tint
        let effect: UIVisualEffect
        if #available(iOS 26.0, *) {
            let glass = UIGlassEffect()
            glass.tintColor = tint?.withAlphaComponent(0.55)
                ?? UIColor.white.withAlphaComponent(0.03)
            effect = glass
        } else {
            effect = UIBlurEffect(style: .systemThinMaterialDark)
        }
        super.init(effect: effect)
        isUserInteractionEnabled = false
        maskLayer.fillColor = UIColor.white.cgColor
        maskLayer.fillRule = .evenOdd
        rimMaskView.layer.addSublayer(maskLayer)
        mask = rimMaskView
        highlight.fillColor = UIColor.clear.cgColor
        highlight.lineWidth = 0.7
        contentView.layer.addSublayer(highlight)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        let corner = UtilURLRow.cornerRadius
        let rim: CGFloat = 1.5
        let path = UIBezierPath(roundedRect: bounds, cornerRadius: corner)
        path.append(UIBezierPath(
            roundedRect: bounds.insetBy(dx: rim, dy: rim),
            cornerRadius: corner - rim))
        rimMaskView.frame = bounds
        maskLayer.frame = bounds
        maskLayer.path = path.cgPath
        highlight.frame = bounds
        highlight.path = UIBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            cornerRadius: corner - 0.5).cgPath
        highlight.strokeColor = (
            tint?.withAlphaComponent(0.65) ?? GlassStyle.glassBorderColor
        ).resolvedColor(with: traitCollection).cgColor
    }
}

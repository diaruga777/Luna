//
//  UtilCardContentViewController.swift
//  Luna
//

import LunaDesignSystem
import LunaModels
import LunaStorage
import LunaURLClassification
import UIKit
import UniformTypeIdentifiers

/// Where the util card's parts sit. The intro headline is the only measurement
/// that is a FRACTION of the card: everything else either hangs off it or is
/// anchored to the paste row at the bottom, so the block resolves downward the
/// way the standalone onboarding root's did.
enum UtilCardLayout {
    static let inset: CGFloat = 20
    /// The headline's top. The standalone onboarding root put its copy at
    /// exactly a third of the surface; the util card lifts it a little to leave
    /// the weekly row its own room below — a little, not up onto the card's
    /// shoulder.
    static let headlineTopRatio: CGFloat = 0.28
    static let headlineToWeekly: CGFloat = 24
    static let weeklyRowHeight: CGFloat = 82
    static let recentRowHeight: CGFloat = 74
    static let setupButtonHeight: CGFloat = 54
    static let setupButtonGap: CGFloat = 10
    /// The gap the setup block keeps above the paste field when no “or” stands
    /// between them.
    static let setupToPasteGap: CGFloat = 16
    static let bottomPadding: CGFloat = 20
}

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
    static let saveOfTheWeekURLString = "https://www.lewissociety.org/innerring/"

    private let showsOnboarding: Bool
    /// Whether the headline's two-beat sweep belongs to THIS appearance. It is
    /// the launch's animation: a card paged back to shows the finished sentence
    /// instead of saying it again.
    private let animatesIntro: Bool
    private let configuration: OnboardingSurfaceConfiguration
    private let saveHandler: SaveHandler
    private let onboardingStore: AppOnboardingStore
    /// Whether the deck holds any save of its own. The “or” belongs to a card
    /// that is the only thing in the app.
    private let hasSaves: () -> Bool
    private let savedURLStrings: () -> Set<String>

    private let headline: OnboardingIntroHeadlineView?
    private let saveOfTheWeek = UtilURLRow(style: .saveOfTheWeek)
    private let safariButton = UIButton(type: .system)
    private let saveSetupButton = UIButton(type: .system)
    private let orLabel = UILabel()
    private let pasteRow = OnboardingPasteRow()
    private var recentRows: [UtilURLRow] = []
    private var didSettleHeadline = false
    private var weeklyPreview: RecentURLPreview
    private var observers: [NSObjectProtocol] = []

    init(
        showsOnboarding: Bool,
        animatesIntro: Bool = false,
        configuration: OnboardingSurfaceConfiguration = .current,
        onboardingStore: AppOnboardingStore = .shared,
        hasSaves: @escaping () -> Bool = { !ReadingListStore.shared.items().isEmpty },
        savedURLStrings: @escaping () -> Set<String> = {
            Set(ReadingListStore.shared.items().map(\.urlString))
        },
        saveHandler: @escaping SaveHandler
    ) {
        self.showsOnboarding = showsOnboarding
        self.animatesIntro = showsOnboarding && animatesIntro
        self.configuration = configuration
        self.onboardingStore = onboardingStore
        self.hasSaves = hasSaves
        self.savedURLStrings = savedURLStrings
        self.saveHandler = saveHandler
        headline = showsOnboarding
            ? OnboardingIntroHeadlineView(copy: configuration.introCopy)
            : nil
        weeklyPreview = RecentURLPreview(
            urlString: Self.saveOfTheWeekURLString,
            title: "The Inner Ring",
            subtitle: "www.lewissociety.org",
            kind: .article,
            imageData: nil)
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

        if let headline {
            view.addSubview(headline)
            // The sweep is the launch's. Anywhere else the sentence is simply
            // already finished — including while this card is still a side peek,
            // so paging to it never pops the copy into place.
            if !animatesIntro {
                headline.showFinishedState()
                didSettleHeadline = true
            }
        }
        view.addSubview(saveOfTheWeek)
        view.addSubview(pasteRow)

        configureWeeklyRow()

        if showsOnboarding {
            configureSetupButtons()
            configureOrLabel()
            view.addSubview(safariButton)
            view.addSubview(saveSetupButton)
            view.addSubview(orLabel)
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
            self?.updateOrVisibility()
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .readingListChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.updateWeeklySavedState()
            self?.updateOrVisibility()
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in RecentURLMatcher.shared.refresh() }
        })

        RecentURLMatcher.shared.refresh()
        loadSaveOfTheWeekPreview()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let inset = UtilCardLayout.inset
        let width = max(0, view.bounds.width - inset * 2)
        let pasteHeight = OnboardingIntroActionMetrics.pasteRowHeight
        pasteRow.frame = CGRect(
            x: inset,
            y: view.bounds.height - pasteHeight - UtilCardLayout.bottomPadding,
            width: width,
            height: pasteHeight)

        if let headline {
            // The setup actions keep the seat they had on the standalone intro:
            // stacked upward from the paste field, with the “or” — when the card
            // is the whole app — in the seam between them.
            var actionsBottom = pasteRow.frame.minY - UtilCardLayout.setupToPasteGap
            if !orLabel.isHidden {
                let orHeight = OnboardingIntroActionMetrics.orHeight
                let gap = OnboardingIntroActionMetrics.orSpacing
                orLabel.frame = CGRect(
                    x: inset,
                    y: pasteRow.frame.minY - gap - orHeight,
                    width: width,
                    height: orHeight)
                actionsBottom = orLabel.frame.minY - gap
            }
            let buttonHeight = UtilCardLayout.setupButtonHeight
            saveSetupButton.frame = CGRect(
                x: inset,
                y: actionsBottom - buttonHeight,
                width: width,
                height: buttonHeight)
            safariButton.frame = CGRect(
                x: inset,
                y: saveSetupButton.frame.minY
                    - UtilCardLayout.setupButtonGap - buttonHeight,
                width: width,
                height: buttonHeight)

            headline.frame = CGRect(
                x: inset,
                y: (view.bounds.height * UtilCardLayout.headlineTopRatio).rounded(),
                width: width,
                height: headline.height)
            let weeklyHeight = UtilCardLayout.weeklyRowHeight
            saveOfTheWeek.frame = CGRect(
                x: inset,
                y: min(
                    headline.frame.maxY + UtilCardLayout.headlineToWeekly,
                    max(
                        headline.frame.maxY,
                        safariButton.frame.minY - 18 - weeklyHeight)),
                width: width,
                height: weeklyHeight)
            return
        }

        saveOfTheWeek.frame = CGRect(
            x: inset, y: 24, width: width, height: UtilCardLayout.weeklyRowHeight)
        var nextY = saveOfTheWeek.frame.maxY + 10
        let availableBottom = pasteRow.frame.minY - 12
        for row in recentRows {
            let fits = nextY + UtilCardLayout.recentRowHeight <= availableBottom
            row.isHidden = !fits
            if fits {
                row.frame = CGRect(
                    x: inset, y: nextY,
                    width: width, height: UtilCardLayout.recentRowHeight)
                nextY = row.frame.maxY + 9
            }
        }
    }

    override func cardDidBecomeCentered() {
        super.cardDidBecomeCentered()
        guard let headline, !didSettleHeadline else { return }
        didSettleHeadline = true
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

    // MARK: - Save of the week

    private func configureWeeklyRow() {
        saveOfTheWeek.configure(weeklyPreview)
        saveOfTheWeek.onTap = { [weak self, weak saveOfTheWeek] in
            guard let self, let source = saveOfTheWeek else { return }
            self.save(self.weeklyPreview.urlString, source: .manual, sourceView: source)
        }
        updateWeeklySavedState()
    }

    private func loadSaveOfTheWeekPreview() {
        Task { @MainActor [weak self] in
            guard let self,
                  let preview = await RecentURLMatcher.evaluate(
                    urlString: Self.saveOfTheWeekURLString,
                    surface: .luna)
            else { return }
            weeklyPreview = preview
            configureWeeklyRow()
        }
    }

    /// The weekly recommendation may already be in the deck — the canonical URL
    /// the row would save, or the bundled one it started from. Then it is shown
    /// as answered rather than offered.
    private func updateWeeklySavedState() {
        let saved = savedURLStrings()
        saveOfTheWeek.setSaved(
            saved.contains(weeklyPreview.urlString)
                || saved.contains(Self.saveOfTheWeekURLString))
    }

    // MARK: - Setup actions

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
            symbol: "square.and.arrow.up",
            image: saveSetupIcon(),
            action: #selector(saveSetupTapped))
    }

    private func configureOrLabel() {
        orLabel.text = OnboardingStrings.Intro.orSeparator.value()
        orLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        orLabel.textColor = LunaColors.quaternaryText
        orLabel.textAlignment = .center
        orLabel.accessibilityIdentifier =
            OnboardingStrings.Accessibility.introOr.value()
        orLabel.isAccessibilityElement = false
        updateOrVisibility()
    }

    /// The “or” is the seam between "set Luna up" and "or just paste something".
    /// It reads as that choice only while the setup legs are still open AND the
    /// deck holds nothing else — once either is untrue the card is no longer an
    /// either/or.
    private func updateOrVisibility() {
        guard showsOnboarding else { return }
        let setupOutstanding = !(onboardingStore.hasFinishedSafariSetup
            && onboardingStore.hasFinishedSaveSetup)
        let shouldShow = setupOutstanding && !hasSaves()
        guard orLabel.isHidden == shouldShow else { return }
        orLabel.isHidden = !shouldShow
        view.setNeedsLayout()
    }

    /// The save lesson's own artwork: the real Shortcuts app icon for the Action
    /// Button journey, this app's icon for the share-sheet one — the same
    /// artwork the standalone intro card used. A generic bolt reads as some
    /// other feature entirely. nil falls back to the button's symbol.
    private func saveSetupIcon() -> UIImage? {
        let artwork: UIImage?
        switch configuration.saveSetupMode {
        case .actionButtonShortcut:
            artwork = Bundle.main.path(forResource: "ShortcutsAppIcon", ofType: "png")
                .flatMap(UIImage.init(contentsOfFile:))
        case .shareSheet:
            artwork = OnboardingAppIcon.image()
        }
        guard let artwork else { return nil }
        let size = CGSize(width: 22, height: 22)
        return UIGraphicsImageRenderer(size: size).image { _ in
            artwork.draw(in: CGRect(origin: .zero, size: size))
        }.withRenderingMode(.alwaysOriginal)
    }

    private func configure(
        _ button: UIButton,
        title: String,
        symbol: String,
        image: UIImage? = nil,
        action: Selector
    ) {
        button.configuration = GlassStyle.actionButtonConfiguration(
            title: title,
            symbol: symbol,
            prominent: true,
            tint: LunaSurfacePalette.baseColor)
        if let image { button.configuration?.image = image }
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
        if finished {
            button.configuration?.image = UIImage(systemName: "checkmark.circle.fill")
        } else if button === safariButton {
            button.configuration?.image = UIImage(systemName: "safari.fill")
        } else {
            button.configuration?.image = saveSetupIcon()
                ?? UIImage(systemName: "square.and.arrow.up")
        }
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

/// A black URL row with a narrow Liquid Glass rim — the same rim the deck's own
/// cards wear, so a row reads as a card in waiting rather than as a tinted
/// banner.
final class UtilURLRow: UIControl {
    enum Style: Equatable { case saveOfTheWeek, recent }

    private let style: Style
    private let thumbnail = UIImageView()
    private let savedOverlay = UIView()
    private let savedCheckmark = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let border = UtilURLRowGlassBorder()
    private var previewKind: RecentURLPreview.Kind?
    private(set) var isShownAsSaved = false
    var onTap: (() -> Void)?

    init(style: Style) {
        self.style = style
        super.init(frame: .zero)
        accessibilityIdentifier = style == .saveOfTheWeek
            ? "utilCard.saveOfTheWeek"
            : "utilCard.recent"
        isAccessibilityElement = true
        backgroundColor = UIColor(white: 0.025, alpha: 1)
        layer.cornerRadius = UtilURLRowGlassBorder.cornerRadius
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

        // Already saved: the artwork stays legible under a thin scrim and the
        // deck's own answer sits on top of it.
        savedOverlay.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        savedOverlay.layer.cornerRadius = thumbnail.layer.cornerRadius
        savedOverlay.layer.cornerCurve = .continuous
        savedOverlay.isUserInteractionEnabled = false
        savedOverlay.isHidden = true
        savedCheckmark.image = UIImage(systemName: "checkmark.circle.fill")
        savedCheckmark.tintColor = UIColor.white.withAlphaComponent(0.9)
        savedCheckmark.contentMode = .scaleAspectFit
        savedOverlay.addSubview(savedCheckmark)

        addSubview(thumbnail)
        addSubview(savedOverlay)
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

    func configure(_ preview: RecentURLPreview) {
        previewKind = preview.kind
        thumbnail.image = preview.image ?? UIImage(
            systemName: preview.kind == .media ? "play.rectangle.fill"
                : preview.kind == .product ? "bag.fill" : "safari.fill")
        titleLabel.text = preview.title
        let host = URL(string: preview.urlString)?.host ?? preview.subtitle ?? preview.urlString
        subtitleLabel.text = style == .saveOfTheWeek
            ? host + "  •  " + L10n.string("Save of the week")
            : host
        accessibilityLabel = [titleLabel.text, subtitleLabel.text]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    /// This URL is already in the deck: the row dims and its artwork carries a
    /// checkmark, through which the favicon or thumbnail still reads.
    func setSaved(_ saved: Bool) {
        isShownAsSaved = saved
        savedOverlay.isHidden = !saved
        alpha = saved ? 0.55 : 1
        accessibilityValue = saved ? L10n.string("Saved") : nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let imageSide = min(52, max(42, bounds.height - 22))
        thumbnail.frame = CGRect(
            x: 11,
            y: (bounds.height - imageSide) / 2,
            width: imageSide,
            height: imageSide)
        savedOverlay.frame = thumbnail.frame
        let checkSide = (imageSide * 0.52).rounded()
        savedCheckmark.frame = CGRect(
            x: ((imageSide - checkSide) / 2).rounded(),
            y: ((imageSide - checkSide) / 2).rounded(),
            width: checkSide,
            height: checkSide)
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

/// The rim a util row wears, and the same rim the save transition's growing
/// shell wears: `CardSurfaceView`'s recipe — plain Liquid Glass under
/// `GlassStyle.glassBorderColor` — at whatever corner radius its owner is
/// currently drawn with. Nothing is tinted with the app's palette here: a row
/// is a card in waiting, and the deck's cards carry no tint.
final class UtilURLRowGlassBorder: UIVisualEffectView {
    static let cornerRadius: CGFloat = 16

    private let rimMaskView = UIView()
    private let maskLayer = CAShapeLayer()
    private let highlight = CAShapeLayer()

    /// Follows the owner's corner radius. Assigning it inside a UIView
    /// animation block carries the rim along with an animating card radius,
    /// since both shape layers pick up the transaction's implicit animation.
    var cornerRadius: CGFloat = UtilURLRowGlassBorder.cornerRadius {
        didSet {
            guard cornerRadius != oldValue else { return }
            applyGeometry()
        }
    }

    init() {
        super.init(effect: GlassStyle.barEffect())
        isUserInteractionEnabled = false
        maskLayer.fillColor = UIColor.white.cgColor
        maskLayer.fillRule = .evenOdd
        rimMaskView.layer.addSublayer(maskLayer)
        mask = rimMaskView
        highlight.fillColor = UIColor.clear.cgColor
        highlight.lineWidth = 0.5
        contentView.layer.addSublayer(highlight)
        registerForTraitChanges([LunaSkyTrait.self]) {
            (rim: UtilURLRowGlassBorder, _: UITraitCollection) in
            rim.applyGeometry()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyGeometry()
    }

    private func applyGeometry() {
        let corner = cornerRadius
        let rim: CGFloat = 1.5
        let path = UIBezierPath(roundedRect: bounds, cornerRadius: corner)
        path.append(UIBezierPath(
            roundedRect: bounds.insetBy(dx: rim, dy: rim),
            cornerRadius: max(0, corner - rim)))
        rimMaskView.frame = bounds
        maskLayer.frame = bounds
        maskLayer.path = path.cgPath
        highlight.frame = bounds
        highlight.path = UIBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            cornerRadius: max(0, corner - 0.5)).cgPath
        highlight.strokeColor = GlassStyle.glassBorderColor
            .resolvedColor(with: traitCollection).cgColor
    }
}

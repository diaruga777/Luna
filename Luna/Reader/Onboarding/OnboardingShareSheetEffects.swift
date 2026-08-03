//
//  OnboardingShareSheetEffects.swift
//  Luna
//

import LunaDesignSystem
import UIKit

enum OnboardingShareSheetTiming {
    static let contextMenuHold: TimeInterval = 0.55
    static let sheetSettle: TimeInterval = 0.75
    static let betweenSteps: TimeInterval = 0.48
    static let scrollDuration: TimeInterval = 0.62
    static let editTransitionDuration: TimeInterval = 0.36
    static let promotionDuration: TimeInterval = 0.46
}

enum OnboardingActionExtensionIcon {
    static func image(appBundle: Bundle = .main) -> UIImage? {
        guard let plugInsURL = appBundle.builtInPlugInsURL,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: plugInsURL,
                includingPropertiesForKeys: nil)
        else { return nil }
        for entry in entries where entry.pathExtension == "appex" {
            guard let bundle = Bundle(url: entry),
                  bundle.bundleIdentifier?.hasSuffix(".action2") == true,
                  let image = primaryIcon(in: bundle)
            else { continue }
            return image
        }
        return nil
    }

    private static func primaryIcon(in bundle: Bundle) -> UIImage? {
        let icons = bundle.object(forInfoDictionaryKey: "CFBundleIcons")
            as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        let files = primary?["CFBundleIconFiles"] as? [String] ?? []
        for name in files.reversed() {
            if let image = UIImage(named: name, in: bundle, compatibleWith: nil) {
                return image
            }
            guard let resources = bundle.resourceURL,
                  let entries = try? FileManager.default.contentsOfDirectory(
                    at: resources, includingPropertiesForKeys: nil),
                  let path = entries.first(where: {
                    $0.pathExtension == "png"
                        && $0.deletingPathExtension().lastPathComponent.hasPrefix(name)
                  })?.path,
                  let image = UIImage(contentsOfFile: path)
            else { continue }
            return image
        }
        return nil
    }
}

/// System glass for the mock system UI in this file.
///
/// Deliberately NOT `GlassStyle`: those materials are tinted with Luna's own
/// palette, and everything here is a replica of somebody else's chrome, which
/// has to look like the OS rather than like the app.
enum OnboardingSystemGlass {
    /// A context MENU: liquid glass from iOS 26, the chrome material before it.
    static func menuEffect() -> UIVisualEffect {
        if #available(iOS 26.0, *) { return UIGlassEffect() }
        return UIBlurEffect(style: .systemChromeMaterial)
    }

    /// A presented SHEET is a thick material rather than a lens — what is behind
    /// it is meant to be unreadable, not refracted.
    static func sheetEffect() -> UIVisualEffect {
        UIBlurEffect(style: .systemThickMaterial)
    }

    /// Small circular chrome (a sheet's close button).
    static func controlEffect() -> UIVisualEffect {
        if #available(iOS 26.0, *) { return UIGlassEffect() }
        return UIBlurEffect(style: .systemThinMaterial)
    }

    /// What a context menu blurs its whole screen with behind the lifted
    /// preview.
    static func backdropEffect() -> UIVisualEffect {
        UIBlurEffect(style: .systemUltraThinMaterial)
    }

    /// Rounds a glass view the way the OS version of it allows.
    static func round(_ glass: UIVisualEffectView, radius: CGFloat) {
        if #available(iOS 26.0, *) {
            glass.cornerConfiguration = .corners(radius: .fixed(radius))
        } else {
            glass.layer.cornerRadius = radius
            glass.layer.cornerCurve = .continuous
            glass.clipsToBounds = true
        }
    }
}

/// The system context menu iMessage raises when a link bubble is held.
///
/// A REPLICA of `UIContextMenuInteraction`'s presentation rather than a popup of
/// our own, because the popup it replaced read as neither: it floated a made-up
/// white preview card in the middle of the screen with a menu bolted under it,
/// unattached to the bubble that was supposedly held. What the system does, and
/// what this does:
///
/// - the screen behind BLURS, ramping the material in rather than cutting to a
///   flat scrim;
/// - the source itself LIFTS in place — the `UITargetedPreview` beat. A raster
///   copy is lifted and the real bubble hides underneath, exactly as the system
///   hides a source view while its preview is up (the tail curls outside the
///   bubble's bounds, so the copy is rendered from the layer rather than
///   snapshot-viewed);
/// - the menu springs out of the EDGE of that lifted bubble, anchored to the
///   side it appears on, at system menu metrics.
///
/// A real `UIContextMenuInteraction` cannot stand in: it only presents from a
/// live touch, and every gesture in this lesson is scripted.
///
/// Trait note: this lives inside the Messages replica, which pins itself to
/// `.light` because iMessage is white — so these materials resolve to the LIGHT
/// system menu, which is what the surface being imitated looks like. The
/// app-wide `.dark` pin is not in force inside a replica of somebody else's app.
final class OnboardingMockLinkContextMenuView: UIView {
    /// System menu metrics.
    private static let menuWidth: CGFloat = 250
    private static let rowHeight: CGFloat = 44
    private static let menuCornerRadius: CGFloat = 13
    /// The gap the system leaves between a lifted preview and its menu.
    private static let previewGap: CGFloat = 8
    private static let liftedScale: CGFloat = 1.05
    private static let edgeMargin: CGFloat = 16

    private let backdrop = UIVisualEffectView(effect: nil)
    private let dim = UIView()
    private let lifted = UIImageView()
    private let menu = UIView()
    private let menuGlass = UIVisualEffectView(
        effect: OnboardingSystemGlass.menuEffect())
    private let rows = UIStackView()
    private let shareRow: OnboardingMenuRowView
    private weak var source: UIView?
    private var liftedRect = CGRect.zero
    private var placesMenuBelowSource = false

    init(frame: CGRect, source: UIView) {
        shareRow = OnboardingMenuRowView(
            title: OnboardingStrings.SystemUI.share.value(),
            symbol: "square.and.arrow.up")
        self.source = source
        super.init(frame: frame)
        isUserInteractionEnabled = false

        backdrop.frame = bounds
        backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(backdrop)
        dim.frame = bounds
        dim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dim.backgroundColor = UIColor.black.withAlphaComponent(0.12)
        dim.alpha = 0
        addSubview(dim)

        lifted.image = Self.liftedImage(of: source)
        lifted.contentMode = .scaleAspectFit
        lifted.layer.shadowColor = UIColor.black.cgColor
        lifted.layer.shadowRadius = 22
        lifted.layer.shadowOffset = CGSize(width: 0, height: 12)
        lifted.layer.shadowOpacity = 0
        addSubview(lifted)

        // The rows sit as SIBLINGS above the glass rather than inside its
        // content view: a glass content view does not rasterize through
        // `layer.render(in:)`, and every ending in this flow snapshots the
        // screen it is leaving.
        addSubview(menu)
        OnboardingSystemGlass.round(menuGlass, radius: Self.menuCornerRadius)
        menu.addSubview(menuGlass)
        rows.axis = .vertical
        rows.alignment = .fill
        // A pressed row's fill has to stop at the menu's own rounded shape; the
        // glass beneath it is rounded by the OS, not by a mask the rows share.
        rows.layer.cornerRadius = Self.menuCornerRadius
        rows.layer.cornerCurve = .continuous
        rows.clipsToBounds = true
        menu.addSubview(rows)
        menu.layer.shadowColor = UIColor.black.cgColor
        menu.layer.shadowRadius = 24
        menu.layer.shadowOffset = CGSize(width: 0, height: 8)
        menu.layer.shadowOpacity = 0

        // What Messages really offers on a bare link, in its own order.
        rows.addArrangedSubview(OnboardingMenuRowView(
            title: OnboardingStrings.SystemUI.openLink.value(),
            symbol: "safari"))
        rows.addArrangedSubview(OnboardingMenuRowView(
            title: OnboardingStrings.SystemUI.copy.value(),
            symbol: "doc.on.doc"))
        rows.addArrangedSubview(shareRow)
        for row in rows.arrangedSubviews {
            row.heightAnchor.constraint(
                equalToConstant: Self.rowHeight).isActive = true
        }
        (rows.arrangedSubviews.last as? OnboardingMenuRowView)?
            .showsSeparator = false

        alpha = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let source, let image = lifted.image else { return }
        // Transform-safe geometry throughout: both the lifted bubble and the
        // menu are mid-animation for most of this view's life, and setting
        // `frame` on a transformed view corrupts it.
        let padded = Self.paddedBounds(of: source)
        liftedRect = convert(padded, from: source)

        let menuHeight = CGFloat(rows.arrangedSubviews.count) * Self.rowHeight
        let topLimit = safeAreaInsets.top + Self.edgeMargin
        let bottomLimit = bounds.height - safeAreaInsets.bottom - Self.edgeMargin
        placesMenuBelowSource =
            liftedRect.maxY + Self.previewGap + menuHeight <= bottomLimit
        // If the menu fits on neither side, the system lifts the preview clear
        // of it rather than clipping the menu.
        var lift: CGFloat = 0
        if !placesMenuBelowSource {
            let wantedTop = liftedRect.minY - Self.previewGap - menuHeight
            lift = max(topLimit - wantedTop, 0)
        }
        liftedRect.origin.y -= lift

        lifted.bounds = CGRect(origin: .zero, size: image.size)
        lifted.center = CGPoint(x: liftedRect.midX, y: liftedRect.midY)

        let menuLeft = min(
            max(liftedRect.minX, Self.edgeMargin),
            bounds.width - Self.edgeMargin - Self.menuWidth)
        let menuTop = placesMenuBelowSource
            ? liftedRect.maxY + Self.previewGap
            : liftedRect.minY - Self.previewGap - menuHeight
        menu.bounds = CGRect(
            origin: .zero,
            size: CGSize(width: Self.menuWidth, height: menuHeight))
        // The menu grows out of the edge nearest the bubble, so that edge is
        // where its anchor sits.
        menu.layer.anchorPoint = CGPoint(
            x: 0.5, y: placesMenuBelowSource ? 0 : 1)
        menu.layer.position = CGPoint(
            x: menuLeft + Self.menuWidth / 2,
            y: placesMenuBelowSource ? menuTop : menuTop + menuHeight)
        // A clear view casts no shadow off its children, so the lift under the
        // menu is drawn from its shape rather than from its (empty) contents.
        menu.layer.shadowPath = UIBezierPath(
            roundedRect: menu.bounds,
            cornerRadius: Self.menuCornerRadius).cgPath
        menuGlass.frame = menu.bounds
        rows.frame = menu.bounds
    }

    /// Blur in, bubble up, menu out.
    func present(completion: @escaping () -> Void) {
        layoutIfNeeded()
        source?.alpha = 0
        alpha = 1

        if UIAccessibility.isReduceMotionEnabled {
            backdrop.effect = OnboardingSystemGlass.backdropEffect()
            dim.alpha = 1
            lifted.layer.shadowOpacity = 0.18
            menu.layer.shadowOpacity = 0.18
            menu.alpha = 0
            UIView.animate(withDuration: 0.2, animations: {
                self.menu.alpha = 1
            }) { _ in
                completion()
            }
            return
        }

        menu.alpha = 0
        menu.transform = CGAffineTransform(scaleX: 0.3, y: 0.3)
        lifted.transform = .identity
        // The material ramps in; it never cuts.
        UIView.animate(withDuration: 0.28, delay: 0, options: [.curveEaseOut]) {
            self.backdrop.effect = OnboardingSystemGlass.backdropEffect()
            self.dim.alpha = 1
        }
        animateShadow(of: lifted.layer, to: 0.18, duration: 0.34)
        animateShadow(of: menu.layer, to: 0.18, duration: 0.34)
        UIView.animate(
            withDuration: 0.34,
            delay: 0,
            usingSpringWithDamping: 0.8,
            initialSpringVelocity: 0.1,
            options: [.curveEaseOut, .beginFromCurrentState]
        ) {
            self.lifted.transform = CGAffineTransform(
                scaleX: Self.liftedScale, y: Self.liftedScale)
            self.menu.transform = .identity
        } completion: { _ in completion() }
        UIView.animate(withDuration: 0.14) { self.menu.alpha = 1 }
    }

    /// The scripted tap on Share…: the row lights the way a pressed menu row
    /// does, then the whole presentation collapses back into the bubble.
    func tapShare(completion: @escaping () -> Void) {
        let tap = OnboardingMockTapIndicatorView()
        tap.play(
            at: convert(
                CGPoint(x: shareRow.bounds.midX, y: shareRow.bounds.midY),
                from: shareRow),
            in: self,
            // Nothing to squeeze: a menu row lights up under a finger, and the
            // row does that itself.
            pressing: nil
        ) { [weak self] in
            self?.dismiss(completion: completion)
        }
        shareRow.flashHighlight()
    }

    /// Takes the presentation down without reporting a tap — the loop's own
    /// teardown — and gives the bubble back.
    func cancel() {
        layer.removeAllAnimations()
        menu.layer.removeAllAnimations()
        lifted.layer.removeAllAnimations()
        source?.alpha = 1
        removeFromSuperview()
    }

    private func dismiss(completion: @escaping () -> Void) {
        let finish = { [weak self] in
            self?.source?.alpha = 1
            self?.removeFromSuperview()
            completion()
        }
        guard !UIAccessibility.isReduceMotionEnabled else {
            UIView.animate(withDuration: 0.2, animations: {
                self.alpha = 0
            }) { _ in
                finish()
            }
            return
        }
        animateShadow(of: lifted.layer, to: 0, duration: 0.26)
        animateShadow(of: menu.layer, to: 0, duration: 0.26)
        UIView.animate(
            withDuration: 0.26,
            delay: 0,
            options: [.curveEaseIn, .beginFromCurrentState]
        ) {
            self.backdrop.effect = nil
            self.dim.alpha = 0
            self.lifted.transform = .identity
            self.menu.transform = CGAffineTransform(scaleX: 0.3, y: 0.3)
            self.menu.alpha = 0
        } completion: { _ in finish() }
    }

    /// `shadowOpacity` is a layer property, so it needs its own animation to
    /// travel with a UIView one.
    private func animateShadow(
        of layer: CALayer,
        to opacity: Float,
        duration: CFTimeInterval
    ) {
        let fade = CABasicAnimation(keyPath: "shadowOpacity")
        fade.fromValue = layer.shadowOpacity
        fade.toValue = opacity
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.shadowOpacity = opacity
        layer.add(
            fade,
            forKey: OnboardingStrings.AnimationKeys.contextMenuShadow.value())
    }

    /// The bubble's tail curls outside its own bounds, so the lifted copy is
    /// rendered from the layer over a padded rect rather than taken as a
    /// snapshot view (which would crop it, and could not be shadowed).
    private static func liftedImage(of source: UIView) -> UIImage? {
        let padded = paddedBounds(of: source)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        return UIGraphicsImageRenderer(bounds: padded, format: format).image {
            context in
            context.cgContext.translateBy(x: -padded.minX, y: -padded.minY)
            source.layer.render(in: context.cgContext)
        }
    }

    private static func paddedBounds(of source: UIView) -> CGRect {
        source.bounds.insetBy(dx: -8, dy: -2)
    }
}

/// One row of a system menu: title leading, symbol trailing, hairline below.
final class OnboardingMenuRowView: UIView {
    private let highlight = UIView()
    private let separator = UIView()

    var showsSeparator: Bool = true {
        didSet { separator.isHidden = !showsSeparator }
    }

    init(title: String, symbol: String) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false

        highlight.backgroundColor = .systemFill
        highlight.alpha = 0
        highlight.translatesAutoresizingMaskIntoConstraints = false
        addSubview(highlight)

        let label = UILabel()
        label.text = title
        label.font = .systemFont(ofSize: 17)
        label.textColor = .label
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        let icon = UIImageView(image: UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 17)))
        icon.tintColor = .label
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)

        separator.backgroundColor = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        NSLayoutConstraint.activate([
            highlight.topAnchor.constraint(equalTo: topAnchor),
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            label.trailingAnchor.constraint(
                lessThanOrEqualTo: icon.leadingAnchor, constant: -8),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(
                equalToConstant: 1 / max(traitCollection.displayScale, 2)),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The press state of a menu row: in under the finger, out with the menu.
    func flashHighlight() {
        UIView.animate(
            withDuration: 0.10,
            delay: OnboardingAnimationClock.delay(0.16),
            options: [.curveEaseOut]
        ) {
            self.highlight.alpha = 1
        }
    }
}

/// A deliberately finite facsimile of iOS's share sheet. It renders only the
/// rows the lesson needs, then drives the exact edit/promotion path with the
/// same visible tap indicator used by the shortcut demonstration.
///
/// Everything it is made of is the OS's own: the card is a thick system material
/// under a system sheet radius, the grouped lists are system fills with system
/// hairlines between their rows, the labels are `.label`/`.secondaryLabel`, and
/// the close button is glass. It used to be hand-mixed greys and hardcoded
/// whites, which is how a replica ends up looking like a drawing of a share
/// sheet instead of one.
final class OnboardingMockShareSheetView: UIView {
    private enum Screen { case share, edit }

    /// A presented sheet's corner radius, and the metrics of the chrome around
    /// its top edge.
    private static let cardCornerRadius: CGFloat = 38
    private static let closeButtonSide: CGFloat = 30
    /// A share target's tile: the system draws app icons and avatars at 60pt,
    /// with the continuous-corner radius Springboard uses.
    private static let tileSide: CGFloat = 60

    private let appName: String
    private let urlString: String
    private let appIcon: UIImage?
    private let scrim = UIView()
    private let card = UIView()
    private let cardGlass = UIVisualEffectView(
        effect: OnboardingSystemGlass.sheetEffect())
    private let grabber = UIView()
    private let closeButton = UIVisualEffectView(
        effect: OnboardingSystemGlass.controlEffect())
    private let scrollView = UIScrollView()
    private let shareContent = UIView()
    private let editContent = UIView()
    private let editButton = UIButton(type: .system)
    private let doneButton = UIButton(type: .system)
    private let lunaPlusButton = UIButton(type: .system)
    private var lunaActionView: UIView?
    private var lunaEditRow: UIView?
    private var lunaIsFavorite = false
    private var screen = Screen.share
    private var walkthroughGeneration = 0

    init(frame: CGRect, appName: String, urlString: String, appIcon: UIImage?) {
        self.appName = appName
        self.urlString = urlString
        self.appIcon = appIcon
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityIdentifier = "onboarding.messages.mockShareSheet"
        // A system sheet, so its materials and semantic colours have to resolve
        // DARK — which is what the app pins everywhere (the sky it paints is a
        // trait, not a style). This particular view, though, lives inside the
        // Messages replica, which pins ITSELF to `.light` because iMessage is
        // white; without this the share sheet would come up in light glass with
        // black-on-black labels.
        overrideUserInterfaceStyle = .dark

        scrim.backgroundColor = UIColor.black.withAlphaComponent(0.34)
        scrim.alpha = 0
        addSubview(scrim)
        card.layer.cornerRadius = Self.cardCornerRadius
        card.layer.cornerCurve = .continuous
        card.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        card.clipsToBounds = true
        addSubview(card)
        // The sheet's material, behind everything the sheet draws.
        cardGlass.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        card.addSubview(cardGlass)
        grabber.backgroundColor = .tertiaryLabel
        grabber.layer.cornerRadius = 2.5
        card.addSubview(grabber)
        OnboardingSystemGlass.round(
            closeButton, radius: Self.closeButtonSide / 2)
        let closeGlyph = UIImageView(image: UIImage(
            systemName: "xmark",
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: 13, weight: .bold)))
        closeGlyph.tintColor = .secondaryLabel
        closeGlyph.contentMode = .center
        closeGlyph.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        closeButton.contentView.addSubview(closeGlyph)
        closeGlyph.frame = CGRect(
            origin: .zero,
            size: CGSize(width: Self.closeButtonSide, height: Self.closeButtonSide))
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        card.addSubview(scrollView)
        scrollView.addSubview(shareContent)
        card.addSubview(editContent)
        editContent.isHidden = true
        buildShareContent()
        buildEditContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrim.frame = bounds
        let top: CGFloat = max(safeAreaInsets.top + 20, 58)
        card.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - top)
        card.center = CGPoint(x: bounds.midX, y: top + card.bounds.height / 2)
        cardGlass.frame = card.bounds
        grabber.frame = CGRect(x: (card.bounds.width - 36) / 2, y: 6, width: 36, height: 5)
        scrollView.frame = CGRect(x: 0, y: 18, width: card.bounds.width, height: card.bounds.height - 18)
        // Keep Edit Actions just below the first viewport even on tall phones,
        // so the lesson visibly scrolls through the two action rows to reach it.
        shareContent.frame = CGRect(
            x: 0,
            y: 0,
            width: scrollView.bounds.width,
            height: max(860, scrollView.bounds.height + 82))
        scrollView.contentSize = shareContent.bounds.size
        editContent.frame = CGRect(x: 0, y: 18, width: card.bounds.width, height: card.bounds.height - 18)
        layoutShareContent()
        layoutEditContent()
    }

    func playWalkthrough(completion: @escaping () -> Void) {
        walkthroughGeneration += 1
        let generation = walkthroughGeneration
        card.transform = CGAffineTransform(translationX: 0, y: card.bounds.height)
        // The dim arrives ahead of the card, as it does on a real sheet: the
        // screen is already backing off by the time the sheet catches up to it.
        UIView.animate(withDuration: 0.30, delay: 0, options: [.curveEaseOut]) {
            self.scrim.alpha = 1
        }
        UIView.animate(
            withDuration: 0.52,
            delay: 0,
            usingSpringWithDamping: 0.86,
            initialSpringVelocity: 0,
            options: [.curveEaseOut]
        ) {
            self.card.transform = .identity
        } completion: { [weak self] _ in
            guard let self else { return }
            self.after(OnboardingShareSheetTiming.sheetSettle, generation: generation) {
                self.scrollToEdit(generation: generation, completion: completion)
            }
        }
    }

    func cancelWalkthrough() {
        walkthroughGeneration += 1
        layer.removeAllAnimations()
        removeFromSuperview()
    }

    private func scrollToEdit(generation: Int, completion: @escaping () -> Void) {
        let target = max(scrollView.contentSize.height - scrollView.bounds.height, 0)
        UIView.animate(
            withDuration: OnboardingShareSheetTiming.scrollDuration,
            delay: 0,
            options: [.curveEaseInOut]
        ) {
            self.scrollView.contentOffset.y = target
        } completion: { [weak self] _ in
            guard let self else { return }
            self.after(OnboardingShareSheetTiming.betweenSteps, generation: generation) {
                self.tap(view: self.editButton, generation: generation) {
                    self.showEditScreen(generation: generation, completion: completion)
                }
            }
        }
    }

    private func showEditScreen(generation: Int, completion: @escaping () -> Void) {
        screen = .edit
        editContent.isHidden = false
        editContent.alpha = 0
        editContent.transform = CGAffineTransform(translationX: bounds.width * 0.16, y: 0)
        UIView.animate(withDuration: OnboardingShareSheetTiming.editTransitionDuration) {
            self.scrollView.alpha = 0
            self.scrollView.transform = CGAffineTransform(translationX: -self.bounds.width * 0.12, y: 0)
            self.editContent.alpha = 1
            self.editContent.transform = .identity
        } completion: { [weak self] _ in
            guard let self else { return }
            self.scrollView.isHidden = true
            self.after(OnboardingShareSheetTiming.betweenSteps, generation: generation) {
                self.tap(view: self.lunaPlusButton, generation: generation) {
                    self.promoteLuna(generation: generation, completion: completion)
                }
            }
        }
    }

    private func promoteLuna(generation: Int, completion: @escaping () -> Void) {
        guard let sourceRow = lunaEditRow,
              let flyingRow = sourceRow.snapshotView(afterScreenUpdates: true)
        else {
            finishPromotionWithoutFlight(
                generation: generation,
                completion: completion)
            return
        }
        let sourceFrame = editContent.convert(sourceRow.bounds, from: sourceRow)
        flyingRow.frame = sourceFrame
        editContent.addSubview(flyingRow)
        sourceRow.alpha = 0
        lunaIsFavorite = true
        buildEditRows()
        layoutEditContent()
        guard let favoritesCard = editContent.viewWithTag(201),
              let destinationRow = favoritesCard.subviews.last
        else {
            flyingRow.removeFromSuperview()
            scheduleDoneAfterPromotion(
                generation: generation,
                completion: completion)
            return
        }
        destinationRow.alpha = 0
        let destinationFrame = editContent.convert(
            destinationRow.bounds,
            from: destinationRow)
        UIView.animate(
            withDuration: OnboardingShareSheetTiming.promotionDuration,
            delay: 0,
            usingSpringWithDamping: 0.82,
            initialSpringVelocity: 0.25,
            options: [.curveEaseInOut]
        ) {
            flyingRow.frame = destinationFrame
            flyingRow.transform = CGAffineTransform(scaleX: 1.02, y: 1.02)
        } completion: { [weak self] _ in
            guard let self else { return }
            flyingRow.removeFromSuperview()
            destinationRow.alpha = 1
            self.scheduleDoneAfterPromotion(
                generation: generation,
                completion: completion)
        }
    }

    private func finishPromotionWithoutFlight(
        generation: Int,
        completion: @escaping () -> Void
    ) {
        lunaIsFavorite = true
        UIView.transition(
            with: editContent,
            duration: OnboardingShareSheetTiming.promotionDuration,
            options: [.transitionCrossDissolve]
        ) {
            self.buildEditRows()
            self.layoutEditContent()
        } completion: { [weak self] _ in
            self?.scheduleDoneAfterPromotion(
                generation: generation,
                completion: completion)
        }
    }

    private func scheduleDoneAfterPromotion(
        generation: Int,
        completion: @escaping () -> Void
    ) {
        after(OnboardingShareSheetTiming.betweenSteps, generation: generation) {
            self.tap(view: self.doneButton, generation: generation) {
                self.returnToShareScreen(generation: generation, completion: completion)
            }
        }
    }

    private func returnToShareScreen(generation: Int, completion: @escaping () -> Void) {
        screen = .share
        rebuildActionFavorites()
        scrollView.isHidden = false
        scrollView.alpha = 0
        scrollView.transform = CGAffineTransform(translationX: -bounds.width * 0.12, y: 0)
        UIView.animate(withDuration: OnboardingShareSheetTiming.editTransitionDuration) {
            self.editContent.alpha = 0
            self.editContent.transform = CGAffineTransform(translationX: self.bounds.width * 0.14, y: 0)
            self.scrollView.alpha = 1
            self.scrollView.transform = .identity
        } completion: { [weak self] _ in
            guard let self else { return }
            self.editContent.isHidden = true
            UIView.animate(
                withDuration: OnboardingShareSheetTiming.scrollDuration,
                delay: 0,
                options: [.curveEaseInOut]
            ) {
                self.scrollView.contentOffset = .zero
            } completion: { [weak self] _ in
                guard let self else { return }
                self.after(OnboardingShareSheetTiming.betweenSteps, generation: generation) {
                    guard let luna = self.lunaActionView else { return }
                    self.tap(view: luna, generation: generation) {
                        self.dismiss(completion: completion)
                    }
                }
            }
        }
    }

    private func dismiss(completion: @escaping () -> Void) {
        UIView.animate(
            withDuration: 0.34,
            delay: 0,
            options: [.curveEaseIn, .beginFromCurrentState]
        ) {
            self.scrim.alpha = 0
            self.card.transform = CGAffineTransform(
                translationX: 0, y: self.card.bounds.height)
        } completion: { _ in
            self.removeFromSuperview()
            completion()
        }
    }

    private func tap(view target: UIView, generation: Int, completion: @escaping () -> Void) {
        guard generation == walkthroughGeneration else { return }
        let tap = OnboardingMockTapIndicatorView()
        tap.play(
            at: convert(
                CGPoint(x: target.bounds.midX, y: target.bounds.midY),
                from: target),
            in: self,
            pressing: target
        ) { [weak self] in
            guard let self, generation == self.walkthroughGeneration else { return }
            completion()
        }
    }

    private func after(_ delay: TimeInterval, generation: Int, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(
            deadline: .now() + OnboardingAnimationClock.delay(delay)
        ) { [weak self] in
            guard let self, generation == self.walkthroughGeneration else { return }
            work()
        }
    }

    // MARK: Share sheet construction

    private func buildShareContent() {
        let preview = UIView()
        preview.tag = 10
        shareContent.addSubview(preview)
        let icon = UIImageView(image: UIImage(systemName: "link.circle.fill"))
        icon.tag = 1
        icon.tintColor = .systemBlue
        icon.contentMode = .scaleAspectFit
        preview.addSubview(icon)
        let title = UILabel()
        title.tag = 2
        title.text = urlString
        title.textColor = .label
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        preview.addSubview(title)
        let host = UILabel()
        host.tag = 3
        host.text = URL(string: urlString)?.host
        host.textColor = .secondaryLabel
        host.font = .systemFont(ofSize: 14)
        preview.addSubview(host)
        // The close button rides with the item preview, as it does on the real
        // sheet — both scroll away together.
        preview.addSubview(closeButton)

        let people = UIView()
        people.tag = 20
        shareContent.addSubview(people)
        people.addSubview(targetTile(
            title: OnboardingStrings.SystemUI.laptop.value(),
            symbol: "laptopcomputer",
            tint: .systemBlue))
        people.addSubview(targetTile(
            title: OnboardingStrings.SystemUI.contact.value(),
            symbol: "person.crop.circle.fill",
            tint: .systemGray))

        let apps = UIView()
        apps.tag = 30
        shareContent.addSubview(apps)
        let appItems: [(String, String, UIColor)] = [
            // There is no public AirDrop app artwork. This is the supported
            // system radio-wave glyph on the iOS 26 fallback; `airdrop` is not
            // an available SF Symbol there and renders an empty tile.
            (OnboardingStrings.SystemUI.airDrop.value(),
             "dot.radiowaves.up.forward", .systemBlue),
            (OnboardingStrings.SystemUI.messages.value(),
             "message.fill", .systemGreen),
            (OnboardingStrings.SystemUI.reminders.value(),
             "list.bullet.circle.fill", .systemIndigo),
            (OnboardingStrings.SystemUI.more.value(), "ellipsis", .systemGray),
        ]
        for item in appItems { apps.addSubview(iconTile(title: item.0, symbol: item.1, tint: item.2)) }

        let favorites = UIView()
        favorites.tag = 40
        shareContent.addSubview(favorites)
        let actions = UIView()
        actions.tag = 50
        // A grouped list on a sheet is a system fill over the sheet's material,
        // not a hand-mixed white wash.
        actions.backgroundColor = .secondarySystemFill
        actions.layer.cornerRadius = 18
        actions.layer.cornerCurve = .continuous
        actions.clipsToBounds = true
        shareContent.addSubview(actions)
        actions.addSubview(actionRow(
            title: OnboardingStrings.SystemUI.saveToFiles.value(),
            symbol: "folder"))
        actions.addSubview(actionRow(
            title: OnboardingStrings.SystemUI.addToReadingList.value(),
            symbol: "eyeglasses"))

        var editConfiguration = UIButton.Configuration.gray()
        editConfiguration.title = OnboardingStrings.SystemUI.editActions.value()
        editConfiguration.baseForegroundColor = .label
        editConfiguration.cornerStyle = .capsule
        editButton.configuration = editConfiguration
        shareContent.addSubview(editButton)
        rebuildActionFavorites()
    }

    private func layoutShareContent() {
        guard let preview = shareContent.viewWithTag(10),
              let people = shareContent.viewWithTag(20),
              let apps = shareContent.viewWithTag(30),
              let favorites = shareContent.viewWithTag(40),
              let actions = shareContent.viewWithTag(50)
        else { return }
        let inset: CGFloat = 22
        let width = shareContent.bounds.width - inset * 2
        preview.frame = CGRect(x: inset, y: 8, width: width, height: 76)
        preview.viewWithTag(1)?.frame = CGRect(x: 4, y: 13, width: 48, height: 48)
        // The title stops short of the close button rather than sliding under it.
        let titleWidth = width - 68 - Self.closeButtonSide - 12
        preview.viewWithTag(2)?.frame = CGRect(x: 64, y: 12, width: titleWidth, height: 28)
        preview.viewWithTag(3)?.frame = CGRect(x: 64, y: 40, width: titleWidth, height: 22)
        closeButton.frame = CGRect(
            x: width - Self.closeButtonSide,
            y: (76 - Self.closeButtonSide) / 2,
            width: Self.closeButtonSide,
            height: Self.closeButtonSide)
        people.frame = CGRect(x: inset, y: 98, width: width, height: 126)
        layoutTiles(in: people, side: Self.tileSide, count: 2, circular: true)
        apps.frame = CGRect(x: inset, y: 236, width: width, height: 126)
        layoutTiles(in: apps, side: Self.tileSide, count: 4)
        favorites.frame = CGRect(x: inset, y: 374, width: width, height: 118)
        layoutTiles(
            in: favorites, side: Self.tileSide, count: favorites.subviews.count)
        actions.frame = CGRect(x: inset, y: 510, width: width, height: 116)
        for (index, row) in actions.subviews.enumerated() {
            row.frame = CGRect(x: 0, y: CGFloat(index) * 58, width: width, height: 58)
            (row as? OnboardingSheetListRow)?.showsSeparator =
                index < actions.subviews.count - 1
        }
        editButton.frame = CGRect(
            x: (shareContent.bounds.width - 156) / 2,
            y: shareContent.bounds.height - 70,
            width: 156,
            height: 50)
    }

    private func rebuildActionFavorites() {
        guard let favorites = shareContent.viewWithTag(40) else { return }
        favorites.subviews.forEach { $0.removeFromSuperview() }
        favorites.addSubview(iconTile(
            title: OnboardingStrings.SystemUI.copy.value(),
            symbol: "doc.on.doc",
            tint: .systemGray))
        lunaActionView = nil
        if lunaIsFavorite {
            let luna = iconTile(title: appName, image: appIcon, tint: .systemGray)
            favorites.addSubview(luna)
            lunaActionView = luna
        }
        setNeedsLayout()
    }

    // MARK: Edit Actions construction

    private func buildEditContent() {
        let title = UILabel()
        title.tag = 101
        title.text = OnboardingStrings.SystemUI.editActions.value()
        title.textColor = .label
        title.textAlignment = .center
        title.font = .systemFont(ofSize: 25, weight: .bold)
        editContent.addSubview(title)
        var doneConfiguration = UIButton.Configuration.filled()
        doneConfiguration.image = UIImage(systemName: "checkmark")
        doneConfiguration.cornerStyle = .capsule
        doneButton.configuration = doneConfiguration
        editContent.addSubview(doneButton)
        buildEditRows()
    }

    private func buildEditRows() {
        lunaEditRow = nil
        editContent.subviews.filter { $0.tag >= 200 }.forEach { $0.removeFromSuperview() }
        let favoritesLabel = sectionLabel(
            OnboardingStrings.SystemUI.favorites.value())
        favoritesLabel.tag = 200
        editContent.addSubview(favoritesLabel)
        let favoritesCard = groupedListCard(tag: 201)
        editContent.addSubview(favoritesCard)
        favoritesCard.addSubview(editRow(
            title: OnboardingStrings.SystemUI.copy.value(), favorite: true))
        if lunaIsFavorite {
            favoritesCard.addSubview(editRow(title: appName, favorite: true, image: appIcon))
        }

        let otherLabel = sectionLabel(
            OnboardingStrings.SystemUI.otherActions.value())
        otherLabel.tag = 202
        editContent.addSubview(otherLabel)
        let otherCard = groupedListCard(tag: 203)
        editContent.addSubview(otherCard)
        if !lunaIsFavorite {
            let luna = editRow(title: appName, favorite: false, image: appIcon)
            lunaEditRow = luna
            lunaPlusButton.removeFromSuperview()
            lunaPlusButton.setImage(UIImage(systemName: "plus.circle.fill"), for: .normal)
            lunaPlusButton.tintColor = .systemGreen
            luna.addSubview(lunaPlusButton)
            otherCard.addSubview(luna)
        }
        otherCard.addSubview(editRow(
            title: OnboardingStrings.SystemUI.saveToFiles.value(),
            favorite: false,
            symbol: "folder"))
        otherCard.addSubview(editRow(
            title: OnboardingStrings.SystemUI.addToReadingList.value(),
            favorite: false,
            symbol: "eyeglasses"))
    }

    /// One grouped list on the Edit Actions screen. Its rows are its only
    /// subviews — `layoutEditRows` and the promotion flight both count on that.
    private func groupedListCard(tag: Int) -> UIView {
        let card = UIView()
        card.tag = tag
        card.backgroundColor = .secondarySystemFill
        card.layer.cornerRadius = 18
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        return card
    }

    private func layoutEditContent() {
        editContent.viewWithTag(101)?.frame = CGRect(
            x: 90, y: 14, width: editContent.bounds.width - 180, height: 48)
        doneButton.frame = CGRect(x: editContent.bounds.width - 72, y: 12, width: 52, height: 52)
        guard let favoritesLabel = editContent.viewWithTag(200),
              let favoritesCard = editContent.viewWithTag(201),
              let otherLabel = editContent.viewWithTag(202),
              let otherCard = editContent.viewWithTag(203)
        else { return }
        let inset: CGFloat = 20
        let width = editContent.bounds.width - inset * 2
        favoritesLabel.frame = CGRect(x: inset + 14, y: 86, width: width, height: 32)
        let favoriteHeight = CGFloat(favoritesCard.subviews.count) * 60
        favoritesCard.frame = CGRect(x: inset, y: 122, width: width, height: favoriteHeight)
        layoutEditRows(in: favoritesCard)
        otherLabel.frame = CGRect(x: inset + 14, y: favoritesCard.frame.maxY + 42, width: width, height: 32)
        otherCard.frame = CGRect(
            x: inset, y: otherLabel.frame.maxY + 4,
            width: width, height: CGFloat(otherCard.subviews.count) * 60)
        layoutEditRows(in: otherCard)
    }

    private func layoutEditRows(in card: UIView) {
        for (index, row) in card.subviews.enumerated() {
            row.frame = CGRect(x: 0, y: CGFloat(index) * 60, width: card.bounds.width, height: 60)
            (row as? OnboardingSheetListRow)?.showsSeparator =
                index < card.subviews.count - 1
            if row.subviews.contains(lunaPlusButton) {
                lunaPlusButton.frame = CGRect(x: 14, y: 15, width: 30, height: 30)
            }
        }
    }

    // MARK: Small reusable mock pieces

    private func targetTile(title: String, symbol: String, tint: UIColor) -> UIView {
        iconTile(title: title, symbol: symbol, tint: tint, circular: true)
    }

    private func iconTile(
        title: String,
        symbol: String,
        tint: UIColor,
        circular: Bool = false
    ) -> UIView {
        iconTile(title: title, image: UIImage(systemName: symbol), tint: tint, circular: circular)
    }

    private func iconTile(
        title: String,
        image: UIImage?,
        tint: UIColor,
        circular: Bool = false
    ) -> UIView {
        let container = UIView()
        let tile = UIView()
        tile.tag = 1
        tile.backgroundColor = circular ? .quaternarySystemFill : tint
        tile.layer.cornerCurve = .continuous
        tile.clipsToBounds = true
        container.addSubview(tile)
        let icon = UIImageView(image: image)
        icon.tag = 2
        icon.contentMode = .scaleAspectFit
        icon.tintColor = circular ? .secondaryLabel : .white
        icon.layer.cornerRadius = 13
        icon.layer.cornerCurve = .continuous
        icon.clipsToBounds = true
        tile.addSubview(icon)
        let label = UILabel()
        label.tag = 3
        label.text = title
        label.textColor = .label
        label.font = .systemFont(ofSize: 13)
        label.textAlignment = .center
        label.numberOfLines = 2
        container.addSubview(label)
        return container
    }

    private func layoutTiles(
        in host: UIView,
        side: CGFloat,
        count: Int,
        circular: Bool = false
    ) {
        guard count > 0 else { return }
        let slot = host.bounds.width / CGFloat(max(count, 4))
        for (index, item) in host.subviews.enumerated() {
            item.frame = CGRect(x: CGFloat(index) * slot, y: 0, width: slot, height: host.bounds.height)
            let tileSide = min(side, slot - 8)
            item.viewWithTag(1)?.frame = CGRect(
                x: (slot - tileSide) / 2, y: 0, width: tileSide, height: tileSide)
            // An avatar is round; an app icon takes Springboard's own ratio of
            // radius to side.
            item.viewWithTag(1)?.layer.cornerRadius = circular
                ? tileSide / 2
                : (tileSide * 0.2255).rounded()
            item.viewWithTag(2)?.frame = CGRect(
                x: tileSide * 0.18, y: tileSide * 0.18,
                width: tileSide * 0.64, height: tileSide * 0.64)
            item.viewWithTag(3)?.frame = CGRect(
                x: 0, y: tileSide + 6, width: slot, height: 38)
        }
    }

    private func actionRow(title: String, symbol: String) -> OnboardingSheetListRow {
        let row = OnboardingSheetListRow(separatorInset: 62)
        let icon = UIImageView(image: UIImage(systemName: symbol))
        icon.tintColor = .label
        icon.contentMode = .scaleAspectFit
        icon.frame = CGRect(x: 18, y: 15, width: 28, height: 28)
        row.addSubview(icon)
        let label = UILabel()
        label.text = title
        label.textColor = .label
        label.font = .systemFont(ofSize: 18)
        label.frame = CGRect(x: 62, y: 0, width: 270, height: 58)
        row.addSubview(label)
        return row
    }

    private func sectionLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.textColor = .secondaryLabel
        label.font = .systemFont(ofSize: 22, weight: .bold)
        return label
    }

    private func editRow(
        title: String,
        favorite: Bool,
        symbol: String? = nil,
        image: UIImage? = nil
    ) -> OnboardingSheetListRow {
        let row = OnboardingSheetListRow(separatorInset: 58)
        row.tag = 300
        let leading = UIImageView(image: UIImage(
            systemName: favorite ? "minus.circle.fill" : "plus.circle.fill"))
        leading.tintColor = favorite ? .systemRed : .systemGreen
        leading.contentMode = .scaleAspectFit
        leading.layer.cornerRadius = 7
        leading.clipsToBounds = true
        leading.frame = CGRect(x: 15, y: 16, width: 28, height: 28)
        row.addSubview(leading)
        let label = UILabel()
        label.text = title
        label.textColor = .label
        label.font = .systemFont(ofSize: 18)
        label.frame = CGRect(x: 58, y: 0, width: 260, height: 60)
        row.addSubview(label)
        if favorite {
            let reorder = UIImageView(image: UIImage(systemName: "line.3.horizontal"))
            reorder.tintColor = .tertiaryLabel
            reorder.frame = CGRect(x: 326, y: 19, width: 28, height: 22)
            reorder.autoresizingMask = [.flexibleLeftMargin]
            row.addSubview(reorder)
        }
        return row
    }
}

/// A row of a grouped list inside the mock share sheet, carrying the hairline
/// iOS draws between rows — inset to the label, and never under the last one.
private final class OnboardingSheetListRow: UIView {
    private let separator = UIView()
    private let separatorInset: CGFloat

    var showsSeparator = true {
        didSet { separator.isHidden = !showsSeparator }
    }

    init(separatorInset: CGFloat) {
        self.separatorInset = separatorInset
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        separator.backgroundColor = .separator
        addSubview(separator)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        let hairline = 1 / max(traitCollection.displayScale, 2)
        separator.frame = CGRect(
            x: separatorInset,
            y: bounds.height - hairline,
            width: max(bounds.width - separatorInset, 0),
            height: hairline)
        bringSubviewToFront(separator)
    }
}

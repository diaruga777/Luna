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

/// The preview card and Copy/Share menu iMessage displays after a link is held.
final class OnboardingMockLinkContextMenuView: UIView {
    private let scrim = UIView()
    private let preview = UIView()
    private let menu = UIStackView()
    private let shareButton = UIButton(type: .system)
    private let urlString: String

    init(frame: CGRect, urlString: String) {
        self.urlString = urlString
        super.init(frame: frame)
        isUserInteractionEnabled = false

        scrim.frame = bounds
        scrim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrim.backgroundColor = UIColor.black.withAlphaComponent(0.36)
        addSubview(scrim)

        preview.backgroundColor = .white
        preview.layer.cornerRadius = 18
        preview.layer.cornerCurve = .continuous
        preview.layer.shadowColor = UIColor.black.cgColor
        preview.layer.shadowOpacity = 0.2
        preview.layer.shadowRadius = 18
        addSubview(preview)

        let icon = UIImageView(image: UIImage(
            systemName: "link",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold)))
        icon.tintColor = .systemBlue
        icon.contentMode = .center
        preview.addSubview(icon)
        let label = UILabel()
        label.text = urlString
        label.textColor = UIColor(white: 0.1, alpha: 1)
        label.font = .systemFont(ofSize: 16, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        preview.addSubview(label)
        icon.frame = CGRect(x: 14, y: 13, width: 36, height: 36)
        label.frame = CGRect(x: 58, y: 12, width: 258, height: 38)

        menu.axis = .vertical
        menu.spacing = 1
        menu.layer.cornerRadius = 16
        menu.layer.cornerCurve = .continuous
        menu.clipsToBounds = true
        addSubview(menu)
        menu.addArrangedSubview(menuButton(title: "Copy", symbol: "doc.on.doc"))
        shareButton.configuration = menuConfiguration(title: "Share…", symbol: "square.and.arrow.up")
        shareButton.backgroundColor = UIColor(white: 0.97, alpha: 1)
        menu.addArrangedSubview(shareButton)

        alpha = 0
        preview.transform = CGAffineTransform(scaleX: 0.82, y: 0.82)
        menu.transform = CGAffineTransform(scaleX: 0.82, y: 0.82)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = min(bounds.width - 44, 332)
        preview.frame = CGRect(
            x: (bounds.width - width) / 2,
            y: max(bounds.midY - 118, 124),
            width: width,
            height: 62)
        menu.frame = CGRect(
            x: preview.frame.minX,
            y: preview.frame.maxY + 10,
            width: width,
            height: 102)
    }

    func present(completion: @escaping () -> Void) {
        UIView.animate(
            withDuration: 0.34,
            delay: 0,
            usingSpringWithDamping: 0.78,
            initialSpringVelocity: 0.2,
            options: [.curveEaseOut]
        ) {
            self.alpha = 1
            self.preview.transform = .identity
            self.menu.transform = .identity
        } completion: { _ in completion() }
    }

    func tapShare(completion: @escaping () -> Void) {
        let tap = OnboardingMockTapIndicatorView()
        tap.play(
            at: convert(
                CGPoint(x: shareButton.bounds.midX, y: shareButton.bounds.midY),
                from: shareButton),
            in: self,
            pressing: shareButton
        ) { [weak self] in
            guard let self else { return }
            UIView.animate(withDuration: 0.22, animations: {
                self.alpha = 0
            }) { _ in
                self.removeFromSuperview()
                completion()
            }
        }
    }

    private func menuButton(title: String, symbol: String) -> UIButton {
        let button = UIButton(type: .system)
        button.configuration = menuConfiguration(title: title, symbol: symbol)
        button.backgroundColor = UIColor(white: 0.97, alpha: 1)
        return button
    }

    private func menuConfiguration(title: String, symbol: String) -> UIButton.Configuration {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.image = UIImage(systemName: symbol)
        configuration.imagePlacement = .trailing
        configuration.imagePadding = 8
        configuration.baseForegroundColor = UIColor(white: 0.08, alpha: 1)
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 10, leading: 16, bottom: 10, trailing: 16)
        return configuration
    }
}

/// A deliberately finite facsimile of iOS's share sheet. It renders only the
/// rows the lesson needs, then drives the exact edit/promotion path with the
/// same visible tap indicator used by the shortcut demonstration.
final class OnboardingMockShareSheetView: UIView {
    private enum Screen { case share, edit }

    private let appName: String
    private let urlString: String
    private let appIcon: UIImage?
    private let scrim = UIView()
    private let card = UIView()
    private let grabber = UIView()
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

        scrim.backgroundColor = UIColor.black.withAlphaComponent(0.34)
        scrim.alpha = 0
        addSubview(scrim)
        card.backgroundColor = UIColor(red: 0.11, green: 0.115, blue: 0.12, alpha: 0.98)
        card.layer.cornerRadius = 30
        card.layer.cornerCurve = .continuous
        card.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        card.clipsToBounds = true
        addSubview(card)
        grabber.backgroundColor = UIColor.white.withAlphaComponent(0.32)
        grabber.layer.cornerRadius = 2.5
        card.addSubview(grabber)
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
        grabber.frame = CGRect(x: (card.bounds.width - 38) / 2, y: 7, width: 38, height: 5)
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
        UIView.animate(
            withDuration: 0.52,
            delay: 0,
            usingSpringWithDamping: 0.90,
            initialSpringVelocity: 0,
            options: [.curveEaseOut]
        ) {
            self.scrim.alpha = 1
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
        UIView.animate(withDuration: 0.34, animations: {
            self.scrim.alpha = 0
            self.card.transform = CGAffineTransform(translationX: 0, y: self.card.bounds.height)
        }) { _ in
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
        title.textColor = .white
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        preview.addSubview(title)
        let host = UILabel()
        host.tag = 3
        host.text = URL(string: urlString)?.host
        host.textColor = UIColor.white.withAlphaComponent(0.55)
        host.font = .systemFont(ofSize: 14)
        preview.addSubview(host)

        let people = UIView()
        people.tag = 20
        shareContent.addSubview(people)
        people.addSubview(targetTile(title: "Laptop", symbol: "laptopcomputer", tint: .systemBlue))
        people.addSubview(targetTile(title: "Johnny\nAppleseed", symbol: "person.crop.circle.fill", tint: .systemGray))

        let apps = UIView()
        apps.tag = 30
        shareContent.addSubview(apps)
        let appItems: [(String, String, UIColor)] = [
            // There is no public AirDrop app artwork. This is the supported
            // system radio-wave glyph on the iOS 26 fallback; `airdrop` is not
            // an available SF Symbol there and renders an empty tile.
            ("AirDrop", "dot.radiowaves.up.forward", .systemBlue),
            ("Messages", "message.fill", .systemGreen),
            ("Reminders", "list.bullet.circle.fill", .systemIndigo),
            ("More", "ellipsis", .systemGray),
        ]
        for item in appItems { apps.addSubview(iconTile(title: item.0, symbol: item.1, tint: item.2)) }

        let favorites = UIView()
        favorites.tag = 40
        shareContent.addSubview(favorites)
        let actions = UIView()
        actions.tag = 50
        actions.backgroundColor = UIColor.white.withAlphaComponent(0.10)
        actions.layer.cornerRadius = 18
        actions.layer.cornerCurve = .continuous
        shareContent.addSubview(actions)
        actions.addSubview(actionRow(title: "Save to Files", symbol: "folder"))
        actions.addSubview(actionRow(title: "Add to Reading List", symbol: "eyeglasses"))

        var editConfiguration = UIButton.Configuration.gray()
        editConfiguration.title = "Edit Actions"
        editConfiguration.baseForegroundColor = .white
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
        preview.viewWithTag(2)?.frame = CGRect(x: 64, y: 12, width: width - 68, height: 28)
        preview.viewWithTag(3)?.frame = CGRect(x: 64, y: 40, width: width - 68, height: 22)
        people.frame = CGRect(x: inset, y: 98, width: width, height: 126)
        layoutTiles(in: people, side: 76, count: 2)
        apps.frame = CGRect(x: inset, y: 236, width: width, height: 126)
        layoutTiles(in: apps, side: 68, count: 4)
        favorites.frame = CGRect(x: inset, y: 374, width: width, height: 118)
        layoutTiles(in: favorites, side: 68, count: favorites.subviews.count)
        actions.frame = CGRect(x: inset, y: 510, width: width, height: 116)
        for (index, row) in actions.subviews.enumerated() {
            row.frame = CGRect(x: 0, y: CGFloat(index) * 58, width: width, height: 58)
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
        favorites.addSubview(iconTile(title: "Copy", symbol: "doc.on.doc", tint: .systemGray))
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
        title.text = "Edit Actions"
        title.textColor = .white
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
        let favoritesLabel = sectionLabel("Favorites")
        favoritesLabel.tag = 200
        editContent.addSubview(favoritesLabel)
        let favoritesCard = UIView()
        favoritesCard.tag = 201
        favoritesCard.backgroundColor = UIColor.white.withAlphaComponent(0.10)
        favoritesCard.layer.cornerRadius = 18
        editContent.addSubview(favoritesCard)
        favoritesCard.addSubview(editRow(title: "Copy", favorite: true))
        if lunaIsFavorite {
            favoritesCard.addSubview(editRow(title: appName, favorite: true, image: appIcon))
        }

        let otherLabel = sectionLabel("Other Actions")
        otherLabel.tag = 202
        editContent.addSubview(otherLabel)
        let otherCard = UIView()
        otherCard.tag = 203
        otherCard.backgroundColor = UIColor.white.withAlphaComponent(0.10)
        otherCard.layer.cornerRadius = 18
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
        otherCard.addSubview(editRow(title: "Save to Files", favorite: false, symbol: "folder"))
        otherCard.addSubview(editRow(title: "Add to Reading List", favorite: false, symbol: "eyeglasses"))
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
        tile.backgroundColor = circular ? UIColor.white.withAlphaComponent(0.92) : tint
        tile.layer.cornerRadius = circular ? 34 : 15
        tile.layer.cornerCurve = .continuous
        container.addSubview(tile)
        let icon = UIImageView(image: image)
        icon.tag = 2
        icon.contentMode = .scaleAspectFit
        icon.tintColor = circular ? tint : .white
        icon.layer.cornerRadius = 13
        icon.layer.cornerCurve = .continuous
        icon.clipsToBounds = true
        tile.addSubview(icon)
        let label = UILabel()
        label.tag = 3
        label.text = title
        label.textColor = .white
        label.font = .systemFont(ofSize: 13)
        label.textAlignment = .center
        label.numberOfLines = 2
        container.addSubview(label)
        return container
    }

    private func layoutTiles(in host: UIView, side: CGFloat, count: Int) {
        guard count > 0 else { return }
        let slot = host.bounds.width / CGFloat(max(count, 4))
        for (index, item) in host.subviews.enumerated() {
            item.frame = CGRect(x: CGFloat(index) * slot, y: 0, width: slot, height: host.bounds.height)
            let tileSide = min(side, slot - 8)
            item.viewWithTag(1)?.frame = CGRect(
                x: (slot - tileSide) / 2, y: 0, width: tileSide, height: tileSide)
            item.viewWithTag(2)?.frame = CGRect(
                x: tileSide * 0.18, y: tileSide * 0.18,
                width: tileSide * 0.64, height: tileSide * 0.64)
            item.viewWithTag(3)?.frame = CGRect(
                x: 0, y: tileSide + 6, width: slot, height: 38)
        }
    }

    private func actionRow(title: String, symbol: String) -> UIView {
        let row = UIView()
        let icon = UIImageView(image: UIImage(systemName: symbol))
        icon.tintColor = .white
        icon.frame = CGRect(x: 18, y: 15, width: 28, height: 28)
        row.addSubview(icon)
        let label = UILabel()
        label.text = title
        label.textColor = .white
        label.font = .systemFont(ofSize: 18)
        label.frame = CGRect(x: 62, y: 0, width: 270, height: 58)
        row.addSubview(label)
        return row
    }

    private func sectionLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.textColor = UIColor.white.withAlphaComponent(0.55)
        label.font = .systemFont(ofSize: 22, weight: .bold)
        return label
    }

    private func editRow(
        title: String,
        favorite: Bool,
        symbol: String? = nil,
        image: UIImage? = nil
    ) -> UIView {
        let row = UIView()
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
        label.textColor = .white
        label.font = .systemFont(ofSize: 18)
        label.frame = CGRect(x: 58, y: 0, width: 260, height: 60)
        row.addSubview(label)
        if favorite {
            let reorder = UIImageView(image: UIImage(systemName: "line.3.horizontal"))
            reorder.tintColor = UIColor.white.withAlphaComponent(0.35)
            reorder.frame = CGRect(x: 326, y: 19, width: 28, height: 22)
            reorder.autoresizingMask = [.flexibleLeftMargin]
            row.addSubview(reorder)
        }
        return row
    }
}

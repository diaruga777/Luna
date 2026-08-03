//
//  CardCarouselHostViewController.swift
//  Luna
//

import LunaDesignSystem
import LunaModels
import LunaSocial
import UIKit

/// Owns the archive tray's horizontal contribution to the card deck.
final class TrayShiftContribution {
    private let shiftedViews: () -> [UIView]
    private var appliedShiftByView: [ObjectIdentifier: CGFloat] = [:]

    init(shiftedViews: @escaping () -> [UIView]) {
        self.shiftedViews = shiftedViews
    }

    func apply(_ shift: CGFloat) {
        let views = shiftedViews()
        let liveIDs = Set(views.map { ObjectIdentifier($0) })
        for view in views {
            let id = ObjectIdentifier(view)
            let previous = appliedShiftByView[id] ?? 0
            let delta = shift - previous
            if abs(delta) > 0.001 {
                var transform = view.transform
                transform.tx += delta
                view.transform = transform
            }
            appliedShiftByView[id] = shift
        }
        let staleIDs = appliedShiftByView.keys.filter { !liveIDs.contains($0) }
        for id in staleIDs {
            appliedShiftByView.removeValue(forKey: id)
        }
    }
}

/// The parts of a util URL row that keep their identity while its empty card
/// shell grows. The source supplies real UIKit copies rather than one flat
/// snapshot, so the favicon and label can move without being scaled to the
/// destination card's height.
@MainActor
struct UtilCardSaveTransitionArtwork {
    let kind: RecentURLPreview.Kind
    let sourceFrame: CGRect
    let backgroundColor: UIColor
    let cornerRadius: CGFloat
    let thumbnail: UIImageView
    let title: UILabel
    let subtitle: UILabel?
}

@MainActor
protocol UtilCardSaveTransitionArtworkProviding: AnyObject {
    func makeUtilCardSaveTransitionArtwork(in coordinateView: UIView)
        -> UtilCardSaveTransitionArtwork?
}

/// Stable identifiers let the handoff settle onto the destination's exact
/// header geometry without coupling this shared host to Reader or Price Tracker
/// private view-controller types.
enum UtilCardSaveTransitionAnchor {
    static let thumbnail = "utilCardSaveTransition.destinationThumbnail"
    static let title = "utilCardSaveTransition.destinationTitle"
}

struct UtilCardSaveTransitionGeometry {
    let thumbnail: CGRect
    let title: CGRect

    /// A useful target while ingest is still running and the real card does not
    /// exist yet. Once it mounts, tagged destination views replace these with
    /// their exact frames.
    static func fallback(
        in cardFrame: CGRect,
        kind: RecentURLPreview.Kind,
        sourceTitleHeight: CGFloat
    ) -> Self {
        switch kind {
        case .product:
            let image = CGRect(
                x: cardFrame.minX + 18, y: cardFrame.minY + 18,
                width: 64, height: 64)
            return Self(
                thumbnail: image,
                title: CGRect(
                    x: image.maxX + 12, y: image.minY,
                    width: max(0, cardFrame.maxX - image.maxX - 30), height: 64))
        case .article, .media:
            let titleHeight = min(max(sourceTitleHeight, 30), 90)
            let title = CGRect(
                x: cardFrame.minX + 62, y: cardFrame.minY + 38,
                width: max(0, cardFrame.width - 82), height: titleHeight)
            return Self(
                thumbnail: CGRect(
                    x: cardFrame.minX + 20,
                    y: title.midY - 15,
                    width: 30, height: 30),
                title: title)
        }
    }
}

/// One continuous handoff between a util-card URL row and its saved carousel
/// card. Only the recent's empty shell expands to the full card frame. Its
/// favicon and title travel independently into the normal header geometry;
/// after ingest mounts the real card, that artwork is replaced by a crossfade.
/// A source view that supplies no artwork falls back to one flat snapshot of
/// itself.
@MainActor
private final class UtilCardSaveTransition {
    let urlString: String
    private weak var host: CardCarouselHostViewController?
    private let sourceSnapshot: UIView
    private let artwork: UtilCardSaveTransitionArtwork?
    /// The shell's own card rim, kept in step with its animating corner radius.
    private var shellRim: UtilURLRowGlassBorder?
    /// Luna's own waiting: the horizon spinner for a page being read, the
    /// eclipse bar for a transfer. Retired by the crossfade into real content.
    private var loadingIndicator: UIView?
    private var movementAnimator: UIViewPropertyAnimator?
    private weak var destination: UIView?
    private var destinationSnapshot: UIView?
    private var isFinishing = false
    private var isFinished = false
    var completion: (() -> Void)?

    init?(host: CardCarouselHostViewController, urlString: String, sourceView: UIView) {
        self.urlString = urlString
        self.host = host
        if let provider = sourceView as? UtilCardSaveTransitionArtworkProviding,
           let artwork = provider.makeUtilCardSaveTransitionArtwork(in: host.view) {
            self.artwork = artwork
            let shell = UIView(frame: artwork.sourceFrame)
            shell.backgroundColor = artwork.backgroundColor
            shell.layer.cornerRadius = artwork.cornerRadius
            shell.layer.cornerCurve = .continuous
            shell.clipsToBounds = true
            shell.isUserInteractionEnabled = false
            sourceSnapshot = shell
            // The growing shell IS the destination card from the first frame:
            // it wears the deck's own rim (following its radius as it opens) and
            // carries the app's loading indicator until real content lands —
            // never a black rectangle with nothing happening in it.
            let rim = UtilURLRowGlassBorder()
            rim.cornerRadius = artwork.cornerRadius
            rim.frame = shell.bounds
            rim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            shell.addSubview(rim)
            shellRim = rim
            host.view.addSubview(shell)
            for view in [artwork.thumbnail, artwork.title] + [artwork.subtitle].compactMap({ $0 }) {
                view.isUserInteractionEnabled = false
                host.view.addSubview(view)
            }
            installLoadingIndicator(for: artwork.kind, in: shell)
        } else {
            guard let snapshot = sourceView.snapshotView(afterScreenUpdates: false) else { return nil }
            artwork = nil
            sourceSnapshot = snapshot
            snapshot.frame = sourceView.convert(sourceView.bounds, to: host.view)
            snapshot.layer.cornerRadius = Self.cornerRadius(of: sourceView)
            snapshot.layer.cornerCurve = .continuous
            snapshot.clipsToBounds = true
            snapshot.isUserInteractionEnabled = false
            host.view.addSubview(snapshot)
        }

        // Defer one turn so the target uses the card's final resting frame while
        // the source frame above remains the exact on-screen row that was tapped.
        DispatchQueue.main.async { [weak self] in self?.beginMovement() }
    }

    /// Hides the newly mounted destination during the same reload call stack
    /// that created it, before Core Animation can commit a frame. Its snapshot
    /// is deliberately deferred until `finish`, after ingest's final layout and
    /// asynchronous thumbnail/header updates have had their chance to land.
    func prepare(destination: UIView?) {
        guard !isFinished, !isFinishing, let destination,
              self.destination !== destination else { return }
        self.destination?.alpha = 1
        destinationSnapshot = nil
        self.destination = destination
        destination.alpha = 0
    }

    func finish(to destination: UIView?) {
        if self.destination !== destination { prepare(destination: destination) }
        guard !isFinished, !isFinishing, let host, let destination = self.destination else {
            cancel()
            return
        }
        isFinishing = true
        host.view.layoutIfNeeded()
        host.carousel.view.layoutIfNeeded()
        // Alpha changes inside this synchronous stack never reach the render
        // server, but exposing the view here lets `snapshotView` capture the
        // final loaded pixels instead of the hidden destination's empty alpha.
        destination.alpha = 1
        guard let destinationSnapshot = destination.snapshotView(afterScreenUpdates: false) else {
            destination.alpha = 0
            cancel()
            return
        }
        destination.alpha = 0
        self.destinationSnapshot = destinationSnapshot

        let targetFrame = destination.convert(destination.bounds, to: host.view)
        let currentFrame = sourceSnapshot.layer.presentation()?.frame ?? sourceSnapshot.frame
        let currentCornerRadius = sourceSnapshot.layer.presentation()?.cornerRadius
            ?? sourceSnapshot.layer.cornerRadius
        let remainingFraction = max(0, 1 - (movementAnimator?.fractionComplete ?? 0))
        let artworkFrames = artwork.map { artwork in
            (
                thumbnail: Self.presentationFrame(of: artwork.thumbnail),
                title: Self.presentationFrame(of: artwork.title),
                subtitle: artwork.subtitle.map(Self.presentationFrame(of:))
            )
        }
        movementAnimator?.stopAnimation(true)
        movementAnimator = nil
        sourceSnapshot.layer.removeAllAnimations()
        sourceSnapshot.frame = currentFrame
        sourceSnapshot.layer.cornerRadius = currentCornerRadius
        shellRim?.cornerRadius = currentCornerRadius
        if let artwork, let artworkFrames {
            artwork.thumbnail.layer.removeAllAnimations()
            artwork.title.layer.removeAllAnimations()
            artwork.subtitle?.layer.removeAllAnimations()
            artwork.thumbnail.frame = artworkFrames.thumbnail
            artwork.title.frame = artworkFrames.title
            if let subtitleFrame = artworkFrames.subtitle { artwork.subtitle?.frame = subtitleFrame }
        }

        destinationSnapshot.frame = targetFrame
        destinationSnapshot.alpha = 0
        destinationSnapshot.layer.cornerRadius = CardSurfaceView.cornerRadius
        destinationSnapshot.layer.cornerCurve = .continuous
        destinationSnapshot.clipsToBounds = true
        destinationSnapshot.isUserInteractionEnabled = false
        host.view.addSubview(destinationSnapshot)

        let targetArtwork = artwork.map {
            self.targetArtworkGeometry(for: $0, cardFrame: targetFrame, destination: destination)
        }
        let settle = { [weak self] in
            guard let self else { return }
            self.sourceSnapshot.frame = targetFrame
            self.sourceSnapshot.layer.cornerRadius = CardSurfaceView.cornerRadius
            self.shellRim?.cornerRadius = CardSurfaceView.cornerRadius
            if let artwork = self.artwork, let targetArtwork {
                artwork.thumbnail.frame = targetArtwork.thumbnail
                artwork.thumbnail.layer.cornerRadius = min(
                    targetArtwork.thumbnail.width, targetArtwork.thumbnail.height) * 0.2
                artwork.title.frame = targetArtwork.title
                artwork.subtitle?.alpha = 0
            }
        }
        let crossfade = { [weak self] in
            guard let self else { return }
            let changes = {
                self.sourceSnapshot.alpha = 0
                self.artwork?.thumbnail.alpha = 0
                self.artwork?.title.alpha = 0
                self.artwork?.subtitle?.alpha = 0
                destinationSnapshot.alpha = 1
            }
            guard UIView.areAnimationsEnabled, !UIAccessibility.isReduceMotionEnabled else {
                changes()
                self.complete()
                return
            }
            UIView.animate(
                withDuration: 0.18, delay: 0,
                options: [.curveEaseInOut, .allowUserInteraction],
                animations: changes,
                completion: { [weak self] _ in self?.complete() })
        }

        guard !UIAccessibility.isReduceMotionEnabled, UIView.areAnimationsEnabled else {
            settle()
            crossfade()
            return
        }
        UIView.animate(
            withDuration: max(0.12, 0.34 * remainingFraction), delay: 0,
            usingSpringWithDamping: 0.92, initialSpringVelocity: 0.15,
            options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut],
            animations: settle,
            completion: { _ in crossfade() })
    }

    func cancel() {
        guard !isFinished else { return }
        isFinished = true
        movementAnimator?.stopAnimation(true)
        movementAnimator = nil
        destination?.alpha = 1
        destinationSnapshot?.removeFromSuperview()
        destinationSnapshot = nil
        let finish = { [sourceSnapshot] in
            sourceSnapshot.alpha = 0
            self.artwork?.thumbnail.alpha = 0
            self.artwork?.title.alpha = 0
            self.artwork?.subtitle?.alpha = 0
        }
        let completed = { [weak self] in
            self?.removeTransitionViews()
            self?.completion?()
        }
        if UIView.areAnimationsEnabled {
            UIView.animate(
                withDuration: 0.12, animations: finish,
                completion: { _ in completed() })
        } else {
            finish()
            completed()
        }
    }

    private func beginMovement() {
        guard !isFinished, !isFinishing, let host else { return }
        host.view.layoutIfNeeded()
        host.carousel.view.layoutIfNeeded()
        guard let targetFrame = host.carousel.restingCenteredCardFrame(in: host.view),
              !UIAccessibility.isReduceMotionEnabled, UIView.areAnimationsEnabled
        else { return }
        let animator = UIViewPropertyAnimator(duration: 0.34, dampingRatio: 0.92) {
            self.sourceSnapshot.frame = targetFrame
            self.sourceSnapshot.layer.cornerRadius = CardSurfaceView.cornerRadius
            self.shellRim?.cornerRadius = CardSurfaceView.cornerRadius
            if let artwork = self.artwork {
                let target = UtilCardSaveTransitionGeometry.fallback(
                    in: targetFrame, kind: artwork.kind,
                    sourceTitleHeight: artwork.title.bounds.height)
                artwork.thumbnail.frame = target.thumbnail
                artwork.thumbnail.layer.cornerRadius = min(
                    target.thumbnail.width, target.thumbnail.height) * 0.2
                artwork.title.frame = target.title
                artwork.subtitle?.alpha = 0
            }
        }
        movementAnimator = animator
        animator.startAnimation()
    }

    /// The app's own waiting, inside the growing shell: a horizon spinner for a
    /// page still being read, the eclipse progress bar for a media transfer
    /// (which mounts at zero and hands off to the real card's own bar). Faded in
    /// after a beat so a save that resolves at once never flashes it.
    private func installLoadingIndicator(
        for kind: RecentURLPreview.Kind, in shell: UIView
    ) {
        let indicator: UIView
        switch kind {
        case .media:
            let bar = EclipseProgressBar()
            bar.setProgress(0, animated: false)
            let width = max(80, shell.bounds.width * 0.6)
            bar.frame = CGRect(
                x: (shell.bounds.width - width) / 2,
                y: shell.bounds.midY - bar.intrinsicContentSize.height / 2,
                width: width,
                height: bar.intrinsicContentSize.height)
            indicator = bar
        case .article, .product:
            let spinner = HorizonSpinnerView(side: 30)
            spinner.frame = CGRect(
                x: shell.bounds.midX - 15, y: shell.bounds.midY - 15,
                width: 30, height: 30)
            spinner.startAnimating()
            indicator = spinner
        }
        indicator.autoresizingMask = [
            .flexibleTopMargin, .flexibleBottomMargin,
            .flexibleLeftMargin, .flexibleRightMargin,
        ]
        indicator.alpha = 0
        shell.addSubview(indicator)
        loadingIndicator = indicator
        guard UIView.areAnimationsEnabled else {
            indicator.alpha = 1
            return
        }
        UIView.animate(withDuration: 0.2, delay: 0.15, options: [.curveEaseOut]) {
            indicator.alpha = 1
        }
    }

    private func retireLoadingIndicator() {
        (loadingIndicator as? HorizonSpinnerView)?.stopAnimating()
        loadingIndicator?.removeFromSuperview()
        loadingIndicator = nil
    }

    private func complete() {
        guard !isFinished else { return }
        isFinished = true
        destination?.alpha = 1
        removeTransitionViews()
        destinationSnapshot?.removeFromSuperview()
        destinationSnapshot = nil
        completion?()
    }

    private func removeTransitionViews() {
        retireLoadingIndicator()
        sourceSnapshot.removeFromSuperview()
        artwork?.thumbnail.removeFromSuperview()
        artwork?.title.removeFromSuperview()
        artwork?.subtitle?.removeFromSuperview()
    }

    private func targetArtworkGeometry(
        for artwork: UtilCardSaveTransitionArtwork,
        cardFrame: CGRect,
        destination: UIView
    ) -> UtilCardSaveTransitionGeometry {
        let fallback = UtilCardSaveTransitionGeometry.fallback(
            in: cardFrame, kind: artwork.kind,
            sourceTitleHeight: artwork.title.bounds.height)
        let thumbnail = destination.firstDescendant(
            accessibilityIdentifier: UtilCardSaveTransitionAnchor.thumbnail)
            .map { $0.convert($0.bounds, to: host?.view) }
        let title = destination.firstDescendant(
            accessibilityIdentifier: UtilCardSaveTransitionAnchor.title)
            .map { $0.convert($0.bounds, to: host?.view) }
        return UtilCardSaveTransitionGeometry(
            thumbnail: thumbnail ?? fallback.thumbnail,
            title: title ?? fallback.title)
    }

    private static func presentationFrame(of view: UIView) -> CGRect {
        view.layer.presentation()?.frame ?? view.frame
    }

    private static func cornerRadius(of view: UIView) -> CGFloat {
        if let cell = view as? UICollectionViewCell {
            return cell.contentView.layer.cornerRadius
        }
        return view.layer.cornerRadius
    }
}

private extension UIView {
    func firstDescendant(accessibilityIdentifier identifier: String) -> UIView? {
        if accessibilityIdentifier == identifier { return self }
        for child in subviews {
            if let match = child.firstDescendant(accessibilityIdentifier: identifier) {
                return match
            }
        }
        return nil
    }
}

/// The shared skeleton behind the root card decks. Every deck begins with the
/// permanent util card, then its saved items, and may expose the archive tray
/// beyond its final save. This base owns the carousel instance and the shared
/// chrome/index math; subclasses keep their item models and store plumbing.
class CardCarouselHostViewController: UIViewController {

    let carousel = CardCarouselViewController()
    private(set) var archiveTray: ArchiveTrayController?
    private var utilCardSaveTransition: UtilCardSaveTransition?
    private let utilCardShowsOnboardingAtLaunch =
        !AppOnboardingStore.shared.isCompleted
    /// The eclipse corona the launch splash draws around the card. It belongs to
    /// the util card while onboarding is unanswered — the same condition as the
    /// intro headline — so an incomplete first run keeps the light the splash
    /// handed it instead of losing it to the crossfade.
    private var utilCardCorona: EclipseCoronaView?
    private var isUtilCardCentered = true

    final var utilCardIndex: Int { 0 }

    final func isUtilCard(_ index: Int) -> Bool { index == utilCardIndex }

    /// - Parameter hasSaves: whether the deck holds any save of its own. It
    ///   decides the “or” separator, and — because an empty store launches
    ///   centered on the util card — whether this appearance is the one the
    ///   intro headline's sweep belongs to.
    final func makeUtilCardContentController(
        hasSaves: @escaping () -> Bool,
        saveHandler: @escaping UtilCardContentViewController.SaveHandler
    ) -> CardContentViewController {
        UtilCardContentViewController(
            showsOnboarding: utilCardShowsOnboardingAtLaunch,
            animatesIntro: !hasSaves() && !AppLaunchTransition.hasFinished,
            hasSaves: hasSaves,
            saveHandler: saveHandler)
    }

    final func loadUtilCardThumbnail(completion: @escaping (UIImage?) -> Void) {
        completion(OnboardingActionExtensionIcon.image() ?? OnboardingAppIcon.image())
    }

    /// Adds the already-configured `carousel` (style/dataSource/delegate are the
    /// subclass's business, set before calling this) as a full-screen child,
    /// pinned to all four edges.
    final func mountCarousel() {
        addChild(carousel)
        view.addSubview(carousel.view)
        carousel.view.translatesAutoresizingMaskIntoConstraints = false
        carousel.didMove(toParent: self)
        NSLayoutConstraint.activate([
            carousel.view.topAnchor.constraint(equalTo: view.topAnchor),
            carousel.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            carousel.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            carousel.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: - The util card's corona

    /// Keeps the corona in step with the deck. Hosts call this from
    /// `didCenterCardAt`; the light belongs to the util card, so it fades out as
    /// the deck moves to a save and back in when the card returns.
    ///
    /// It is drawn behind the carousel (over the starfield), at the resting
    /// centered card frame — the same geometry the launch splash used, which is
    /// what makes an incomplete first run's launch crossfade reveal no change.
    final func updateUtilCardCorona(forCenteredIndex index: Int, animated: Bool = true) {
        guard utilCardShowsOnboardingAtLaunch else { return }
        layoutUtilCardCorona()
        let centered = isUtilCard(index)
        guard centered != isUtilCardCentered, let corona = utilCardCorona else { return }
        isUtilCardCentered = centered
        let apply = { corona.alpha = centered ? 1 : 0 }
        guard animated, UIView.areAnimationsEnabled else {
            apply()
            return
        }
        UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState]) {
            apply()
        }
    }

    private func layoutUtilCardCorona() {
        guard utilCardShowsOnboardingAtLaunch,
              let cardFrame = carousel.restingCenteredCardFrame(in: view)
        else { return }
        if utilCardCorona?.bounds.size != cardFrame.size {
            utilCardCorona?.removeFromSuperview()
            let corona = AppLaunchTransition.makePeakCoronaView(cardFrame: cardFrame)
            isUtilCardCentered = isUtilCard(carousel.currentIndex)
            corona.alpha = isUtilCardCentered ? 1 : 0
            view.insertSubview(corona, belowSubview: carousel.view)
            utilCardCorona = corona
        } else {
            utilCardCorona?.frame = cardFrame
        }
    }

    final func mountArchiveTray(
        shifting views: @escaping () -> [UIView],
        canPull: @escaping () -> Bool,
        openStateChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        archiveTray = ArchiveTrayController(
            host: self,
            shiftedViews: views,
            canPull: canPull,
            openStateChanged: openStateChanged)
    }

    final func refreshArchivePullAvailability(animated: Bool) {
        archiveTray?.refreshPullAvailability(animated: animated)
    }

    /// Captures the tapped util-card row before ingest starts. Surface
    /// hosts finish or cancel this after their normal ingest path resolves.
    final var pendingUtilCardSaveURLString: String? {
        utilCardSaveTransition?.urlString
    }

    final func beginUtilCardSaveTransition(
        for urlString: String, from sourceView: UIView
    ) {
        utilCardSaveTransition?.cancel()
        guard let transition = UtilCardSaveTransition(
            host: self, urlString: urlString, sourceView: sourceView)
        else {
            utilCardSaveTransition = nil
            return
        }
        transition.completion = { [weak self, weak transition] in
            guard let self, self.utilCardSaveTransition === transition else { return }
            self.utilCardSaveTransition = nil
        }
        utilCardSaveTransition = transition
    }

    final func prepareUtilCardSaveDestination(_ destination: UIView?) {
        utilCardSaveTransition?.prepare(destination: destination)
    }

    final func finishUtilCardSaveTransition(to destination: UIView?) {
        utilCardSaveTransition?.finish(to: destination)
    }

    final func cancelUtilCardSaveTransition() {
        utilCardSaveTransition?.cancel()
    }

    /// Retracts the tray from the carousel's intended target rather than its
    /// not-yet-swapped `currentIndex`, so paging away hides the tab immediately.
    /// Paging toward the last card deliberately does nothing here: the tab is
    /// revealed only by `refreshArchivePullAvailability` after that card centers.
    final func updateArchivePullAvailability(
        forTargetIndex index: Int,
        cardCount: Int,
        animated: Bool
    ) {
        guard cardCount > 0, index != cardCount - 1 else { return }
        archiveTray?.setPullAvailable(false, animated: animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Reaching the app's main screen (on launch or by navigating back) clears
        // the "open the app" follow-up share notifications; first-share prompts
        // that deep-link to settings are left intact.
        //
        // This lived on the sectioned list's `viewDidAppear`. When that screen was
        // deleted the call went with it and nothing cleared the notifications, so
        // it belongs here instead — on the base class every app's root inherits,
        // rather than on one deck.
        NotificationManager.clearShareNotifications()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The carousel resolves its card metrics in its own pass, which runs
        // after this one, so settle it before reading the card column back.
        carousel.view.layoutIfNeeded()
        alignBottomControlsToCardColumn()
        layoutUtilCardCorona()
        archiveTray?.layout(in: view.bounds, safeAreaInsets: view.safeAreaInsets)
    }

    /// Cards rest fully below the safe area; `inset` adds any extra chrome-row
    /// clearance a subclass floats above the carousel (Reader's top control row;
    /// Downloader has none).
    final func applyCarouselTopInset(_ inset: CGFloat) {
        carousel.setTopInset(view.safeAreaInsets.top + inset)
    }

    /// A nil `action` leaves the button's behaviour to the caller — used by the
    /// share pill, which presents a menu as its primary action rather than firing
    /// a tap handler.
    final func configureBottomButton(
        _ button: UIButton, symbol: String, action: Selector?, accessibilityLabel: String
    ) {
        button.configuration = GlassStyle.circularButtonConfiguration(symbol: symbol, padding: 10)
        button.accessibilityLabel = accessibilityLabel
        if let action { button.addTarget(self, action: action, for: .touchUpInside) }
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    private var bottomControlLeadingConstraint: NSLayoutConstraint?
    private var bottomControlTrailingConstraint: NSLayoutConstraint?

    /// Pins two already-`configureBottomButton`-ed buttons to the bottom
    /// corners, flanking the scrub strip: 12pt from each side edge, 26pt above
    /// the safe area, 44×44.
    ///
    /// On a wide container the pair follows the card's column instead of the
    /// screen's (see `alignBottomControlsToCardColumn`) — the deck reads as one
    /// object, and two circles a thousand points apart do not.
    final func mountBottomControls(leading: UIButton, trailing: UIButton) {
        view.addSubview(leading)
        view.addSubview(trailing)
        let leadingConstraint = leading.leadingAnchor.constraint(
            equalTo: view.leadingAnchor, constant: 12)
        let trailingConstraint = trailing.trailingAnchor.constraint(
            equalTo: view.trailingAnchor, constant: -12)
        bottomControlLeadingConstraint = leadingConstraint
        bottomControlTrailingConstraint = trailingConstraint
        NSLayoutConstraint.activate([
            leadingConstraint,
            leading.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -26),
            leading.widthAnchor.constraint(equalToConstant: 44),
            leading.heightAnchor.constraint(equalToConstant: 44),
            trailingConstraint,
            trailing.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -26),
            trailing.widthAnchor.constraint(equalToConstant: 44),
            trailing.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    /// Keeps the flanking circles just inside the centered card's edges on a wide
    /// container — the same 12pt they keep from the screen edges on a phone,
    /// where the card very nearly IS the screen.
    ///
    /// Each edge is resolved independently rather than as one symmetric inset:
    /// a deck stepped aside for a second column is no longer centered, and a
    /// mirrored inset would leave the trailing circle floating in the gap
    /// between the two cards.
    private func alignBottomControlsToCardColumn() {
        guard let leadingConstraint = bottomControlLeadingConstraint,
              let trailingConstraint = bottomControlTrailingConstraint
        else { return }
        var leading: CGFloat = 12
        var trailing: CGFloat = -12
        if LunaLayout.isWide(containerWidth: view.bounds.width) {
            let column = carousel.restingCardColumn(in: view)
            leading = max(12, column.lowerBound + 12)
            trailing = min(-12, column.upperBound - view.bounds.width - 12)
        }
        guard abs(leadingConstraint.constant - leading) > 0.5
            || abs(trailingConstraint.constant - trailing) > 0.5
        else { return }
        leadingConstraint.constant = leading
        trailingConstraint.constant = trailing
    }

    // MARK: - Util-card index math

    /// The util card permanently occupies index zero, shifting every saved
    /// item one position to the right.
    final var cardOffset: Int { 1 }

    final func itemIndex(forCarouselIndex index: Int, itemCount: Int) -> Int? {
        let itemIndex = index - cardOffset
        return (0..<itemCount).contains(itemIndex) ? itemIndex : nil
    }

    // MARK: - Centering on a new save

    /// Every id this deck has already accounted for: the cards it showed plus
    /// the rows it holds offstage.
    private var seenItemIDs: Set<UUID> = []
    private var hasSeenASnapshot = false

    /// Where a reload should center because it turned up a save this deck has
    /// never shown — nil when it turned up none.
    ///
    /// A save reaches a deck from a dozen places (this app's own paste/left
    /// tray, its share/action/Safari extension, an App Intent, the mailbox
    /// importer, a sibling app writing the shared store) and at any moment,
    /// including while this process was suspended or dead. Rather than have
    /// every entry point announce itself, every reload simply compares ids
    /// against the previous snapshot: whatever is new arrived since, however it
    /// got here, and the deck moves to it.
    ///
    /// `cardIDs` is the saved-item portion of the deck, so
    /// the result is an ITEM index — add `cardOffset` before centering.
    /// `offstageIDs` are ids the deck knows but doesn't show (archived rows):
    /// counting them as seen keeps unarchiving one from reading as a new save.
    /// The first snapshot only seeds the set — nothing is "new" on a deck that
    /// has shown nothing yet, and its newest-first default already opens on the
    /// most recent save.
    final func newSaveItemIndex(cardIDs: [UUID], offstageIDs: Set<UUID> = []) -> Int? {
        defer {
            seenItemIDs = Set(cardIDs).union(offstageIDs)
            hasSeenASnapshot = true
        }
        guard hasSeenASnapshot else { return nil }
        return cardIDs.firstIndex { !seenItemIDs.contains($0) }
    }

    // MARK: - Settings

    @objc func settingsTapped() {
        navigationController?.pushViewController(SettingsViewController(), animated: true)
    }
}

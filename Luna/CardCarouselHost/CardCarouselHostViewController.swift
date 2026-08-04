//
//  CardCarouselHostViewController.swift
//  Luna
//

import LunaDesignSystem
import LunaModels
import LunaReadingList
import LunaSocial
import LunaStorage
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
    /// The source's rim colour when it is not the neutral glass one — the Save
    /// of the Week row's palette tint. The shell wears it so the grow starts
    /// from exactly the row that was tapped instead of flicking to neutral on
    /// its first frame.
    let rimTint: UIColor?
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
            rim.rimTint = artwork.rimTint
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
        CardTransitionSnapshot.cornerRadius(of: view)
    }
}

/// Snapshots taken FROM a deck surface, for the moves the deck animates by hand:
/// a util-card row growing into its card, a card dissolving as it is archived, an
/// archive cell dissolving into the card it is restored to.
///
/// The corner radius is the subtle part and it lives here once: a carousel card
/// and an archive-tray cell are both `UICollectionViewCell`s whose radius is on
/// the CONTENT view, so reading `layer.cornerRadius` off the cell itself gives
/// zero and the snapshot travels as a hard-edged rectangle.
@MainActor
enum CardTransitionSnapshot {

    static func cornerRadius(of view: UIView) -> CGFloat {
        if let cell = view as? UICollectionViewCell {
            return cell.contentView.layer.cornerRadius
        }
        return view.layer.cornerRadius
    }

    /// A snapshot of `sourceView`, already added to `host` at the source's own
    /// on-screen frame and wearing its corner radius — ready to be animated and
    /// then removed by the caller.
    static func make(of sourceView: UIView, in host: UIView) -> UIView? {
        guard let snapshot = sourceView.snapshotView(afterScreenUpdates: false) else { return nil }
        snapshot.frame = sourceView.convert(sourceView.bounds, to: host)
        snapshot.layer.cornerRadius = cornerRadius(of: sourceView)
        snapshot.layer.cornerCurve = .continuous
        snapshot.clipsToBounds = true
        host.addSubview(snapshot)
        return snapshot
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

/// THE root card deck. Every app's home screen is this class: the permanent
/// util card at index zero, then its saves, then the archive tray beyond the
/// last of them. It owns the carousel, the index arithmetic over its slots, the
/// six-phase reload with its fingerprint diff and its centering ladder, the
/// carousel's data source and delegate, the archive tray's item pipeline, the
/// flanking Settings/share circles, and the util card's save transition.
///
/// What differs between four apps' decks is what a card IS, and that arrives
/// through `deckProvider` (`CardDeckProviding`). A subclass exists only where a
/// deck has genuine screen-level chrome of its own to add — which today is one
/// deck, the Reader's, whose cards are live readers.
class CardCarouselHostViewController: UIViewController {

    let carousel = CardCarouselViewController()

    /// The kind-specific half of this deck. Subclasses return themselves; the
    /// base default leaves a deck with nothing but its util card, which is
    /// exactly what a bare host is.
    var deckProvider: CardDeckProviding? { nil }

    /// The cards past the util card, as the last APPLIED reload left them. The
    /// single source of truth for every count and every index the host resolves;
    /// a provider's own typed arrays are committed in the same breath and stay
    /// in step with it by construction.
    private(set) var slots: [CardDeckSlot] = []
    private var appliedFingerprint: [String] = []
    /// An empty deck fingerprints as an empty array, which is also
    /// `appliedFingerprint`'s initial value — without this the very first reload
    /// would be abandoned and the carousel would never unhide.
    private var hasAppliedSnapshot = false
    private var pendingCenteringRequest: CardDeckCenteringRequest?

    /// A one-shot centering that outranks the parked card but NOT a save that
    /// just arrived: the archive choreography commits its store write first and
    /// then needs the intended successor (or the row it just restored) sitting
    /// under its animation snapshot. Consumed by the next reload whether or not
    /// it resolved.
    var pendingTransitionCenteredID: UUID?

    /// The deck's leading bottom circle. Always Settings, in every app.
    let settingsButton = UIButton(type: .system)
    /// The deck's trailing bottom circle. Its verb is the deck's business (a
    /// share sheet, a reader's share ladder); its seat, its glass, and when it
    /// is refreshed are not.
    let trailingBottomButton = UIButton(type: .system)

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

    // MARK: - Bringing the deck up

    /// Brings the whole deck up, in the one order every app's home screen uses:
    /// the carousel (whose `style` the caller has already set), the flanking
    /// circles, the archive tray, the store observation, then the first reload.
    ///
    /// That first reload runs SYNCHRONOUSLY here on purpose — the stores serve an
    /// in-memory cache, so the deck opens already showing its saves rather than
    /// unhiding a frame later.
    final func mountDeck() {
        carousel.dataSource = self
        carousel.delegate = self
        mountCarousel()
        deckWillMountBottomControls()
        mountDeckBottomControls()
        deckDidMountBottomControls()
        mountDeckArchiveTray()
        deckProvider?.deckWillBeginObservingStores()
        observeStoreChanges()
        reload()
    }

    /// Chrome that belongs above the carousel but below the flanking circles —
    /// Reader's hosted scroll indicator and its footer veil.
    func deckWillMountBottomControls() {}

    /// Chrome that belongs above the flanking circles — Reader's top control row.
    func deckDidMountBottomControls() {}

    private func mountDeckBottomControls() {
        configureBottomButton(
            settingsButton, symbol: "gearshape", action: #selector(settingsTapped),
            accessibilityLabel: L10n.string("Settings"))
        configureTrailingBottomButton(trailingBottomButton)
        mountBottomControls(leading: settingsButton, trailing: trailingBottomButton)
    }

    /// Dresses the trailing circle. The default is the deck's share pill as its
    /// provider describes it; Reader overrides to hang the reader's own share
    /// MENU on it instead of a tap handler.
    func configureTrailingBottomButton(_ button: UIButton) {
        guard let share = deckProvider?.deckShareButton else { return }
        configureBottomButton(
            button, symbol: "square.and.arrow.up",
            action: #selector(shareCenteredCardTapped),
            accessibilityLabel: share.accessibilityLabel)
    }

    /// Reconciles the trailing circle with the centered card. Called from the two
    /// places the centered card can change — the tail of an applied reload, and
    /// `didCenterCardAt` — so a deck never has to remember both.
    func refreshTrailingBottomButton() {
        guard let provider = deckProvider, let share = provider.deckShareButton
        else { return }
        let available = provider.deckCanShare(
            slot: slotIndex(forCarouselIndex: carousel.currentIndex))
        switch share.unavailability {
        case .hides: trailingBottomButton.isHidden = !available
        case .disables: trailingBottomButton.isEnabled = available
        }
    }

    @objc private func shareCenteredCardTapped() {
        guard let slot = slotIndex(forCarouselIndex: carousel.currentIndex) else { return }
        deckProvider?.deckShare(
            slot: slot,
            sourceView: carousel.cardView(at: carousel.currentIndex) ?? trailingBottomButton)
    }

    private func mountDeckArchiveTray() {
        mountArchiveTray(
            shifting: { [weak self] in
                guard let self else { return [] }
                return [self.carousel.view]
            },
            canPull: { [weak self] in
                guard let self, self.deckAllowsArchivePull else { return false }
                // The tray opens off the END of the deck, so every card counts —
                // including a kind's own error cards, which sit after its saves.
                let count = self.cardCount
                return count == 0 || self.carousel.currentIndex == count - 1
            },
            openStateChanged: { [weak self] open in
                self?.deckArchiveTrayOpenStateDidChange(open)
            })
    }

    /// Whether the tray may be pulled at all right now. Reader says no while a
    /// second reader column is open beside the card.
    var deckAllowsArchivePull: Bool { true }

    /// The tray's chrome consequences. Every deck occludes the card's mute
    /// button; Reader also stands its read-aloud circle down.
    func deckArchiveTrayOpenStateDidChange(_ open: Bool) {
        carousel.setMuteButtonOccluded(open)
    }

    private func observeStoreChanges() {
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(reload), name: .readingListChanged, object: nil)
        for name in deckProvider?.deckChangeNotificationNames ?? [] {
            center.addObserver(self, selector: #selector(reload), name: name, object: nil)
        }
        // A save can be committed by an extension or an App Intent while this app
        // is suspended, so no in-process notification ever reaches this
        // controller. Foregrounding is therefore a reload trigger in its own
        // right, and the ladder below makes whatever turned up take the center.
        center.addObserver(
            self, selector: #selector(reload),
            name: UIApplication.willEnterForegroundNotification, object: nil)
        for name in deckProvider?.deckActivationNotificationNames ?? [] {
            center.addObserver(self, selector: #selector(reload), name: name, object: nil)
        }
    }

    // MARK: - Reload

    /// Bring `request`'s save to the center on the next applied reload — the
    /// deck's own interactive saves, and a row coming back out of the archive.
    final func requestCentering(_ request: CardDeckCenteringRequest) {
        pendingCenteringRequest = request
    }

    final func requestCentering(onSlotID id: UUID) {
        requestCentering(CardDeckCenteringRequest(itemID: id))
    }

    final func slotIndex(resolving request: CardDeckCenteringRequest) -> Int? {
        slots.firstIndex(where: request.matches)
    }

    /// The deck's one reload, in six phases: read, guard, remember where the user
    /// was, adopt, resolve the center, hand the carousel the result.
    ///
    /// It is `@objc` because every store notification lands here directly, and
    /// `final` because there is exactly one of it — a deck with something extra
    /// to do hooks `deckWillReload` / `deckWillApplyReload` / `deckDidApplyReload`
    /// rather than growing a second copy of the algorithm.
    @objc final func reload() {
        deckWillReload()
        guard let provider = deckProvider else { return }
        let snapshot = provider.deckPreparedSnapshot()
        let fingerprint = snapshot.slots.map(\.fingerprint) + snapshot.offstageFingerprint
        // Runs on the abandoned path too: a reload that changes nothing is
        // exactly when a deck wants to notice something that has gone missing
        // behind its back.
        defer { provider.deckDidSettleReload() }
        guard !hasAppliedSnapshot
            || fingerprint != appliedFingerprint
            || pendingCenteringRequest != nil
            || pendingTransitionCenteredID != nil
        else { return }
        hasAppliedSnapshot = true
        appliedFingerprint = fingerprint

        deckWillApplyReload()

        // Where the user was parked, by identity — the index it sat at means
        // nothing once the deck is reordered.
        let parkedID = slotIndex(forCarouselIndex: carousel.currentIndex)
            .map { slots[$0].id }
        slots = snapshot.slots
        provider.deckCommitPreparedSnapshot()

        // ONE ladder, every deck, every source. A save this deck has never shown
        // arrived — typed into the util card here, dropped in by the share,
        // action or Safari extension, an App Intent, the mailbox importer, or a
        // sibling app writing the shared store while this one was suspended —
        // and it takes the center from whatever the deck was holding. Nothing
        // gates that on the save having been made interactively: the deck simply
        // compares ids against the previous snapshot, so however a save got
        // here, it is the card the user is shown.
        //
        // Below it: the archive choreography's intended successor, then a save
        // this deck is still waiting to see appear, then the parked card, then
        // the deck's own default (its newest save, or the util card if it has
        // none).
        let newSaveIndex = newSaveItemIndex(
            cardIDs: slots.map(\.id), offstageIDs: snapshot.offstageIDs)
        let transitionIndex = pendingTransitionCenteredID.flatMap { id in
            slots.firstIndex { $0.id == id }
        }
        let requestedIndex = pendingCenteringRequest.flatMap(slotIndex(resolving:))
        let parkedIndex = parkedID.flatMap { id in slots.firstIndex { $0.id == id } }
        let centeredIndex = (newSaveIndex ?? transitionIndex ?? requestedIndex ?? parkedIndex)
            .map { $0 + cardOffset }
            ?? (slots.isEmpty ? utilCardIndex : cardOffset)
        pendingTransitionCenteredID = nil
        // Kept until it resolves: the row a save becomes can appear a
        // notification later than the save itself (the Downloader's media row is
        // written by a second store).
        if requestedIndex != nil { pendingCenteringRequest = nil }

        carousel.reloadData(centeringAt: centeredIndex)
        // The util-card row that started this save now has a real card to land
        // on; hide it before Core Animation can commit a frame of it.
        if let pendingURL = pendingUtilCardSaveURLString,
           let index = slots.firstIndex(where: { $0.urlString == pendingURL }) {
            prepareUtilCardSaveDestination(carousel.cardView(at: index + cardOffset))
        }
        carousel.view.isHidden = false
        archiveTray?.setItems(provider.deckArchiveTrayItems())
        deckDidApplyReload()
        if deckReconcilesArchivePullOnReload {
            refreshArchivePullAvailability(animated: false)
        }
        refreshTrailingBottomButton()
    }

    /// Runs at the top of every reload, before the fingerprint is even computed.
    func deckWillReload() {}

    /// Runs on a reload that is going ahead, before the deck adopts its new
    /// slots — the last moment anything may look at the OLD deck.
    func deckWillApplyReload() {}

    /// Runs after the carousel and the archive tray have been handed the new
    /// deck, before pull availability and the trailing circle are reconciled.
    func deckDidApplyReload() {}

    /// Whether an applied reload may reconcile the archive tray's pull
    /// availability. Reader says no mid-unarchive: the tray is still open and
    /// about to be dismissed in step with a traveling snapshot, and reconciling
    /// would snap it shut first.
    var deckReconcilesArchivePullOnReload: Bool { true }

    // MARK: - Saving from the util card

    /// The one save path every deck's util card runs, and the only place the
    /// `handleSavePress` outcome is read: start the row-into-card transition,
    /// ingest, find the item the ingest settled on, reload with that item
    /// claiming the center, then hand the transition its real destination card —
    /// or cancel it, when the save produced no card on this deck at all.
    private func saveUtilCardURL(
        _ urlString: String,
        source: CaptureSource,
        sourceView: UIView,
        completion: @escaping (Bool) -> Void
    ) {
        beginUtilCardSaveTransition(for: urlString, from: sourceView)
        Task { @MainActor [weak self] in
            let result = await ReadingListIngestor.shared.handleSavePress(
                urlString: urlString, source: source)
            guard let self else { return }
            let item: ReadingListItem?
            switch result {
            case .saved(let value), .sentToEreaders(let value),
                 .sentToFriends(let value), .friendPromptRequested(let value),
                 // In-app saves pass no double-save surface, so no export is
                 // ever requested here — the item is what matters either way.
                 .exportRequested(let value, _):
                item = value
            case .ignored:
                item = ReadingListStore.shared.item(forURLString: urlString)
            case .unsupportedKind:
                item = nil
            }
            guard let item else {
                self.cancelUtilCardSaveTransition()
                completion(false)
                return
            }
            // Both keys travel: the URL the user handed over, the URL ingest
            // settled on, and the item's id. Whichever one this deck's slots are
            // keyed by resolves (see `CardDeckSlot.urlString`).
            let request = CardDeckCenteringRequest(
                itemID: item.id, urlStrings: [urlString, item.urlString])
            self.requestCentering(request)
            self.reload()
            self.view.layoutIfNeeded()
            let destination = self.slotIndex(resolving: request).map { $0 + self.cardOffset }
            self.finishUtilCardSaveTransition(
                to: destination.flatMap(self.carousel.cardView(at:)))
            completion(destination != nil)
        }
    }

    /// Adds the already-configured `carousel` (style is the subclass's business,
    /// set before `mountDeck`) as a full-screen child, pinned to all four edges.
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

    /// Extra chrome-row clearance this deck floats above the carousel, on top of
    /// the safe area (Reader's top control row; the other decks have none and
    /// keep the shared 4pt breathing room).
    class var carouselTopClearance: CGFloat { 4 }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
        applyCarouselTopInset(Self.carouselTopClearance)
        deckCarouselInsetsDidChange()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        applyCarouselTopInset(Self.carouselTopClearance)
        deckCarouselInsetsDidChange()
    }

    /// The deck's chance to follow a changed card area. Reader's cards embed live
    /// readers whose own top inset is measured off it.
    func deckCarouselInsetsDidChange() {}

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

    /// Every card this deck shows, util card included.
    final var cardCount: Int { slots.count + cardOffset }

    /// The provider slot behind a carousel index — nil for the util card and for
    /// anything past the last save. The ONE place the util card's offset is taken
    /// off, which is why a provider never sees a carousel index at all.
    final func slotIndex(forCarouselIndex index: Int) -> Int? {
        itemIndex(forCarouselIndex: index, itemCount: slots.count)
    }

    final func carouselIndex(forSlot slot: Int) -> Int { slot + cardOffset }

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

    // MARK: - Delegate hooks a deck may take over

    /// A card other than the util card has settled at the center, after the
    /// shared reconciliation (archive pull, the corona, the trailing circle) and
    /// after the provider's own `deckSlotDidCenter`. Reader retargets its reader
    /// chrome here.
    func deckDidCenterCard(at index: Int) {}

    /// An edge page pan began while immersed; the carousel has already restored
    /// its own chrome synchronously. Reader restores the matching screen-level
    /// chrome before the page moves.
    func deckDidSurfaceForEdgePaging() {}
}

// MARK: - The carousel's data source

// One conformance, for every app's deck. Each method resolves the util card, then
// hands a SLOT index to the provider — so no kind's code ever performs the
// util-card offset, and no deck can disagree with another about what index zero
// means.
extension CardCarouselHostViewController: CardCarouselDataSource {

    func numberOfCards(in carousel: CardCarouselViewController) -> Int { cardCount }

    func carousel(
        _ carousel: CardCarouselViewController,
        contentControllerForCardAt index: Int
    ) -> CardContentViewController {
        if isUtilCard(index) {
            return makeUtilCardContentController(
                hasSaves: { [weak self] in self?.slots.isEmpty == false }
            ) { [weak self] url, source, sourceView, completion in
                self?.saveUtilCardURL(
                    url, source: source, sourceView: sourceView, completion: completion)
            }
        }
        guard let slot = slotIndex(forCarouselIndex: index), let provider = deckProvider
        else { return CardContentViewController() }
        return provider.deckContentController(forSlot: slot)
    }

    func carousel(
        _ carousel: CardCarouselViewController,
        previewContentControllerForCardAt index: Int
    ) -> CardContentViewController? {
        if let slot = slotIndex(forCarouselIndex: index),
           deckProvider?.deckAllowsPreparedPreview(forSlot: slot) == false {
            return nil
        }
        return self.carousel(carousel, contentControllerForCardAt: index)
    }

    func carousel(
        _ carousel: CardCarouselViewController,
        loadThumbnailForCardAt index: Int,
        completion: @escaping (UIImage?) -> Void
    ) {
        if isUtilCard(index) {
            loadUtilCardThumbnail(completion: completion)
            return
        }
        guard let slot = slotIndex(forCarouselIndex: index), let provider = deckProvider
        else {
            completion(nil)
            return
        }
        provider.deckLoadThumbnail(forSlot: slot, completion: completion)
    }

    func carousel(
        _ carousel: CardCarouselViewController,
        titleForCardAt index: Int
    ) -> String? {
        if isUtilCard(index) { return LunaApp.current.displayName }
        guard let slot = slotIndex(forCarouselIndex: index) else { return nil }
        return deckProvider?.deckTitle(forSlot: slot)
    }

    func carousel(
        _ carousel: CardCarouselViewController,
        loadSourceBadgeForCardAt index: Int,
        completion: @escaping (CarouselSourceBadge?) -> Void
    ) {
        guard let slot = slotIndex(forCarouselIndex: index), let provider = deckProvider
        else {
            completion(nil)
            return
        }
        provider.deckLoadSourceBadge(forSlot: slot, completion: completion)
    }

    func carousel(
        _ carousel: CardCarouselViewController,
        loadMiniCarouselAccessoryForCardAt index: Int,
        completion: @escaping (UIImage?) -> Void
    ) {
        guard let slot = slotIndex(forCarouselIndex: index), let provider = deckProvider
        else {
            completion(nil)
            return
        }
        provider.deckLoadMiniCarouselAccessory(forSlot: slot, completion: completion)
    }

    func carousel(
        _ carousel: CardCarouselViewController,
        prefersThumbnailChipForCardAt index: Int
    ) -> Bool {
        guard let slot = slotIndex(forCarouselIndex: index) else { return false }
        return deckProvider?.deckPrefersThumbnailChip(forSlot: slot) ?? false
    }

    /// The util card holds no save, so its chip is neither a still nor a
    /// favicon-and-skeleton mini card: it is the app's own mark over a button.
    func carousel(
        _ carousel: CardCarouselViewController,
        prefersUtilityChipForCardAt index: Int
    ) -> Bool {
        isUtilCard(index)
    }

    func carousel(
        _ carousel: CardCarouselViewController,
        topLeadingAccessoryForCardAt index: Int
    ) -> UIView? {
        guard let slot = slotIndex(forCarouselIndex: index) else { return nil }
        return deckProvider?.deckTopLeadingAccessory(forSlot: slot)
    }

    /// A broken card carries a red rim — the only card chrome that says "this one
    /// is broken" without a badge or a banner.
    func carousel(
        _ carousel: CardCarouselViewController,
        edgeGlowColorForCardAt index: Int
    ) -> UIColor? {
        guard let slot = slotIndex(forCarouselIndex: index) else { return nil }
        return deckProvider?.deckEdgeGlowColor(forSlot: slot)
    }
}

// MARK: - The carousel's delegate

extension CardCarouselHostViewController: CardCarouselDelegate {

    func carousel(
        _ carousel: CardCarouselViewController,
        navigationTargetDidChangeTo index: Int
    ) {
        updateArchivePullAvailability(
            forTargetIndex: index, cardCount: cardCount, animated: true)
    }

    func carousel(_ carousel: CardCarouselViewController, didCenterCardAt index: Int) {
        refreshArchivePullAvailability(animated: true)
        updateUtilCardCorona(forCenteredIndex: index)
        refreshTrailingBottomButton()
        if let slot = slotIndex(forCarouselIndex: index) {
            deckProvider?.deckSlotDidCenter(slot)
        } else {
            deckProvider?.deckUtilCardDidCenter()
        }
        deckDidCenterCard(at: index)
    }

    func carousel(_ carousel: CardCarouselViewController, menuForCardAt index: Int) -> UIMenu? {
        guard let slot = slotIndex(forCarouselIndex: index) else { return nil }
        return deckProvider?.deckMenu(forSlot: slot)
    }

    func carousel(_ carousel: CardCarouselViewController, didTapCenteredCardAt index: Int) {
        guard let slot = slotIndex(forCarouselIndex: index) else { return }
        deckProvider?.deckSlotWasTapped(slot)
    }

    func carouselDidSurfaceForEdgePaging(_ carousel: CardCarouselViewController) {
        deckDidSurfaceForEdgePaging()
    }
}

// Every app's launch splash crossfades from its deck's real resting card
// geometry. The carousel owns that geometry, so the launch transition asks it
// here rather than duplicating safe-area/scrubber math in SceneDelegate — and
// once, on the base every deck already is, rather than in three identical
// per-deck extensions.
extension CardCarouselHostViewController: AppLaunchTransitionTarget {
    func appLaunchTargetFrame(in window: UIWindow) -> CGRect? {
        view.layoutIfNeeded()
        guard let frame = carousel.restingCenteredCardFrame(in: view) else { return nil }
        return view.convert(frame, to: window)
    }
}

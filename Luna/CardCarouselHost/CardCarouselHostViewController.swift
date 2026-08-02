//
//  CardCarouselHostViewController.swift
//  Luna
//

import LunaDesignSystem
import LunaModels
import LunaSocial
import UniformTypeIdentifiers
import UIKit

enum PasteboardTemporaryMediaPolicy {
    static let lifetime: TimeInterval = 60 * 60

    static func isExpired(expiresAt: Date, now: Date = Date()) -> Bool {
        expiresAt <= now
    }
}

enum PasteboardCommitPolicy {
    /// A completed save may clear only the synthetic card it started from.
    /// If a newer card is already represented, it must survive the older
    /// save's asynchronous storage/Photos completion.
    static func shouldClearCommittedCard(
        committedChangeCount: Int,
        currentPasteboardChangeCount: Int,
        representedChangeCount: Int?
    ) -> Bool {
        currentPasteboardChangeCount == committedChangeCount
            || representedChangeCount == committedChangeCount
    }
}

/// Owns one edge tray's horizontal contribution to views shared by both trays.
/// Each tray adjusts only the delta from its previous value, so applying a
/// closed tray's zero contribution cannot erase the opposite tray's open shift.
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

/// The parts of a recent-link row that keep their identity while its empty card
/// shell grows. `LeftTrayCell` supplies real UIKit copies rather than one flat
/// snapshot, so the favicon and label can move without being scaled to the
/// destination card's height.
@MainActor
struct LeftTraySaveTransitionArtwork {
    let kind: RecentURLPreview.Kind
    let sourceFrame: CGRect
    let backgroundColor: UIColor
    let cornerRadius: CGFloat
    let thumbnail: UIImageView
    let title: UILabel
    let subtitle: UILabel?
}

@MainActor
protocol LeftTraySaveTransitionArtworkProviding: AnyObject {
    func makeLeftTraySaveTransitionArtwork(in coordinateView: UIView)
        -> LeftTraySaveTransitionArtwork?
}

/// Stable identifiers let the handoff settle onto the destination's exact
/// header geometry without coupling this shared host to Reader or Price Tracker
/// private view-controller types.
enum LeftTraySaveTransitionAnchor {
    static let thumbnail = "leftTraySaveTransition.destinationThumbnail"
    static let title = "leftTraySaveTransition.destinationTitle"
}

struct LeftTraySaveTransitionGeometry {
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

/// One continuous handoff between a left-tray recent and its saved carousel
/// card. Only the recent's empty shell expands to the full card frame. Its
/// favicon and title travel independently into the normal header geometry;
/// after ingest mounts the real card, that artwork is replaced by a crossfade.
/// Pasteboard artwork has a bespoke physical layout and retains the older flat
/// snapshot fallback.
@MainActor
private final class LeftTraySaveTransition {
    let urlString: String
    private weak var host: CardCarouselHostViewController?
    private let sourceSnapshot: UIView
    private let artwork: LeftTraySaveTransitionArtwork?
    private var movementAnimator: UIViewPropertyAnimator?
    private weak var destination: UIView?
    private var destinationSnapshot: UIView?
    private var isFinishing = false
    private var isFinished = false
    var completion: (() -> Void)?

    init?(host: CardCarouselHostViewController, urlString: String, sourceView: UIView) {
        self.urlString = urlString
        self.host = host
        if let provider = sourceView as? LeftTraySaveTransitionArtworkProviding,
           let artwork = provider.makeLeftTraySaveTransitionArtwork(in: host.view) {
            self.artwork = artwork
            let shell = UIView(frame: artwork.sourceFrame)
            shell.backgroundColor = artwork.backgroundColor
            shell.layer.cornerRadius = artwork.cornerRadius
            shell.layer.cornerCurve = .continuous
            shell.clipsToBounds = true
            shell.isUserInteractionEnabled = false
            sourceSnapshot = shell
            host.view.addSubview(shell)
            for view in [artwork.thumbnail, artwork.title] + [artwork.subtitle].compactMap({ $0 }) {
                view.isUserInteractionEnabled = false
                host.view.addSubview(view)
            }
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

        // `LeftTrayController.save` invokes the host callback before it changes
        // the tray's model transform to closed. Defer one turn so this target is
        // the card's final, unshifted resting frame while the source frame above
        // remains the exact on-screen cell that was tapped.
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
            if let artwork = self.artwork {
                let target = LeftTraySaveTransitionGeometry.fallback(
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
        sourceSnapshot.removeFromSuperview()
        artwork?.thumbnail.removeFromSuperview()
        artwork?.title.removeFromSuperview()
        artwork?.subtitle?.removeFromSuperview()
    }

    private func targetArtworkGeometry(
        for artwork: LeftTraySaveTransitionArtwork,
        cardFrame: CGRect,
        destination: UIView
    ) -> LeftTraySaveTransitionGeometry {
        let fallback = LeftTraySaveTransitionGeometry.fallback(
            in: cardFrame, kind: artwork.kind,
            sourceTitleHeight: artwork.title.bounds.height)
        let thumbnail = destination.firstDescendant(
            accessibilityIdentifier: LeftTraySaveTransitionAnchor.thumbnail)
            .map { $0.convert($0.bounds, to: host?.view) }
        let title = destination.firstDescendant(
            accessibilityIdentifier: LeftTraySaveTransitionAnchor.title)
            .map { $0.convert($0.bounds, to: host?.view) }
        return LeftTraySaveTransitionGeometry(
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

/// The shared skeleton behind Reader's and Downloader's root screens: both
/// present one `CardCarouselViewController` full-screen, flank its scrub strip
/// with two persistent Liquid Glass circles (Settings + a share/action button),
/// and attach mirrored edge trays (setup/paste/recent on the left, archive on
/// the right). This base owns the carousel instance and the chrome/index-math
/// pieces that are byte-identical between the two hosts; each subclass keeps
/// its own item model, data source/delegate conformance, and store reload
/// orchestration.
class CardCarouselHostViewController: UIViewController {

    let carousel = CardCarouselViewController()
    private(set) var archiveTray: ArchiveTrayController?
    private(set) var leftTray: LeftTrayController?
    private var leftTraySaveTransition: LeftTraySaveTransition?

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

    final func mountLeftTray(
        shifting views: @escaping () -> [UIView],
        canPull: @escaping () -> Bool,
        savedURL: @escaping (String, CaptureSource, UIView) -> Void,
        openStateChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        leftTray = LeftTrayController(
            host: self, shiftedViews: views, canPull: canPull,
            savedURL: savedURL,
            openStateChanged: openStateChanged)
    }

    final func refreshArchivePullAvailability(animated: Bool) {
        archiveTray?.refreshPullAvailability(animated: animated)
    }

    final func refreshLeftPullAvailability(animated: Bool) {
        leftTray?.refreshPullAvailability(animated: animated)
    }

    /// Captures the tapped tray cell before the tray starts retracting. Surface
    /// hosts finish or cancel this after their normal ingest path resolves.
    final var pendingLeftTraySaveURLString: String? {
        leftTraySaveTransition?.urlString
    }

    final func beginLeftTraySaveTransition(
        for urlString: String, from sourceView: UIView
    ) {
        leftTraySaveTransition?.cancel()
        guard let transition = LeftTraySaveTransition(
            host: self, urlString: urlString, sourceView: sourceView)
        else {
            leftTraySaveTransition = nil
            return
        }
        transition.completion = { [weak self, weak transition] in
            guard let self, self.leftTraySaveTransition === transition else { return }
            self.leftTraySaveTransition = nil
        }
        leftTraySaveTransition = transition
    }

    final func prepareLeftTraySaveDestination(_ destination: UIView?) {
        leftTraySaveTransition?.prepare(destination: destination)
    }

    final func finishLeftTraySaveTransition(to destination: UIView?) {
        leftTraySaveTransition?.finish(to: destination)
    }

    final func cancelLeftTraySaveTransition() {
        leftTraySaveTransition?.cancel()
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
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-openLeftTray") {
            DispatchQueue.main.async { [weak self] in
                self?.refreshLeftPullAvailability(animated: false)
                self?.leftTray?.setOpenForTesting(true)
            }
        }
        #endif
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The carousel resolves its card metrics in its own pass, which runs
        // after this one, so settle it before reading the card column back.
        carousel.view.layoutIfNeeded()
        alignBottomControlsToCardColumn()
        archiveTray?.layout(in: view.bounds, safeAreaInsets: view.safeAreaInsets)
        leftTray?.layout(in: view.bounds, safeAreaInsets: view.safeAreaInsets)
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

    // MARK: - Pasteboard-offset index math

    /// Whether a synthetic pasteboard card is currently prepended to the
    /// carousel, shifting every real item's carousel index by one. Subclasses
    /// override to reflect their own pasteboard state.
    var hasLeadingPasteboardCard: Bool { false }

    final var cardOffset: Int { hasLeadingPasteboardCard ? 1 : 0 }

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
    /// `cardIDs` is the deck's card order minus any leading pasteboard card, so
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

    // MARK: - Empty state

    /// The image + title + subtitle stack both hosts use for "nothing saved
    /// yet" — identical layout, subclass-supplied glyph and copy.
    static func makeEmptyStateView(symbol: String, title: String, subtitle: String) -> UIView {
        let container = UIView()
        let image = UIImageView(image: UIImage(systemName: symbol))
        image.tintColor = LunaColors.tertiaryText
        image.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 44, weight: .regular)
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .preferredFont(forTextStyle: .title3)
        titleLabel.textColor = LunaColors.primaryText
        let subtitleLabel = UILabel()
        subtitleLabel.text = subtitle
        subtitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        subtitleLabel.textColor = LunaColors.secondaryText
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 0
        let stack = UIStackView(arrangedSubviews: [image, titleLabel, subtitleLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -32),
            // One long line of explanatory copy across an iPad reads as a banner,
            // not a sentence.
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: LunaLayout.readableWidth),
        ])
        return container
    }

    // MARK: - Settings

    @objc func settingsTapped() {
        navigationController?.pushViewController(SettingsViewController(), animated: true)
    }
}

/// The privacy-preserving leading card shown after pattern detection says the
/// pasteboard might contain a URL. Merely constructing/centering it does not
/// access the pasteboard value.
///
/// The read is performed by a system `UIPasteControl`, whose tap IS the
/// authorization: the pasted item arrives through `paste(itemProviders:)` and
/// the "Allow Paste from Other Apps" alert never appears. Nothing else on this
/// card touches the pasteboard, so the value stays unread until the user asks
/// for it — the same privacy posture as before, without the interruption.
/// `onPaste` nil (the transient "Loading Paste" state) shows no control.
final class PasteboardPlaceholderCardContentViewController: CardContentViewController {
    private let titleText: String
    private let detailText: String
    private let onPaste: ((String) -> Void)?

    init(title: String, detail: String, onPaste: ((String) -> Void)? = nil) {
        self.titleText = title
        self.detailText = detail
        self.onPaste = onPaste
        super.init()
        pasteConfiguration = UIPasteConfiguration(
            acceptableTypeIdentifiers: [UTType.url.identifier, UTType.plainText.identifier])
    }

    /// The paste control owns this card's interaction; a stray card tap would
    /// otherwise page or toggle under the user's finger.
    override func allowsCardTap(at point: CGPoint) -> Bool { onPaste == nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LunaColors.background
        // With a real control present the card must not swallow it into one
        // accessibility element; without one the whole card is the affordance.
        view.isAccessibilityElement = onPaste == nil
        view.accessibilityLabel = titleText
        view.accessibilityHint = detailText

        let icon = UIImageView(image: UIImage(systemName: "doc.on.clipboard"))
        icon.tintColor = GlassStyle.readingAccent
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: 42, weight: .medium)

        let title = UILabel()
        title.text = titleText
        title.font = .preferredFont(forTextStyle: .title2)
        title.textColor = LunaColors.primaryText
        title.textAlignment = .center

        let detail = UILabel()
        detail.text = detailText
        detail.font = .preferredFont(forTextStyle: .subheadline)
        detail.textColor = LunaColors.secondaryText
        detail.textAlignment = .center
        detail.numberOfLines = 0

        var arranged: [UIView] = [icon, title, detail]
        if onPaste != nil { arranged.append(makePasteControl()) }
        let stack = UIStackView(arrangedSubviews: arranged)
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 14
        stack.setCustomSpacing(24, after: detail)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
        ])
    }

    /// The system paste button, dressed as one of Luna's capsule actions: the
    /// fixed brand indigo rather than the configurable reading accent, so a
    /// yellow highlight preference can't leave white-on-yellow.
    private func makePasteControl() -> UIPasteControl {
        var configuration = UIPasteControl.Configuration()
        configuration.displayMode = .iconAndLabel
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = GlassStyle.lunaBrandAccent
        configuration.baseForegroundColor = .white
        let control = UIPasteControl(configuration: configuration)
        control.target = self
        control.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            control.heightAnchor.constraint(equalToConstant: 44),
            control.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
        ])
        return control
    }

    /// Delivered by `UIPasteControl` — an implicitly authorized read, so no
    /// prompt and no timing heuristics.
    override func paste(itemProviders: [NSItemProvider]) {
        if let provider = itemProviders.first(where: { $0.canLoadObject(ofClass: URL.self) }) {
            _ = provider.loadObject(ofClass: URL.self) { [weak self] url, _ in
                guard let url else { return }
                DispatchQueue.main.async { self?.onPaste?(url.absoluteString) }
            }
            return
        }
        guard let provider = itemProviders.first(where: { $0.canLoadObject(ofClass: NSString.self) })
        else { return }
        _ = provider.loadObject(ofClass: NSString.self) { [weak self] string, _ in
            guard let string = string as? NSString else { return }
            DispatchQueue.main.async { self?.onPaste?(string as String) }
        }
    }
}

/// A failed user-initiated paste read: the pasted text was not a URL this app
/// can take. There is no "Allow Paste" branch to explain — the read arrives
/// through `UIPasteControl`, which never asks.
final class InvalidPasteCardContentViewController: CardContentViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LunaColors.background

        let icon = UIImageView(image: UIImage(systemName: "exclamationmark.circle"))
        icon.tintColor = LunaColors.secondaryText
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: 40, weight: .medium)

        let title = UILabel()
        title.text = L10n.string("Invalid paste")
        title.font = .preferredFont(forTextStyle: .title2)
        title.textColor = LunaColors.primaryText
        title.textAlignment = .center

        let detail = UILabel()
        detail.text = L10n.string("Invalid URL")
        detail.font = .preferredFont(forTextStyle: .subheadline)
        detail.textColor = LunaColors.secondaryText
        detail.textAlignment = .center
        detail.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [icon, title, detail])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -28),
            detail.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -56),
        ])
    }
}

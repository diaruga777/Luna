//
//  MessagesReplicaViewController.swift
//  Luna
//

import LunaDesignSystem
import UIKit

enum OnboardingMessagesReplicaTiming {
    static let firstMessageDelay: TimeInterval = 0.34
    /// The gap before each staged arrival AFTER the first — one entry per
    /// hand-off, because two friends texting do not keep a metronome. The
    /// greeting's follow-up lands almost on top of it, the reply takes the
    /// beat it costs to actually type, and the link follows its own
    /// "check it:" immediately.
    ///
    /// The ratios between them are what make the thread read as two people;
    /// the absolute scale is what makes it read as *typing*. These are paced
    /// off someone typing quickly rather than off an animation timeline — an
    /// earlier, brisker set landed four sentences in under three seconds,
    /// which is a transcript being replayed, not a conversation happening.
    static let stagedMessageDelays: [TimeInterval] = [0.85, 2.0, 1.5, 0.75]
    static let messageDuration: TimeInterval = 0.42
    static let saveDelayAfterLastMessage: TimeInterval = 1.1

    static var actionButtonReplayDelay: TimeInterval {
        firstMessageDelay
            + stagedMessageDelays.reduce(0, +)
            + messageDuration
            + saveDelayAfterLastMessage
    }
}

/// A noninteractive iMessage conversation used as the second source in the
/// onboarding save loop. A friend opens with "Yoooooo", asks what your Action
/// Button is doing, hears that it's dead, and offers what theirs does —
/// followed by a link. The Action Button ripple then plays over that link and
/// the save resolves as a mock shortcut run: Dynamic Island progress, a staged
/// tap, the action-extension sheet — ending on the friend's pill messages that
/// install the shortcut and open Settings.
@MainActor
final class MessagesReplicaViewController: OnboardingSaveSourceViewController {
    var onInstallShortcut: (() -> Void)?
    var onSetActionButton: (() -> Void)?
    /// Fired once the shortcut-install message is on screen: the
    /// demonstration is over and the pill (or the skip-out) owns what's next.
    var onShortcutSetupMessagesShown: (() -> Void)?
    var onSkipSetup: (() -> Void)?

    /// The thread in the order it reads top to bottom — which is NOT the order
    /// it arrives in. The Settings message lands ABOVE the skip-out, which is
    /// already on screen by the time the user comes back from the Shortcuts
    /// install, so reveals are driven by row identity rather than a count.
    private enum Row: Int, CaseIterable {
        case greeting
        case question
        case answer
        case pitch
        case link
        case shortcut
        case settings
        case skip

        /// The rows that arrive on their own, before the Action Button press.
        static let staged: [Row] = [.greeting, .question, .answer, .pitch, .link]
    }

    private let senderNameLabel = UILabel()
    private let conversationStack = UIStackView()
    private let urlBubble = OnboardingMessageURLBubble(showsTail: true)
    private let shortcutPill = OnboardingMessagePillButton(style: .shortcuts)
    private let settingsPill = OnboardingMessagePillButton(style: .settings)
    private let skipPill = OnboardingMessagePillButton(style: .skip)
    private var shortcutBubble: OnboardingMessagePillBubble?
    private var currentURLString: String
    private var messageRows: [OnboardingMessageRow] = []
    private var revealedRows: Set<Row> = []
    private var presentationGeneration = 0
    private var sequenceGeneration = 0
    private var islandView: OnboardingDynamicIslandRunView?
    private var mockTap: OnboardingMockTapIndicatorView?
    private var flyingBubble: UIView?
    private var extensionSheet: OnboardingActionExtensionSheetView?
    private var hidesStatusBarForIsland = false
    private(set) var isShowingSetupMessages = false
    /// How far the real bubble sinks while its flying copy carries the
    /// departure — a faint ghost rather than a hard gap in the thread.
    private static let bubbleFlightFadeAlpha: CGFloat = 0.15

    override var preferredStatusBarStyle: UIStatusBarStyle { .darkContent }
    override var prefersStatusBarHidden: Bool { hidesStatusBarForIsland }
    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }
    override var sharedURLString: String { currentURLString }
    override var saveEffectStyle: OnboardingSaveEffectStyle { .rippleOnly }
    override var actionButtonReplayDelay: TimeInterval {
        OnboardingMessagesReplicaTiming.actionButtonReplayDelay
    }

    init(urlString: String) {
        currentURLString = urlString
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .light
        view.backgroundColor = .white
        view.accessibilityIdentifier = "onboarding.messages.replica"
        let composer = configureComposer()
        configureConversation(above: composer)
        configureHeader()
        urlBubble.setURL(currentURLString)
        shortcutPill.onActivate = { [weak self] in self?.onInstallShortcut?() }
        settingsPill.onActivate = { [weak self] in self?.onSetActionButton?() }
        skipPill.onActivate = { [weak self] in
            guard let self else { return }
            self.skipPill.isUserInteractionEnabled = false
            self.onSkipSetup?()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Until the first message lands, the conversation waits just below its
        // resting spot; each reveal then springs the thread up from there.
        if revealedRows.isEmpty {
            conversationStack.transform = CGAffineTransform(
                translationX: 0, y: stackOffset())
        }
    }

    private func rowView(_ row: Row) -> OnboardingMessageRow {
        messageRows[row.rawValue]
    }

    func updateURL(_ urlString: String) {
        currentURLString = urlString
        if isViewLoaded {
            urlBubble.setURL(urlString)
        }
    }

    override func setURLHighlighted(_ highlighted: Bool) {
        urlBubble.setURLHighlighted(highlighted)
    }

    override var isURLHighlighted: Bool { urlBubble.isURLHighlighted }

    override var highlightedLinkRegion: OnboardingHighlightedLinkRegion? {
        guard isViewLoaded else { return nil }
        return OnboardingHighlightedLinkRegion(
            frame: view.convert(urlBubble.bounds, from: urlBubble),
            cornerRadius: urlBubble.layer.cornerRadius)
    }

    override func prepareForPresentation() {
        super.prepareForPresentation()
        resetConversation()
        scheduleStagedConversation()
    }

    /// Returns the conversation to its untouched resting state — nothing
    /// revealed, no in-flight shortcut run — without starting the staged
    /// arrivals. The app-switcher hop snapshots this state as its incoming
    /// card before the first bubble lands.
    func resetConversation() {
        presentationGeneration += 1
        cancelShortcutRunSequence()
        isShowingSetupMessages = false
        revealedRows.removeAll()

        for row in messageRows {
            row.layer.removeAllAnimations()
            row.bubbleView.layer.removeAllAnimations()
            row.alpha = 0
            row.transform = .identity
            row.bubbleView.transform = .identity
            row.bubbleView.alpha = 1
        }
        // The Settings message waits collapsed — it opens its own space in the
        // middle of the thread when it finally arrives.
        rowView(.settings).isHidden = true
        conversationStack.setCustomSpacing(
            UIStackView.spacingUseDefault, after: rowView(.shortcut))
        shortcutBubble?.setShowsTail(true)
        shortcutPill.reset()
        settingsPill.reset()
        skipPill.reset()
        skipPill.isUserInteractionEnabled = true
        view.layoutIfNeeded()
        conversationStack.transform = CGAffineTransform(
            translationX: 0, y: stackOffset())
    }

    /// Starts the timed arrival of the staged messages.
    func scheduleStagedConversation() {
        let generation = presentationGeneration
        var delay = OnboardingMessagesReplicaTiming.firstMessageDelay
        for (index, row) in Row.staged.enumerated() {
            if index > 0 {
                delay += OnboardingMessagesReplicaTiming
                    .stagedMessageDelays[index - 1]
            }
            DispatchQueue.main.asyncAfter(
                deadline: .now() + OnboardingAnimationClock.delay(delay)
            ) { [weak self] in
                guard let self,
                      generation == self.presentationGeneration
                else { return }
                self.reveal(row)
            }
        }
    }

    // MARK: - Message arrival

    /// Lands the staged conversation instantly — the deterministic seam tests
    /// (and debug holds) use instead of the timed arrival.
    func revealStagedConversationImmediately() {
        presentationGeneration += 1
        view.layoutIfNeeded()
        for row in Row.staged {
            revealedRows.insert(row)
            rowView(row).alpha = 1
        }
        conversationStack.transform = CGAffineTransform(
            translationX: 0, y: stackOffset())
    }

    /// Lands the three setup messages instantly, in the order they really
    /// arrive — the deterministic seam tests use instead of playing out the
    /// mock shortcut run and a trip to the Shortcuts app.
    func revealSetupMessagesImmediately() {
        isShowingSetupMessages = true
        reveal(.shortcut)
        reveal(.skip)
        revealSettingsSetupMessage()
    }

    /// Pops a bubble in the way iMessage does: the thread springs up while the
    /// new bubble grows out of its tail corner.
    private func reveal(_ row: Row, completion: (() -> Void)? = nil) {
        guard !revealedRows.contains(row) else {
            completion?()
            return
        }
        revealedRows.insert(row)
        let arriving = rowView(row)
        view.layoutIfNeeded()

        // The Settings message is the only one that arrives INTO the thread
        // rather than under it — the skip-out is already sitting below where
        // it belongs. Opening its collapsed space shoves everything above it
        // up and leaves the skip where it is, so the rows above start
        // displaced by exactly that much and are animated back: a movement
        // rather than a jump.
        var displaced: [OnboardingMessageRow] = []
        if arriving.isHidden {
            let heightBefore = conversationStack.bounds.height
            arriving.isHidden = false
            conversationStack.setCustomSpacing(
                OnboardingMessageRow.groupedSpacing, after: rowView(.shortcut))
            view.layoutIfNeeded()
            let shove = conversationStack.bounds.height - heightBefore
            displaced = Row.allCases
                .filter { $0.rawValue < row.rawValue }
                .map { rowView($0) }
            for view in displaced {
                view.transform = CGAffineTransform(translationX: 0, y: shove)
            }
        }
        let offset = stackOffset()

        if UIAccessibility.isReduceMotionEnabled {
            conversationStack.transform = CGAffineTransform(
                translationX: 0, y: offset)
            UIView.animate(withDuration: 0.18, animations: {
                arriving.alpha = 1
                for view in displaced { view.transform = .identity }
            }) { _ in completion?() }
            return
        }

        let bubble = arriving.bubbleView
        let scale: CGFloat = 0.55
        let anchorShift = CGPoint(
            x: bubble.bounds.width * (1 - scale) / 2
                * (arriving.direction == .outgoing ? 1 : -1),
            y: bubble.bounds.height * (1 - scale) / 2)
        bubble.transform = CGAffineTransform(
            translationX: anchorShift.x, y: anchorShift.y
        ).scaledBy(x: scale, y: scale)

        UIView.animate(
            withDuration: 0.16,
            delay: 0,
            options: [.curveEaseOut, .beginFromCurrentState]
        ) {
            arriving.alpha = 1
        }
        UIView.animate(
            withDuration: OnboardingMessagesReplicaTiming.messageDuration,
            delay: 0,
            usingSpringWithDamping: 0.78,
            initialSpringVelocity: 0.4,
            options: [.curveEaseOut, .beginFromCurrentState]
        ) {
            self.conversationStack.transform = CGAffineTransform(
                translationX: 0, y: offset)
            for view in displaced { view.transform = .identity }
        }
        UIView.animate(
            withDuration: 0.52,
            delay: 0,
            usingSpringWithDamping: 0.66,
            initialSpringVelocity: 0.5,
            options: [.beginFromCurrentState]
        ) {
            bubble.transform = .identity
        } completion: { _ in
            completion?()
        }
    }

    /// How far the whole thread sits below its resting spot so that the
    /// bottom-most revealed bubble is the one hugging the composer. Before
    /// anything has arrived, the thread waits one bubble-length lower so the
    /// first message rises out of the composer, the way iMessage lands one.
    private func stackOffset() -> CGFloat {
        guard !messageRows.isEmpty else { return 0 }
        guard let bottom = Row.allCases.last(where: revealedRows.contains) else {
            return conversationStack.bounds.height
                - rowView(.greeting).frame.maxY + 34
        }
        return conversationStack.bounds.height - rowView(bottom).frame.maxY
    }

    // MARK: - The mock shortcut run

    override func rippleSaveEffectDidFinish() {
        sequenceGeneration += 1
        let generation = sequenceGeneration
        afterDelay(
            OnboardingShortcutRunTiming.islandExpandDelay,
            generation: generation
        ) {
            self.presentIsland(generation: generation)
        }
    }

    override func saveEffectWasCancelled() {
        cancelShortcutRunSequence()
    }

    private func afterDelay(
        _ delay: TimeInterval,
        generation: Int,
        _ work: @escaping () -> Void
    ) {
        DispatchQueue.main.asyncAfter(
            deadline: .now() + OnboardingAnimationClock.delay(delay)
        ) { [weak self] in
            guard let self, generation == self.sequenceGeneration else { return }
            work()
        }
    }

    private func presentIsland(generation: Int) {
        setStatusBarHiddenForIsland(true)
        let island = OnboardingDynamicIslandRunView(
            appIcon: OnboardingAppIcon.image())
        islandView = island
        island.expand(in: view) { [weak self] in
            guard let self, generation == self.sequenceGeneration else { return }
            island.runProgress { [weak self] in
                guard let self, generation == self.sequenceGeneration else { return }
                self.afterDelay(
                    OnboardingShortcutRunTiming.islandTapDelay,
                    generation: generation
                ) {
                    self.playMockTap(on: island, generation: generation)
                }
            }
        }
        // The saved link rides along: the bubble pops out of the thread and
        // arcs up into the inflating island.
        flyURLBubble(into: island, generation: generation)
    }

    /// Pops the URL bubble out of its spot and flies it — a curved climb with
    /// a slight tumble, shrinking — up under the island, which swallows it.
    private func flyURLBubble(
        into island: OnboardingDynamicIslandRunView,
        generation: Int
    ) {
        if UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.25) {
                self.urlBubble.alpha = Self.bubbleFlightFadeAlpha
            }
            return
        }
        guard urlBubble.alpha > 0, let row = urlBubble.superview else { return }

        // Fly a raster copy (the tail curls outside the bubble's bounds, so a
        // plain snapshotView would crop it) and pop the real bubble out.
        let padded = urlBubble.bounds.insetBy(dx: -8, dy: -2)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        let image = UIGraphicsImageRenderer(
            bounds: padded, format: format
        ).image { context in
            urlBubble.layer.render(in: context.cgContext)
        }
        let flying = UIImageView(image: image)
        flying.bounds = CGRect(origin: .zero, size: padded.size)
        flying.center = view.convert(
            CGPoint(x: urlBubble.center.x, y: urlBubble.center.y),
            from: row)
        view.insertSubview(flying, belowSubview: island)
        flyingBubble = flying
        // The copy carries the departure; the real bubble stays put but sinks
        // to a faint ghost so the thread doesn't leave a hard gap while it's
        // gone, then un-fades as the flight lands.
        urlBubble.alpha = Self.bubbleFlightFadeAlpha

        let start = flying.center
        let target = CGPoint(
            x: island.frame.midX,
            y: island.frame.maxY - 6)
        let path = UIBezierPath()
        path.move(to: start)
        path.addCurve(
            to: target,
            controlPoint1: CGPoint(
                x: start.x + view.bounds.width * 0.42,
                y: start.y - (start.y - target.y) * 0.38),
            controlPoint2: CGPoint(
                x: target.x + view.bounds.width * 0.24,
                y: target.y + (start.y - target.y) * 0.20))

        let duration = OnboardingShortcutRunTiming.bubbleFlightDuration
        let position = CAKeyframeAnimation(keyPath: "position")
        position.path = path.cgPath
        position.calculationMode = .paced
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = -0.22
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1
        scale.toValue = 0.16
        scale.timingFunction = CAMediaTimingFunction(name: .easeIn)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1, 1, 0.9, 0]
        fade.keyTimes = [0, 0.72, 0.9, 1]
        let flight = CAAnimationGroup()
        flight.animations = [position, rotation, scale, fade]
        flight.duration = duration
        flight.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        flight.fillMode = .forwards
        flight.isRemovedOnCompletion = false
        flying.layer.add(flight, forKey: "onboarding.bubble.flight")
        flying.layer.opacity = 0

        afterDelay(duration, generation: generation) {
            self.flyingBubble?.removeFromSuperview()
            self.flyingBubble = nil
            island.absorb()
            UIView.animate(withDuration: 0.22) {
                self.urlBubble.alpha = 1
            }
        }
    }

    private func playMockTap(
        on island: OnboardingDynamicIslandRunView,
        generation: Int
    ) {
        let tap = OnboardingMockTapIndicatorView()
        mockTap = tap
        tap.play(
            at: island.tapTarget(in: view),
            in: view,
            pressing: island
        ) { [weak self] in
            guard let self, generation == self.sequenceGeneration else { return }
            self.mockTap = nil
            island.collapse { [weak self] in
                guard let self, generation == self.sequenceGeneration else { return }
                self.islandView = nil
                self.setStatusBarHiddenForIsland(false)
                self.presentMockActionExtension(generation: generation)
            }
        }
    }

    /// The tapped island "runs" the save: the app's ordinary action-extension
    /// sheet slides up over the conversation with the reader inside, holds a
    /// beat, and slides away.
    private func presentMockActionExtension(generation: Int) {
        let sheet = OnboardingActionExtensionSheetView(frame: view.bounds)
        extensionSheet = sheet
        view.addSubview(sheet)
        sheet.present { [weak self] in
            guard let self, generation == self.sequenceGeneration else { return }
            self.afterDelay(
                OnboardingShortcutRunTiming.extensionSheetHoldDuration,
                generation: generation
            ) {
                self.extensionSheet?.dismiss { [weak self] in
                    guard let self,
                          generation == self.sequenceGeneration
                    else { return }
                    self.extensionSheet?.removeFromSuperview()
                    self.extensionSheet = nil
                    self.finishShortcutRunSequence(generation: generation)
                }
            }
        }
    }

    private func finishShortcutRunSequence(generation: Int) {
        setURLHighlighted(false)
        urlBubble.alpha = 1
        afterDelay(
            OnboardingShortcutRunTiming.followUpMessageDelay,
            generation: generation
        ) {
            self.reveal(.shortcut)
            self.shortcutPill.beginAttentionPulse()
            self.isShowingSetupMessages = true
            self.onShortcutSetupMessagesShown?()
            self.afterDelay(
                OnboardingShortcutRunTiming.skipMessageDelay,
                generation: generation
            ) {
                self.reveal(.skip)
            }
        }
    }

    /// The Settings walkthrough message arrives only once the user has been
    /// to the Shortcuts install and re-foregrounded the app — by which time
    /// the skip-out is already below it, so it lands in between.
    func revealSettingsSetupMessage() {
        guard isShowingSetupMessages, !revealedRows.contains(.settings)
        else { return }
        shortcutBubble?.setShowsTail(false)
        reveal(.settings)
        settingsPill.beginAttentionPulse()
    }

    private func setStatusBarHiddenForIsland(_ hidden: Bool) {
        guard hidesStatusBarForIsland != hidden else { return }
        hidesStatusBarForIsland = hidden
        UIView.animate(withDuration: 0.25) {
            self.setNeedsStatusBarAppearanceUpdate()
            self.parent?.setNeedsStatusBarAppearanceUpdate()
        }
    }

    private func cancelShortcutRunSequence() {
        sequenceGeneration += 1
        islandView?.layer.removeAllAnimations()
        islandView?.removeFromSuperview()
        islandView = nil
        mockTap?.layer.removeAllAnimations()
        mockTap?.removeFromSuperview()
        mockTap = nil
        flyingBubble?.layer.removeAllAnimations()
        flyingBubble?.removeFromSuperview()
        flyingBubble = nil
        extensionSheet?.removeFromSuperview()
        extensionSheet = nil
        setStatusBarHiddenForIsland(false)
        urlBubble.layer.removeAllAnimations()
        urlBubble.transform = .identity
        if revealedRows.contains(.link) {
            urlBubble.alpha = 1
        }
    }

    // MARK: - Static chrome

    private func configureHeader() {
        let header = UIView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.backgroundColor = UIColor.white.withAlphaComponent(0.96)
        view.addSubview(header)

        let separator = UIView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.backgroundColor = UIColor(white: 0.86, alpha: 1)
        header.addSubview(separator)

        let back = UIImageView(image: UIImage(
            systemName: "chevron.backward",
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: 18, weight: .semibold)))
        back.translatesAutoresizingMaskIntoConstraints = false
        back.tintColor = .systemBlue
        back.contentMode = .center
        header.addSubview(back)

        let avatar = UIImageView(image: UIImage(
            systemName: "person.crop.circle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 48)))
        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.tintColor = UIColor(white: 0.72, alpha: 1)
        avatar.contentMode = .scaleAspectFit
        header.addSubview(avatar)

        senderNameLabel.translatesAutoresizingMaskIntoConstraints = false
        senderNameLabel.text = "Johnny Appleseed"
        senderNameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        senderNameLabel.textColor = UIColor(white: 0.12, alpha: 1)
        senderNameLabel.textAlignment = .center
        senderNameLabel.accessibilityIdentifier = "onboarding.messages.senderName"
        header.addSubview(senderNameLabel)

        let disclosure = UIImageView(image: UIImage(
            systemName: "chevron.down",
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: 8, weight: .semibold)))
        disclosure.translatesAutoresizingMaskIntoConstraints = false
        disclosure.tintColor = UIColor(white: 0.42, alpha: 1)
        header.addSubview(disclosure)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 88),
            separator.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 0.5),
            back.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 15),
            back.centerYAnchor.constraint(equalTo: avatar.centerYAnchor),
            back.widthAnchor.constraint(equalToConstant: 28),
            back.heightAnchor.constraint(equalToConstant: 44),
            avatar.topAnchor.constraint(equalTo: header.topAnchor, constant: 7),
            avatar.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 48),
            avatar.heightAnchor.constraint(equalToConstant: 48),
            senderNameLabel.topAnchor.constraint(
                equalTo: avatar.bottomAnchor, constant: 3),
            senderNameLabel.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            disclosure.leadingAnchor.constraint(
                equalTo: senderNameLabel.trailingAnchor, constant: 4),
            disclosure.centerYAnchor.constraint(equalTo: senderNameLabel.centerYAnchor),
        ])
    }

    private func configureConversation(above composer: UIView) {
        let shortcutBubble = OnboardingMessagePillBubble(
            direction: .incoming,
            showsTail: true,
            text: "Just install this shortcut",
            pill: shortcutPill,
            accessibilityIdentifier: "onboarding.messages.shortcutSetup")
        self.shortcutBubble = shortcutBubble

        // Thread order (see `Row`): the friend opens, asks, hears the Action
        // Button is dead, offers what theirs does, and sends the link.
        messageRows = [
            OnboardingMessageRow(
                direction: .incoming,
                bubble: OnboardingMessageTextBubble(
                    direction: .incoming,
                    showsTail: false,
                    text: "Yoooooo",
                    accessibilityIdentifier: "onboarding.messages.greeting")),
            OnboardingMessageRow(
                direction: .incoming,
                bubble: OnboardingMessageTextBubble(
                    direction: .incoming,
                    showsTail: true,
                    text: "You using your action button for anything?",
                    accessibilityIdentifier: "onboarding.messages.question")),
            OnboardingMessageRow(
                direction: .outgoing,
                bubble: OnboardingMessageTextBubble(
                    direction: .outgoing,
                    showsTail: true,
                    text: "Nah. Its kinda dead tbh.",
                    accessibilityIdentifier: "onboarding.messages.answer")),
            OnboardingMessageRow(
                direction: .incoming,
                bubble: OnboardingMessageTextBubble(
                    direction: .incoming,
                    showsTail: false,
                    text: "I use it to instant save any link on screen. "
                        + "Check it:",
                    accessibilityIdentifier: "onboarding.messages.pitch")),
            OnboardingMessageRow(direction: .incoming, bubble: urlBubble),
            OnboardingMessageRow(direction: .incoming, bubble: shortcutBubble),
            OnboardingMessageRow(
                direction: .incoming,
                bubble: OnboardingMessagePillBubble(
                    direction: .incoming,
                    showsTail: true,
                    text: "Then set your action button to it in",
                    pill: settingsPill,
                    accessibilityIdentifier: "onboarding.messages.settingsSetup")),
            OnboardingMessageRow(
                direction: .outgoing,
                bubble: OnboardingMessagePillBubble(
                    direction: .outgoing,
                    showsTail: false,
                    appearance: .ghost,
                    text: "Or",
                    pill: skipPill,
                    accessibilityIdentifier: "onboarding.messages.skipSetup")),
        ]
        for row in messageRows {
            row.alpha = 0
            conversationStack.addArrangedSubview(row)
        }
        rowView(.settings).isHidden = true

        conversationStack.translatesAutoresizingMaskIntoConstraints = false
        conversationStack.axis = .vertical
        conversationStack.spacing = OnboardingMessageRow.senderSpacing
        // Consecutive same-sender bubbles group tightly, like iMessage. The
        // shortcut/Settings pair groups the same way, but only once the
        // Settings message is actually there (see `reveal`) — until then that
        // spacing would pull the skip-out up against the shortcut bubble.
        conversationStack.setCustomSpacing(
            OnboardingMessageRow.groupedSpacing, after: rowView(.greeting))
        conversationStack.setCustomSpacing(
            OnboardingMessageRow.groupedSpacing, after: rowView(.pitch))
        conversationStack.accessibilityIdentifier = "onboarding.messages.conversation"
        // Unrevealed rows wait below the resting thread; keep them (and each
        // arrival's rise) underneath the opaque composer.
        view.insertSubview(conversationStack, belowSubview: composer)

        // The thread is a replica of a PHONE conversation, so it keeps phone width
        // and centres on anything wider. Two bubbles pinned to opposite edges of
        // an iPad, a thousand points apart, stop reading as a conversation. The
        // header and composer bars stay full width, as they would in any
        // single-pane iPad app.
        let threadWidth = conversationStack.widthAnchor.constraint(
            lessThanOrEqualToConstant: LunaLayout.phoneReplicaWidth)
        let fullWidth = conversationStack.widthAnchor.constraint(
            equalTo: view.widthAnchor)
        fullWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            conversationStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            threadWidth,
            fullWidth,
            conversationStack.bottomAnchor.constraint(
                equalTo: composer.topAnchor, constant: -12),
        ])
    }

    private func configureComposer() -> UIView {
        let composer = UIView()
        composer.translatesAutoresizingMaskIntoConstraints = false
        composer.backgroundColor = .white
        view.addSubview(composer)

        let plus = UIImageView(image: UIImage(
            systemName: "plus.circle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 26)))
        plus.translatesAutoresizingMaskIntoConstraints = false
        plus.tintColor = UIColor(white: 0.66, alpha: 1)
        composer.addSubview(plus)

        let field = UIView()
        field.translatesAutoresizingMaskIntoConstraints = false
        field.layer.cornerRadius = 18
        field.layer.cornerCurve = .continuous
        field.layer.borderWidth = 1
        field.layer.borderColor = UIColor(white: 0.82, alpha: 1).cgColor
        composer.addSubview(field)

        let microphone = UIImageView(image: UIImage(
            systemName: "mic.fill",
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: 15, weight: .semibold)))
        microphone.translatesAutoresizingMaskIntoConstraints = false
        microphone.tintColor = UIColor(white: 0.48, alpha: 1)
        field.addSubview(microphone)

        NSLayoutConstraint.activate([
            composer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composer.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -30),
            composer.heightAnchor.constraint(equalToConstant: 54),
            plus.leadingAnchor.constraint(equalTo: composer.leadingAnchor, constant: 12),
            plus.centerYAnchor.constraint(equalTo: composer.centerYAnchor),
            plus.widthAnchor.constraint(equalToConstant: 30),
            plus.heightAnchor.constraint(equalToConstant: 30),
            field.leadingAnchor.constraint(equalTo: plus.trailingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: composer.trailingAnchor, constant: -12),
            field.centerYAnchor.constraint(equalTo: composer.centerYAnchor),
            field.heightAnchor.constraint(equalToConstant: 38),
            microphone.trailingAnchor.constraint(equalTo: field.trailingAnchor, constant: -11),
            microphone.centerYAnchor.constraint(equalTo: field.centerYAnchor),
        ])
        return composer
    }
}

// MARK: - Bubbles

enum OnboardingMessageDirection {
    case incoming
    case outgoing
}

private final class OnboardingMessageRow: UIView {
    /// iMessage's two vertical rhythms: bubbles from the same sender in a row
    /// almost touch, and a change of sender opens a real gap.
    static let groupedSpacing: CGFloat = 2
    static let senderSpacing: CGFloat = 8

    let direction: OnboardingMessageDirection
    let bubbleView: OnboardingMessageBubble

    init(direction: OnboardingMessageDirection, bubble: OnboardingMessageBubble) {
        self.direction = direction
        self.bubbleView = bubble
        super.init(frame: .zero)
        bubble.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bubble)

        let edgeConstraint: NSLayoutConstraint
        switch direction {
        case .incoming:
            edgeConstraint = bubble.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: 16)
        case .outgoing:
            edgeConstraint = bubble.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -16)
        }
        NSLayoutConstraint.activate([
            edgeConstraint,
            bubble.topAnchor.constraint(equalTo: topAnchor),
            bubble.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

/// The rounded iMessage bubble surface, with the classic outward tail curl on
/// the last bubble of a same-sender group.
class OnboardingMessageBubble: UIView {
    static let outgoingBlue = UIColor(
        red: 0 / 255, green: 122 / 255, blue: 255 / 255, alpha: 1)
    static let incomingGray = UIColor(
        red: 233 / 255, green: 233 / 255, blue: 235 / 255, alpha: 1)
    /// Larger than the real app's 17pt — the conversation is a demonstration
    /// watched from arm's length, not something being read up close.
    static let textSize: CGFloat = 19

    /// A bubble is either a line of the conversation or the way out of it. The
    /// skip-out is drawn, never sent: unfilled and sketched in dots, in a
    /// faded version of the outgoing blue, so it reads as an option offered by
    /// the app rather than something the friend said.
    enum Appearance {
        case filled
        case ghost
    }

    let direction: OnboardingMessageDirection
    let appearance: Appearance
    private let tail = CAShapeLayer()
    private let ghostOutline = CAShapeLayer()
    private var showsTail: Bool

    init(
        direction: OnboardingMessageDirection,
        showsTail: Bool,
        appearance: Appearance = .filled
    ) {
        self.direction = direction
        self.appearance = appearance
        self.showsTail = showsTail
        super.init(frame: .zero)
        clipsToBounds = false
        layer.cornerRadius = 18
        layer.cornerCurve = .continuous
        switch appearance {
        case .filled:
            let fill = direction == .incoming
                ? Self.incomingGray
                : Self.outgoingBlue
            backgroundColor = fill
            tail.fillColor = fill.cgColor
            layer.addSublayer(tail)
        case .ghost:
            backgroundColor = .clear
            ghostOutline.fillColor = nil
            ghostOutline.strokeColor = Self.outgoingBlue
                .withAlphaComponent(0.45).cgColor
            ghostOutline.lineWidth = Self.ghostLineWidth
            ghostOutline.lineCap = .round
            // A zero-length dash under a round cap is a dot.
            ghostOutline.lineDashPattern = [0.01, 6]
            layer.addSublayer(ghostOutline)
        }
        widthAnchor.constraint(lessThanOrEqualToConstant: 292).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private static let ghostLineWidth: CGFloat = 2

    /// The colour this bubble's own words take.
    var contentColor: UIColor {
        switch appearance {
        case .ghost:
            return Self.outgoingBlue.withAlphaComponent(0.7)
        case .filled:
            return direction == .incoming
                ? UIColor(white: 0.08, alpha: 1)
                : .white
        }
    }

    func setShowsTail(_ shows: Bool) {
        guard shows != showsTail else { return }
        showsTail = shows
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        switch appearance {
        case .filled:
            tail.frame = bounds
            tail.path = showsTail ? tailPath().cgPath : nil
        case .ghost:
            let inset = Self.ghostLineWidth / 2
            ghostOutline.frame = bounds
            ghostOutline.path = UIBezierPath(
                roundedRect: bounds.insetBy(dx: inset, dy: inset),
                cornerRadius: layer.cornerRadius - inset).cgPath
        }
    }

    /// A flat run along the baseline out to a point just beyond the bubble,
    /// curling concavely back up into the bubble's side — mirrored for
    /// incoming bubbles.
    private func tailPath() -> UIBezierPath {
        let width = bounds.width
        let height = bounds.height
        let path = UIBezierPath()
        path.move(to: CGPoint(x: width - 18, y: height))
        path.addLine(to: CGPoint(x: width + 6, y: height))
        path.addQuadCurve(
            to: CGPoint(x: width, y: height - 10),
            controlPoint: CGPoint(x: width + 0.5, y: height - 3))
        path.addLine(to: CGPoint(x: width, y: height - 18))
        path.close()
        if direction == .incoming {
            path.apply(CGAffineTransform(scaleX: -1, y: 1)
                .translatedBy(x: -width, y: 0))
        }
        return path
    }
}

private final class OnboardingMessageTextBubble: OnboardingMessageBubble {
    init(
        direction: OnboardingMessageDirection,
        showsTail: Bool,
        text: String,
        accessibilityIdentifier: String
    ) {
        super.init(direction: direction, showsTail: showsTail)
        self.accessibilityIdentifier = accessibilityIdentifier

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = text
        label.font = .systemFont(ofSize: OnboardingMessageBubble.textSize)
        label.textColor = contentColor
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.accessibilityLabel = text
        addSubview(label)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -13),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }
}

final class OnboardingMessageURLBubble: OnboardingMessageBubble {
    private let highlight = OnboardingURLHighlightView()
    private let label = UILabel()
    private var urlString = ""

    init(showsTail: Bool) {
        super.init(direction: .incoming, showsTail: showsTail)
        accessibilityIdentifier = "onboarding.messages.latestIncoming"

        highlight.translatesAutoresizingMaskIntoConstraints = false
        addSubview(highlight)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.accessibilityIdentifier = "onboarding.messages.latestURL"
        addSubview(label)

        NSLayoutConstraint.activate([
            highlight.topAnchor.constraint(equalTo: topAnchor),
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -11),
        ])
    }

    func setURL(_ urlString: String) {
        self.urlString = urlString
        accessibilityValue = urlString
        applyURLText(highlighted: isURLHighlighted)
    }

    func setURLHighlighted(_ highlighted: Bool) {
        highlight.setHighlighted(highlighted)
        applyURLText(highlighted: highlighted)
    }

    var isURLHighlighted: Bool { highlight.isHighlighted }

    /// iMessage renders bare links as underlined blue text.
    private func applyURLText(highlighted: Bool) {
        label.attributedText = NSAttributedString(
            string: urlString,
            attributes: [
                .font: UIFont.systemFont(
                    ofSize: OnboardingMessageBubble.textSize - 1),
                .foregroundColor: highlighted
                    ? UIColor(white: 0.08, alpha: 1)
                    : UIColor.systemBlue,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ])
    }
}

/// An outgoing bubble whose sentence carries an interactive pill INLINE: the
/// pill flows with the words (an attachment reserves its spot, so the line
/// breaking stays natural) and the live control sits exactly over that spot.
private final class OnboardingMessagePillBubble: OnboardingMessageBubble {
    private let textView = UITextView()
    private let pill: OnboardingMessagePillButton
    private let attachmentIndex: Int
    private let pillSize: CGSize

    init(
        direction: OnboardingMessageDirection,
        showsTail: Bool,
        appearance: Appearance = .filled,
        text: String,
        pill: OnboardingMessagePillButton,
        accessibilityIdentifier: String
    ) {
        self.pill = pill
        self.pillSize = pill.systemLayoutSizeFitting(
            UIView.layoutFittingCompressedSize)
        self.attachmentIndex = (text + " ").utf16.count
        super.init(
            direction: direction, showsTail: showsTail, appearance: appearance)
        self.accessibilityIdentifier = accessibilityIdentifier

        textView.isEditable = false
        textView.isSelectable = false
        textView.isScrollEnabled = false
        textView.isUserInteractionEnabled = false
        textView.backgroundColor = .clear
        // The app dresses every UITextView through the appearance proxy
        // (`LunaColors.applyGlobalAppearance` — near-white ink for the black
        // sky), and UIKit applies that the moment this one enters a window,
        // repainting the attributed string it was given. This replica is a
        // LIGHT-mode facsimile of Messages, so pin the colour on the instance:
        // an explicitly set property is left alone by the proxy.
        textView.textColor = contentColor
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.isAccessibilityElement = false
        textView.translatesAutoresizingMaskIntoConstraints = false

        let font = UIFont.systemFont(ofSize: OnboardingMessageBubble.textSize)
        let content = NSMutableAttributedString(
            string: text + " ",
            attributes: [.font: font, .foregroundColor: contentColor])
        let placeholder = NSTextAttachment()
        // An attachment with no contents draws the system's missing-image
        // glyph, which peeks out from behind the pill seated over it. An
        // empty transparent image of the pill's own size reserves the spot
        // and draws nothing.
        placeholder.image = UIGraphicsImageRenderer(size: pillSize).image { _ in }
        placeholder.bounds = CGRect(
            x: 0,
            y: (font.capHeight - pillSize.height) / 2,
            width: pillSize.width,
            height: pillSize.height)
        content.append(NSAttributedString(attachment: placeholder))
        textView.attributedText = content
        addSubview(textView)

        addSubview(pill)
        accessibilityLabel = text

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            textView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -13),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
        ])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        positionPill()
    }

    /// Seats the live pill exactly over its attachment's laid-out spot.
    private func positionPill() {
        let layoutManager = textView.layoutManager
        layoutManager.ensureLayout(for: textView.textContainer)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: attachmentIndex, length: 1),
            actualCharacterRange: nil)
        guard glyphRange.length > 0 else { return }
        let rect = layoutManager.boundingRect(
            forGlyphRange: glyphRange,
            in: textView.textContainer)
        pill.frame = CGRect(
            x: (textView.frame.minX + rect.minX).rounded(),
            y: (textView.frame.minY + rect.midY - pillSize.height / 2).rounded(),
            width: pillSize.width,
            height: pillSize.height)
    }
}

/// The tappable in-bubble chip: the Shortcuts-purple "Luna" shortcut install,
/// the grey system-Settings link, and the skip-out. The first two breathe an
/// eclipse corona until tapped; the skip-out never asks for the tap, so it
/// does not.
final class OnboardingMessagePillButton: UIControl {
    enum Style {
        case shortcuts
        case settings
        case skip
    }

    var onActivate: (() -> Void)?
    private(set) var wasActivated = false
    /// The colour the pill's corona burns. (A drop shadow in this colour used
    /// to be the whole effect.)
    private let glowColor: UIColor
    private let pulsesForAttention: Bool
    private var isPulsing = false
    private var corona: EclipseCoronaView?

    private static let shortcutsPurple = UIColor(
        red: 0.46, green: 0.29, blue: 0.96, alpha: 1)

    init(style: Style) {
        let icon: UIImage?
        let title: String
        let fill: UIColor
        let titleColor: UIColor
        let iconTint: UIColor?
        pulsesForAttention = style != .skip
        switch style {
        case .shortcuts:
            icon = OnboardingSystemIcons.shortcutsAppIcon
            title = "Luna"
            // White lifted faintly toward the Shortcuts app's violet.
            fill = UIColor(red: 0.93, green: 0.91, blue: 1.0, alpha: 1)
            titleColor = UIColor(red: 0.32, green: 0.18, blue: 0.78, alpha: 1)
            iconTint = nil
            glowColor = Self.shortcutsPurple
            super.init(frame: .zero)
            accessibilityIdentifier = "onboarding.messages.shortcutPill"
            accessibilityLabel = "Install the Luna shortcut"
        case .settings:
            icon = UIImage(
                systemName: "gearshape.fill",
                withConfiguration: UIImage.SymbolConfiguration(
                    pointSize: 14, weight: .medium))
            title = "Settings"
            fill = UIColor(red: 0.93, green: 0.93, blue: 0.94, alpha: 1)
            titleColor = UIColor(white: 0.15, alpha: 1)
            iconTint = UIColor(white: 0.42, alpha: 1)
            glowColor = UIColor(white: 0.55, alpha: 1)
            super.init(frame: .zero)
            accessibilityIdentifier = "onboarding.messages.settingsPill"
            accessibilityLabel = "Open Settings"
        case .skip:
            icon = UIImage(
                systemName: "chevron.forward",
                withConfiguration: UIImage.SymbolConfiguration(
                    pointSize: 13, weight: .semibold))
            title = "skip setup"
            // A wash of its own ghost bubble's blue, so the way out is legible
            // without competing with the two pills that want the tap.
            fill = OnboardingMessageBubble.outgoingBlue
                .withAlphaComponent(0.10)
            titleColor = OnboardingMessageBubble.outgoingBlue
                .withAlphaComponent(0.85)
            iconTint = OnboardingMessageBubble.outgoingBlue
                .withAlphaComponent(0.7)
            glowColor = .clear
            super.init(frame: .zero)
            accessibilityIdentifier = "onboarding.messages.skipPill"
            accessibilityLabel = "Skip setup"
        }
        accessibilityTraits = .button
        backgroundColor = fill
        layer.cornerCurve = .continuous

        let iconView = UIImageView(image: icon)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentMode = .scaleAspectFit
        if let iconTint {
            iconView.tintColor = iconTint
        }
        addSubview(iconView)

        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = titleColor
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),
            titleLabel.leadingAnchor.constraint(
                equalTo: iconView.trailingAnchor, constant: 6),
            titleLabel.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -12),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        addTarget(self, action: #selector(activated), for: .touchUpInside)
        // Setting the Action Button is a trip out of the app and back, and
        // iOS strips every running animation off a layer on the way out. A
        // pill still waiting for its tap has to pick its breath back up.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(resumePulseIfNeeded),
            name: UIApplication.didBecomeActiveNotification,
            object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        installCoronaIfNeeded()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        resumePulseIfNeeded()
    }

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(
                withDuration: 0.12,
                delay: 0,
                options: [.beginFromCurrentState, .allowUserInteraction]
            ) {
                self.transform = self.isHighlighted
                    ? CGAffineTransform(scaleX: 0.93, y: 0.93)
                    : .identity
            }
        }
    }

    /// How far the pill's corona throws. `EclipseCorona`'s own default has a
    /// 56pt floor sized for a card; on a 34pt chip that hands it streamers
    /// twice the height of the thing they surround.
    private static let coronaReach: CGFloat = 30
    /// One full breath. The corona is not in phase with it — see below.
    private static let pulseCycle: CFTimeInterval = 1.9
    static let pulseAnimationKey = "onboarding.pill.pulse"

    /// The corona lives INSIDE the pill, behind its icon and label. It can:
    /// `EclipseCorona` clips the silhouette's interior out of its raster, so
    /// the only thing drawn over the pill's own fill is the chromosphere's
    /// inner half — which reads as a lit rim, exactly what a limb should do.
    private func installCoronaIfNeeded() {
        guard pulsesForAttention, bounds.width > 1, bounds.height > 1 else { return }
        if let corona {
            guard corona.bounds.size != bounds.size else { return }
            corona.removeFromSuperview()
        }
        let halo = EclipseCoronaView(
            bodySize: bounds.size,
            cornerRadius: bounds.height / 2,
            tint: .white,
            // The replica is a LIGHT-mode facsimile of Messages. The real
            // corona's pearl is built to burn against Luna's black sky and
            // would be invisible here, so it burns the pill's own colour.
            light: glowColor,
            reach: Self.coronaReach)
        halo.frame = bounds
        halo.alpha = 0
        insertSubview(halo, at: 0)
        corona = halo
        if isPulsing { applyPulseAnimations() }
    }

    /// The pill demands its tap: a slow corona-and-scale breath that runs
    /// until the user follows it.
    func beginAttentionPulse() {
        guard pulsesForAttention, !isPulsing, !wasActivated else { return }
        isPulsing = true
        applyPulseAnimations()
    }

    /// Re-adds the breath after anything that could have stripped it — a trip
    /// out of the app, or a spell out of the window.
    @objc private func resumePulseIfNeeded() {
        guard isPulsing, window != nil,
              layer.animation(forKey: Self.pulseAnimationKey) == nil
        else { return }
        applyPulseAnimations()
    }

    private func applyPulseAnimations() {
        if UIAccessibility.isReduceMotionEnabled {
            corona?.alpha = 0.85
            return
        }

        // Durations are set on every keyframe rather than on a wrapping group:
        // a `CAAnimationGroup` does NOT scale its children to its own duration,
        // it clips them, so members left at the default ran a quarter-second
        // twitch inside a two-second cycle and the breath barely registered.
        let ease = CAMediaTimingFunction(name: .easeInEaseOut)

        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [1.0, 1.065, 1.065, 1.0]
        scale.keyTimes = [0, 0.42, 0.60, 1.0]
        scale.timingFunctions = [ease, ease, ease]
        scale.duration = Self.pulseCycle
        scale.repeatCount = .infinity
        layer.add(scale, forKey: Self.pulseAnimationKey)

        // The light leads the movement: totality is reached BEFORE the pill
        // finishes swelling, holds through the top of the breath, and burns
        // back down as the pill settles — so the corona is the event and the
        // scale is the pill reacting to it, not the other way round.
        guard let corona else { return }
        let bloom = CAKeyframeAnimation(keyPath: "opacity")
        bloom.values = [0, 1.0, 1.0, 0, 0]
        bloom.keyTimes = [0, 0.30, 0.60, 0.94, 1.0]
        bloom.timingFunctions = [ease, ease, ease, ease]
        bloom.duration = Self.pulseCycle
        bloom.repeatCount = .infinity
        corona.layer.add(bloom, forKey: Self.pulseAnimationKey)
    }

    private func stopAttentionPulse() {
        isPulsing = false
        layer.removeAnimation(forKey: Self.pulseAnimationKey)
        corona?.layer.removeAnimation(forKey: Self.pulseAnimationKey)
        corona?.alpha = 0
    }

    func reset() {
        wasActivated = false
        stopAttentionPulse()
    }

    @objc private func activated() {
        wasActivated = true
        stopAttentionPulse()
        onActivate?()
    }
}


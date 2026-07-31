//
//  MessagesReplicaViewController.swift
//  Luna
//

import UIKit

enum OnboardingMessagesReplicaTiming {
    static let firstMessageDelay: TimeInterval = 0.18
    static let interMessageDelay: TimeInterval = 1.6
    static let messageDuration: TimeInterval = 0.42
    static let saveDelayAfterLastMessage: TimeInterval = 0.75

    static var actionButtonReplayDelay: TimeInterval {
        firstMessageDelay
            + interMessageDelay * 2
            + messageDuration
            + saveDelayAfterLastMessage
    }
}

/// A noninteractive iMessage conversation used as the second source in the
/// onboarding save loop. Its three staged messages arrive one by one, the
/// Action Button ripple lights the shared URL, and the save then plays out as
/// a mock shortcut run: Dynamic Island progress, a staged tap, an app-switcher
/// hop into the saved Luna screen and back — ending on two follow-up messages
/// whose glowing pills install the shortcut and open Settings.
@MainActor
final class MessagesReplicaViewController: OnboardingSaveSourceViewController {
    var onInstallShortcut: (() -> Void)?
    var onSetActionButton: (() -> Void)?
    /// Fired once the setup messages (4 and 5) are on screen: the
    /// demonstration is over and the pills own the next step.
    var onShortcutSetupMessagesShown: (() -> Void)?

    private let senderNameLabel = UILabel()
    private let conversationStack = UIStackView()
    private let urlBubble = OnboardingMessageURLBubble(showsTail: true)
    private let shortcutPill = OnboardingMessagePillButton(style: .shortcuts)
    private let settingsPill = OnboardingMessagePillButton(style: .settings)
    private var shortcutBubble: OnboardingMessagePillBubble?
    private var currentURLString: String
    private var messageRows: [OnboardingMessageRow] = []
    /// Rows that arrive on their own before the Action Button press; the rest
    /// arrive after the mock shortcut run.
    private let stagedRowCount = 3
    private var revealedRowCount = 0
    private var presentationGeneration = 0
    private var sequenceGeneration = 0
    private var islandView: OnboardingDynamicIslandRunView?
    private var mockTap: OnboardingMockTapIndicatorView?
    private var appSwitcher: OnboardingAppSwitcherView?
    private(set) var isShowingSetupMessages = false

    override var preferredStatusBarStyle: UIStatusBarStyle { .darkContent }
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
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Until the first message lands, the conversation waits just below its
        // resting spot; each reveal then springs the thread up from there.
        if revealedRowCount == 0 {
            conversationStack.transform = CGAffineTransform(
                translationX: 0,
                y: stackOffset(afterRevealing: 0))
        }
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
        presentationGeneration += 1
        cancelShortcutRunSequence()
        isShowingSetupMessages = false
        revealedRowCount = 0

        for row in messageRows {
            row.layer.removeAllAnimations()
            row.bubbleView.layer.removeAllAnimations()
            row.alpha = 0
            row.bubbleView.transform = .identity
        }
        shortcutBubble?.setShowsTail(true)
        shortcutPill.reset()
        settingsPill.reset()
        view.layoutIfNeeded()
        conversationStack.transform = CGAffineTransform(
            translationX: 0,
            y: stackOffset(afterRevealing: 0))

        let generation = presentationGeneration
        for index in 0..<stagedRowCount {
            let delay = OnboardingMessagesReplicaTiming.firstMessageDelay
                + Double(index) * OnboardingMessagesReplicaTiming.interMessageDelay
            DispatchQueue.main.asyncAfter(
                deadline: .now() + OnboardingAnimationClock.delay(delay)
            ) { [weak self] in
                guard let self,
                      generation == self.presentationGeneration
                else { return }
                self.revealNextRow()
            }
        }
    }

    // MARK: - Message arrival

    /// Lands the staged conversation instantly — the deterministic seam tests
    /// (and debug holds) use instead of the timed arrival.
    func revealStagedConversationImmediately() {
        presentationGeneration += 1
        view.layoutIfNeeded()
        while revealedRowCount < stagedRowCount {
            messageRows[revealedRowCount].alpha = 1
            revealedRowCount += 1
        }
        conversationStack.transform = CGAffineTransform(
            translationX: 0,
            y: stackOffset(afterRevealing: revealedRowCount))
    }

    /// Pops the next bubble in the way iMessage does: the thread springs up
    /// while the new bubble grows out of its tail corner.
    private func revealNextRow(completion: (() -> Void)? = nil) {
        guard revealedRowCount < messageRows.count else {
            completion?()
            return
        }
        let row = messageRows[revealedRowCount]
        revealedRowCount += 1
        view.layoutIfNeeded()
        let offset = stackOffset(afterRevealing: revealedRowCount)

        if UIAccessibility.isReduceMotionEnabled {
            conversationStack.transform = CGAffineTransform(
                translationX: 0, y: offset)
            UIView.animate(withDuration: 0.18, animations: {
                row.alpha = 1
            }) { _ in completion?() }
            return
        }

        let bubble = row.bubbleView
        let scale: CGFloat = 0.55
        let anchorShift = CGPoint(
            x: bubble.bounds.width * (1 - scale) / 2
                * (row.direction == .outgoing ? 1 : -1),
            y: bubble.bounds.height * (1 - scale) / 2)
        bubble.transform = CGAffineTransform(
            translationX: anchorShift.x, y: anchorShift.y
        ).scaledBy(x: scale, y: scale)

        UIView.animate(
            withDuration: 0.16,
            delay: 0,
            options: [.curveEaseOut, .beginFromCurrentState]
        ) {
            row.alpha = 1
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

    /// How far the whole thread sits below its resting spot so that the last
    /// revealed bubble is the one hugging the composer. Before anything has
    /// arrived, the thread waits one bubble-length lower so the first message
    /// rises out of the composer, the way a freshly sent iMessage does.
    private func stackOffset(afterRevealing count: Int) -> CGFloat {
        guard count > 0, messageRows.indices.contains(count - 1) else {
            guard !messageRows.isEmpty else { return 0 }
            return stackOffset(afterRevealing: 1) + 34
        }
        return conversationStack.bounds.height
            - messageRows[count - 1].frame.maxY
    }

    // MARK: - The mock shortcut run

    override func rippleSaveEffectDidFinish() {
        sequenceGeneration += 1
        let generation = sequenceGeneration
        setURLBubbleEmphasized(true)
        afterDelay(
            OnboardingShortcutRunTiming.islandExpandDelay
                + OnboardingShortcutRunTiming.bubbleEmphasisDuration,
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

    private func setURLBubbleEmphasized(_ emphasized: Bool) {
        let transform = emphasized
            ? CGAffineTransform(scaleX: 1.12, y: 1.12)
            : .identity
        if UIAccessibility.isReduceMotionEnabled {
            urlBubble.transform = transform
            return
        }
        UIView.animate(
            withDuration: OnboardingShortcutRunTiming.bubbleEmphasisDuration,
            delay: 0,
            usingSpringWithDamping: 0.6,
            initialSpringVelocity: 0.5,
            options: [.beginFromCurrentState]
        ) {
            self.urlBubble.transform = transform
        }
    }

    private func presentIsland(generation: Int) {
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
                self.switchToSavedLunaScreen(generation: generation)
            }
        }
    }

    private func switchToSavedLunaScreen(generation: Int) {
        guard let makeSnapshot = makeActionButtonDestinationSnapshot,
              let lunaScreen = makeSnapshot()
        else {
            // No saved-screen raster to hop into — settle straight on the
            // setup messages so the journey can still complete.
            finishShortcutRunSequence(generation: generation)
            return
        }
        let switcher = OnboardingAppSwitcherView(
            frame: view.bounds,
            messages: renderConversationSnapshot(),
            luna: lunaScreen)
        appSwitcher = switcher
        view.addSubview(switcher)
        switcher.playToLuna { [weak self] in
            guard let self, generation == self.sequenceGeneration else { return }
            self.afterDelay(
                OnboardingShortcutRunTiming.savedAppHoldDuration,
                generation: generation
            ) {
                self.appSwitcher?.playToMessages { [weak self] in
                    guard let self,
                          generation == self.sequenceGeneration
                    else { return }
                    self.appSwitcher?.removeFromSuperview()
                    self.appSwitcher = nil
                    self.finishShortcutRunSequence(generation: generation)
                }
            }
        }
    }

    private func finishShortcutRunSequence(generation: Int) {
        setURLHighlighted(false)
        setURLBubbleEmphasized(false)
        afterDelay(
            OnboardingShortcutRunTiming.followUpMessageDelay,
            generation: generation
        ) {
            self.revealNextRow()
            self.shortcutPill.beginGlowPulse()
            self.afterDelay(
                OnboardingShortcutRunTiming.followUpInterMessageDelay,
                generation: generation
            ) {
                self.shortcutBubble?.setShowsTail(false)
                self.revealNextRow()
                self.settingsPill.beginGlowPulse()
                self.isShowingSetupMessages = true
                self.onShortcutSetupMessagesShown?()
            }
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
        appSwitcher?.removeFromSuperview()
        appSwitcher = nil
        urlBubble.layer.removeAllAnimations()
        urlBubble.transform = .identity
    }

    private func renderConversationSnapshot() -> UIImage {
        UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: false)
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
            direction: .outgoing,
            showsTail: true,
            text: "Yeah just install this shortcut",
            pill: shortcutPill,
            accessibilityIdentifier: "onboarding.messages.shortcutSetup")
        self.shortcutBubble = shortcutBubble

        messageRows = [
            OnboardingMessageRow(
                direction: .outgoing,
                bubble: OnboardingMessageTextBubble(
                    direction: .outgoing,
                    showsTail: true,
                    text: "You can press the Action Button and Luna saves "
                        + "any link on screen",
                    accessibilityIdentifier: "onboarding.messages.firstOutgoing")),
            OnboardingMessageRow(
                direction: .incoming,
                bubble: OnboardingMessageTextBubble(
                    direction: .incoming,
                    showsTail: false,
                    text: "Woah! Like this?",
                    accessibilityIdentifier: "onboarding.messages.secondIncoming")),
            OnboardingMessageRow(direction: .incoming, bubble: urlBubble),
            OnboardingMessageRow(direction: .outgoing, bubble: shortcutBubble),
            OnboardingMessageRow(
                direction: .outgoing,
                bubble: OnboardingMessagePillBubble(
                    direction: .outgoing,
                    showsTail: true,
                    text: "And change your action button to that shortcut in",
                    pill: settingsPill,
                    accessibilityIdentifier: "onboarding.messages.settingsSetup")),
        ]
        for row in messageRows {
            row.alpha = 0
            conversationStack.addArrangedSubview(row)
        }

        conversationStack.translatesAutoresizingMaskIntoConstraints = false
        conversationStack.axis = .vertical
        conversationStack.spacing = 8
        // Consecutive same-sender bubbles group tightly, like iMessage.
        conversationStack.setCustomSpacing(2, after: messageRows[1])
        conversationStack.setCustomSpacing(2, after: messageRows[3])
        conversationStack.accessibilityIdentifier = "onboarding.messages.conversation"
        // Unrevealed rows wait below the resting thread; keep them (and each
        // arrival's rise) underneath the opaque composer.
        view.insertSubview(conversationStack, belowSubview: composer)

        NSLayoutConstraint.activate([
            conversationStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            conversationStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
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

        let mutedText = OnboardingMessageGradientBlock(width: 76)
        mutedText.translatesAutoresizingMaskIntoConstraints = false
        field.addSubview(mutedText)

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
            composer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            composer.heightAnchor.constraint(equalToConstant: 54),
            plus.leadingAnchor.constraint(equalTo: composer.leadingAnchor, constant: 12),
            plus.centerYAnchor.constraint(equalTo: composer.centerYAnchor),
            plus.widthAnchor.constraint(equalToConstant: 30),
            plus.heightAnchor.constraint(equalToConstant: 30),
            field.leadingAnchor.constraint(equalTo: plus.trailingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: composer.trailingAnchor, constant: -12),
            field.centerYAnchor.constraint(equalTo: composer.centerYAnchor),
            field.heightAnchor.constraint(equalToConstant: 38),
            mutedText.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: 13),
            mutedText.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            mutedText.heightAnchor.constraint(equalToConstant: 10),
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

    let direction: OnboardingMessageDirection
    private let tail = CAShapeLayer()
    private var showsTail: Bool

    init(direction: OnboardingMessageDirection, showsTail: Bool) {
        self.direction = direction
        self.showsTail = showsTail
        super.init(frame: .zero)
        clipsToBounds = false
        layer.cornerRadius = 18
        layer.cornerCurve = .continuous
        let fill = direction == .incoming ? Self.incomingGray : Self.outgoingBlue
        backgroundColor = fill
        tail.fillColor = fill.cgColor
        layer.addSublayer(tail)
        widthAnchor.constraint(lessThanOrEqualToConstant: 292).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func setShowsTail(_ shows: Bool) {
        guard shows != showsTail else { return }
        showsTail = shows
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        tail.frame = bounds
        tail.path = showsTail ? tailPath().cgPath : nil
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
        label.font = .systemFont(ofSize: 17)
        label.textColor = direction == .incoming
            ? UIColor(white: 0.08, alpha: 1)
            : .white
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
                .font: UIFont.systemFont(ofSize: 16),
                .foregroundColor: highlighted
                    ? UIColor(white: 0.08, alpha: 1)
                    : UIColor.systemBlue,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ])
    }
}

/// An outgoing bubble whose sentence hands off to an interactive pill.
private final class OnboardingMessagePillBubble: OnboardingMessageBubble {
    init(
        direction: OnboardingMessageDirection,
        showsTail: Bool,
        text: String,
        pill: OnboardingMessagePillButton,
        accessibilityIdentifier: String
    ) {
        super.init(direction: direction, showsTail: showsTail)
        self.accessibilityIdentifier = accessibilityIdentifier

        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 17)
        label.textColor = direction == .incoming
            ? UIColor(white: 0.08, alpha: 1)
            : .white
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.accessibilityLabel = text

        let pillRow = UIStackView(arrangedSubviews: [pill, UIView()])
        pillRow.axis = .horizontal
        pillRow.alignment = .center

        let content = UIStackView(arrangedSubviews: [label, pillRow])
        content.axis = .vertical
        content.alignment = .fill
        content.spacing = 7
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -13),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }
}

/// The tappable in-bubble chip: the Shortcuts-purple "Luna" shortcut install
/// and the grey system-Settings link. Glows and pulses until tapped.
final class OnboardingMessagePillButton: UIControl {
    enum Style {
        case shortcuts
        case settings
    }

    var onActivate: (() -> Void)?
    private(set) var wasActivated = false
    private let glowColor: UIColor
    private var isPulsing = false

    private static let shortcutsPurple = UIColor(
        red: 0.46, green: 0.29, blue: 0.96, alpha: 1)

    init(style: Style) {
        let icon: UIImage?
        let title: String
        let fill: UIColor
        let titleColor: UIColor
        switch style {
        case .shortcuts:
            icon = OnboardingSystemIcons.shortcuts
            title = "Luna"
            // White lifted faintly toward the Shortcuts app's violet.
            fill = UIColor(red: 0.93, green: 0.91, blue: 1.0, alpha: 1)
            titleColor = UIColor(red: 0.32, green: 0.18, blue: 0.78, alpha: 1)
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
            glowColor = UIColor(white: 0.55, alpha: 1)
            super.init(frame: .zero)
            accessibilityIdentifier = "onboarding.messages.settingsPill"
            accessibilityLabel = "Open Settings"
        }
        accessibilityTraits = .button
        backgroundColor = fill
        layer.cornerCurve = .continuous
        layer.shadowColor = glowColor.cgColor
        layer.shadowOffset = .zero
        layer.shadowOpacity = 0
        layer.shadowRadius = 6

        let iconView = UIImageView(image: icon)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentMode = .scaleAspectFit
        if style == .settings {
            iconView.tintColor = UIColor(white: 0.42, alpha: 1)
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
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

    /// The pill demands its tap: a slow shadow-and-scale breath that runs
    /// until the user follows it.
    func beginGlowPulse() {
        guard !isPulsing, !wasActivated else { return }
        isPulsing = true

        if UIAccessibility.isReduceMotionEnabled {
            layer.shadowOpacity = 0.6
            layer.shadowRadius = 8
            return
        }

        let opacity = CABasicAnimation(keyPath: "shadowOpacity")
        opacity.fromValue = 0.25
        opacity.toValue = 0.9
        let radius = CABasicAnimation(keyPath: "shadowRadius")
        radius.fromValue = 5
        radius.toValue = 12
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.0
        scale.toValue = 1.05
        let pulse = CAAnimationGroup()
        pulse.animations = [opacity, radius, scale]
        pulse.duration = 0.85
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.shadowOpacity = 0.25
        layer.add(pulse, forKey: "onboarding.pill.pulse")
    }

    private func stopGlowPulse() {
        isPulsing = false
        layer.removeAnimation(forKey: "onboarding.pill.pulse")
        layer.shadowOpacity = 0
    }

    func reset() {
        wasActivated = false
        stopGlowPulse()
    }

    @objc private func activated() {
        wasActivated = true
        stopGlowPulse()
        onActivate?()
    }
}

private final class OnboardingMessageGradientBlock: UIView {
    private let gradient = CAGradientLayer()

    init(width: CGFloat) {
        super.init(frame: .zero)
        widthAnchor.constraint(equalToConstant: width).isActive = true
        gradient.colors = [
            UIColor(white: 0.70, alpha: 0.78).cgColor,
            UIColor(white: 0.88, alpha: 0.88).cgColor,
            UIColor(white: 0.74, alpha: 0.82).cgColor,
        ]
        gradient.locations = [0, 0.5, 1]
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        layer.addSublayer(gradient)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = bounds
        gradient.cornerRadius = 4
    }
}

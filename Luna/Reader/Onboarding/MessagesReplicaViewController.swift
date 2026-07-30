//
//  MessagesReplicaViewController.swift
//  Luna
//

import UIKit

enum OnboardingMessagesReplicaTiming {
    static let firstMessageDelay: TimeInterval = 0.18
    static let interMessageDelay: TimeInterval = 0.62
    static let messageDuration: TimeInterval = 0.42
    static let saveDelayAfterLastMessage: TimeInterval = 0.42

    static var actionButtonReplayDelay: TimeInterval {
        firstMessageDelay
            + interMessageDelay * 2
            + messageDuration
            + saveDelayAfterLastMessage
    }
}

/// A noninteractive iMessage conversation used as the second source in the
/// onboarding save loop. Its three readable messages arrive one by one before
/// the shared Action Button save effect begins.
@MainActor
final class MessagesReplicaViewController: OnboardingSaveSourceViewController {
    private let senderNameLabel = UILabel()
    private let urlBubble = OnboardingMessageURLBubble()
    private var currentURLString: String
    private var messageRows: [UIView] = []
    private var presentationGeneration = 0

    override var preferredStatusBarStyle: UIStatusBarStyle { .darkContent }
    override var sharedURLString: String { currentURLString }
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
        configureHeader()
        configureConversation()
        configureComposer()
        urlBubble.setURL(currentURLString)
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
        let generation = presentationGeneration

        for row in messageRows {
            row.layer.removeAllAnimations()
            row.alpha = 0
            row.transform = CGAffineTransform(
                translationX: 0, y: 14).scaledBy(x: 0.94, y: 0.94)
        }

        for (index, row) in messageRows.enumerated() {
            let delay = OnboardingMessagesReplicaTiming.firstMessageDelay
                + Double(index) * OnboardingMessagesReplicaTiming.interMessageDelay
            DispatchQueue.main.asyncAfter(
                deadline: .now() + OnboardingAnimationClock.delay(delay)
            ) { [weak self, weak row] in
                guard let self, let row,
                      generation == self.presentationGeneration
                else { return }
                UIView.animate(
                    withDuration: UIAccessibility.isReduceMotionEnabled
                        ? 0.18 : OnboardingMessagesReplicaTiming.messageDuration,
                    delay: 0,
                    usingSpringWithDamping: 0.7,
                    initialSpringVelocity: 0.45,
                    options: [.curveEaseOut, .beginFromCurrentState]
                ) {
                    row.alpha = 1
                    row.transform = .identity
                }
            }
        }
    }

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

    private func configureConversation() {
        messageRows = [
            OnboardingMessageRow(
                direction: .outgoing,
                bubble: OnboardingMessageTextBubble(
                    direction: .outgoing,
                    text: "You can save any link on your screen, too",
                    accessibilityIdentifier: "onboarding.messages.firstOutgoing")),
            OnboardingMessageRow(
                direction: .incoming,
                bubble: OnboardingMessageTextBubble(
                    direction: .incoming,
                    text: "Really? Like this?",
                    accessibilityIdentifier: "onboarding.messages.secondIncoming")),
            OnboardingMessageRow(direction: .incoming, bubble: urlBubble),
        ]
        let stack = UIStackView(arrangedSubviews: messageRows)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 10
        stack.accessibilityIdentifier = "onboarding.messages.conversation"
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: 34),
        ])
    }

    private func configureComposer() {
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
    }
}

private enum OnboardingMessageDirection {
    case incoming
    case outgoing
}

private final class OnboardingMessageRow: UIView {
    init(direction: OnboardingMessageDirection, bubble: UIView) {
        super.init(frame: .zero)
        bubble.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bubble)

        let edgeConstraint: NSLayoutConstraint
        switch direction {
        case .incoming:
            edgeConstraint = bubble.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: 14)
        case .outgoing:
            edgeConstraint = bubble.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -14)
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

private final class OnboardingMessageTextBubble: UIView {
    init(
        direction: OnboardingMessageDirection,
        text: String,
        accessibilityIdentifier: String
    ) {
        super.init(frame: .zero)
        self.accessibilityIdentifier = accessibilityIdentifier
        backgroundColor = direction == .incoming
            ? UIColor(white: 0.91, alpha: 1)
            : .systemBlue
        layer.cornerRadius = 18
        layer.cornerCurve = .continuous

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
            widthAnchor.constraint(lessThanOrEqualToConstant: 292),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -13),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
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

private final class OnboardingMessageURLBubble: UIView {
    private let highlight = OnboardingURLHighlightView()
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "onboarding.messages.latestIncoming"
        backgroundColor = UIColor(white: 0.91, alpha: 1)
        layer.cornerRadius = 18
        layer.cornerCurve = .continuous

        highlight.translatesAutoresizingMaskIntoConstraints = false
        addSubview(highlight)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 16)
        label.textColor = .systemBlue
        label.numberOfLines = 3
        label.lineBreakMode = .byCharWrapping
        label.accessibilityIdentifier = "onboarding.messages.latestURL"
        addSubview(label)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 280),
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

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func setURL(_ urlString: String) {
        label.text = urlString
        accessibilityValue = urlString
    }

    func setURLHighlighted(_ highlighted: Bool) {
        highlight.setHighlighted(highlighted)
        label.textColor = highlighted
            ? UIColor(white: 0.08, alpha: 1)
            : .systemBlue
    }

    var isURLHighlighted: Bool { highlight.isHighlighted }
}

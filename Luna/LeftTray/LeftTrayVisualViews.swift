//
//  LeftTrayVisualViews.swift
//  Luna
//

import LunaDesignSystem
import LunaModels
import LunaReadingListUI
import UIKit

/// Compact, object-shaped setup affordances for the left tray. These are not
/// miniature cards: each one keeps the silhouette of the thing it represents.
final class LeftTraySetupVisualView: UIView {
    private(set) var messageBubble: OnboardingMessageTextBubble?

    func configure(
        kind: LeftTraySetupKind,
        emailNeedsAttention: Bool,
        tint: UIColor
    ) {
        subviews.forEach { $0.removeFromSuperview() }
        messageBubble = nil
        layer.removeAllAnimations()
        accessibilityIdentifier = "leftTray.setup.\(kind.accessibilityName)"

        switch kind {
        case .shortcut:
            let bubble = OnboardingMessageTextBubble(
                direction: .incoming,
                showsTail: true,
                text: L10n.string("Show me one click save"),
                accessibilityIdentifier: "leftTray.setup.shortcutBubble")
            bubble.translatesAutoresizingMaskIntoConstraints = false
            bubble.isUserInteractionEnabled = false
            addSubview(bubble)
            NSLayoutConstraint.activate([
                bubble.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
                bubble.topAnchor.constraint(equalTo: topAnchor, constant: 6),
                bubble.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
                bubble.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            ])
            messageBubble = bubble
            accessibilityLabel = L10n.string("Show me one click save")
            accessibilityHint = L10n.string("Opens the one click save walkthrough")

        case .email:
            let envelope = UIImageView(image: UIImage(
                systemName: "envelope.fill",
                withConfiguration: UIImage.SymbolConfiguration(
                    pointSize: 58, weight: .medium)))
            envelope.translatesAutoresizingMaskIntoConstraints = false
            envelope.contentMode = .scaleAspectFit
            envelope.tintColor = UIColor.white.withAlphaComponent(0.94)
            envelope.accessibilityIdentifier = "leftTray.setup.emailEnvelope"
            addSubview(envelope)

            let dot = UIView()
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.backgroundColor = .systemRed
            dot.layer.cornerRadius = 8
            dot.accessibilityIdentifier = "leftTray.setup.emailAttention"
            addSubview(dot)
            NSLayoutConstraint.activate([
                envelope.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
                envelope.centerYAnchor.constraint(equalTo: centerYAnchor),
                envelope.widthAnchor.constraint(equalToConstant: 72),
                envelope.heightAnchor.constraint(equalToConstant: 58),
                dot.widthAnchor.constraint(equalToConstant: 16),
                dot.heightAnchor.constraint(equalToConstant: 16),
                dot.centerXAnchor.constraint(equalTo: envelope.trailingAnchor, constant: -3),
                dot.centerYAnchor.constraint(equalTo: envelope.topAnchor, constant: 5),
            ])
            dot.beginAttentionPulse(color: .systemRed)
            accessibilityLabel = emailNeedsAttention
                ? L10n.string("Email sign-in needs attention")
                : L10n.string("Connect email")
            accessibilityHint = L10n.string("Opens email sign-in")

        case .safari:
            let palette = UIImage.SymbolConfiguration(paletteColors: [
                .systemRed, .white, .systemBlue,
            ])
            let pointSize = UIImage.SymbolConfiguration(pointSize: 64, weight: .regular)
            let safari = UIImageView(image: UIImage(
                systemName: "safari.fill",
                withConfiguration: pointSize.applying(palette)))
            safari.translatesAutoresizingMaskIntoConstraints = false
            safari.contentMode = .scaleAspectFit
            safari.accessibilityIdentifier = "leftTray.setup.safariCompass"
            addSubview(safari)

            let extensionPiece = UIImageView(image: UIImage(
                systemName: "puzzlepiece.extension.fill",
                withConfiguration: UIImage.SymbolConfiguration(
                    pointSize: 26, weight: .semibold)))
            extensionPiece.translatesAutoresizingMaskIntoConstraints = false
            extensionPiece.contentMode = .scaleAspectFit
            extensionPiece.tintColor = tint
            extensionPiece.accessibilityIdentifier = "leftTray.setup.safariExtension"
            addSubview(extensionPiece)
            NSLayoutConstraint.activate([
                safari.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
                safari.centerYAnchor.constraint(equalTo: centerYAnchor),
                safari.widthAnchor.constraint(equalToConstant: 64),
                safari.heightAnchor.constraint(equalToConstant: 64),
                extensionPiece.widthAnchor.constraint(equalToConstant: 29),
                extensionPiece.heightAnchor.constraint(equalToConstant: 29),
                extensionPiece.centerXAnchor.constraint(equalTo: safari.trailingAnchor, constant: -2),
                extensionPiece.centerYAnchor.constraint(equalTo: safari.topAnchor, constant: 5),
            ])
            extensionPiece.beginAttentionPulse(color: tint)
            accessibilityLabel = L10n.string("Set up the Safari extension")
            accessibilityHint = L10n.string("Opens the Safari extension walkthrough")
        }

        isAccessibilityElement = true
        accessibilityTraits = .button
    }
}

/// A small physical clipboard. Its empty state is deliberately only a dotted
/// attachment outline; once a URL is available, a paper preview sits under the
/// polished clip and becomes the tray's save affordance.
final class LeftTrayClipboardView: UIView {
    enum State {
        case empty
        case pasteAvailable
        case loading
        case preview(RecentURLPreview)
        case invalid
    }

    private let board = UIView()
    private let emptyAttachment = UIView()
    private let emptyOutline = CAShapeLayer()
    private let paper = UIView()
    private let previewImage = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let urlBar = UIView()
    private let urlBarIcon = UIImageView()
    private let statusSymbol = UIImageView()
    private let clip = UIView()
    private let clipHighlight = UIView()
    private let spinner = UIActivityIndicatorView(style: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        accessibilityIdentifier = "leftTray.clipboard"

        board.translatesAutoresizingMaskIntoConstraints = false
        board.backgroundColor = UIColor(white: 0.16, alpha: 0.98)
        board.layer.cornerRadius = 19
        board.layer.cornerCurve = .continuous
        board.layer.borderWidth = 0.75
        board.layer.borderColor = UIColor.white.withAlphaComponent(0.14).cgColor
        board.layer.shadowColor = UIColor.black.cgColor
        board.layer.shadowOpacity = 0.30
        board.layer.shadowRadius = 14
        board.layer.shadowOffset = CGSize(width: 0, height: 8)
        board.accessibilityIdentifier = "leftTray.clipboard.board"
        addSubview(board)

        emptyAttachment.translatesAutoresizingMaskIntoConstraints = false
        emptyAttachment.backgroundColor = UIColor.white.withAlphaComponent(0.025)
        emptyAttachment.layer.cornerRadius = 12
        emptyAttachment.layer.cornerCurve = .continuous
        emptyOutline.fillColor = UIColor.clear.cgColor
        emptyOutline.strokeColor = UIColor.white.withAlphaComponent(0.42).cgColor
        emptyOutline.lineWidth = 1.5
        emptyOutline.lineCap = .round
        emptyOutline.lineDashPattern = [1, 6]
        emptyAttachment.layer.addSublayer(emptyOutline)
        emptyAttachment.accessibilityIdentifier = "leftTray.clipboard.emptyAttachment"
        board.addSubview(emptyAttachment)

        paper.translatesAutoresizingMaskIntoConstraints = false
        paper.backgroundColor = UIColor(white: 0.97, alpha: 1)
        paper.layer.cornerRadius = 12
        paper.layer.cornerCurve = .continuous
        paper.layer.shadowColor = UIColor.black.cgColor
        paper.layer.shadowOpacity = 0.22
        paper.layer.shadowRadius = 5
        paper.layer.shadowOffset = CGSize(width: 0, height: 3)
        paper.accessibilityIdentifier = "leftTray.clipboard.paper"
        board.addSubview(paper)

        previewImage.translatesAutoresizingMaskIntoConstraints = false
        previewImage.contentMode = .scaleAspectFill
        previewImage.clipsToBounds = true
        previewImage.layer.cornerRadius = 8
        previewImage.layer.cornerCurve = .continuous
        previewImage.tintColor = .systemBlue
        previewImage.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.10)
        paper.addSubview(previewImage)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = UIColor(white: 0.12, alpha: 1)
        titleLabel.numberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail
        paper.addSubview(titleLabel)

        urlBar.translatesAutoresizingMaskIntoConstraints = false
        urlBar.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.08)
        urlBar.layer.cornerRadius = 7
        urlBar.layer.cornerCurve = .continuous
        paper.addSubview(urlBar)

        urlBarIcon.translatesAutoresizingMaskIntoConstraints = false
        urlBarIcon.image = UIImage(
            systemName: "link",
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: 9.5, weight: .semibold))
        urlBarIcon.tintColor = .systemBlue
        urlBarIcon.contentMode = .scaleAspectFit
        urlBar.addSubview(urlBarIcon)

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
        detailLabel.textColor = UIColor(white: 0.42, alpha: 1)
        detailLabel.numberOfLines = 1
        detailLabel.lineBreakMode = .byTruncatingMiddle
        urlBar.addSubview(detailLabel)

        statusSymbol.translatesAutoresizingMaskIntoConstraints = false
        statusSymbol.contentMode = .scaleAspectFit
        statusSymbol.tintColor = .systemBlue
        paper.addSubview(statusSymbol)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.color = .systemBlue
        spinner.hidesWhenStopped = true
        paper.addSubview(spinner)

        clip.translatesAutoresizingMaskIntoConstraints = false
        clip.backgroundColor = UIColor(white: 0.52, alpha: 1)
        clip.layer.cornerRadius = 8
        clip.layer.cornerCurve = .continuous
        clip.layer.borderWidth = 0.75
        clip.layer.borderColor = UIColor.white.withAlphaComponent(0.34).cgColor
        clip.layer.shadowColor = UIColor.black.cgColor
        clip.layer.shadowOpacity = 0.34
        clip.layer.shadowRadius = 4
        clip.layer.shadowOffset = CGSize(width: 0, height: 2)
        board.addSubview(clip)

        clipHighlight.translatesAutoresizingMaskIntoConstraints = false
        clipHighlight.backgroundColor = UIColor.white.withAlphaComponent(0.20)
        clipHighlight.layer.cornerRadius = 1
        clip.addSubview(clipHighlight)

        NSLayoutConstraint.activate([
            board.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            board.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            board.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            board.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),

            emptyAttachment.topAnchor.constraint(equalTo: board.topAnchor, constant: 22),
            emptyAttachment.leadingAnchor.constraint(equalTo: board.leadingAnchor, constant: 11),
            emptyAttachment.trailingAnchor.constraint(equalTo: board.trailingAnchor, constant: -11),
            emptyAttachment.bottomAnchor.constraint(equalTo: board.bottomAnchor, constant: -11),

            paper.topAnchor.constraint(equalTo: board.topAnchor, constant: 17),
            paper.leadingAnchor.constraint(equalTo: board.leadingAnchor, constant: 10),
            paper.trailingAnchor.constraint(equalTo: board.trailingAnchor, constant: -10),
            paper.bottomAnchor.constraint(equalTo: board.bottomAnchor, constant: -10),

            previewImage.leadingAnchor.constraint(equalTo: paper.leadingAnchor, constant: 10),
            previewImage.topAnchor.constraint(equalTo: paper.topAnchor, constant: 18),
            previewImage.widthAnchor.constraint(equalToConstant: 42),
            previewImage.heightAnchor.constraint(equalToConstant: 42),
            titleLabel.leadingAnchor.constraint(equalTo: previewImage.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: paper.trailingAnchor, constant: -8),
            titleLabel.topAnchor.constraint(equalTo: previewImage.topAnchor),
            titleLabel.bottomAnchor.constraint(lessThanOrEqualTo: urlBar.topAnchor, constant: -5),
            urlBar.leadingAnchor.constraint(equalTo: paper.leadingAnchor, constant: 9),
            urlBar.trailingAnchor.constraint(equalTo: paper.trailingAnchor, constant: -9),
            urlBar.bottomAnchor.constraint(equalTo: paper.bottomAnchor, constant: -8),
            urlBar.heightAnchor.constraint(equalToConstant: 22),
            urlBarIcon.leadingAnchor.constraint(equalTo: urlBar.leadingAnchor, constant: 7),
            urlBarIcon.centerYAnchor.constraint(equalTo: urlBar.centerYAnchor),
            urlBarIcon.widthAnchor.constraint(equalToConstant: 12),
            urlBarIcon.heightAnchor.constraint(equalToConstant: 12),
            detailLabel.leadingAnchor.constraint(equalTo: urlBarIcon.trailingAnchor, constant: 5),
            detailLabel.trailingAnchor.constraint(equalTo: urlBar.trailingAnchor, constant: -7),
            detailLabel.centerYAnchor.constraint(equalTo: urlBar.centerYAnchor),
            statusSymbol.centerXAnchor.constraint(equalTo: previewImage.centerXAnchor),
            statusSymbol.centerYAnchor.constraint(equalTo: previewImage.centerYAnchor),
            statusSymbol.widthAnchor.constraint(equalToConstant: 24),
            statusSymbol.heightAnchor.constraint(equalToConstant: 24),
            spinner.centerXAnchor.constraint(equalTo: previewImage.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: previewImage.centerYAnchor),

            clip.topAnchor.constraint(equalTo: board.topAnchor, constant: -1),
            clip.centerXAnchor.constraint(equalTo: board.centerXAnchor),
            clip.widthAnchor.constraint(equalToConstant: 66),
            clip.heightAnchor.constraint(equalToConstant: 20),
            clipHighlight.topAnchor.constraint(equalTo: clip.topAnchor, constant: 3),
            clipHighlight.leadingAnchor.constraint(equalTo: clip.leadingAnchor, constant: 9),
            clipHighlight.trailingAnchor.constraint(equalTo: clip.trailingAnchor, constant: -9),
            clipHighlight.heightAnchor.constraint(equalToConstant: 2),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        emptyOutline.frame = emptyAttachment.bounds
        emptyOutline.path = UIBezierPath(
            roundedRect: emptyAttachment.bounds.insetBy(dx: 1, dy: 1),
            cornerRadius: 11).cgPath
    }

    func configure(_ state: State) {
        spinner.stopAnimating()
        statusSymbol.tintColor = .systemBlue
        emptyAttachment.isHidden = true
        paper.isHidden = false
        previewImage.image = nil
        previewImage.isHidden = false
        statusSymbol.isHidden = false
        titleLabel.text = nil
        detailLabel.text = nil

        switch state {
        case .empty:
            emptyAttachment.isHidden = false
            paper.isHidden = true
            accessibilityLabel = L10n.string("Clipboard, no URL")

        case .pasteAvailable:
            statusSymbol.image = UIImage(systemName: "link")
            titleLabel.text = L10n.string("Paste URL")
            detailLabel.text = L10n.string("From Clipboard")
            accessibilityLabel = L10n.string("Paste URL from Clipboard")

        case .loading:
            statusSymbol.isHidden = true
            spinner.startAnimating()
            titleLabel.text = L10n.string("Checking URL")
            detailLabel.text = L10n.string("From Clipboard")
            accessibilityLabel = L10n.string("Checking Clipboard URL")

        case .preview(let preview):
            if let image = preview.image {
                previewImage.image = image
                statusSymbol.isHidden = true
            } else {
                statusSymbol.image = UIImage(systemName: preview.symbolName)
            }
            titleLabel.text = preview.title
            detailLabel.text = URL(string: preview.urlString)?.host(percentEncoded: false)
                ?? preview.subtitle
                ?? preview.urlString
            accessibilityLabel = [preview.title, preview.urlString]
                .joined(separator: ", ")

        case .invalid:
            statusSymbol.image = UIImage(systemName: "exclamationmark.triangle.fill")
            statusSymbol.tintColor = .systemRed
            titleLabel.text = L10n.string("Not a web link")
            detailLabel.text = L10n.string("Try copying a URL")
            accessibilityLabel = L10n.string("Clipboard does not contain a valid URL")
        }
        isAccessibilityElement = true
    }
}

private extension LeftTraySetupKind {
    var accessibilityName: String {
        switch self {
        case .safari: return "safari"
        case .shortcut: return "shortcut"
        case .email: return "email"
        }
    }
}

private extension RecentURLPreview {
    var symbolName: String {
        switch kind {
        case .article: return "doc.text.fill"
        case .media: return "play.rectangle.fill"
        case .product: return "bag.fill"
        }
    }
}

private extension UIView {
    func beginAttentionPulse(color: UIColor) {
        layer.shadowColor = color.cgColor
        layer.shadowOffset = .zero
        layer.shadowRadius = 11
        layer.shadowOpacity = 0.85

        let glow = CABasicAnimation(keyPath: "shadowOpacity")
        glow.fromValue = 0.34
        glow.toValue = 1.0
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.92
        scale.toValue = 1.08
        let pulse = CAAnimationGroup()
        pulse.animations = [glow, scale]
        pulse.duration = 1.35
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(pulse, forKey: "leftTrayAttentionPulse")
    }
}

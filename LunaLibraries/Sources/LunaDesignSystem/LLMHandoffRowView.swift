//
//  LLMHandoffRowView.swift
//  LunaDesignSystem
//

import LunaModels
import UIKit

/// What a hand-off row's host does when the user picks a provider.
@MainActor
public protocol LLMHandoffRowDelegate: AnyObject {
    func row(_ row: LLMHandoffRowView, didChoose provider: LLMProvider)
}

/// The chat hand-off, as one row: a caption, a glass button per provider, and
/// a hint line under them (`claudedocs/llm-handoff.md`).
///
/// The same row is the failed card's chin, the Downloader's no-media chin and
/// the extension failure card's, so a user who meets the offer twice meets the
/// same object. The Claude button's long-press menu picks between ordinary
/// chat and Claude Code, and remembers the answer.
public final class LLMHandoffRowView: UIView {

    public weak var delegate: (any LLMHandoffRowDelegate)?

    private let captionLabel = UILabel()
    private let hintLabel = UILabel()
    private let buttonRow = UIStackView()
    private var buttons: [LLMProvider: UIButton] = [:]

    /// - Parameter caption: the line above the buttons. The recovery surfaces
    ///   keep the default; a plugin screen says what it is asking for instead.
    public init(caption: String = L10n.string("LLMHandoff_rowCaption")) {
        super.init(frame: .zero)
        build(caption: caption)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The line under the buttons — what the user does with the reply — or nil
    /// to take it away.
    public func setHint(_ text: String?) {
        hintLabel.text = text
        hintLabel.isHidden = text == nil
    }

    /// The hint the recovery surfaces show while a reply is outstanding: which
    /// file extension to look for in the chat.
    public static func waitingHint(for app: LunaApp = .current) -> String {
        L10n.string("LLMHandoff_waitingHint", app.fileExtension ?? "luna")
    }

    /// Dims the row while something else owns the card — an automatic rescue
    /// still running, or a file being applied.
    public func setEnabled(_ isEnabled: Bool) {
        for button in buttons.values {
            button.isEnabled = isEnabled
            button.alpha = isEnabled ? 1 : 0.5
        }
    }

    #if DEBUG
    /// The hint line, so a card's test can assert what the row says without a
    /// tap. DEBUG-only.
    public var hintForTesting: String? { hintLabel.isHidden ? nil : hintLabel.text }
    #endif

    // MARK: - Hierarchy

    private func build(caption: String) {
        captionLabel.text = caption
        captionLabel.font = .preferredFont(forTextStyle: .caption1)
        captionLabel.adjustsFontForContentSizeCategory = true
        captionLabel.textColor = LunaColors.secondaryText
        captionLabel.textAlignment = .center

        buttonRow.axis = .horizontal
        buttonRow.distribution = .fillEqually
        buttonRow.spacing = 8
        for provider in LLMProvider.allCases {
            let button = makeButton(for: provider)
            buttons[provider] = button
            buttonRow.addArrangedSubview(button)
        }

        hintLabel.font = .preferredFont(forTextStyle: .caption2)
        hintLabel.adjustsFontForContentSizeCategory = true
        hintLabel.textColor = LunaColors.secondaryText
        hintLabel.textAlignment = .center
        hintLabel.numberOfLines = 2
        hintLabel.isHidden = true

        let column = UIStackView(arrangedSubviews: [captionLabel, buttonRow, hintLabel])
        column.axis = .vertical
        column.spacing = 6
        column.alignment = .fill
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    private func makeButton(for provider: LLMProvider) -> UIButton {
        let button = UIButton(type: .system)
        var configuration = GlassStyle.actionButtonConfiguration(
            title: provider.displayName, symbol: "sparkles", prominent: true, compact: true)
        configuration.image = LLMProviderGlyph.image(for: provider)
        button.configuration = configuration
        button.contentHorizontalAlignment = .center
        button.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.delegate?.row(self, didChoose: provider)
        }, for: .touchUpInside)
        if provider == .claude { attachTargetMenu(to: button) }
        return button
    }

    /// The long press that picks Claude Code. It is a menu rather than a
    /// second button because the choice is made once and then remembered.
    private func attachTargetMenu(to button: UIButton) {
        button.addInteraction(UIContextMenuInteraction(delegate: self))
    }
}

// MARK: - The Claude target menu

extension LLMHandoffRowView: UIContextMenuInteractionDelegate {

    public func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            let current = LLMProviderPreferences.claudeTarget
            let actions = LLMClaudeTarget.allCases.map { target in
                let action = UIAction(title: target.displayName) { _ in
                    LLMProviderPreferences.claudeTarget = target
                }
                action.state = target == current ? .on : .off
                return action
            }
            return UIMenu(children: actions)
        }
    }
}

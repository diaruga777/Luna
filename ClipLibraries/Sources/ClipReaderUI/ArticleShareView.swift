//
//  ArticleShareView.swift
//  Clip
//

import ClipDesignSystem
import UIKit

/// End-of-article share affordance: a separator, a prompt, a Share button, and
/// (when the site has a sharing history) a one-tap "Send to <friend>"
/// suggestion. Shown at the bottom of the scroll reader and revealed at the end
/// of the speed readers. The owning view controller wires the actions.
public final class ArticleShareView: UIView {

    private let onShare: () -> Void
    private let onSendSuggested: () -> Void
    /// Fired when the user picks "Report a bug" from the bug icon's menu (nil → no
    /// bug icon shown). Marks the save's replay user-reported and shares its zip.
    private let onReportBug: (() -> Void)?

    public init(suggestionName: String?, onShare: @escaping () -> Void,
         onSendSuggested: @escaping () -> Void, onReportBug: (() -> Void)? = nil) {
        self.onShare = onShare
        self.onSendSuggested = onSendSuggested
        self.onReportBug = onReportBug
        super.init(frame: .zero)
        build(suggestionName: suggestionName)
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    private func build(suggestionName: String?) {
        let separator = UIView()
        separator.backgroundColor = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true

        let prompt = UILabel()
        prompt.text = "Done reading? Share it."
        prompt.font = .preferredFont(forTextStyle: .subheadline)
        prompt.textColor = .secondaryLabel
        prompt.textAlignment = .center

        var shareConfig = UIButton.Configuration.filled()
        shareConfig.title = "Share"
        shareConfig.image = UIImage.dotMatrixIcon(systemName: "square.and.arrow.up", pointSize: 18)
        shareConfig.imagePadding = 8
        shareConfig.baseBackgroundColor = GlassStyle.readingAccent
        shareConfig.cornerStyle = .large
        let shareButton = UIButton(configuration: shareConfig)
        shareButton.addAction(UIAction { [weak self] _ in self?.onShare() }, for: .touchUpInside)

        // The share row holds the Share button with a small bug icon to its LEFT (a
        // context menu offering "Report a bug" / "Dismiss"; tapping outside dismisses).
        let shareRow: UIView = onReportBug == nil ? shareButton : makeShareRow(shareButton: shareButton)

        let buttons = UIStackView(arrangedSubviews: [shareRow])
        buttons.axis = .vertical
        buttons.spacing = 10
        buttons.alignment = .fill

        if let suggestionName {
            var suggestConfig = UIButton.Configuration.tinted()
            suggestConfig.title = "Send to \(suggestionName)"
            suggestConfig.image = UIImage.dotMatrixIcon(systemName: "person.fill", pointSize: 18)
            suggestConfig.imagePadding = 8
            suggestConfig.baseForegroundColor = GlassStyle.readingAccent
            suggestConfig.baseBackgroundColor = GlassStyle.readingAccent
            suggestConfig.cornerStyle = .large
            let suggestButton = UIButton(configuration: suggestConfig)
            suggestButton.addAction(
                UIAction { [weak self] _ in self?.onSendSuggested() }, for: .touchUpInside)
            buttons.insertArrangedSubview(suggestButton, at: 0)
        }

        let stack = UIStackView(arrangedSubviews: [separator, prompt, buttons])
        stack.axis = .vertical
        stack.spacing = 16
        stack.setCustomSpacing(20, after: separator)
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    /// A horizontal row: a small bug-report icon on the LEFT, then the Share button
    /// filling the rest. The bug button shows a menu ("Report a bug" / "Dismiss").
    private func makeShareRow(shareButton: UIButton) -> UIView {
        let bugButton = UIButton(type: .system)
        bugButton.setImage(
            UIImage.dotMatrixIcon(systemName: "ladybug", pointSize: 18, weight: .regular),
            for: .normal)
        bugButton.tintColor = .secondaryLabel
        bugButton.accessibilityLabel = "Report a bug"
        bugButton.showsMenuAsPrimaryAction = true
        bugButton.menu = UIMenu(children: [
            UIAction(title: "Report a bug", image: UIImage(systemName: "ladybug")) { [weak self] _ in
                self?.onReportBug?()
            },
            UIAction(title: "Dismiss") { _ in },
        ])
        bugButton.setContentHuggingPriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [bugButton, shareButton])
        row.axis = .horizontal
        row.spacing = 12
        row.alignment = .center
        return row
    }
}

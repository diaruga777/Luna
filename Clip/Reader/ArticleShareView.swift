//
//  ArticleShareView.swift
//  Clip
//

import UIKit

/// End-of-article share affordance: a separator, a prompt, a Share button, and
/// (when the site has a sharing history) a one-tap "Send to <friend>"
/// suggestion. Shown at the bottom of the scroll reader and revealed at the end
/// of the speed readers. The owning view controller wires the actions.
final class ArticleShareView: UIView {

    private let onShare: () -> Void
    private let onSendSuggested: () -> Void

    init(suggestionName: String?, onShare: @escaping () -> Void,
         onSendSuggested: @escaping () -> Void) {
        self.onShare = onShare
        self.onSendSuggested = onSendSuggested
        super.init(frame: .zero)
        build(suggestionName: suggestionName)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

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
        shareConfig.image = UIImage(systemName: "square.and.arrow.up")
        shareConfig.imagePadding = 8
        shareConfig.baseBackgroundColor = GlassStyle.readingAccent
        shareConfig.cornerStyle = .large
        let shareButton = UIButton(configuration: shareConfig)
        shareButton.addAction(UIAction { [weak self] _ in self?.onShare() }, for: .touchUpInside)

        let buttons = UIStackView(arrangedSubviews: [shareButton])
        buttons.axis = .vertical
        buttons.spacing = 10
        buttons.alignment = .fill

        if let suggestionName {
            var suggestConfig = UIButton.Configuration.tinted()
            suggestConfig.title = "Send to \(suggestionName)"
            suggestConfig.image = UIImage(systemName: "person.fill")
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
}

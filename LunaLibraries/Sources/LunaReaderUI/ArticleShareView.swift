//
//  ArticleShareView.swift
//  Luna
//

import LunaDesignSystem
import UIKit

/// End-of-article share affordance: a separator, a prompt, and a Share button.
/// Shown at the bottom of the scroll reader and revealed at the end of the speed
/// readers. The owning view controller wires the actions.
public final class ArticleShareView: UIView {

    private let onShare: () -> Void

    public init(onShare: @escaping () -> Void) {
        self.onShare = onShare
        super.init(frame: .zero)
        build()
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        let separator = UIView()
        separator.backgroundColor = LunaColors.separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true

        let prompt = UILabel()
        prompt.text = "Done reading? Share it."
        prompt.font = .preferredFont(forTextStyle: .subheadline)
        prompt.textColor = LunaColors.secondaryText
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

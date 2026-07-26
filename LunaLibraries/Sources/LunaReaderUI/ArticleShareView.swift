//
//  ArticleShareView.swift
//  Luna
//

import LunaDesignSystem
import UIKit
import LunaModels

/// End-of-article share affordance: a separator, a prompt, and a Share button.
/// Shown at the bottom of the scroll reader and revealed at the end of the speed
/// readers. The owning view controller wires the actions.
public final class ArticleShareView: UIView {

    private let shareMenu: (() -> UIMenu?)?
    private let onShare: () -> Void

    /// `shareMenu` non-nil turns the button into a menu button (press-and-slide to
    /// pick an option); nil keeps it a plain tap that runs `onShare`.
    public init(shareMenu: (() -> UIMenu?)? = nil, onShare: @escaping () -> Void) {
        self.shareMenu = shareMenu
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
        prompt.text = L10n.string("Done reading? Share it.")
        prompt.font = .preferredFont(forTextStyle: .subheadline)
        prompt.textColor = LunaColors.secondaryText
        prompt.textAlignment = .center

        var shareConfig = UIButton.Configuration.filled()
        shareConfig.title = L10n.string("Share")
        shareConfig.image = UIImage(systemName: "square.and.arrow.up")
        shareConfig.imagePadding = 8
        shareConfig.baseBackgroundColor = GlassStyle.readingAccent
        shareConfig.cornerStyle = .large
        let shareButton = UIButton(configuration: shareConfig)
        ReaderShareMenu.install(
            on: shareButton,
            providesMenu: shareMenu != nil,
            build: { [weak self] in self?.shareMenu?() },
            fallback: { [weak self] in self?.onShare() })

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

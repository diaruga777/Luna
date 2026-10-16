import UIKit

@MainActor final class PodcastDescriptionView: UIStackView {
    private let text = UILabel()
    private let toggle = UIButton(type: .system)
    private var expanded = false
    var onResize: (() -> Void)?

    init(text value: String) {
        super.init(frame: .zero)
        axis = .vertical; spacing = 4; alignment = .fill
        text.text = value; text.numberOfLines = 4
        text.font = .preferredFont(forTextStyle: .body)
        text.adjustsFontForContentSizeCategory = true; text.textColor = .secondaryLabel
        toggle.setTitle("More", for: .normal)
        toggle.titleLabel?.font = .preferredFont(forTextStyle: .body)
        toggle.titleLabel?.adjustsFontForContentSizeCategory = true
        toggle.contentHorizontalAlignment = .leading
        toggle.accessibilityIdentifier = "podcasts.description.expand"
        toggle.addAction(UIAction { [weak self] _ in self?.toggleExpanded() }, for: .touchUpInside)
        text.isUserInteractionEnabled = true
        text.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(toggleExpanded)))
        addArrangedSubview(text); addArrangedSubview(toggle)
        toggle.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0 else { return }
        // Measure an unlimited copy: sizeThatFits on a four-line label is capped.
        let height = (text.text ?? "").boundingRect(
            with: CGSize(width: bounds.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: text.font as Any], context: nil).height
        let needsToggle = expanded || height > ceil(text.font.lineHeight * 4) + 1
        if toggle.isHidden == needsToggle { toggle.isHidden = !needsToggle; onResize?() }
    }

    @objc private func toggleExpanded() {
        expanded.toggle(); text.numberOfLines = expanded ? 0 : 4
        toggle.setTitle(expanded ? "Less" : "More", for: .normal)
        toggle.accessibilityValue = expanded ? "Expanded" : "Collapsed"
        onResize?()
    }
}

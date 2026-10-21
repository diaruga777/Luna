import UIKit
import LunaVaultBEP

/// Shared by every Luna Mac client's connection settings.
final class LunaMacStorageView: UIView {
    init(volume: LunaMacStorageVolume) {
        super.init(frame: .zero)
        let stack = UIStackView(); stack.axis = .vertical; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16)
        ])
        stack.addArrangedSubview(label(volume.name, style: .headline))
        stack.addArrangedSubview(label("\(bytes(volume.usedBytes)) of \(bytes(volume.totalBytes)) used", style: .subheadline, color: .secondaryLabel))
        stack.addArrangedSubview(StorageBar(segments: [
            (volume.lunaBytes, .systemBlue), (volume.otherBytes, .systemGray), (volume.freeBytes, .quaternaryLabel)
        ]))
        stack.addArrangedSubview(row("Luna Mac", bytes: volume.lunaBytes, color: .systemBlue))
        stack.addArrangedSubview(row("Other Disk Usage", bytes: volume.otherBytes, color: .systemGray))
        stack.addArrangedSubview(row("Free Space", bytes: volume.freeBytes, color: .quaternaryLabel))
        let heading = label("Luna Mac Breakdown", style: .headline)
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(heading)
        stack.addArrangedSubview(StorageBar(segments: LunaMacStorageCategory.allCases.map {
            (volume.categories[$0, default: 0], Self.color($0))
        }))
        for category in LunaMacStorageCategory.allCases {
            stack.addArrangedSubview(row(category.title, bytes: volume.categories[category, default: 0], color: Self.color(category)))
        }
        accessibilityIdentifier = "luna.mac.storage.volume"
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func color(_ category: LunaMacStorageCategory) -> UIColor {
        switch category {
        case .music: return .systemPink
        case .photos: return .systemOrange
        case .videos: return .systemPurple
        case .files: return .systemBlue
        case .code: return .systemIndigo
        case .appData: return .systemTeal
        }
    }
    private func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }
    private func label(_ text: String, style: UIFont.TextStyle, color: UIColor = .label) -> UILabel {
        let label = UILabel(); label.text = text; label.textColor = color
        label.font = .preferredFont(forTextStyle: style); label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        return label
    }
    private func row(_ title: String, bytes count: Int64, color: UIColor) -> UIView {
        let dot = UIView(); dot.backgroundColor = color; dot.layer.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([dot.widthAnchor.constraint(equalToConstant: 8), dot.heightAnchor.constraint(equalToConstant: 8)])
        let name = label(title, style: .subheadline)
        let value = label(bytes(count), style: .subheadline, color: .secondaryLabel)
        value.textAlignment = .right; value.setContentCompressionResistancePriority(.required, for: .horizontal)
        let heading = UIStackView(arrangedSubviews: [dot, name]); heading.spacing = 10; heading.alignment = .center
        let row = UIStackView(arrangedSubviews: [heading, value])
        func updateLayout(_ row: UIStackView) {
            let largeText = row.traitCollection.preferredContentSizeCategory.isAccessibilityCategory
            row.axis = largeText ? .vertical : .horizontal
            row.alignment = largeText ? .fill : .center
            row.spacing = largeText ? 4 : 10
            value.textAlignment = largeText ? .left : .right
        }
        updateLayout(row)
        row.registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (row: UIStackView, _: UITraitCollection) in updateLayout(row) }
        row.isAccessibilityElement = true; row.accessibilityLabel = "\(title), \(bytes(count))"
        return row
    }
}

private final class StorageBar: UIView {
    private let segments: [(Int64, UIColor)]
    init(segments: [(Int64, UIColor)]) {
        self.segments = segments
        super.init(frame: .zero)
        backgroundColor = .tertiarySystemFill
        layer.cornerRadius = 6; clipsToBounds = true
        heightAnchor.constraint(equalToConstant: 12).isActive = true
        isAccessibilityElement = false
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: StorageBar, _: UITraitCollection) in view.setNeedsDisplay() }
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ rect: CGRect) {
        let total = segments.reduce(0.0) { $0 + Double($1.0) }
        guard total > 0 else { return }
        var x: CGFloat = 0
        for (bytes, color) in segments where bytes > 0 {
            let width = bounds.width * CGFloat(Double(bytes) / total)
            color.setFill(); UIRectFill(CGRect(x: x, y: 0, width: width, height: bounds.height))
            x += width
        }
    }
}

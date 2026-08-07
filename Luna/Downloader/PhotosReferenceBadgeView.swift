import UIKit
import LunaModels

/// Compact Photos-style rosette used as a storage-origin badge. It is drawn in
/// code so it remains crisp at both grid and fullscreen sizes.
final class PhotosReferenceBadgeView: UIButton {
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        setImage(Self.icon, for: .normal)
        imageView?.contentMode = .scaleAspectFit
        accessibilityLabel = L10n.string("Downloader_mediaCard_photosBadgeAccessibilityLabel")
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.28
        layer.shadowRadius = 2
        layer.shadowOffset = CGSize(width: 0, height: 1)
        addTarget(self, action: #selector(openPhotos), for: .touchUpInside)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func openPhotos() {
        action()
    }

    private static let icon: UIImage = {
        let size = CGSize(width: 48, height: 48)
        return UIGraphicsImageRenderer(size: size).image { renderer in
            let bounds = CGRect(origin: .zero, size: size)
            UIColor.white.setFill()
            UIBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerRadius: 11).fill()

            let colors: [UIColor] = [
                .systemRed, .systemOrange, .systemYellow, .systemGreen,
                .systemTeal, .systemBlue, .systemPurple, .systemPink,
            ]
            let context = renderer.cgContext
            context.saveGState()
            context.translateBy(x: size.width / 2, y: size.height / 2)
            for (index, color) in colors.enumerated() {
                context.saveGState()
                context.rotate(by: CGFloat(index) * .pi / 4)
                context.setFillColor(color.withAlphaComponent(0.86).cgColor)
                context.fillEllipse(in: CGRect(x: -6.2, y: -20, width: 12.4, height: 22))
                context.restoreGState()
            }
            context.restoreGState()
        }
    }()
}

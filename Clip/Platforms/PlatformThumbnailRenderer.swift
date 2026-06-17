//
//  PlatformThumbnailRenderer.swift
//  Clip
//

import UIKit

/// Builds a 96×54 list thumbnail for a platform item: aspect-fill cached art (if
/// downloaded) with a small platform glyph composited bottom-left, or a flat
/// tile with a centered glyph when there's no art. (Brand-logo assets can
/// replace the SF Symbol glyph later.)
enum PlatformThumbnailRenderer {
    static let size = CGSize(width: 96, height: 54)

    static func thumbnail(
        cachedArtPath: String?, glyphSymbolName: String, logoAssetName: String? = nil
    ) -> UIImage {
        let baseImage = cachedArtPath.flatMap { UIImage(contentsOfFile: $0) }
        // Prefer a bundled brand logo asset; else the SF Symbol glyph.
        let mark = logoAssetName.flatMap { UIImage(named: $0) }
            ?? UIImage(systemName: glyphSymbolName)

        return UIGraphicsImageRenderer(size: size).image { _ in
            UIColor.secondarySystemFill.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))

            if let baseImage {
                let scale = max(size.width / baseImage.size.width,
                                size.height / baseImage.size.height)
                let drawSize = CGSize(width: baseImage.size.width * scale,
                                      height: baseImage.size.height * scale)
                baseImage.draw(in: CGRect(
                    x: (size.width - drawSize.width) / 2,
                    y: (size.height - drawSize.height) / 2,
                    width: drawSize.width, height: drawSize.height))
                // Small badge bottom-left so the platform is identifiable.
                let badge: CGFloat = 18
                mark?.withTintColor(.white.withAlphaComponent(0.95), renderingMode: .alwaysOriginal)
                    .draw(in: CGRect(x: 4, y: size.height - badge - 4, width: badge, height: badge))
            } else {
                let glyph: CGFloat = 26
                mark?.withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal)
                    .draw(in: CGRect(
                        x: (size.width - glyph) / 2, y: (size.height - glyph) / 2,
                        width: glyph, height: glyph))
            }
        }
    }
}

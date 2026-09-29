import LunaModels
import UIKit

/// Provider artwork, shared by the app and extensions through this resource bundle.
public enum LLMProviderGlyph {
    public static func image(for provider: LLMProvider, side: CGFloat = 17) -> UIImage {
        let name = provider == .chatGPT ? "LLMProviderChatGPT" : "LLMProviderClaude"
        guard let source = UIImage(named: name, in: .module, compatibleWith: nil) else {
            assertionFailure("Missing provider artwork: \(name)")
            return UIImage()
        }
        let size = CGSize(width: side, height: side)
        let scale = min(side / source.size.width, side / source.size.height)
        let fitted = CGSize(width: source.size.width * scale, height: source.size.height * scale)
        return UIGraphicsImageRenderer(size: size).image { _ in
            source.draw(in: CGRect(
                x: (side - fitted.width) / 2, y: (side - fitted.height) / 2,
                width: fitted.width, height: fitted.height))
        }.withRenderingMode(.alwaysTemplate)
    }
}

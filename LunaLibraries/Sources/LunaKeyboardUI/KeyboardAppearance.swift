import UIKit

/// Shared by the board, callouts and preview host. Typing keys remain quiet;
/// Liquid Glass is reserved for the controls above the content.
enum KeyboardAppearance {
  static func key(dark: Bool) -> UIColor {
    dark ? UIColor(white: 0.42, alpha: 1) : .white
  }
  static func modifier(dark: Bool) -> UIColor {
    dark ? UIColor(white: 0.27, alpha: 1) : UIColor(red: 171/255, green: 176/255, blue: 186/255, alpha: 1)
  }
  static func background(dark: Bool) -> UIColor {
    dark ? UIColor(white: 0.13, alpha: 1) : UIColor(red: 209/255, green: 212/255, blue: 218/255, alpha: 1)
  }
  static func glass(interactive: Bool = false) -> UIVisualEffectView {
    if #available(iOS 26, *) {
      let effect = UIGlassEffect(style: .regular)
      effect.isInteractive = interactive
      let view = UIVisualEffectView(effect: effect)
      view.cornerConfiguration = .capsule()
      return view
    }
    let view = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    view.layer.cornerRadius = 21
    view.clipsToBounds = true
    return view
  }
  static func glassContainer() -> UIVisualEffectView {
    if #available(iOS 26, *) {
      let effect = UIGlassContainerEffect()
      effect.spacing = 8
      return UIVisualEffectView(effect: effect)
    }
    return UIVisualEffectView(effect: nil)
  }
  static func animate(_ changes: @escaping () -> Void) {
    guard !UIAccessibility.isReduceMotionEnabled else { changes(); return }
    UIView.animate(withDuration: 0.24, delay: 0, usingSpringWithDamping: 0.9,
                   initialSpringVelocity: 0, options: [.beginFromCurrentState, .allowUserInteraction],
                   animations: changes)
  }
}

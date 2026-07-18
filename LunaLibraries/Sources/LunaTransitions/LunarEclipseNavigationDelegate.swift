import ObjectiveC
import UIKit

public final class LunarEclipseNavigationDelegate: NSObject, UINavigationControllerDelegate {
    public func navigationController(
        _ navigationController: UINavigationController,
        animationControllerFor operation: UINavigationController.Operation,
        from fromViewController: UIViewController,
        to toViewController: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        LunarEclipseTransitionCenter.animator(
            for: operation,
            from: fromViewController,
            to: toViewController)
    }
}

public extension UINavigationController {
    func installLunarEclipseTransition() {
        guard delegate == nil || delegate is LunarEclipseNavigationDelegate else { return }
        let transitionDelegate = (delegate as? LunarEclipseNavigationDelegate)
            ?? LunarEclipseNavigationDelegate()
        delegate = transitionDelegate
        objc_setAssociatedObject(
            self,
            &Self.lunarEclipseDelegateKey,
            transitionDelegate,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private static var lunarEclipseDelegateKey: UInt8 = 0
}

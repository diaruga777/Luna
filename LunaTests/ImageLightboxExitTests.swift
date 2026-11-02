import LunaReaderUI
import UIKit
import XCTest

@MainActor
final class ImageLightboxExitTests: XCTestCase {
    func testTallImageKeepsCloseControlInsideSafeAreaAndHittableAfterResizing() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 30, height: 300)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 30, height: 300))
        }
        let controller = ImageLightboxViewController(image: image, sourceFrame: CGRect(x: 20, y: 100, width: 30, height: 300))
        let window = UITestSupport.host(controller)
        defer { window.isHidden = true }
        let close = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? UIButton }.first)
        // Test the settled viewer without waiting for its opening animation.
        controller.view.layer.removeAllAnimations()
        close.layer.removeAllAnimations()
        for size in [CGSize(width: 402, height: 874), CGSize(width: 874, height: 402)] {
            controller.additionalSafeAreaInsets = size.width < size.height
                ? UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0)
                : UIEdgeInsets(top: 0, left: 62, bottom: 21, right: 62)
            window.frame.size = size
            window.layoutIfNeeded()
            controller.view.layoutIfNeeded()
            close.alpha = 1
            XCTAssertTrue(controller.view.safeAreaLayoutGuide.layoutFrame.contains(close.frame))
            XCTAssertGreaterThanOrEqual(close.bounds.width, 44)
            XCTAssertGreaterThanOrEqual(close.bounds.height, 44)
            let hit = controller.view.hitTest(close.center, with: nil)
            XCTAssertTrue(hit?.isDescendant(of: close) == true)
        }
    }
}

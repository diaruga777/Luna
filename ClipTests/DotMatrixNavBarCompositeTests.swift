//
//  DotMatrixNavBarCompositeTests.swift
//  ClipTests
//
//  Regression test for the pop-back nav-header animation (task 6). On a pop to the
//  large-title reading list, the DESTINATION bar must be composited into the AFTER
//  image at its OWN (taller) frame — not the compact SOURCE bar's frame — so the
//  large-title header dissolves in dot-by-dot with the body instead of snapping in at
//  the end. These geometry/pixel-level assertions stand in for a full UI transition.
//

@testable import ClipTransitions
import UIKit
import XCTest

final class DotMatrixNavBarCompositeTests: XCTestCase {

    private let size = CGSize(width: 100, height: 200)

    /// A solid-color image of `s` at scale 1.
    private func solid(_ color: UIColor, _ s: CGSize) -> UIImage {
        let f = UIGraphicsImageRendererFormat.preferred()
        f.scale = 1
        f.opaque = true
        return UIGraphicsImageRenderer(size: s, format: f).image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: s))
        }
    }

    /// RGBA of the pixel at `point` in `image` (UIKit top-left coords, scale 1 assumed).
    private func pixel(_ image: UIImage, at point: CGPoint) -> (r: UInt8, g: UInt8, b: UInt8) {
        let cg = image.cgImage!
        let h = CGFloat(cg.height)
        let space = CGColorSpaceCreateDeviceRGB()
        var data = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8,
                            bytesPerRow: 4, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // CGContext origin is bottom-left; flip the y so `point` is in UIKit top-left space.
        ctx.draw(cg, in: CGRect(x: -point.x, y: -(h - 1 - point.y),
                                width: CGFloat(cg.width), height: h))
        return (data[0], data[1], data[2])
    }

    /// The bar image is drawn exactly at the supplied frame: inside reads bar color, the
    /// content shows everywhere else. This proves the after-image honors the DESTINATION
    /// frame (and the before-image its own SOURCE frame) rather than a single shared one.
    func testBarCompositedAtItsOwnFrame() {
        let content = solid(.black, size)
        let destFrame = CGRect(x: 0, y: 0, width: 100, height: 96) // tall large-title bar
        let bar = solid(.red, destFrame.size)

        let out = DotMatrixTransitionSession.composite(
            content: content, bar: bar, at: destFrame, size: size)

        // A point well inside the (tall) destination bar reads the bar color...
        let inside = pixel(out, at: CGPoint(x: 50, y: 80))
        XCTAssertGreaterThan(inside.r, 200)
        XCTAssertLessThan(inside.g, 60)
        XCTAssertLessThan(inside.b, 60)
        // ...and a point below the destination frame still reads the content (black).
        let below = pixel(out, at: CGPoint(x: 50, y: 150))
        XCTAssertLessThan(below.r, 60)
        XCTAssertLessThan(below.g, 60)
        XCTAssertLessThan(below.b, 60)
    }

    /// The SAME bar image composited at a SHORT (compact source) frame vs a TALL
    /// (destination) frame yields different pixels in the band between the two heights —
    /// the regression was compositing the dest bar into the source frame, so this band
    /// would have been wrongly empty in the after-image.
    func testSourceAndDestFramesPlaceBarDifferently() {
        let content = solid(.black, size)
        let compact = CGRect(x: 0, y: 0, width: 100, height: 44)  // source reader bar
        let large = CGRect(x: 0, y: 0, width: 100, height: 96)    // dest large-title bar
        let bar = solid(.red, large.size)

        let atCompact = DotMatrixTransitionSession.composite(
            content: content, bar: bar, at: compact, size: size)
        let atLarge = DotMatrixTransitionSession.composite(
            content: content, bar: bar, at: large, size: size)

        // In the band y∈(44,96): squashed into the compact frame it's content (black);
        // at the large frame it's bar (red). Distinct frames ⇒ distinct results.
        let band = CGPoint(x: 50, y: 70)
        let compactBand = pixel(atCompact, at: band)
        let largeBand = pixel(atLarge, at: band)
        XCTAssertLessThan(compactBand.r, 120, "compact frame leaves the band as content")
        XCTAssertGreaterThan(largeBand.r, 200, "large frame fills the band with the bar")
    }

    /// No bar (a bar-hiding destination) ⇒ content returned unchanged, no ghost header.
    func testNilBarReturnsContentUnchanged() {
        let content = solid(.black, size)
        let out = DotMatrixTransitionSession.composite(
            content: content, bar: nil, at: CGRect(x: 0, y: 0, width: 100, height: 96),
            size: size)
        XCTAssertEqual(out.size, content.size)
        let p = pixel(out, at: CGPoint(x: 50, y: 80))
        XCTAssertLessThan(p.r, 60) // still black content, no red bar folded in
    }
}

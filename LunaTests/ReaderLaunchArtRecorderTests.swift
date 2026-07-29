//
//  ReaderLaunchArtRecorderTests.swift
//  LunaTests
//

import UIKit
import XCTest
@testable import Luna

/// Records the standalone composite used by LunaLaunchScreen.storyboard, plus
/// its two source layers, from the same production views that draw the first
/// live frame. The test skips in normal runs; opt in with
/// READER_LAUNCH_ART_DIR when the corona or rim changes.
@MainActor
final class ReaderLaunchArtRecorderTests: XCTestCase {
    func testRecordReaderLaunchArtworkWhenRequested() throws {
        guard let outputPath = ProcessInfo.processInfo.environment["READER_LAUNCH_ART_DIR"],
              !outputPath.isEmpty
        else {
            throw XCTSkip("Set READER_LAUNCH_ART_DIR to regenerate launch artwork.")
        }

        let outputURL = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputURL, withIntermediateDirectories: true)

        let reference = AppLaunchGeometry.referenceSize
        let referenceBounds = CGRect(origin: .zero, size: reference)
        let starfield = AppLaunchTransition.makeStaticStarfieldView(
            frame: referenceBounds)
        let coronaCard = AppLaunchTransition.makeStaticCoronaCardView(
            frame: referenceBounds,
            cardFrame: AppLaunchGeometry.referenceRootCardFrame)
        let composite = AppLaunchTransition.makeLaunchView(
            frame: referenceBounds,
            cardFrame: AppLaunchGeometry.referenceRootCardFrame)

        for scale in [1, 2, 3] {
            try render(starfield, opaque: true, scale: CGFloat(scale)).pngData()?.write(
                to: outputURL.appendingPathComponent(
                    "ReaderLaunchStarfield@\(scale)x.png"))
            try render(coronaCard, opaque: false, scale: CGFloat(scale)).pngData()?.write(
                to: outputURL.appendingPathComponent(
                    "ReaderLaunchCoronaCard@\(scale)x.png"))
            let compositeName = scale == 1
                ? "LunaLaunchComposite.png"
                : "LunaLaunchComposite@\(scale)x.png"
            try render(composite, opaque: true, scale: CGFloat(scale)).pngData()?.write(
                to: outputURL.appendingPathComponent(compositeName))
        }
    }

    private func render(_ view: UIView, opaque: Bool, scale: CGFloat) -> UIImage {
        view.setNeedsLayout()
        view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = opaque
        return UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { context in
            view.layer.render(in: context.cgContext)
        }
    }
}

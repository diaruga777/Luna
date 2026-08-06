//
//  ReaderLaunchArtRecorderTests.swift
//  LunaTests
//

import LunaDesignSystem
import UIKit
import XCTest
@testable import Luna

/// Records the two rasters the launch screen is built from, from the same
/// production views that draw the app's first live frame. The test skips in
/// normal runs; opt in with READER_LAUNCH_ART_DIR when the corona or rim
/// changes.
///
/// Both are **single-scale** images: the launch storyboard scales them to the
/// card frame it computes for the device, so one generously-sized raster serves
/// every screen. The corona canvas is exactly `AppLaunchGeometry.coronaFrame` —
/// the card grown by its proportional reach — and nothing else, so scaling it to
/// that frame is the whole placement rule.
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
        let cardFrame = AppLaunchGeometry.referenceRootCardFrame
        let starfield = AppLaunchTransition.makeStaticStarfieldView(
            frame: CGRect(origin: .zero, size: reference))
        let coronaCard = AppLaunchTransition.makeCoronaCardArtworkView(
            cardFrame: cardFrame)

        try render(starfield, opaque: true).pngData()?.write(
            to: outputURL.appendingPathComponent(
                "\(AppLaunchTransition.starfieldArtworkName).png"))
        try render(coronaCard, opaque: false).pngData()?.write(
            to: outputURL.appendingPathComponent(
                "\(AppLaunchTransition.coronaCardArtworkName).png"))
    }

    /// Rasterises at `EclipseCorona.artworkScale` and hands the result back as a
    /// 1x image: a single-scale asset's point size IS its pixel size, which is
    /// what lets one file serve @2x iPads and @3x phones without either being
    /// upscaled.
    private func render(_ view: UIView, opaque: Bool) -> UIImage {
        view.setNeedsLayout()
        view.layoutIfNeeded()
        let scale = EclipseCorona.artworkScale
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = opaque
        let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format)
            .image { context in
                context.cgContext.interpolationQuality = .high
                view.layer.render(in: context.cgContext)
            }
        guard let cgImage = image.cgImage else { return image }
        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    }
}

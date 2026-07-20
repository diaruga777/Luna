//
//  DownsampledImageLoaderTests.swift
//  LunaTests
//

import LunaDesignSystem
import UIKit
import XCTest

/// Covers the shared thumbnail loader introduced for WS-B (Downloader grid cells,
/// and available to any other on-disk-thumbnail consumer): downsampling to the
/// requested size, caching the decoded bitmap, and dropping a delivery once the
/// caller has marked itself stale (the same contract `ReadingListItemCell.loadToken`
/// established, generalized so it doesn't have to be reinvented per call site).
final class DownsampledImageLoaderTests: XCTestCase {
    private var scratch: URL!

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownsampledImageLoader-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    /// Writes a real, decodable PNG well above the requested thumbnail size, so a
    /// failure to downsample (returning the full-size bitmap) is observable.
    private func writeLargePNG(named name: String, side: CGFloat = 800) -> String {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        let image = renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
        let path = scratch.appendingPathComponent(name).path
        try? image.pngData()?.write(to: URL(fileURLWithPath: path))
        return path
    }

    func testLoadDownsamplesToRequestedSize() async throws {
        let path = writeLargePNG(named: "big.png")
        let pointSize = CGSize(width: 50, height: 50)
        let scale: CGFloat = 2

        let expectation = expectation(description: "decoded")
        var delivered: UIImage?
        DownsampledImageLoader.load(
            path: path, pointSize: pointSize, scale: scale, isStale: { false }
        ) { image in
            delivered = image
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 5)

        let image = try XCTUnwrap(delivered)
        // Downsampled to roughly the requested pixel size (100x100), nowhere near
        // the source's 800x800 — generous slack for CGImageSource's own rounding.
        XCTAssertLessThanOrEqual(image.size.width * image.scale, 120)
        XCTAssertLessThanOrEqual(image.size.height * image.scale, 120)
    }

    func testLoadDiscardsStaleDelivery() async {
        let path = writeLargePNG(named: "stale.png")
        let pointSize = CGSize(width: 40, height: 40)
        let scale: CGFloat = 2

        let notCalled = expectation(description: "completion should not run for a stale caller")
        notCalled.isInverted = true
        DownsampledImageLoader.load(
            path: path, pointSize: pointSize, scale: scale,
            isStale: { true }   // the caller has already moved on by the time this is checked
        ) { _ in
            notCalled.fulfill()
        }
        await fulfillment(of: [notCalled], timeout: 1)
    }
}

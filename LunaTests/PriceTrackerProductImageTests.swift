//
//  PriceTrackerProductImageTests.swift
//  LunaTests
//
//  `PriceTrackerProductImage.load` used to decode the persisted product picture
//  fresh on every call — every deck reload re-read and re-decoded the same file.
//  It now goes through the shared `DownsampledImageLoader`, so a repeat load for
//  the same file name is served from cache rather than the disk.
//

import LunaStorage
@testable import LunaPriceUI
import UIKit
import XCTest

final class PriceTrackerProductImageTests: XCTestCase {

    private func writePNG(named name: String, side: CGFloat) -> String {
        let fileURL = SavesStore.shared.articlesDirectory.appendingPathComponent(name)
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Pin the renderer to 1x: the default format uses the device scale, and a
        // 4000pt canvas at 3x is a 12000px bitmap — slow enough under full-suite
        // load to blow the wait timeout before the loader is even involved.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        let image = renderer.image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
        try? image.pngData()?.write(to: fileURL, options: .atomic)
        return name
    }

    private func load(_ fileName: String) -> UIImage? {
        let expectation = expectation(description: "loaded")
        var delivered: UIImage?
        PriceTrackerProductImage.load(imageFileName: fileName, pageURL: nil) { image in
            delivered = image
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 15)
        return delivered
    }

    /// A source photo well above the loader's cache target is downsampled rather
    /// than held as a full-size bitmap — the same contract every other
    /// `DownsampledImageLoader` consumer gets.
    func testLoadDownsamplesAnOversizedSourcePhoto() throws {
        // Comfortably above the loader's 900pt/3x (2700px) cache target, so a
        // failure to downsample (returning the full-size bitmap) is observable.
        let name = writePNG(named: "product-oversized-\(UUID().uuidString).png", side: 4000)
        defer {
            try? FileManager.default.removeItem(
                at: SavesStore.shared.articlesDirectory.appendingPathComponent(name))
        }

        let image = try XCTUnwrap(load(name))

        XCTAssertLessThan(image.size.width * image.scale, 3000)
        XCTAssertLessThan(image.size.height * image.scale, 3000)
    }

    /// The literal problem this adoption fixes: a second load for the same file
    /// name is answered from the shared cache, not a re-read of the (now deleted)
    /// file.
    func testRepeatedLoadIsServedFromCacheNotDisk() throws {
        let name = writePNG(named: "product-cache-\(UUID().uuidString).png", side: 40)
        let fileURL = SavesStore.shared.articlesDirectory.appendingPathComponent(name)

        _ = try XCTUnwrap(load(name), "first load should decode the real file")
        try FileManager.default.removeItem(at: fileURL)

        let second = load(name)
        XCTAssertNotNil(
            second, "a cached decode must still answer once the source file is gone")
    }

    /// No local file and no page URL: the loader has nothing to offer.
    func testMissingFileAndPageURLReturnsNil() {
        XCTAssertNil(load("no-such-product-image-\(UUID().uuidString).png"))
    }
}

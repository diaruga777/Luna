//
//  ScreenshotDigestTests.swift
//  LunaTests
//

import LunaIntents
import CoreGraphics
import ImageIO
import XCTest

final class ScreenshotDigestTests: XCTestCase {

    // MARK: - In-memory PNG fixtures

    private func solidPNGData(size: Int, red: CGFloat, green: CGFloat, blue: CGFloat) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return encodePNG(context.makeImage()!)
    }

    private func gradientPNGData(size: Int) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: [CGColor(red: 0, green: 0, blue: 0, alpha: 1), CGColor(red: 1, green: 1, blue: 1, alpha: 1)] as CFArray,
            locations: [0, 1])!
        context.drawLinearGradient(
            gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: size, y: size), options: [])
        return encodePNG(context.makeImage()!)
    }

    private func encodePNG(_ cgImage: CGImage) -> Data {
        let mutableData = NSMutableData()
        let destination = CGImageDestinationCreateWithData(mutableData, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, cgImage, nil)
        CGImageDestinationFinalize(destination)
        return mutableData as Data
    }

    // MARK: - digest(forImageData:)

    func testInvalidDataFailsToDigest() {
        XCTAssertNil(ScreenshotDigest.digest(forImageData: Data([0x01, 0x02, 0x03])))
    }

    func testDigestIsAlwaysSideBySideBytes() {
        let data = solidPNGData(size: 150, red: 0.3, green: 0.3, blue: 0.3)
        guard let digest = ScreenshotDigest.digest(forImageData: data) else {
            return XCTFail("expected a digest")
        }
        XCTAssertEqual(digest.count, ScreenshotDigest.side * ScreenshotDigest.side)
    }

    // MARK: - Similarity

    func testIdenticalContentIsSimilar() {
        let a = solidPNGData(size: 200, red: 0.2, green: 0.4, blue: 0.6)
        let b = solidPNGData(size: 200, red: 0.2, green: 0.4, blue: 0.6)
        guard let digestA = ScreenshotDigest.digest(forImageData: a),
              let digestB = ScreenshotDigest.digest(forImageData: b)
        else { return XCTFail("expected digests") }
        XCTAssertTrue(ScreenshotDigest.isSimilar(digestA, digestB))
    }

    func testDifferentContentIsNotSimilar() {
        let black = solidPNGData(size: 200, red: 0, green: 0, blue: 0)
        let white = solidPNGData(size: 200, red: 1, green: 1, blue: 1)
        guard let digestBlack = ScreenshotDigest.digest(forImageData: black),
              let digestWhite = ScreenshotDigest.digest(forImageData: white)
        else { return XCTFail("expected digests") }
        XCTAssertFalse(ScreenshotDigest.isSimilar(digestBlack, digestWhite))
    }

    func testGradientVsSolidIsNotSimilar() {
        let solid = solidPNGData(size: 200, red: 0.5, green: 0.5, blue: 0.5)
        let gradient = gradientPNGData(size: 200)
        guard let digestSolid = ScreenshotDigest.digest(forImageData: solid),
              let digestGradient = ScreenshotDigest.digest(forImageData: gradient)
        else { return XCTFail("expected digests") }
        XCTAssertFalse(ScreenshotDigest.isSimilar(digestSolid, digestGradient))
    }

    func testSameContentAtDifferentSizesIsSimilar() {
        // Both downscale to the same fixed side, so the ORIGINAL pixel
        // dimensions never matter to the comparison.
        let small = solidPNGData(size: 80, red: 0.5, green: 0.5, blue: 0.5)
        let large = solidPNGData(size: 900, red: 0.5, green: 0.5, blue: 0.5)
        guard let digestSmall = ScreenshotDigest.digest(forImageData: small),
              let digestLarge = ScreenshotDigest.digest(forImageData: large)
        else { return XCTFail("expected digests") }
        XCTAssertEqual(digestSmall.count, digestLarge.count)
        XCTAssertTrue(ScreenshotDigest.isSimilar(digestSmall, digestLarge))
    }

    // MARK: - meanAbsoluteDifference

    func testMeanAbsoluteDifferenceNilForMismatchedSizes() {
        XCTAssertNil(ScreenshotDigest.meanAbsoluteDifference(Data(repeating: 0, count: 10), Data(repeating: 0, count: 20)))
    }

    func testMeanAbsoluteDifferenceNilForEmptyData() {
        XCTAssertNil(ScreenshotDigest.meanAbsoluteDifference(Data(), Data()))
    }

    func testMeanAbsoluteDifferenceIsZeroForIdenticalBytes() {
        let a = Data([10, 20, 30, 40])
        XCTAssertEqual(ScreenshotDigest.meanAbsoluteDifference(a, a), 0)
    }

    func testMeanAbsoluteDifferenceIsNormalizedToUnitScale() {
        let a = Data([0, 0])
        let b = Data([255, 255])
        guard let difference = ScreenshotDigest.meanAbsoluteDifference(a, b) else {
            return XCTFail("expected a difference")
        }
        XCTAssertEqual(difference, 1.0, accuracy: 0.0001)
    }
}

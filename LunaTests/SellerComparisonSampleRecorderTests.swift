//
//  SellerComparisonSampleRecorderTests.swift
//  LunaTests
//

import LunaModels
import UIKit
import XCTest
@testable import LunaPriceUI

/// Writes a REVIEWABLE copy of the comparison document — the thing a Shortcut
/// hands back — so its typography, its axis labels and its favicons can be
/// looked at rather than inferred from assertions.
///
/// Skipped unless `RECORD_COMPARISON_SAMPLE=1`, in the same shape as
/// `EclipsePreviewRecorderTests`: it is a recorder, not a check. The assets are
/// synthesised here rather than fetched, because `LiveNetworkPolicy` refuses
/// live traffic from a test process — and because a sample that depends on
/// whether a retailer's icon server answered today is not a sample.
final class SellerComparisonSampleRecorderTests: XCTestCase {

    /// Where the file lands. Defaults inside the simulator's temporary
    /// directory; `COMPARISON_SAMPLE_PATH` puts it somewhere readable.
    private var destination: URL {
        if let path = ProcessInfo.processInfo.environment["COMPARISON_SAMPLE_PATH"] {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("seller-comparison-sample.html")
    }

    func testRecordComparisonDocumentSampleWhenRequested() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RECORD_COMPARISON_SAMPLE"] == "1",
            "Set RECORD_COMPARISON_SAMPLE=1 to write the reviewable sample document.")

        let now = Date(timeIntervalSince1970: 1_754_600_000)
        let tracker = Self.sampleTracker(now: now)
        let content = await SellerComparisonDocument.content(
            for: tracker, articlesDirectory: FileManager.default.temporaryDirectory,
            now: now,
            faviconLoader: { url in
                let name = SellerComparisonDocument.sellerName(forURLString: url.absoluteString)
                // One seller deliberately has no icon, so the placeholder badge
                // is visible in the sample too.
                guard name != "Newegg" else { return nil }
                return Self.iconPNG(letter: String(name.prefix(1)), seed: name.count)
            })
        let withHero = SellerComparisonDocument.Content(
            productName: content.productName,
            productImageDataURI: SellerComparisonDocument.dataURI(
                Self.productPNG(), mimeType: "image/png"),
            sellers: content.sellers,
            series: content.series,
            currentPrice: content.currentPrice,
            displayCurrency: content.displayCurrency,
            generatedAt: content.generatedAt)

        let html = SellerComparisonDocument.html(withHero)
        try Data(html.utf8).write(to: destination, options: .atomic)
        print("[comparison-sample] wrote \(destination.path) (\(html.count) bytes, "
            + "\(withHero.series.count) history points)")
        XCTAssertGreaterThan(withHero.series.count, 300, "a full year of daily history")
    }

    // MARK: - Fixture

    /// Six sellers and a full year of daily history — the shape the document has
    /// to survive, not the three-point toy the unit tests use.
    static func sampleTracker(now: Date) -> PriceTracker {
        let sellers = [
            "www.amazon.com", "www.bestbuy.com", "www.target.com",
            "www.walmart.com", "www.newegg.com", "www.bhphotovideo.com",
        ]
        var stores: [PriceTrackerStore] = []
        for (index, host) in sellers.enumerated() {
            // The last seller is deliberately unpriced — a shop Luna is watching
            // and currently cannot read is part of the picture.
            let priced = index < sellers.count - 1
            var store = PriceTrackerStore(
                urlString: "https://\(host)/product/acme-headphones-x2",
                lastPrice: nil, currency: "USD", lastRefreshed: priced ? now : nil)
            guard priced else { stores.append(store); continue }
            // A year of daily samples: a seasonal wander, a sale window seven
            // weeks back (so the all-time low is HISTORY), and a today that sits
            // above it — which is what gives the axis three distinct labels.
            func price(onDay day: Int) -> Decimal {
                let phase = Double(day) / 364
                let seasonal = 22 * sin(phase * 5.4)
                let drift = Double(index) * 6
                let sale = (44...58).contains(day) ? -38.0 : 0
                return Decimal(round((205 + seasonal + drift + sale) * 100) / 100)
            }
            for day in stride(from: 364, through: 0, by: -1) {
                store.recordSample(
                    price: price(onDay: day), currency: "USD",
                    at: now.addingTimeInterval(-Double(day) * 86_400))
            }
            store.lastPrice = price(onDay: 0)
            stores.append(store)
        }
        var tracker = PriceTracker(
            productName: "Acme Studio Headphones X2 (Wireless, Noise Cancelling)",
            stores: stores, brand: "Acme", productID: "0885909950805")
        tracker.seedComparisonBaseline(at: now)
        return tracker
    }

    /// A flat coloured badge with a letter — a stand-in favicon that is visibly
    /// an icon rather than a grey square.
    static func iconPNG(letter: String, seed: Int) -> Data {
        let side = CGFloat(64)
        let hue = CGFloat((seed * 37) % 360) / 360
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        let image = renderer.image { context in
            UIColor(hue: hue, saturation: 0.65, brightness: 0.85, alpha: 1).setFill()
            UIBezierPath(
                roundedRect: CGRect(x: 0, y: 0, width: side, height: side),
                cornerRadius: 14).fill()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 38, weight: .bold),
                .foregroundColor: UIColor.white,
            ]
            let text = NSAttributedString(string: letter.uppercased(), attributes: attributes)
            let size = text.size()
            text.draw(at: CGPoint(x: (side - size.width) / 2, y: (side - size.height) / 2))
            _ = context
        }
        return image.pngData() ?? Data()
    }

    /// A stand-in product photo.
    static func productPNG() -> Data {
        let size = CGSize(width: 440, height: 440)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { _ in
            UIColor(white: 0.93, alpha: 1).setFill()
            UIBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
            UIColor(hue: 0.62, saturation: 0.35, brightness: 0.45, alpha: 1).setFill()
            UIBezierPath(
                ovalIn: CGRect(x: 70, y: 90, width: 300, height: 260)).fill()
            UIColor(white: 0.93, alpha: 1).setFill()
            UIBezierPath(
                ovalIn: CGRect(x: 120, y: 150, width: 200, height: 200)).fill()
        }
        return image.pngData() ?? Data()
    }
}

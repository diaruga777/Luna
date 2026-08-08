//
//  ReadableColumnTests.swift
//  LunaTests
//
//  The column an extension surface lays its bands out in must never be wider
//  than the surface. It used to be, and the price editor in the share sheet was
//  clipped off both edges as a result.
//

import LunaDesignSystem
import LunaModels
import LunaPriceUI
import LunaStorage
import UIKit
import XCTest
@testable import Luna

final class ReadableColumnTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UIView.setAnimationsEnabled(false)
    }

    override func tearDown() {
        UITestSupport.wipeSharedStore()
        super.tearDown()
    }

    /// The column still fills an ordinary container — the clamp is a ceiling, not
    /// a shrink.
    @MainActor
    func testColumnFillsANarrowHostAndCapsOnAWideOne() {
        let phone = UIView(frame: CGRect(x: 0, y: 0, width: 393, height: 800))
        let phoneColumn = ReadableColumn.install(in: phone)
        phone.layoutIfNeeded()
        XCTAssertEqual(phoneColumn.layoutFrame.width, 393, accuracy: 0.5)

        let pad = UIView(frame: CGRect(x: 0, y: 0, width: 1024, height: 800))
        let padColumn = ReadableColumn.install(in: pad)
        pad.layoutIfNeeded()
        XCTAssertEqual(padColumn.layoutFrame.width, LunaLayout.readableWidth, accuracy: 0.5)
        XCTAssertEqual(padColumn.layoutFrame.midX, 512, accuracy: 0.5, "the column should be centred")
    }

    /// The whole editor, at phone width: every band inside the screen, left and
    /// right. This is the screenshot that started it — product title, seller row,
    /// history heading and alert footer each clipped at both edges at once.
    @MainActor
    func testPriceEditorBandsStayInsideTheScreenWidth() {
        // The reported save, reproduced. The long marketplace title is the whole
        // of it: measured here, that `numberOfLines = 0` label reports a 634pt
        // intrinsic width and drags the column to 428pt inside a 393pt screen.
        StageFixtures.seed([
            StageFixtures.pendingTracker(
                seed: "long-title",
                name: "Panasonic spare blade men's shaver 6-blade ES9600 : "
                    + "Amazon.com.au: Health, Household & Personal Care",
                url: "https://www.amazon.com.au/Panasonic-spare-blade-shaver-ES9600/dp/B003FGWPPS",
                price: 116.33, daysAgo: 0, alertThresholdFraction: nil),
        ])
        guard let tracker = ReadingListStore.shared.items().first(where: { $0.isPriceTracker }) else {
            XCTFail("no price tracker seeded"); return
        }
        let editor = PriceTrackingViewController(
            mode: .creation(itemID: tracker.id, host: .extension))
        let window = UITestSupport.host(editor)

        let bands = editor.view.subviews.filter { !$0.bounds.isEmpty }
        XCTAssertGreaterThanOrEqual(bands.count, 4, "expected the editor's bands to be laid out")
        for band in bands {
            let frame = band.convert(band.bounds, to: editor.view)
            XCTAssertGreaterThanOrEqual(
                frame.minX, -0.5,
                "\(type(of: band)) hangs off the leading edge: \(frame) in \(editor.view.bounds)")
            XCTAssertLessThanOrEqual(
                frame.maxX, editor.view.bounds.width + 0.5,
                "\(type(of: band)) hangs off the trailing edge: \(frame) in \(editor.view.bounds)")
        }
        _ = window
    }
}

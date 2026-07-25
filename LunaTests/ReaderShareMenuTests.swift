//
//  ReaderShareMenuTests.swift
//  LunaTests
//

import LunaDesignSystem
import LunaReaderUI
import UIKit
import XCTest

@MainActor
final class ReaderShareMenuTests: XCTestCase {

    /// A provider that offers options gets a menu button: the press opens the system
    /// popover (which is what supplies press-and-slide-to-pick), and the tap handler
    /// never runs.
    func testInstallMakesTheMenuThePrimaryAction() {
        let button = UIButton(type: .system)
        var fellBack = false
        ReaderShareMenu.install(
            on: button, providesMenu: true,
            build: { UIMenu(children: [UIAction(title: "Copy link") { _ in }]) },
            fallback: { fellBack = true })

        XCTAssertTrue(button.showsMenuAsPrimaryAction)
        XCTAssertEqual(button.preferredMenuElementOrder, .fixed)
        XCTAssertNotNil(button.menu)
        button.sendActions(for: .touchUpInside)
        XCTAssertFalse(fellBack)
    }

    /// A single-verb provider (the app extension's plain link share) keeps a plain
    /// tap — a one-option popover would be pure ceremony.
    func testInstallKeepsTheTapWhenThereIsNoMenu() {
        let button = UIButton(type: .system)
        var fellBack = false
        ReaderShareMenu.install(
            on: button, providesMenu: false,
            build: { XCTFail("should not build a menu"); return nil },
            fallback: { fellBack = true })

        XCTAssertFalse(button.showsMenuAsPrimaryAction)
        XCTAssertNil(button.menu)
        button.sendActions(for: .touchUpInside)
        XCTAssertTrue(fellBack)
    }

    /// The menu is deferred, so a button that outlives the article it points at
    /// (the deck's chrome pill) resolves its options at press time, not install time.
    func testMenuIsRebuiltOnEachPresentation() {
        let button = UIButton(type: .system)
        var builds = 0
        ReaderShareMenu.install(
            on: button, providesMenu: true,
            build: {
                builds += 1
                return UIMenu(children: [UIAction(title: "Copy link") { _ in }])
            },
            fallback: {})

        XCTAssertEqual(builds, 0, "install must not resolve the options eagerly")
        let deferred = try? XCTUnwrap(button.menu?.children.first as? UIDeferredMenuElement)
        XCTAssertNotNil(deferred)
    }
}

@MainActor
final class LunaToastTests: XCTestCase {

    func testToastAppearsImmediatelyAndDoesNotBlockTouches() {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        LunaToast.show("Copied", in: host)

        let capsule = try? XCTUnwrap(host.subviews.last)
        XCTAssertNotNil(capsule)
        XCTAssertEqual(capsule?.isUserInteractionEnabled, false)
        let labels = capsule?.subviews.flatMap(\.subviews).compactMap { $0 as? UILabel } ?? []
        XCTAssertEqual(labels.first?.text, "Copied")
    }

    /// A burst of copies must not stack capsules on top of each other.
    func testSecondToastReplacesTheFirst() {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        LunaToast.show("Copied", in: host)
        LunaToast.show("Copied", in: host)
        XCTAssertEqual(host.subviews.count, 1)
    }
}

//
//  EmailEntryAutoFillTests.swift
//  LunaTests
//

import UIKit
import XCTest
@testable import Luna

@MainActor
final class EmailEntryAutoFillTests: XCTestCase {

    func testAutoFillAcceptsCompleteAddressIntoEmptyField() throws {
        let (controller, field) = try makeSubject()

        let acceptedByUIKit = controller.textField(
            field,
            shouldChangeCharactersInRanges: [NSValue(range: NSRange(location: 0, length: 0))],
            replacementString: "reader@example.com"
        )

        XCTAssertFalse(acceptedByUIKit, "The controller applies a complete AutoFill address itself")
        XCTAssertEqual(field.text, "reader@example.com")
    }

    func testAutoFillReplacesPartiallyTypedAddress() throws {
        let (controller, field) = try makeSubject()
        field.text = "rea"

        let acceptedByUIKit = controller.textField(
            field,
            shouldChangeCharactersInRanges: [NSValue(range: NSRange(location: 0, length: 3))],
            replacementString: "reader@example.com"
        )

        XCTAssertFalse(acceptedByUIKit, "The complete suggestion replaces the existing prefix")
        XCTAssertEqual(field.text, "reader@example.com")
    }

    func testCredentialProviderSingleRangePathAlsoReplacesPrefix() throws {
        let (controller, field) = try makeSubject()
        field.text = "rea"

        let acceptedByUIKit = controller.textField(
            field,
            shouldChangeCharactersIn: NSRange(location: 0, length: 3),
            replacementString: "reader@example.com"
        )

        XCTAssertFalse(acceptedByUIKit)
        XCTAssertEqual(field.text, "reader@example.com")
    }

    func testOrdinaryTypingIncludingAtSignStillUsesUIKitEditingPath() throws {
        let (controller, field) = try makeSubject()
        field.text = "reader"

        let acceptedByUIKit = controller.textField(
            field,
            shouldChangeCharactersInRanges: [NSValue(range: NSRange(location: 6, length: 0))],
            replacementString: "@"
        )

        XCTAssertTrue(acceptedByUIKit)
        XCTAssertEqual(field.text, "reader")
    }

    private func makeSubject() throws -> (EmailEntryViewController, UITextField) {
        let controller = EmailEntryViewController(accountStore: .shared, completion: nil)
        controller.loadViewIfNeeded()
        let field = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? UITextField }.first)
        return (controller, field)
    }
}

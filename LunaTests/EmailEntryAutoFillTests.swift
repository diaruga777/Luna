//
//  EmailEntryAutoFillTests.swift
//  LunaTests
//

import UIKit
import XCTest
@testable import Luna

@MainActor
final class EmailEntryAutoFillTests: XCTestCase {

    func testFieldUsesPersonalEmailAutocompleteAndEmailKeyboard() throws {
        let (_, field) = try makeSubject()

        XCTAssertEqual(field.textContentType, .emailAddress)
        XCTAssertEqual(field.keyboardType, .emailAddress)
        XCTAssertEqual(field.returnKeyType, .continue)
        XCTAssertNil(field.delegate, "Email autocomplete must reach the native text field directly")
    }

    func testNativeInputAcceptsCompleteAddressIntoEmptyField() throws {
        let (_, field) = try makeSubject()

        field.insertText("reader@example.com")

        XCTAssertEqual(field.text, "reader@example.com")
    }

    func testNativeInputReplacesPartiallyTypedAddress() throws {
        let (_, field) = try makeSubject()
        field.text = "rea"
        let wholeField = try XCTUnwrap(
            field.textRange(from: field.beginningOfDocument, to: field.endOfDocument))

        field.replace(wholeField, withText: "reader@example.com")

        XCTAssertEqual(field.text, "reader@example.com")
    }

    func testReturnKeyUsesControlActionWithoutInstallingDelegate() throws {
        let (controller, field) = try makeSubject()
        let actions = field.actions(
            forTarget: controller, forControlEvent: .editingDidEndOnExit) ?? []

        XCTAssertTrue(actions.contains("continueTapped"))
        XCTAssertNil(field.delegate)
    }

    func testInputSessionStartsAfterFieldIsHostedInWindow() throws {
        let (controller, field) = try makeSubject()
        XCTAssertFalse(field.isFirstResponder)

        let window = UITestSupport.host(controller)
        controller.viewDidAppear(false)

        XCTAssertTrue(field.isFirstResponder)
        field.resignFirstResponder()
        window.isHidden = true
        window.rootViewController = nil
    }

    private func makeSubject() throws -> (EmailEntryViewController, UITextField) {
        let controller = EmailEntryViewController(accountStore: .shared, completion: nil)
        controller.loadViewIfNeeded()
        // The field now sits inside a rounded field-card several levels deep
        // (scroll view → content → stack → card → field) rather than as a direct
        // subview of the root view.
        let field = try XCTUnwrap(findTextField(in: controller.view))
        return (controller, field)
    }

    private func findTextField(in view: UIView) -> UITextField? {
        if let field = view as? UITextField { return field }
        for subview in view.subviews {
            if let found = findTextField(in: subview) { return found }
        }
        return nil
    }
}

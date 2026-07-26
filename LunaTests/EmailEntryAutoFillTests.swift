//
//  EmailEntryAutoFillTests.swift
//  LunaTests
//
//  The AutoFill invariants of the inline email-address field in Settings →
//  Email (the only place an account is connected). See
//  `claudedocs/email-login.md`.
//

import LunaMailAccount
import UIKit
import XCTest
@testable import Luna

@MainActor
final class EmailEntryAutoFillTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var window: UIWindow?

    override func setUp() {
        super.setUp()
        suiteName = "EmailEntryAutoFillTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testFieldUsesPersonalEmailAutocompleteAndEmailKeyboard() throws {
        let (_, field) = try makeSubject()

        XCTAssertEqual(field.textContentType, .emailAddress)
        XCTAssertEqual(field.keyboardType, .emailAddress)
        XCTAssertEqual(field.returnKeyType, .go)
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
        let (screen, field) = try makeSubject()
        let actions = field.actions(
            forTarget: screen, forControlEvent: .editingDidEndOnExit) ?? []

        XCTAssertTrue(actions.contains("connectAccount"))
        XCTAssertNil(field.delegate)
    }

    /// Only a redirect ("you need an account to send this") asks for the keyboard.
    func testRedirectStartsTheInputSessionAfterTheFieldIsHostedInWindow() throws {
        let (screen, field) = try makeSubject()
        XCTAssertFalse(field.isFirstResponder)

        screen.focusesAddressField = true
        screen.viewDidAppear(false)

        XCTAssertTrue(field.isFirstResponder)
        field.resignFirstResponder()
    }

    func testPlainVisitLeavesTheKeyboardAlone() throws {
        let (screen, field) = try makeSubject()

        screen.viewDidAppear(false)

        XCTAssertFalse(field.isFirstResponder)
    }

    /// The screen with an empty scratch account store, hosted in a window so the
    /// table realizes real cells, plus the address field from the sign-in row (the
    /// Kindle section has a field of its own, so this looks inside that one cell).
    private func makeSubject() throws -> (EmailAndKindleSettingsScreen, UITextField) {
        let store = EmailAccountStore(defaults: defaults, credentialStorage: InMemoryCredentialStorage())
        let screen = EmailAndKindleSettingsScreen(accountStore: store)
        window = UITestSupport.host(screen)
        let row = try XCTUnwrap(screen.tableView.cellForRow(at: IndexPath(row: 0, section: 0)))
        let field = try XCTUnwrap(findTextField(in: row.contentView))
        return (screen, field)
    }

    private func findTextField(in view: UIView) -> UITextField? {
        if let field = view as? UITextField { return field }
        for subview in view.subviews {
            if let found = findTextField(in: subview) { return found }
        }
        return nil
    }
}

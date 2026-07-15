//
//  EmailLoginTests.swift
//  LunaTests
//
//  Pure-function and lightweight-integration coverage for the redesigned email
//  login flow: password normalization, address validation, provider-badge text,
//  and the two action buttons' enablement tracking their fields.
//

import LunaMailAccount
import UIKit
import XCTest
@testable import Luna

@MainActor
final class EmailLoginTests: XCTestCase {

    // MARK: - CredentialViewController.normalizedPassword

    func testNormalizedPasswordStripsAllWhitespaceForAppPasswordProviders() {
        for providerID: MailProvider.ID in [.gmail, .icloud, .yahoo] {
            XCTAssertEqual(
                CredentialViewController.normalizedPassword("xxxx xxxx xxxx xxxx", providerID: providerID),
                "xxxxxxxxxxxxxxxx")
            XCTAssertEqual(
                CredentialViewController.normalizedPassword("  abcd efgh  ", providerID: providerID),
                "abcdefgh")
        }
    }

    func testNormalizedPasswordOnlyEdgeTrimsForGenericProvider() {
        XCTAssertEqual(
            CredentialViewController.normalizedPassword("  my pass word  ", providerID: .generic),
            "my pass word")
        XCTAssertEqual(
            CredentialViewController.normalizedPassword("nospaces", providerID: .generic),
            "nospaces")
    }

    func testNormalizedPasswordEmptyStaysEmpty() {
        XCTAssertEqual(CredentialViewController.normalizedPassword("", providerID: .gmail), "")
        XCTAssertEqual(CredentialViewController.normalizedPassword("   ", providerID: .gmail), "")
        XCTAssertEqual(CredentialViewController.normalizedPassword("   ", providerID: .generic), "")
    }

    // MARK: - EmailEntryViewController.isValidAddress

    func testIsValidAddressRequiresAtAndDot() {
        XCTAssertTrue(EmailEntryViewController.isValidAddress("person@example.com"))
        XCTAssertTrue(EmailEntryViewController.isValidAddress("  person@example.com  "))
        XCTAssertFalse(EmailEntryViewController.isValidAddress("person@example"))
        XCTAssertFalse(EmailEntryViewController.isValidAddress("person.example.com"))
        XCTAssertFalse(EmailEntryViewController.isValidAddress(""))
    }

    // MARK: - ProviderBadgeText (provider-badge visibility)

    func testProviderBadgeTextHiddenForGenericAndShownForKnownProviders() {
        XCTAssertNil(ProviderBadgeText.text(for: .generic))
        XCTAssertEqual(ProviderBadgeText.text(for: .gmail), "Gmail")
        XCTAssertEqual(ProviderBadgeText.text(for: .icloud), "iCloud")
        XCTAssertEqual(ProviderBadgeText.text(for: .yahoo), "Yahoo")
        XCTAssertEqual(ProviderBadgeText.text(for: .outlook), "Outlook")
    }

    // MARK: - CredentialViewController.isConnectivityFailure

    func testConnectivityFailureDetectsNetworkDomains() {
        XCTAssertTrue(CredentialViewController.isConnectivityFailure(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)))
        XCTAssertTrue(CredentialViewController.isConnectivityFailure(
            NSError(domain: NSPOSIXErrorDomain, code: 61)))
        XCTAssertTrue(CredentialViewController.isConnectivityFailure(
            NSError(domain: "kCFErrorDomainCFNetwork", code: 1)))
    }

    func testConnectivityFailureFalseForCredentialProtocolErrors() {
        struct FakeProtocolError: Error, CustomStringConvertible {
            var description: String { "bad login" }
        }
        XCTAssertFalse(CredentialViewController.isConnectivityFailure(FakeProtocolError()))
    }

    // MARK: - Continue button enablement (EmailEntryViewController)

    func testContinueButtonEnablementTracksFieldValidity() throws {
        let controller = EmailEntryViewController(accountStore: .shared, completion: nil)
        controller.loadViewIfNeeded()
        let field = try XCTUnwrap(findView(of: UITextField.self, in: controller.view))
        let button = try XCTUnwrap(findView(of: EmailLoginActionButton.self, in: controller.view))

        XCTAssertFalse(button.isEnabled, "empty field starts disabled")

        field.text = "person@example.com"
        field.sendActions(for: .editingChanged)
        XCTAssertTrue(button.isEnabled)

        field.text = "not-an-email"
        field.sendActions(for: .editingChanged)
        XCTAssertFalse(button.isEnabled)
    }

    func testProviderBadgeFadesInOnlyForKnownDomains() throws {
        let controller = EmailEntryViewController(accountStore: .shared, completion: nil)
        controller.loadViewIfNeeded()
        let field = try XCTUnwrap(findView(of: UITextField.self, in: controller.view))
        let badge = try XCTUnwrap(findView(of: ProviderBadgeView.self, in: controller.view))

        XCTAssertEqual(badge.alpha, 0, "hidden at rest (empty field)")

        field.text = "person@gmail.com"
        field.sendActions(for: .editingChanged)
        XCTAssertEqual(badge.alpha, 1)

        field.text = "person@some-random-domain.io"
        field.sendActions(for: .editingChanged)
        XCTAssertEqual(badge.alpha, 0)
    }

    // MARK: - Sign In button enablement (CredentialViewController)

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "EmailLoginTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testSignInButtonEnablementTracksPasswordField() throws {
        let store = EmailAccountStore(defaults: defaults, credentialStorage: InMemoryCredentialStorage())
        let account = EmailAccount(providerID: .gmail, address: "person@gmail.com")
        let controller = CredentialViewController(account: account, accountStore: store, completion: nil)
        controller.loadViewIfNeeded()
        let field = try XCTUnwrap(findView(of: UITextField.self, in: controller.view))
        let button = try XCTUnwrap(findView(of: EmailLoginActionButton.self, in: controller.view))

        XCTAssertFalse(button.isEnabled, "empty password starts disabled")

        field.text = "app-password"
        field.sendActions(for: .editingChanged)
        XCTAssertTrue(button.isEnabled)

        field.text = ""
        field.sendActions(for: .editingChanged)
        XCTAssertFalse(button.isEnabled)
    }

    // MARK: - Helpers

    private func findView<T: UIView>(of type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let found = findView(of: type, in: subview) { return found }
        }
        return nil
    }
}

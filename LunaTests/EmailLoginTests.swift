//
//  EmailLoginTests.swift
//  LunaTests
//
//  Pure-function and lightweight-integration coverage for connecting an email
//  account: password normalization, address validation, provider-badge text, and
//  the inline sign-in form in Settings → Email tracking what's typed.
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

    // MARK: - EmailAccountSetup.isValidAddress

    func testIsValidAddressRequiresAtAndDot() {
        XCTAssertTrue(EmailAccountSetup.isValidAddress("person@example.com"))
        XCTAssertTrue(EmailAccountSetup.isValidAddress("  person@example.com  "))
        XCTAssertFalse(EmailAccountSetup.isValidAddress("person@example"))
        XCTAssertFalse(EmailAccountSetup.isValidAddress("person.example.com"))
        XCTAssertFalse(EmailAccountSetup.isValidAddress(""))
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

    // MARK: - Inline sign-in form (Settings → Email)

    /// The Connect row is the form's action: tinted and selectable only once the
    /// typed address could plausibly be one.
    func testConnectRowEnablementTracksTypedAddress() throws {
        let (screen, field) = try makeUnconfiguredAccountForm()

        XCTAssertFalse(connectRowIsEnabled(in: screen), "empty field starts disabled")

        field.text = "person@example.com"
        field.sendActions(for: .editingChanged)
        XCTAssertTrue(connectRowIsEnabled(in: screen))

        field.text = "not-an-email"
        field.sendActions(for: .editingChanged)
        XCTAssertFalse(connectRowIsEnabled(in: screen))
    }

    func testProviderBadgeFadesInOnlyForKnownDomains() throws {
        let (screen, field) = try makeUnconfiguredAccountForm()
        let badge = try findBadge(in: screen)

        XCTAssertEqual(badge.alpha, 0, "hidden at rest (empty field)")

        field.text = "person@gmail.com"
        field.sendActions(for: .editingChanged)
        XCTAssertEqual(badge.alpha, 1)

        field.text = "person@some-random-domain.io"
        field.sendActions(for: .editingChanged)
        XCTAssertEqual(badge.alpha, 0)
    }

    /// With no account connected the Sharing Account section IS the sign-in form,
    /// so the old separate "Connect Email Account…" push has no row left.
    func testUnconfiguredAccountSectionShowsTheFormAndNoPushRow() throws {
        let (screen, _) = try makeUnconfiguredAccountForm()

        XCTAssertEqual(screen.tableView.numberOfRows(inSection: 0), 2)
        let addressRow = try XCTUnwrap(
            screen.tableView.cellForRow(at: IndexPath(row: 0, section: 0)))
        XCTAssertNotNil(findView(of: UITextField.self, in: addressRow.contentView))
        XCTAssertEqual(addressRow.accessoryType, .none)
    }

    func testRejectedCredentialShowsAccountErrorAndReconnectRows() throws {
        let store = EmailAccountStore(
            defaults: defaults, credentialStorage: InMemoryCredentialStorage())
        store.save(
            EmailAccount(providerID: .gmail, address: "person@gmail.com"),
            credential: .appPassword("expired"))
        store.markAuthenticationIssue(.credentialsRejected)
        let screen = EmailAndKindleSettingsScreen(accountStore: store)
        window = UITestSupport.host(screen)

        // The healthy section is two rows (account + Sign Out); an authentication
        // issue inserts the explanation and the Reconnect action between them.
        XCTAssertEqual(screen.tableView.numberOfRows(inSection: 0), 4)
        XCTAssertEqual(contentText(in: screen, row: 0), "person@gmail.com")
        XCTAssertEqual(contentText(in: screen, row: 2), "Reconnect email")
        XCTAssertEqual(contentText(in: screen, row: 3), "Sign Out")
    }

    // MARK: - Sign In button enablement (CredentialViewController)

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var window: UIWindow?

    override func setUp() {
        super.setUp()
        suiteName = "EmailLoginTests.\(UUID().uuidString)"
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

    func testBackingOutOfCredentialScreenCompletesAttemptAsCancelled() {
        let store = EmailAccountStore(
            defaults: defaults, credentialStorage: InMemoryCredentialStorage())
        let root = UIViewController()
        let nav = UINavigationController(rootViewController: root)
        window = UITestSupport.host(nav)
        var completion: Bool?
        let controller = CredentialViewController(
            account: EmailAccount(
                providerID: .gmail, address: "person@gmail.com"),
            accountStore: store,
            completion: { completion = $0 })

        nav.pushViewController(controller, animated: false)
        nav.popViewController(animated: false)

        XCTAssertEqual(completion, false)
    }

    func testRecoveryReusesStoredProviderInsteadOfReinferringAddress() throws {
        let store = EmailAccountStore(
            defaults: defaults, credentialStorage: InMemoryCredentialStorage())
        let root = UIViewController()
        let nav = UINavigationController(rootViewController: root)
        window = UITestSupport.host(nav)
        let setup = EmailAccountSetup(
            presenter: root, accountStore: store, completion: { _ in })
        let storedAccount = EmailAccount(
            providerID: .gmail,
            address: "reader@custom-domain.example",
            server: MailProvider.provider(for: .gmail).server)

        XCTAssertTrue(setup.start(account: storedAccount))
        let credentialScreen = try XCTUnwrap(
            nav.topViewController as? CredentialViewController)
        credentialScreen.loadViewIfNeeded()
        let labels = allViews(of: UILabel.self, in: credentialScreen.view)
        XCTAssertTrue(labels.contains(where: { $0.text == "Gmail" }))
    }

    // MARK: - Helpers

    /// The Email screen with a scratch (empty) account store, hosted in
    /// a window so the table realizes real cells, plus its inline address field.
    private func makeUnconfiguredAccountForm() throws -> (EmailAndKindleSettingsScreen, UITextField) {
        let store = EmailAccountStore(defaults: defaults, credentialStorage: InMemoryCredentialStorage())
        XCTAssertFalse(store.isConfigured)
        let screen = EmailAndKindleSettingsScreen(accountStore: store)
        window = UITestSupport.host(screen)
        let row = try XCTUnwrap(screen.tableView.cellForRow(at: IndexPath(row: 0, section: 0)))
        // The Kindle section carries a text field too, so look inside this row.
        let field = try XCTUnwrap(findView(of: UITextField.self, in: row.contentView))
        return (screen, field)
    }

    private func connectRowIsEnabled(in screen: EmailAndKindleSettingsScreen) -> Bool {
        let cell = screen.tableView(screen.tableView, cellForRowAt: IndexPath(row: 1, section: 0))
        return cell.selectionStyle != .none
    }

    private func contentText(
        in screen: EmailAndKindleSettingsScreen, row: Int
    ) -> String? {
        let cell = screen.tableView(
            screen.tableView, cellForRowAt: IndexPath(row: row, section: 0))
        return (cell.contentConfiguration as? UIListContentConfiguration)?.text
    }

    private func findBadge(in screen: EmailAndKindleSettingsScreen) throws -> ProviderBadgeView {
        let row = try XCTUnwrap(screen.tableView.cellForRow(at: IndexPath(row: 0, section: 0)))
        return try XCTUnwrap(findView(of: ProviderBadgeView.self, in: row.contentView))
    }

    private func findView<T: UIView>(of type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let found = findView(of: type, in: subview) { return found }
        }
        return nil
    }

    private func allViews<T: UIView>(of type: T.Type, in view: UIView) -> [T] {
        var matches = (view as? T).map { [$0] } ?? []
        for subview in view.subviews {
            matches.append(contentsOf: allViews(of: type, in: subview))
        }
        return matches
    }
}

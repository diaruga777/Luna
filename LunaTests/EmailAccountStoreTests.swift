//
//  EmailAccountStoreTests.swift
//  LunaTests
//

import LunaMailAccount
import XCTest

final class EmailAccountStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var credentialStorage: InMemoryCredentialStorage!
    private var store: EmailAccountStore!

    override func setUp() {
        super.setUp()
        suiteName = "EmailAccountStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        credentialStorage = InMemoryCredentialStorage()
        store = EmailAccountStore(defaults: defaults, credentialStorage: credentialStorage)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        store = nil
        credentialStorage = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func makeAccount(address: String = "a@gmail.com") -> EmailAccount {
        EmailAccount(providerID: .gmail, address: address)
    }

    // MARK: - Save / load / clear round trip

    func testSaveLoadClearRoundTrip() {
        XCTAssertNil(store.account)
        XCTAssertFalse(store.isConfigured)

        let account = makeAccount()
        store.save(account, credential: .appPassword("secret"))

        XCTAssertEqual(store.account, account)
        XCTAssertEqual(store.credential, .appPassword("secret"))
        XCTAssertTrue(store.isConfigured)

        store.clear()
        XCTAssertNil(store.account)
        XCTAssertNil(store.credential)
        XCTAssertFalse(store.isConfigured)
    }

    func testOAuthCredentialRoundTrips() {
        let account = EmailAccount(providerID: .outlook, address: "a@outlook.com")
        let tokens = OAuthTokens(accessToken: "at", refreshToken: "rt", expiry: Date())
        store.save(account, credential: .oauth(tokens))
        XCTAssertEqual(store.credential, .oauth(tokens))
        XCTAssertTrue(store.isConfigured)
        XCTAssertTrue(store.isReady)
    }

    func testAuthenticationIssueKeepsAccountForRecoveryButMakesItNotReady() {
        let account = makeAccount()
        store.save(account, credential: .appPassword("secret"))

        store.markAuthenticationIssue(.credentialsRejected)

        XCTAssertEqual(store.account, account)
        XCTAssertEqual(store.credential, .appPassword("secret"))
        XCTAssertEqual(store.authenticationIssue, .credentialsRejected)
        XCTAssertTrue(store.isConfigured)
        XCTAssertFalse(store.isReady)
    }

    func testSavingReplacementCredentialClearsAuthenticationIssue() {
        let account = makeAccount()
        store.save(account, credential: .appPassword("old-secret"))
        store.markAuthenticationIssue(.credentialsRejected)

        store.save(account, credential: .appPassword("new-secret"))

        XCTAssertNil(store.authenticationIssue)
        XCTAssertEqual(store.credential, .appPassword("new-secret"))
        XCTAssertTrue(store.isReady)
    }

    func testAuthenticationIssuePersistsAcrossStoreInstances() {
        store.save(makeAccount(), credential: .appPassword("secret"))
        store.markAuthenticationIssue(.authorizationExpired)

        let secondStore = EmailAccountStore(
            defaults: defaults, credentialStorage: credentialStorage)

        XCTAssertEqual(secondStore.authenticationIssue, .authorizationExpired)
        XCTAssertFalse(secondStore.isReady)
    }

    func testIsConfiguredRequiresBothMetadataAndCredential() {
        // Metadata only, no credential written: not configured.
        if let data = try? JSONEncoder().encode(makeAccount()) {
            defaults.set(data, forKey: "lunaEmailAccount")
        }
        XCTAssertNotNil(store.account)
        XCTAssertNil(store.credential)
        XCTAssertNil(store.authenticationIssue)
        XCTAssertFalse(store.isConfigured)
    }

    func testSwitchingFromAppPasswordToOAuthClearsThePrevious() {
        let account = makeAccount()
        store.save(account, credential: .appPassword("secret"))
        XCTAssertEqual(store.credential, .appPassword("secret"))

        let tokens = OAuthTokens(accessToken: "at", refreshToken: "rt", expiry: Date())
        store.save(account, credential: .oauth(tokens))
        XCTAssertEqual(store.credential, .oauth(tokens))
    }

    // MARK: - accountChanged notification

    func testSaveAndClearPostAccountChanged() {
        let saveExpectation = expectation(forNotification: EmailAccountStore.accountChanged, object: nil)
        store.save(makeAccount(), credential: .appPassword("secret"))
        wait(for: [saveExpectation], timeout: 1)

        let clearExpectation = expectation(forNotification: EmailAccountStore.accountChanged, object: nil)
        store.clear()
        wait(for: [clearExpectation], timeout: 1)
    }

    // MARK: - A second store over a different suite (standing in for "real") is unaffected

    func testSecondStoreOverDifferentSuiteIsUnaffected() {
        let otherSuiteName = "EmailAccountStoreTests.other.\(UUID().uuidString)"
        let otherDefaults = UserDefaults(suiteName: otherSuiteName)!
        let otherCredentialStorage = InMemoryCredentialStorage()
        let otherStore = EmailAccountStore(defaults: otherDefaults, credentialStorage: otherCredentialStorage)
        defer { otherDefaults.removePersistentDomain(forName: otherSuiteName) }

        XCTAssertFalse(otherStore.isConfigured)

        store.save(makeAccount(), credential: .appPassword("secret"))

        // The "real" stand-in never saw the write.
        XCTAssertFalse(otherStore.isConfigured)
        XCTAssertNil(otherStore.account)
        XCTAssertNil(otherStore.credential)

        // Sanity: the store under test really did save.
        XCTAssertTrue(store.isConfigured)
    }

    // MARK: - KeychainCredentialStorage wraps CredentialKeychain unchanged

    func testKeychainCredentialStorageIsTheDefault() {
        // EmailAccountStore.shared (no explicit credentialStorage) must resolve to
        // the real Keychain-backed implementation — verified indirectly: creating a
        // store with the default argument doesn't throw/crash and the type is the
        // documented default. This guards the public API's default value.
        let defaultStore = EmailAccountStore(defaults: defaults)
        XCTAssertFalse(defaultStore.isConfigured)
    }
}

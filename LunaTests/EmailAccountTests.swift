//
//  EmailAccountTests.swift
//  LunaTests
//
//  Merged from EmailAccountStoreTests, EmailAuthenticationStateTests,
//  CredentialKeychainTests, SourceSendSettingsTests (+ its
//  CaptureSourceCodableTests companion), and EmailEntryAutoFillTests.
//
//  Each original concern gets its own namespaced fixtures below, all built
//  fresh (random suite/service names) in one unioned setUp/tearDown so none of
//  the five leak state into the others.
//

import LunaAppConfig
import LunaMailAccount
@testable import LunaMailTransport
import LunaModels
@testable import LunaSend
import LunaStorage
import Security
import UIKit
import XCTest
@testable import Luna

@MainActor
final class EmailAccountTests: XCTestCase {

    // EmailAccountStore concern
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var credentialStorage: InMemoryCredentialStorage!
    private var store: EmailAccountStore!

    // EmailAuthenticationState concern (store is pre-populated with a saved
    // account/credential, unlike the plain `store` above)
    private var authSuiteName: String!
    private var authDefaults: UserDefaults!
    private var authStore: EmailAccountStore!

    // EmailEntryAutoFill concern
    private var autoFillSuiteName: String!
    private var autoFillDefaults: UserDefaults!
    private var window: UIWindow?

    // CredentialKeychain concern — runs against the real simulator keychain
    // (the test host carries the app-group entitlement, which doubles as the
    // keychain access group).
    private var keychainService: String!
    private let keychainAccount = "test-credential"

    // SourceSendSettings concern — opaque generic destination id exercising
    // the plain stored (non-Kindle) code paths. Kindle is special-cased for
    // App-Intents mode (`KindleSendSettings.sendMode`) and for the email toggle
    // (it reuses the "Also Send to Kindle" import setting), so a generic id is
    // needed here. The settings resolve the shared App-Group suite, so the test
    // points them at throwaway suites rather than the real container.
    private let sourceSendDestinationID = "genericDestination"
    private var sourceSendGroupSuiteName: String!
    private var sourceSendLegacySuiteName: String!
    private var sourceSendGroup: UserDefaults!
    private var sourceSendLegacy: UserDefaults!

    override func setUp() {
        super.setUp()

        suiteName = "EmailAccountStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        credentialStorage = InMemoryCredentialStorage()
        store = EmailAccountStore(defaults: defaults, credentialStorage: credentialStorage)

        authSuiteName = "EmailAuthenticationStateTests.\(UUID().uuidString)"
        authDefaults = UserDefaults(suiteName: authSuiteName)
        authStore = EmailAccountStore(
            defaults: authDefaults, credentialStorage: InMemoryCredentialStorage())
        authStore.save(
            EmailAccount(providerID: .gmail, address: "person@gmail.com"),
            credential: .appPassword("saved-password"))

        autoFillSuiteName = "EmailEntryAutoFillTests.\(UUID().uuidString)"
        autoFillDefaults = UserDefaults(suiteName: autoFillSuiteName)

        keychainService = "com.hsanabria.luna.tests.keychain.\(UUID().uuidString)"

        sourceSendGroupSuiteName = "SourceSendSettingsTests.group.\(UUID().uuidString)"
        sourceSendLegacySuiteName = "SourceSendSettingsTests.legacy.\(UUID().uuidString)"
        sourceSendGroup = UserDefaults(suiteName: sourceSendGroupSuiteName)
        sourceSendLegacy = UserDefaults(suiteName: sourceSendLegacySuiteName)
        SourceSendSettings.testDefaultsOverride = MigratingAppGroupDefaults(
            group: sourceSendGroup, legacy: sourceSendLegacy)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        store = nil
        credentialStorage = nil
        defaults = nil
        suiteName = nil

        authDefaults.removePersistentDomain(forName: authSuiteName)
        authStore = nil
        authDefaults = nil
        authSuiteName = nil

        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        autoFillDefaults.removePersistentDomain(forName: autoFillSuiteName)
        autoFillDefaults = nil
        autoFillSuiteName = nil

        CredentialKeychain.delete(service: keychainService, account: keychainAccount)
        keychainService = nil

        SourceSendSettings.testDefaultsOverride = nil
        sourceSendGroup.removePersistentDomain(forName: sourceSendGroupSuiteName)
        sourceSendLegacy.removePersistentDomain(forName: sourceSendLegacySuiteName)
        sourceSendGroup = nil
        sourceSendLegacy = nil
        sourceSendGroupSuiteName = nil
        sourceSendLegacySuiteName = nil

        super.tearDown()
    }

    private func makeAccount(address: String = "a@gmail.com") -> EmailAccount {
        EmailAccount(providerID: .gmail, address: address)
    }

    // MARK: - EmailAccountStore: Save / load / clear round trip

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

    // MARK: - EmailAccountStore: accountChanged notification

    func testSaveAndClearPostAccountChanged() {
        let saveExpectation = expectation(forNotification: EmailAccountStore.accountChanged, object: nil)
        store.save(makeAccount(), credential: .appPassword("secret"))
        wait(for: [saveExpectation], timeout: 1)

        let clearExpectation = expectation(forNotification: EmailAccountStore.accountChanged, object: nil)
        store.clear()
        wait(for: [clearExpectation], timeout: 1)
    }

    // MARK: - EmailAuthenticationState

    func testTypedAuthenticationFailureMarksAccountForRecovery() async {
        let transport = AuthenticationStateTrackingTransport(
            base: StubTransport(result: .authenticationFailure(.credentialsRejected)),
            store: authStore)

        do {
            try await transport.verifyCredentials()
            XCTFail("Expected authentication failure")
        } catch {
            XCTAssertEqual(authStore.authenticationIssue, .credentialsRejected)
            XCTAssertTrue(authStore.isConfigured)
            XCTAssertFalse(authStore.isReady)
            XCTAssertNil(MailTransportFactory.make(store: authStore))
        }
    }

    func testConnectivityFailureDoesNotInvalidateLogin() async {
        let transport = AuthenticationStateTrackingTransport(
            base: StubTransport(result: .connectivityFailure), store: authStore)

        do {
            try await transport.verifyCredentials()
            XCTFail("Expected connectivity failure")
        } catch {
            XCTAssertNil(authStore.authenticationIssue)
            XCTAssertTrue(authStore.isReady)
        }
    }

    func testSuccessfulAuthenticatedCallClearsStaleIssue() async throws {
        authStore.markAuthenticationIssue(.authorizationExpired)
        let transport = AuthenticationStateTrackingTransport(
            base: StubTransport(result: .success), store: authStore)

        try await transport.verifyCredentials()

        XCTAssertNil(authStore.authenticationIssue)
        XCTAssertTrue(authStore.isReady)
    }

    func testGraphAuthenticationResponseClassification() {
        XCTAssertTrue(GraphMailTransport.authenticationFailure(
            statusCode: 401, body: Data()))
        XCTAssertTrue(GraphMailTransport.authenticationFailure(
            statusCode: 400, body: Data(#"{"error":"invalid_grant"}"#.utf8)))
        XCTAssertTrue(GraphMailTransport.authenticationFailure(
            statusCode: 403,
            body: Data(#"{"error":{"code":"ErrorAccessDenied"}}"#.utf8)))
        XCTAssertFalse(GraphMailTransport.authenticationFailure(
            statusCode: 400, body: Data(#"{"error":"invalid_request"}"#.utf8)))
        XCTAssertFalse(GraphMailTransport.authenticationFailure(
            statusCode: 429, body: Data(#"{"error":"too_many_requests"}"#.utf8)))
        XCTAssertFalse(GraphMailTransport.authenticationFailure(
            statusCode: 503, body: Data()))
    }

    // MARK: - CredentialKeychain

    /// The access group of the (single expected) matching item, or nil.
    private func storedAccessGroup() -> String? {
        var query = CredentialKeychain.baseQuery(
            service: keychainService, account: keychainAccount, synchronizable: kSecAttrSynchronizableAny)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let attributes = result as? [String: Any]
        else { return nil }
        return attributes[kSecAttrAccessGroup as String] as? String
    }

    /// Adds an item the way pre-suite builds did: no access group, so it lands
    /// in the app's own private (application-identifier) group.
    private func addLegacyPrivateItem(value: String) {
        var insert = CredentialKeychain.baseQuery(
            service: keychainService, account: keychainAccount, synchronizable: true)
        insert[kSecValueData as String] = Data(value.utf8)
        insert[kSecAttrAccessible as String] = CredentialKeychain.accessibleClass
        XCTAssertEqual(SecItemAdd(insert as CFDictionary, nil), errSecSuccess)
    }

    func testWriteStoresInSharedAccessGroupAndRoundTrips() {
        CredentialKeychain.write("secret", service: keychainService, account: keychainAccount)

        XCTAssertEqual(CredentialKeychain.read(service: keychainService, account: keychainAccount), "secret")
        XCTAssertEqual(storedAccessGroup(), CredentialKeychain.sharedAccessGroup)
        XCTAssertEqual(CredentialKeychain.sharedAccessGroup, AppConfig.appGroupID)
    }

    func testLegacyPrivateGroupItemMigratesToSharedGroupOnRead() {
        addLegacyPrivateItem(value: "legacy-secret")
        XCTAssertNotEqual(storedAccessGroup(), CredentialKeychain.sharedAccessGroup,
                          "precondition: the legacy item must start outside the shared group")

        // The read itself both returns the legacy value and moves it.
        XCTAssertEqual(CredentialKeychain.read(service: keychainService, account: keychainAccount), "legacy-secret")
        XCTAssertEqual(storedAccessGroup(), CredentialKeychain.sharedAccessGroup)

        // Still readable after migration (now from the shared group directly).
        XCTAssertEqual(CredentialKeychain.read(service: keychainService, account: keychainAccount), "legacy-secret")
    }

    func testDeleteRemovesBothSharedAndLegacyCopies() {
        addLegacyPrivateItem(value: "legacy-secret")
        CredentialKeychain.write("shared-secret", service: keychainService, account: keychainAccount)

        CredentialKeychain.delete(service: keychainService, account: keychainAccount)

        XCTAssertNil(CredentialKeychain.read(service: keychainService, account: keychainAccount),
                     "no copy may survive a delete — a leftover legacy item would resurrect via migration")
        XCTAssertNil(storedAccessGroup())
    }

    func testReadMissingItemReturnsNil() {
        XCTAssertNil(CredentialKeychain.read(service: keychainService, account: keychainAccount))
    }

    // MARK: - SourceSendSettings
    //
    // Exercises per-source auto-send resolution. `SourceSendSettings` treats
    // destination ids as opaque strings for the email/share-paste/friend-share
    // toggles, so a made-up id exercises those generic (non-Kindle) code paths.
    //
    // Note: unlike the destination this file used to test (Boox, removed in
    // commit 97833a34), a generic/unregistered destination id has no
    // App-Intents mode of its own — `appIntentsMode`/`setAppIntentsMode` only
    // have a real branch for `ArticleDestinationID.kindle` today, so a
    // made-up id's App-Intents mode is always `.off` regardless of what's set.
    // That also means the "legacy all-saves inherited by default" behavior
    // (`legacyDefault`, keyed off App-Intents mode) can no longer be
    // exercised generically — it only applies to Kindle now.

    private func mode(_ source: CaptureSource, friend: String? = nil) -> ArticleSendMode {
        SourceSendSettings.sendMode(forDestination: sourceSendDestinationID, source: source, friendUsername: friend)
    }

    func testEmailToggleGatesEmailOnly() {
        SourceSendSettings.setEmailEnabled(true, forDestination: sourceSendDestinationID)
        XCTAssertEqual(mode(.email), .allSaves)
        XCTAssertEqual(mode(.appIntent), .off)
        SourceSendSettings.setEmailEnabled(false, forDestination: sourceSendDestinationID)
        XCTAssertEqual(mode(.email), .off)
    }

    func testShareSheetAndPasteShareOneToggle() {
        SourceSendSettings.setShareAndPasteEnabled(true, forDestination: sourceSendDestinationID)
        XCTAssertEqual(mode(.shareSheet), .allSaves)
        XCTAssertEqual(mode(.paste), .allSaves)
        SourceSendSettings.setShareAndPasteEnabled(false, forDestination: sourceSendDestinationID)
        XCTAssertEqual(mode(.shareSheet), .off)
        XCTAssertEqual(mode(.paste), .off)
    }

    func testFriendDefaultAppliesWhenNoOverride() {
        SourceSendSettings.setFriendSharesEnabledDefault(true, forDestination: sourceSendDestinationID)
        XCTAssertEqual(mode(.friendShare, friend: "alice"), .allSaves)
        XCTAssertEqual(mode(.friendShare, friend: nil), .allSaves)
    }

    func testPerFriendOverrideBeatsDefault() {
        SourceSendSettings.setFriendSharesEnabledDefault(true, forDestination: sourceSendDestinationID)
        SourceSendSettings.setFriendShareEnabled(false, forDestination: sourceSendDestinationID, username: "bob")
        XCTAssertEqual(mode(.friendShare, friend: "bob"), .off)        // overridden off
        XCTAssertEqual(mode(.friendShare, friend: "carol"), .allSaves) // still default on
    }

    func testDefaultsOffForAllSourcesOnAGenericDestination() {
        // With no explicit per-source keys set and no App-Intents mode possible
        // for a generic id, every source defaults off.
        XCTAssertEqual(mode(.email), .off)
        XCTAssertEqual(mode(.shareSheet), .off)
        XCTAssertEqual(mode(.friendShare, friend: "dave"), .off)
        XCTAssertEqual(mode(.appIntent), .off)
        XCTAssertEqual(mode(.manual), .off)
    }

    // MARK: - SourceSendSettings: captureSource round-trips through the store

    /// A save with no recorded source — an unset column — reads back as unset and
    /// routes as `.manual`, which is what the per-source send settings ask.
    func testStoredItemWithoutSourceDefaultsToManual() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SavesStore(containerURL: directory)

        var item = SavedItem(urlString: "https://example.com/no-source")
        item.captureSource = nil
        store.seedForTesting(items: [item], contents: [:])

        let stored = try XCTUnwrap(store.item(withID: item.id))
        XCTAssertNil(stored.captureSource)
        XCTAssertEqual(stored.effectiveCaptureSource, .manual)
    }

    func testSourceSurvivesAStoreRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SavesStore(containerURL: directory)

        let saved = store.add(urlString: "https://example.com", source: .friendShare)

        let stored = try XCTUnwrap(store.item(withID: saved.id))
        XCTAssertEqual(stored.captureSource, .friendShare)
        XCTAssertEqual(stored.effectiveCaptureSource, .friendShare)
    }

    // MARK: - EmailEntryAutoFill
    //
    // The AutoFill invariants of the inline email-address field in Settings →
    // Email (the only place an account is connected). See
    // `claudedocs/email-login.md`.

    func testFieldUsesPersonalEmailAutocompleteAndEmailKeyboard() throws {
        let (_, field) = try makeAutoFillSubject()

        XCTAssertEqual(field.textContentType, .emailAddress)
        XCTAssertEqual(field.keyboardType, .emailAddress)
        XCTAssertEqual(field.returnKeyType, .go)
        XCTAssertNil(field.delegate, "Email autocomplete must reach the native text field directly")
    }

    func testNativeInputAcceptsCompleteAddressIntoEmptyField() throws {
        let (_, field) = try makeAutoFillSubject()

        field.insertText("reader@example.com")

        XCTAssertEqual(field.text, "reader@example.com")
    }

    func testNativeInputReplacesPartiallyTypedAddress() throws {
        let (_, field) = try makeAutoFillSubject()
        field.text = "rea"
        let wholeField = try XCTUnwrap(
            field.textRange(from: field.beginningOfDocument, to: field.endOfDocument))

        field.replace(wholeField, withText: "reader@example.com")

        XCTAssertEqual(field.text, "reader@example.com")
    }

    func testReturnKeyUsesControlActionWithoutInstallingDelegate() throws {
        let (screen, field) = try makeAutoFillSubject()
        let actions = field.actions(
            forTarget: screen, forControlEvent: .editingDidEndOnExit) ?? []

        XCTAssertTrue(actions.contains("connectAccount"))
        XCTAssertNil(field.delegate)
    }

    /// Only a redirect ("you need an account to send this") asks for the keyboard.
    func testRedirectStartsTheInputSessionAfterTheFieldIsHostedInWindow() throws {
        let (screen, field) = try makeAutoFillSubject()
        XCTAssertFalse(field.isFirstResponder)

        screen.focusesAddressField = true
        screen.viewDidAppear(false)

        XCTAssertTrue(field.isFirstResponder)
        field.resignFirstResponder()
    }

    func testPlainVisitLeavesTheKeyboardAlone() throws {
        let (screen, field) = try makeAutoFillSubject()

        screen.viewDidAppear(false)

        XCTAssertFalse(field.isFirstResponder)
    }

    /// The screen with an empty scratch account store, hosted in a window so the
    /// table realizes real cells, plus the address field from the sign-in row (the
    /// Kindle section has a field of its own, so this looks inside that one cell).
    private func makeAutoFillSubject() throws -> (EmailAndKindleSettingsScreen, UITextField) {
        let store = EmailAccountStore(defaults: autoFillDefaults, credentialStorage: InMemoryCredentialStorage())
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

private struct StubTransport: EmailTransport {
    enum Result {
        case success
        case authenticationFailure(EmailAuthenticationIssue)
        case connectivityFailure
    }

    let result: Result

    func verifyCredentials() async throws {
        try resolve()
    }

    func send(_ email: OutgoingEmail) async throws {
        try resolve()
    }

    func fetchShares(
        after cursor: MailCursor,
        extraSenders: [String],
        extraSubjects: [String]
    ) async throws -> FetchResult {
        try resolve()
        return FetchResult(messages: [], cursor: cursor)
    }

    func markRead(_ messageIDs: [String]) async throws {
        try resolve()
    }

    func createLunaFilter() async throws -> FilterOutcome {
        try resolve()
        return .created
    }

    private func resolve() throws {
        switch result {
        case .success:
            return
        case .authenticationFailure(let issue):
            throw EmailAuthenticationError(issue: issue, detail: "fixture rejection")
        case .connectivityFailure:
            throw URLError(.notConnectedToInternet)
        }
    }
}

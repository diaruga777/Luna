//
//  CredentialKeychainTests.swift
//  LunaTests
//
//  Runs against the real simulator keychain (the test host carries the
//  app-group entitlement, which doubles as the keychain access group).
//

import LunaAppConfig
import LunaStorage
import Security
import XCTest

final class CredentialKeychainTests: XCTestCase {

    private var service: String!
    private let account = "test-credential"

    override func setUp() {
        super.setUp()
        service = "com.hsanabria.luna.tests.keychain.\(UUID().uuidString)"
    }

    override func tearDown() {
        CredentialKeychain.delete(service: service, account: account)
        service = nil
        super.tearDown()
    }

    /// The access group of the (single expected) matching item, or nil.
    private func storedAccessGroup() -> String? {
        var query = CredentialKeychain.baseQuery(
            service: service, account: account, synchronizable: kSecAttrSynchronizableAny)
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
            service: service, account: account, synchronizable: true)
        insert[kSecValueData as String] = Data(value.utf8)
        insert[kSecAttrAccessible as String] = CredentialKeychain.accessibleClass
        XCTAssertEqual(SecItemAdd(insert as CFDictionary, nil), errSecSuccess)
    }

    func testWriteStoresInSharedAccessGroupAndRoundTrips() {
        CredentialKeychain.write("secret", service: service, account: account)

        XCTAssertEqual(CredentialKeychain.read(service: service, account: account), "secret")
        XCTAssertEqual(storedAccessGroup(), CredentialKeychain.sharedAccessGroup)
        XCTAssertEqual(CredentialKeychain.sharedAccessGroup, AppConfig.appGroupID)
    }

    func testLegacyPrivateGroupItemMigratesToSharedGroupOnRead() {
        addLegacyPrivateItem(value: "legacy-secret")
        XCTAssertNotEqual(storedAccessGroup(), CredentialKeychain.sharedAccessGroup,
                          "precondition: the legacy item must start outside the shared group")

        // The read itself both returns the legacy value and moves it.
        XCTAssertEqual(CredentialKeychain.read(service: service, account: account), "legacy-secret")
        XCTAssertEqual(storedAccessGroup(), CredentialKeychain.sharedAccessGroup)

        // Still readable after migration (now from the shared group directly).
        XCTAssertEqual(CredentialKeychain.read(service: service, account: account), "legacy-secret")
    }

    func testDeleteRemovesBothSharedAndLegacyCopies() {
        addLegacyPrivateItem(value: "legacy-secret")
        CredentialKeychain.write("shared-secret", service: service, account: account)

        CredentialKeychain.delete(service: service, account: account)

        XCTAssertNil(CredentialKeychain.read(service: service, account: account),
                     "no copy may survive a delete — a leftover legacy item would resurrect via migration")
        XCTAssertNil(storedAccessGroup())
    }

    func testReadMissingItemReturnsNil() {
        XCTAssertNil(CredentialKeychain.read(service: service, account: account))
    }
}

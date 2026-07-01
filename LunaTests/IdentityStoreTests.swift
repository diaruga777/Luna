//
//  IdentityStoreTests.swift
//  LunaTests
//

import LunaSocial
import XCTest
@testable import Luna

final class IdentityStoreTests: XCTestCase {

    func testCreateAndLoadRoundTrip() {
        let store = InMemoryIdentityStore()
        XCTAssertNil(store.loadIdentity())

        let created = store.createIdentity(
            username: "  alice  ", email: "a@example.com", phone: nil)
        XCTAssertEqual(created?.username, "alice")

        let loaded = store.loadIdentity()
        XCTAssertEqual(loaded?.uuid, created?.uuid)
        XCTAssertEqual(loaded?.email, "a@example.com")
        XCTAssertNil(loaded?.phone)
    }

    func testCreateRejectsInvalidUsernames() {
        let store = InMemoryIdentityStore()
        XCTAssertNil(store.createIdentity(username: "", email: nil, phone: nil))
        XCTAssertNil(store.createIdentity(username: "   ", email: nil, phone: nil))
        XCTAssertNil(store.createIdentity(
            username: String(repeating: "x", count: 21), email: nil, phone: nil))
        XCTAssertNil(store.loadIdentity())
    }

    func testUpdateProfileKeepsKeysAndUUID() throws {
        let store = InMemoryIdentityStore()
        let created = try XCTUnwrap(store.createIdentity(username: "alice", email: nil, phone: nil))

        let updated = store.updateProfile(
            username: "alice2", email: "", phone: "+1 555 0100")
        XCTAssertEqual(updated?.uuid, created.uuid)
        XCTAssertEqual(updated?.username, "alice2")
        XCTAssertNil(updated?.email) // empty collapses to nil
        XCTAssertEqual(updated?.phone, "+1 555 0100")
        XCTAssertEqual(
            updated?.card.signingPublicKey, created.card.signingPublicKey)
        XCTAssertEqual(
            updated?.card.encryptionPublicKey, created.card.encryptionPublicKey)
    }

    func testUpdateProfileRejectsInvalidUsername() throws {
        let store = InMemoryIdentityStore()
        _ = try XCTUnwrap(store.createIdentity(username: "alice", email: nil, phone: nil))
        XCTAssertNil(store.updateProfile(username: "", email: nil, phone: nil))
        XCTAssertEqual(store.loadIdentity()?.username, "alice")
    }

    func testContactFieldNormalization() {
        XCTAssertNil(ProfileValidation.normalizedContactField(nil))
        XCTAssertNil(ProfileValidation.normalizedContactField("   "))
        XCTAssertEqual(ProfileValidation.normalizedContactField(" a@b.c "), "a@b.c")
        let long = String(repeating: "9", count: 100)
        XCTAssertEqual(
            ProfileValidation.normalizedContactField(long)?.count,
            ProfileValidation.contactFieldMaxLength)
    }
}

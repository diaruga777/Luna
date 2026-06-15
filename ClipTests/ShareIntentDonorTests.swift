//
//  ShareIntentDonorTests.swift
//  ClipTests
//

import Intents
import XCTest
@testable import Clip

final class ShareIntentDonorTests: XCTestCase {

    private func card(email: String?, phone: String?) -> IdentityCard {
        IdentityCard(
            uuid: UUID(), username: "alice", email: email, phone: phone,
            encryptionPublicKey: Data(), signingPublicKey: Data())
    }

    func testPrefersEmail() {
        let person = ShareIntentDonor.recipient(for: card(email: "a@b.com", phone: "+15551234567"))
        XCTAssertEqual(person.personHandle?.value, "a@b.com")
        XCTAssertEqual(person.personHandle?.type, .emailAddress)
        XCTAssertEqual(person.displayName, "alice")
    }

    func testFallsBackToPhone() {
        let person = ShareIntentDonor.recipient(for: card(email: nil, phone: "+15551234567"))
        XCTAssertEqual(person.personHandle?.value, "+15551234567")
        XCTAssertEqual(person.personHandle?.type, .phoneNumber)
    }

    func testFallsBackToUsername() {
        let person = ShareIntentDonor.recipient(for: card(email: nil, phone: nil))
        XCTAssertEqual(person.personHandle?.value, "alice")
        XCTAssertEqual(person.personHandle?.type, .unknown)
    }
}

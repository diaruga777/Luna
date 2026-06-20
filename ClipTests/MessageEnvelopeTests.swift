//
//  MessageEnvelopeTests.swift
//  ClipTests
//

import XCTest
@testable import Clip

final class MessageEnvelopeTests: XCTestCase {

    func testFriendAddRoundTrip() throws {
        let card = IdentityCard(
            uuid: UUID(), username: "alice", email: "a@example.com", phone: "+1555",
            encryptionPublicKey: Data(repeating: 1, count: 32),
            signingPublicKey: Data(repeating: 2, count: 32))
        let body = MessageBody.friendAdd(card)
        XCTAssertEqual(try MessageBody.decoded(from: try body.encoded()), body)
    }

    func testReadingListItemRoundTrip() throws {
        let body = MessageBody.readingListItem(urlString: "https://example.com/a", title: nil)
        XCTAssertEqual(try MessageBody.decoded(from: try body.encoded()), body)
    }

    func testPriceTrackerRoundTrip() throws {
        var tracker = PriceTracker(
            productName: "Sony WH-1000XM5", firstStoreURL: "https://a.example/p",
            price: Decimal(string: "399.99")!, currency: "USD",
            brand: "Sony", productID: "6505725", alertThresholdFraction: 0.15)
        tracker.upsertStore(PriceTrackerStore(
            urlString: "https://b.example/p", lastPrice: Decimal(string: "379.00"),
            currency: "USD"))
        let body = MessageBody.priceTracker(PriceTrackerShare(tracker: tracker))
        let decoded = try MessageBody.decoded(from: try body.encoded())
        XCTAssertEqual(decoded, body)

        guard case .priceTracker(let share) = decoded else {
            return XCTFail("expected priceTracker")
        }
        let recreated = try XCTUnwrap(share.makeTracker())
        XCTAssertEqual(recreated.stores.map(\.urlString),
                       ["https://a.example/p", "https://b.example/p"])
        XCTAssertEqual(recreated.initialPrice, Decimal(string: "379.00"),
                       "baseline is the best price at share time")
        XCTAssertEqual(recreated.alertThresholdFraction, 0.15, accuracy: 0.0001)
        XCTAssertEqual(recreated.productID, "6505725")
    }

    func testPriceTrackerWithNoURLsDecodesAsUnknown() throws {
        let wire = Data(#"{"type":"priceTracker","priceTracker":{"productName":"X","storeURLStrings":[],"initialPriceString":"1","initialCurrency":"USD","alertThresholdFraction":0.1}}"#.utf8)
        XCTAssertEqual(try MessageBody.decoded(from: wire), .unknown(type: "priceTracker"))
    }

    func testUnknownTypeDecodesAsUnknown() throws {
        let wire = Data(#"{"type":"holographicSticker","payload":"whatever"}"#.utf8)
        XCTAssertEqual(try MessageBody.decoded(from: wire), .unknown(type: "holographicSticker"))
    }

    func testKnownTypeWithMissingFieldsDecodesAsUnknown() throws {
        // A "friendAdd" without a card must not crash or half-decode.
        let wire = Data(#"{"type":"friendAdd"}"#.utf8)
        XCTAssertEqual(try MessageBody.decoded(from: wire), .unknown(type: "friendAdd"))
    }
}

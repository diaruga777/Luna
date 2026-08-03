//
//  WeeklySigningTests.swift
//  LunaTests
//

import CryptoKit
import Foundation
import LunaModels
import LunaWeekly
import XCTest

/// The curator's private key deliberately lives OUTSIDE this repository, so
/// these tests split in two: the shipped public key is pinned for shape, and
/// the sign→verify algebra is exercised against a pair each test mints.
final class WeeklySigningTests: XCTestCase {

    func testBundledPublicKeyDecodes() {
        XCTAssertNotNil(
            WeeklySigning.publicKey,
            "The compiled-in public key must parse — everything else verifies against it.")
        XCTAssertEqual(WeeklySigning.publicKey?.rawRepresentation.count, 32)
    }

    /// Nothing signed by a key that isn't the curator's may pass the shipped
    /// check — this is the whole security model of a world-writable public
    /// database.
    func testASaveSignedByAStrangerIsRejectedByTheBundledKey() throws {
        let stranger = Curve25519.Signing.PrivateKey()
        let save = try WeeklySigning.sign(
            kind: .article, urlString: "https://example.com/a", date: Date(),
            privateKey: stranger)
        XCTAssertFalse(WeeklySigning.verify(save))
    }

    func testSignedSaveVerifies() throws {
        let key = Curve25519.Signing.PrivateKey()
        let save = try WeeklySigning.sign(
            kind: .article, urlString: "https://example.com/a", date: Date(),
            privateKey: key)
        XCTAssertTrue(WeeklySigning.verify(save, publicKey: key.publicKey))
    }

    func testTamperedURLFailsVerification() throws {
        let key = Curve25519.Signing.PrivateKey()
        let save = try WeeklySigning.sign(
            kind: .article, urlString: "https://example.com/a", date: Date(),
            privateKey: key)
        let tampered = WeeklySave(
            kind: save.kind, urlString: "https://evil.example/a",
            date: save.date, signature: save.signature)
        XCTAssertFalse(WeeklySigning.verify(tampered, publicKey: key.publicKey))
    }

    func testTamperedDateFailsVerification() throws {
        let key = Curve25519.Signing.PrivateKey()
        let save = try WeeklySigning.sign(
            kind: .media, urlString: "https://example.com/v", date: Date(),
            privateKey: key)
        let tampered = WeeklySave(
            kind: save.kind, urlString: save.urlString,
            date: save.date.addingTimeInterval(-86_400), signature: save.signature)
        XCTAssertFalse(WeeklySigning.verify(tampered, publicKey: key.publicKey))
    }

    func testTamperedKindFailsVerification() throws {
        let key = Curve25519.Signing.PrivateKey()
        let save = try WeeklySigning.sign(
            kind: .product, urlString: "https://example.com/p", date: Date(),
            privateKey: key)
        let tampered = WeeklySave(
            kind: .article, urlString: save.urlString,
            date: save.date, signature: save.signature)
        XCTAssertFalse(WeeklySigning.verify(tampered, publicKey: key.publicKey))
    }

    func testPrivateKeyMatchRejectsAnythingButTheCuratorsKey() {
        let stranger = Curve25519.Signing.PrivateKey()
        XCTAssertFalse(WeeklySigning.privateKeyMatchesBundledPublicKey(
            stranger.rawRepresentation.base64EncodedString()))
        XCTAssertFalse(WeeklySigning.privateKeyMatchesBundledPublicKey("not base64 at all"))
        XCTAssertFalse(WeeklySigning.privateKeyMatchesBundledPublicKey(""))
        // A well-formed base64 blob of the wrong length isn't a key either.
        XCTAssertFalse(WeeklySigning.privateKeyMatchesBundledPublicKey(
            Data(repeating: 7, count: 8).base64EncodedString()))
    }

    /// The signed date is rounded to the canonical formatter's precision, so a
    /// value that round-trips through JSON (and CloudKit) still verifies.
    func testSignedDateSurvivesACodableRoundTrip() throws {
        let key = Curve25519.Signing.PrivateKey()
        let save = try WeeklySigning.sign(
            kind: .article, urlString: "https://example.com/a",
            date: Date(timeIntervalSince1970: 1_700_000_000.512_345),
            privateKey: key)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(WeeklySave.self, from: encoder.encode(save))
        XCTAssertEqual(decoded, save)
        XCTAssertTrue(WeeklySigning.verify(decoded, publicKey: key.publicKey))
    }

    func testCanonicalMessageIsStableAndCarriesNoFractionalSeconds() {
        XCTAssertEqual(
            WeeklySave.canonicalMessageString(
                kind: .product, urlString: "https://shop.example/p",
                date: Date(timeIntervalSince1970: 1_700_000_000.75)),
            "product\nhttps://shop.example/p\n2023-11-14T22:13:20Z")
    }

    func testPerAppKindOwnership() {
        XCTAssertEqual(WeeklySaveKind.kinds(for: .luna), [.article, .media, .product])
        XCTAssertEqual(WeeklySaveKind.kinds(for: .reader), [.article])
        XCTAssertEqual(WeeklySaveKind.kinds(for: .downloader), [.media])
        XCTAssertEqual(WeeklySaveKind.kinds(for: .priceTracker), [.product])
        XCTAssertEqual(WeeklySaveKind.article.recordName, "weekly-article")
    }

    func testProposalRecordNameIsTheURLDedup() {
        let first = WeeklyProposal(
            kind: .article, urlString: "  https://example.com/x  ", date: Date())
        let second = WeeklyProposal(
            kind: .media, urlString: "https://example.com/x",
            date: Date().addingTimeInterval(500))
        XCTAssertEqual(first.recordName, second.recordName)
        XCTAssertEqual(first.urlString, "https://example.com/x")
        XCTAssertTrue(first.recordName.hasPrefix("proposal-"))
        XCTAssertEqual(first.recordName.count, "proposal-".count + 32)
        XCTAssertNotEqual(
            first.recordName,
            WeeklyProposal(
                kind: .article, urlString: "https://example.com/y", date: Date()).recordName)
    }

    func testPerAppLabelsRenameTheNounButNotTheTier() {
        XCTAssertEqual(WeeklySaveLabels.subtitle(for: .luna, monthTier: false), "Save of the week")
        XCTAssertEqual(WeeklySaveLabels.subtitle(for: .luna, monthTier: true), "Save of the month")
        XCTAssertEqual(WeeklySaveLabels.subtitle(for: .reader, monthTier: false), "Read of the week")
        XCTAssertEqual(
            WeeklySaveLabels.subtitle(for: .downloader, monthTier: true),
            "Download of the month")
        XCTAssertEqual(
            WeeklySaveLabels.subtitle(for: .priceTracker, monthTier: false), "Deal of the week")
        XCTAssertEqual(
            WeeklySaveLabels.promoteMenuTitle(for: .reader), "Promote to Read of the Week")
        XCTAssertEqual(WeeklySaveLabels.proposeMenuTitle, "Propose Save of the Week")
    }
}

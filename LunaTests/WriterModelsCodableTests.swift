//
//  WriterModelsCodableTests.swift
//  LunaTests
//

import XCTest
import LunaWriterModels

/// Pins the two hand-written `Codable` conformances in `LunaWriterModels`
/// against what actually wins at build time: a protocol extension default
/// and compiler synthesis can both satisfy the same requirement, and only
/// running the coder says which one a given type got.
final class WriterModelsCodableTests: XCTestCase {

    func testDocumentIDCodesAsABareStringNotAKeyedObject() throws {
        let id = DocumentID()
        let data = try JSONEncoder().encode(id)
        let json = String(data: data, encoding: .utf8)
        XCTAssertEqual(json, "\"\(id.rawValue.uuidString)\"",
                        "the protocol extension's coder must win over synthesis, or storage round trips break")
        let decoded = try JSONDecoder().decode(DocumentID.self, from: data)
        XCTAssertEqual(decoded, id)
    }

    func testEveryIdentifierRoundTrips() throws {
        try roundTrip(DocumentID())
        try roundTrip(GroupID())
        try roundTrip(NoteID())
        try roundTrip(AnnotationID())
        try roundTrip(FilterID())
    }

    private func roundTrip<T: WriterIdentifier>(_ id: T) throws {
        let data = try JSONEncoder().encode(id)
        let decoded = try JSONDecoder().decode(T.self, from: data)
        XCTAssertEqual(decoded, id)
    }

    func testAuthorshipSourceRoundTripsEveryCase() throws {
        try roundTrip(AuthorshipSpan.Source.author)
        try roundTrip(AuthorshipSpan.Source.pasted)
        try roundTrip(AuthorshipSpan.Source.ai(model: "gpt-test"))
    }

    private func roundTrip(_ source: AuthorshipSpan.Source) throws {
        let span = AuthorshipSpan(range: TextRange(start: 3, end: 9), source: source, createdAt: Date(timeIntervalSince1970: 0))
        let data = try JSONEncoder().encode(span)
        let decoded = try JSONDecoder().decode(AuthorshipSpan.self, from: data)
        XCTAssertEqual(decoded.source, source)
        XCTAssertEqual(decoded.range, span.range)
    }
}

//
//  SymbolCatalogTests.swift
//  LunaWriterTests
//

import XCTest
@testable import LunaWriterText

final class SymbolCatalogTests: XCTestCase {

    private let catalog = SymbolCatalog.shared

    func testTheNamesWritersTypeFindTheirSymbolFirst() {
        XCTAssertEqual(catalog.search("emdash").first?.character, "—")
        XCTAssertEqual(catalog.search("em dash").first?.character, "—")
        XCTAssertEqual(catalog.search("epsilon").first?.character, "ε")
        XCTAssertEqual(catalog.search("right arrow").first?.character, "→")
        XCTAssertEqual(catalog.search("ellipsis").first?.character, "…")
        XCTAssertEqual(catalog.search("degree").first?.character, "°")
        XCTAssertEqual(catalog.search("copyright").first?.character, "©")
        XCTAssertEqual(catalog.search("not equal").first?.character, "≠")
        XCTAssertEqual(catalog.search("check").first?.character, "✓")
    }

    func testAPartialWordStillRanksTheObviousSymbolNearTheTop() {
        let dash = catalog.search("emd", limit: 8).map(\.character)
        XCTAssertTrue(dash.contains("—"), "\(dash)")
        let pi = catalog.search("pi", limit: 8).map(\.character)
        XCTAssertTrue(pi.contains("π"), "\(pi)")
    }

    func testNonsenseFindsNothingAndTheLimitHolds() {
        XCTAssertTrue(catalog.search("zzqxv").isEmpty)
        XCTAssertTrue(catalog.search("   ").isEmpty)
        XCTAssertEqual(catalog.search("arrow", limit: 4).count, 4)
    }

    func testEverySymbolIsOnePrintableCharacterWithAUniqueName() {
        XCTAssertGreaterThan(catalog.symbols.count, 500)
        var seen = Set<String>()
        for symbol in catalog.symbols {
            XCTAssertEqual(symbol.character.count, 1, symbol.name)
            XCTAssertFalse(symbol.name.isEmpty)
            XCTAssertTrue(seen.insert(symbol.character).inserted, "duplicate \(symbol.name)")
        }
    }
}

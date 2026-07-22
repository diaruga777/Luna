//
//  CoordinatedJSONIndexTests.swift
//  LunaTests
//

import Foundation
import XCTest
@testable import LunaStorage

final class CoordinatedJSONIndexTests: XCTestCase {

    func testOptionalNilResultDoesNotRepeatMutationOutsideCoordination() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "CoordinatedJSONIndexTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let indexURL = directory.appendingPathComponent("index.json")
        var mutationCount = 0
        let result: Int? = coordinatedMutateJSONIndex(
            lock: NSLock(),
            fileCoordinator: NSFileCoordinator(filePresenter: nil),
            indexURL: indexURL,
            load: { _ in [String]() },
            save: { _, _ in },
            body: { index -> Int? in
                mutationCount += 1
                index.append("mutated")
                return nil
            })

        XCTAssertNil(result)
        XCTAssertEqual(mutationCount, 1)
    }
}

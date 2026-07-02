//
//  FilterGuideTests.swift
//  LunaMailAccountTests
//

import XCTest
@testable import LunaMailAccount

final class FilterGuideTests: XCTestCase {

    func testOutlookIsAutomatic() {
        XCTAssertTrue(FilterGuide.isAutomatic(.outlook))
        XCTAssertFalse(FilterGuide.isAutomatic(.gmail))
        XCTAssertFalse(FilterGuide.isAutomatic(.icloud))
        XCTAssertFalse(FilterGuide.isAutomatic(.generic))
    }

    func testInstructionsMentionSubjectMatch() {
        for id in MailProvider.ID.allCases where id != .outlook {
            XCTAssertTrue(FilterGuide.instructions(for: id).contains(FilterGuide.subjectMatch),
                          "\(id) instructions should reference the subject match")
        }
    }

    func testSettingsURLsForConsumerProviders() {
        XCTAssertNotNil(FilterGuide.settingsURL(for: .gmail))
        XCTAssertNotNil(FilterGuide.settingsURL(for: .icloud))
        XCTAssertNotNil(FilterGuide.settingsURL(for: .yahoo))
        XCTAssertNil(FilterGuide.settingsURL(for: .generic))
    }

    func testSieveScriptMatchesSubject() {
        XCTAssertTrue(FilterGuide.sieveScript.contains(FilterGuide.subjectMatch))
        XCTAssertTrue(FilterGuide.sieveScript.contains("fileinto"))
    }
}

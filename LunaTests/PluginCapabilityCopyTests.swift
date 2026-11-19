//
//  PluginCapabilityCopyTests.swift
//  LunaTests
//
//  A cross-artifact pin: every `PluginCapabilityName` case must have a
//  sentence a non-programmer can read, so a capability the consent screen has
//  no words for can never ship silently (`claudedocs/plans/plugin-platform.md`
//  §15).
//

import LunaModels
import LunaPluginKit
import LunaPluginUI
import XCTest

final class PluginCapabilityCopyTests: XCTestCase {

    func testEveryCapabilityHasASentence() {
        for capability in PluginCapabilityName.allCases {
            let sentence = PluginCapabilityCopy.sentence(for: capability)
            XCTAssertFalse(
                sentence.isEmpty, "\(capability.rawValue) has no consent-screen sentence")
            XCTAssertGreaterThan(
                sentence.count, 8,
                "\(capability.rawValue)'s sentence reads as a placeholder, not a real one")
        }
    }

    func testEveryProducedKindHasASentence() {
        for kind in [PluginModelKind.article, .media, .product] {
            XCTAssertFalse(PluginCapabilityCopy.sentence(for: kind).isEmpty)
        }
    }

    func testTheContainmentDisclosureIsFixedAndDoesNotPromiseWhatCannotBeKept() {
        let disclosure = PluginCapabilityCopy.containmentDisclosure
        XCTAssertFalse(disclosure.isEmpty)
        XCTAssertTrue(disclosure.localizedCaseInsensitiveContains("permissions"))
        XCTAssertTrue(disclosure.localizedCaseInsensitiveContains("freeze Luna"))
    }
}

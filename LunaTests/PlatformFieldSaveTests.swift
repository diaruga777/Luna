//
//  PlatformFieldSaveTests.swift
//  LunaTests
//
//  Pure validation-logic coverage (no network): each platform's required-field
//  check should throw `.missingValues` before any search is attempted.
//

import LunaIntents
import LunaModels
import XCTest

final class PlatformFieldSaveTests: XCTestCase {

    private func assertMissingValues(
        platform: ContentPlatform, fields: [String], file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await PlatformFieldSave.save(
                platform: platform, fields: fields, doubleSaveActionSurface: nil)
            XCTFail("Expected missingValues", file: file, line: line)
        } catch PlatformFieldSave.SaveError.missingValues {
            // expected
        } catch {
            XCTFail("Expected missingValues, got \(error)", file: file, line: line)
        }
    }

    func testBlueskyMissingHandleThrows() async {
        await assertMissingValues(platform: .bluesky, fields: [])
        await assertMissingValues(platform: .bluesky, fields: ["", "phrase"])
    }

    func testBlueskyMissingPhraseThrows() async {
        await assertMissingValues(platform: .bluesky, fields: ["handle.bsky.social"])
        await assertMissingValues(platform: .bluesky, fields: ["handle.bsky.social", ""])
    }

    func testRedditMissingSubredditThrows() async {
        await assertMissingValues(platform: .reddit, fields: [])
        await assertMissingValues(platform: .reddit, fields: ["", "title"])
    }

    func testRedditMissingTitleThrows() async {
        await assertMissingValues(platform: .reddit, fields: ["swift"])
        await assertMissingValues(platform: .reddit, fields: ["swift", ""])
    }

    func testSocialPlatformsMissingHandleOrPhraseThrows() async {
        for platform: ContentPlatform in [.x, .tiktok, .instagram, .facebook] {
            await assertMissingValues(platform: platform, fields: [])
            await assertMissingValues(platform: platform, fields: ["handle"])
            await assertMissingValues(platform: platform, fields: ["", "phrase"])
        }
    }
}

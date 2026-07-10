//
//  AudioMiniPlayerTests.swift
//  LunaTests
//
//  Phase-3 audio UI coverage (claudedocs/audio-playback-plan.md): the
//  mini-player bar-mode rule, the tap-to-return nav-stack resolution, the
//  word-event → shared-token-space mapping RSVP speech mode uses, and
//  snapshots of the mini-player bar's states.
//

import LunaAudioPlayback
import LunaReaderUI
import LunaModels
import UIKit
import XCTest
@testable import Luna

final class AudioMiniPlayerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UIView.setAnimationsEnabled(false)
    }

    // MARK: - Bar-mode rule

    func testBarModeHiddenWhileIdle() {
        XCTAssertEqual(AudioMiniPlayerView.barMode(state: .idle, hasMeldAnchor: false), .hidden)
        // Even with a (stale) meld anchor, idle always hides the bar.
        XCTAssertEqual(AudioMiniPlayerView.barMode(state: .idle, hasMeldAnchor: true), .hidden)
    }

    func testBarModeFullForActiveStatesWithoutAnchor() {
        let id = UUID()
        XCTAssertEqual(AudioMiniPlayerView.barMode(state: .playing(itemID: id), hasMeldAnchor: false), .full)
        XCTAssertEqual(AudioMiniPlayerView.barMode(state: .paused(itemID: id), hasMeldAnchor: false), .full)
        XCTAssertEqual(AudioMiniPlayerView.barMode(state: .announcing(nextItemID: id), hasMeldAnchor: false), .full)
    }

    func testBarModeSlimsForMeldAnchor() {
        let id = UUID()
        XCTAssertEqual(AudioMiniPlayerView.barMode(state: .playing(itemID: id), hasMeldAnchor: true), .slim)
        XCTAssertEqual(AudioMiniPlayerView.barMode(state: .paused(itemID: id), hasMeldAnchor: true), .slim)
    }

    // MARK: - Tap-to-return stack resolution

    private struct FakeReader: ReaderItemContaining {
        let itemIDs: Set<UUID>
        func containsReaderItem(withID itemID: UUID) -> Bool { itemIDs.contains(itemID) }
    }

    func testStackIndexFindsTopmostContainingReader() {
        let playing = UUID()
        let stack: [ReaderItemContaining?] = [
            nil,                                    // reading list
            FakeReader(itemIDs: [playing]),         // older reader for the same item
            FakeReader(itemIDs: [UUID()]),          // unrelated reader
            FakeReader(itemIDs: [playing, UUID()]), // topmost match wins
        ]
        XCTAssertEqual(MiniPlayerNavigation.stackIndex(forItemID: playing, stack: stack), 3)
    }

    func testStackIndexNilWhenItemNotOpenAnywhere() {
        let stack: [ReaderItemContaining?] = [nil, FakeReader(itemIDs: [UUID()])]
        XCTAssertNil(MiniPlayerNavigation.stackIndex(forItemID: UUID(), stack: stack))
        XCTAssertNil(MiniPlayerNavigation.stackIndex(forItemID: UUID(), stack: []))
    }

    // MARK: - Word-event → token-index mapping (RSVP speech mode)

    private func makeBlocks() -> [ArticleContent.Block] {
        [
            ArticleContent.Block(kind: .heading, text: "One two", links: []),
            ArticleContent.Block(kind: .image, text: "", links: []),          // no tokens
            ArticleContent.Block(kind: .paragraph, text: "Three  four five", links: []),
            ArticleContent.Block(kind: .paragraph, text: "Six", links: []),
        ]
    }

    func testBlockTokenStartsSkipEmptyBlocks() {
        XCTAssertEqual(
            AudioWordEventTokenMapping.blockTokenStarts(blocks: makeBlocks()),
            [0, 2, 2, 5])
    }

    func testTokenIndexMapsInBlockLocations() {
        let blocks = makeBlocks()
        let starts = AudioWordEventTokenMapping.blockTokenStarts(blocks: blocks)
        // "Three  four five": Three @0, four @7, five @12 (double space).
        XCTAssertEqual(AudioWordEventTokenMapping.tokenIndex(
            blockIndex: 2, utf16Location: 0, blocks: blocks, blockTokenStarts: starts), 2)
        XCTAssertEqual(AudioWordEventTokenMapping.tokenIndex(
            blockIndex: 2, utf16Location: 7, blocks: blocks, blockTokenStarts: starts), 3)
        XCTAssertEqual(AudioWordEventTokenMapping.tokenIndex(
            blockIndex: 2, utf16Location: 12, blocks: blocks, blockTokenStarts: starts), 4)
        // A location mid-word maps to that word's token.
        XCTAssertEqual(AudioWordEventTokenMapping.tokenIndex(
            blockIndex: 2, utf16Location: 9, blocks: blocks, blockTokenStarts: starts), 3)
        // First word of a later block continues the global count.
        XCTAssertEqual(AudioWordEventTokenMapping.tokenIndex(
            blockIndex: 3, utf16Location: 0, blocks: blocks, blockTokenStarts: starts), 5)
        // Heading block, second word.
        XCTAssertEqual(AudioWordEventTokenMapping.tokenIndex(
            blockIndex: 0, utf16Location: 4, blocks: blocks, blockTokenStarts: starts), 1)
        // Out-of-range block index is refused.
        XCTAssertNil(AudioWordEventTokenMapping.tokenIndex(
            blockIndex: 9, utf16Location: 0, blocks: blocks, blockTokenStarts: starts))
    }

    /// The mapping must agree with the CENTER's own word domain (the audio
    /// script's whitespace word count), or highlights would drift.
    func testTokenStartsAgreeWithAudioScriptWordCount() {
        let content = ArticleContent(title: "T", blocks: makeBlocks())
        let script = AudioScript(passthrough: content)
        let starts = AudioWordEventTokenMapping.blockTokenStarts(blocks: content.blocks)
        let lastBlockTokens = content.blocks.last!.text
            .split(whereSeparator: { $0.isWhitespace }).count
        XCTAssertEqual(starts.last! + lastBlockTokens, script.totalWordCount)
    }

    // MARK: - Snapshots

    private func makeBar(_ display: AudioMiniPlayerView.Display, progress: Double,
                         mode: AudioMiniPlayerView.BarMode = .full) -> AudioMiniPlayerView {
        let bar = AudioMiniPlayerView()
        bar.setMode(mode)
        bar.apply(display)
        bar.setProgress(progress, animated: false)
        return bar
    }

    func testMiniPlayerPlayingSnapshot() {
        let bar = makeBar(
            .init(title: "The Quiet Miracle of Ordinary Mornings", isUpNext: false,
                  thumbnailPath: nil, isPlaying: true, rate: 1.0, isAutoplayOn: true),
            progress: 0.42)
        SnapshotTesting.assertSnapshot(
            of: bar, named: "mini-player-playing",
            size: CGSize(width: 373, height: AudioMiniPlayerView.fullHeight))
    }

    func testMiniPlayerPausedSnapshot() {
        let bar = makeBar(
            .init(title: "A Field Guide to Slow Reading", isUpNext: false,
                  thumbnailPath: nil, isPlaying: false, rate: 1.5, isAutoplayOn: false),
            progress: 0.8)
        SnapshotTesting.assertSnapshot(
            of: bar, named: "mini-player-paused",
            size: CGSize(width: 373, height: AudioMiniPlayerView.fullHeight))
    }

    func testMiniPlayerAnnouncingSnapshot() {
        let bar = makeBar(
            .init(title: "Why Cities Sound Different at Night", isUpNext: true,
                  thumbnailPath: nil, isPlaying: true, rate: 1.0, isAutoplayOn: true),
            progress: 0)
        SnapshotTesting.assertSnapshot(
            of: bar, named: "mini-player-announcing",
            size: CGSize(width: 373, height: AudioMiniPlayerView.fullHeight))
    }

    func testMiniPlayerSlimSnapshot() {
        let bar = makeBar(
            .init(title: "The Quiet Miracle of Ordinary Mornings", isUpNext: false,
                  thumbnailPath: nil, isPlaying: true, rate: 1.0, isAutoplayOn: true),
            progress: 0.42, mode: .slim)
        SnapshotTesting.assertSnapshot(
            of: bar, named: "mini-player-slim",
            size: CGSize(width: 300, height: AudioMiniPlayerView.slimHeight))
    }
}

//
//  RSVPAudioWordSyncTests.swift
//  LunaTests
//
//  The shared "audio-center word event -> RSVP frame" sequence both
//  RSVPViewController and LinkRSVPPreview apply in their AudioPlaybackObserver
//  conformances.
//

import LunaAudioPlayback
import LunaModels
import LunaReaderEngine
import LunaReaderUI
import XCTest

final class RSVPAudioWordSyncTests: XCTestCase {
    private func content(_ paragraphs: [String]) -> ArticleContent {
        ArticleContent(title: "T", blocks: paragraphs.map { .init(kind: .paragraph, text: $0, links: []) })
    }

    func testFrameIndexMapsAWordEventToTheCorrespondingFrame() {
        let content = content(["One two three.", "Four five"])
        let engine = RSVPEngine(content: content)
        let blockTokenStarts = AudioWordEventTokenMapping.blockTokenStarts(blocks: content.blocks)

        // Block 1 ("Four five"), UTF-16 location 5 -> "five" -> global token 4.
        let event = AudioWordEvent(blockIndex: 1, rangeInBlockText: NSRange(location: 5, length: 4))
        let frame = RSVPAudioWordSync.frameIndex(
            for: event, blocks: content.blocks, blockTokenStarts: blockTokenStarts, engine: engine)
        XCTAssertEqual(frame, 4)
        XCTAssertEqual(engine.words[frame!].text, "five")
    }

    func testFrameIndexIsNilForAnOutOfRangeBlock() {
        let content = content(["One two"])
        let engine = RSVPEngine(content: content)
        let blockTokenStarts = AudioWordEventTokenMapping.blockTokenStarts(blocks: content.blocks)
        let event = AudioWordEvent(blockIndex: 5, rangeInBlockText: NSRange(location: 0, length: 3))
        XCTAssertNil(RSVPAudioWordSync.frameIndex(
            for: event, blocks: content.blocks, blockTokenStarts: blockTokenStarts, engine: engine))
    }

    /// A long word split into several RSVP frames maps to the FIRST frame of
    /// its token (`RSVPEngine.frameIndex(forTokenIndex:)`'s contract).
    func testFrameIndexLandsOnFirstFrameOfASplitLongWord() {
        let content = content(["pneumonoultramicroscopic ok"])
        let engine = RSVPEngine(content: content, maxCharactersPerWord: 10)
        let blockTokenStarts = AudioWordEventTokenMapping.blockTokenStarts(blocks: content.blocks)
        let event = AudioWordEvent(blockIndex: 0, rangeInBlockText: NSRange(location: 0, length: 24))
        let frame = RSVPAudioWordSync.frameIndex(
            for: event, blocks: content.blocks, blockTokenStarts: blockTokenStarts, engine: engine)
        XCTAssertEqual(frame, engine.firstFrameIndexByToken[0])
    }
}

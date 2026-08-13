//
//  ReaderAudioLauncher.swift
//  LunaReaderUI
//
//  The in-app / extension seam for read-aloud playback (Phase 3 of
//  claudedocs/audio-playback-plan.md).
//
//  The APP SHELL installs `ReaderAudioLauncher.center` once at launch
//  (`AudioPlaybackWiring.install()` in AppDelegate — the same injected-
//  composition pattern as `SendToFriendSheet.accountSetupPresenter`). When it is
//  installed, the shared readers (`ScrollReaderViewController`,
//  `RSVPViewController`) hand read-aloud off to the app-wide
//  `AudioPlaybackCenter` (background playback, autoplay, the window-level
//  mini-player). When it is nil — the share/action extensions, which link
//  this module but must never gain background-audio machinery — the readers
//  keep the legacy self-contained `SpeechController` path exactly as before.
//
//  Nothing in this module may touch `AudioPlaybackCenter.shared` directly:
//  every access goes through `ReaderAudioLauncher.center`, so an extension
//  process never even instantiates the center (whose init starts an
//  AVAudioSession coordinator).
//

import LunaAudioPlayback
import LunaModels
import LunaReaderEngine
import Foundation
import UIKit

public enum ReaderAudioLauncher {

    /// The app-wide playback center, installed by the app shell at launch;
    /// nil in the share/action extensions (→ legacy SpeechController path).
    public static var center: AudioPlaybackCenter?

    /// Pauses the center iff it currently owns `itemID`'s playback — the
    /// readers' "audio toggled off" hook. Deliberately narrow: it can never
    /// pause audio belonging to a DIFFERENT article (browsing another article
    /// must not disturb playback).
    public static func pauseIfPlaying(itemID: UUID) {
        guard let center, center.currentItemInfo?.itemID == itemID else { return }
        switch center.state {
        case .playing, .announcing: center.pause()
        case .idle, .paused: break
        }
    }
}

// MARK: - RSVP meld anchor

/// How the window-level mini-player learns that the RSVP reader is frontmost
/// in (center-driven) speech mode, so it can slim down and dock directly above
/// RSVP's circular controls instead of floating over them. `RSVPViewController`
/// publishes its `controlsStack` here while that state holds; the mini-player
/// host observes `didChangeNotification` AND re-validates the anchor's actual
/// visibility (window + effective hiddenness) on its own update ticks — the
/// RabbitHole host shows/hides its pre-built reader children without
/// appearance callbacks, so a stale anchor must fail the visibility check
/// rather than rely on a clearing call.
public enum AudioMiniPlayerMeld {

    public static let didChangeNotification = Notification.Name("AudioMiniPlayerMeldDidChange")

    public private(set) static weak var anchorView: UIView?

    public static func setAnchor(_ view: UIView?) {
        guard view !== anchorView else { return }
        anchorView = view
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    /// The anchor, only if it is genuinely on screen: in a window and not
    /// hidden anywhere up its superview chain.
    public static var visibleAnchorView: UIView? {
        guard let anchor = anchorView, anchor.window != nil else { return nil }
        var view: UIView? = anchor
        while let current = view {
            if current.isHidden || current.alpha < 0.01 { return nil }
            view = current.superview
        }
        return anchor
    }
}

// MARK: - Word-event → token-index mapping

/// Pure mapping from the center's `AudioWordEvent` domain — (original block
/// index, UTF-16 range within that block's text) — into the shared token-index
/// space `RSVPEngine`/`WordMap` use (whitespace-delimited tokens counted
/// across the article's blocks in order). Used by RSVP's speech mode to flash
/// the word the center is voicing. Unit-tested in `AudioReaderRerouteTests`.
public enum AudioWordEventTokenMapping {

    /// The global token index at the START of each block of `blocks`
    /// (a parallel array — empty-text blocks contribute zero tokens,
    /// mirroring `RSVPEngine`'s tokenizer and the audio script's word count).
    public static func blockTokenStarts(blocks: [ArticleContent.Block]) -> [Int] {
        var starts: [Int] = []
        starts.reserveCapacity(blocks.count)
        var running = 0
        for block in blocks {
            starts.append(running)
            running += AudioWordIndexing.wordCount(in: block.text)
        }
        return starts
    }

    /// The global token index for a word event: the tokens of every block
    /// before `blockIndex`, plus the 0-based offset of the token containing
    /// `utf16Location` within that block's text. Nil when `blockIndex` is out
    /// of range.
    public static func tokenIndex(
        blockIndex: Int, utf16Location: Int,
        blocks: [ArticleContent.Block], blockTokenStarts: [Int]
    ) -> Int? {
        guard blocks.indices.contains(blockIndex),
              blockTokenStarts.indices.contains(blockIndex) else { return nil }
        let text = blocks[blockIndex].text
        let wordStarts = AudioWordIndexing.wordStartUTF16Offsets(in: text)
        let offset = AudioWordIndexing.wordOffset(forUTF16Location: utf16Location, wordStartOffsets: wordStarts)
        return blockTokenStarts[blockIndex] + offset
    }
}

/// The shared "audio-center word event → RSVP frame" sequence applied by
/// both the full reader's and the link preview's `AudioPlaybackObserver`
/// conformances: the event's (block index, in-block UTF-16 location) maps to
/// the shared token space via `AudioWordEventTokenMapping`, then into the
/// engine's frame space (a word can occupy several frames when its token was
/// long-word-split) via `RSVPEngine.frameIndex(forTokenIndex:)`.
public enum RSVPAudioWordSync {
    public static func frameIndex(
        for event: AudioWordEvent,
        blocks: [ArticleContent.Block],
        blockTokenStarts: [Int],
        engine: RSVPEngine
    ) -> Int? {
        guard let token = AudioWordEventTokenMapping.tokenIndex(
            blockIndex: event.blockIndex, utf16Location: event.rangeInBlockText.location,
            blocks: blocks, blockTokenStarts: blockTokenStarts)
        else { return nil }
        return engine.frameIndex(forTokenIndex: token)
    }
}

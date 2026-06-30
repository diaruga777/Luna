//
//  SpeechController.swift
//  Lune
//

import LuneReaderEngine
import LuneModels
import AVFoundation
import MediaPlayer
import UIKit

/// Receives word-level progress and state changes from read-aloud playback.
public protocol SpeechControllerDelegate: AnyObject {
    /// The synthesizer is about to speak the word at `range` in the rendered
    /// attributed string (`wordIndex` in the shared word-index space).
    func speech(_ controller: SpeechController, willSpeakAttributedRange range: NSRange, wordIndex: Int?)
    /// Play/pause state changed (including via system media controls).
    func speechPlaybackStateDidChange(_ controller: SpeechController)
    /// The whole article finished.
    func speechDidFinishArticle(_ controller: SpeechController)
}

/// On-device read-aloud for an article using AVSpeechSynthesizer: speaks block
/// by block, reports word ranges for highlighting, supports skip/rate, keeps
/// playing in the background, and integrates with system media controls.
public final class SpeechController: NSObject {

    public weak var delegate: SpeechControllerDelegate?

    private let synthesizer = AVSpeechSynthesizer()
    /// The TTS engine to speak with. Resolved at `play(fromWordIndex:)` time from
    /// the user's selection, falling back to a usable engine if the selected one
    /// isn't currently available (model missing / no enhanced voice installed).
    /// Every engine drives this same `AVSpeechSynthesizer`, so word-range
    /// highlighting works identically regardless of engine.
    private var engine: SpeechEngine = BasicSpeechEngine()
    /// Speakable blocks: original block index + text.
    private let speakable: [(blockIndex: Int, text: String)]
    private let blockTextRanges: [NSRange?]
    private let wordMap: WordMap
    private let nowPlayingTitle: String

    private(set) var isPlaying = false
    private var isPausedMidUtterance = false
    private var speakableIndex = 0
    /// UTF-16 offset within the current block where the current utterance starts.
    private var utteranceStartOffset = 0
    private var lastSpokenAttributedRange: NSRange?

    /// Speed multiplier over the default speech rate.
    private(set) var rateFactor: Float = 1.0

    public init(content: ArticleContent, rendered: RenderedArticle, wordMap: WordMap, title: String) {
        self.speakable = content.blocks.enumerated()
            .filter { !$0.element.text.isEmpty }
            .map { (blockIndex: $0.offset, text: $0.element.text) }
        self.blockTextRanges = rendered.blockTextRanges
        self.wordMap = wordMap
        self.nowPlayingTitle = title
        super.init()
        synthesizer.delegate = self
    }

    deinit {
        teardownRemoteCommands()
    }

    // MARK: - Public controls

    public var currentWordIndex: Int? {
        lastSpokenAttributedRange.flatMap { wordMap.wordIndex(nearCharacterIndex: $0.location) }
    }

    public func play(fromWordIndex wordIndex: Int?) {
        // Resolve the engine once per play session (the selection can change in
        // Settings between sessions). `resolveSelected` guarantees a usable
        // engine, falling back from an unavailable selection.
        engine = SpeechEngineFactory.resolveSelected()
        configureAudioSession()
        setupRemoteCommands()
        synthesizer.stopSpeaking(at: .immediate)
        isPausedMidUtterance = false

        if let wordIndex,
           let attrRange = wordMap.attributedRange(forWord: wordIndex),
           let position = blockPosition(forAttributedLocation: attrRange.location) {
            speakableIndex = position.speakableIndex
            utteranceStartOffset = position.offsetInBlock
        } else {
            speakableIndex = 0
            utteranceStartOffset = 0
        }
        isPlaying = true
        speakCurrent()
        updateNowPlaying()
        delegate?.speechPlaybackStateDidChange(self)
    }

    public func togglePlayPause() {
        if isPlaying {
            pause()
        } else if isPausedMidUtterance {
            resume()
        } else {
            play(fromWordIndex: currentWordIndex)
        }
    }

    public func pause() {
        guard isPlaying else { return }
        isPlaying = false
        isPausedMidUtterance = true
        synthesizer.pauseSpeaking(at: .word)
        // Yield the audio session so interrupted audio (e.g. Picture-in-Picture
        // video) resumes while we're paused; `resume()` reactivates it.
        ReaderAudioSession.deactivate()
        updateNowPlaying()
        delegate?.speechPlaybackStateDidChange(self)
    }

    public func resume() {
        guard !isPlaying, isPausedMidUtterance else { return }
        isPlaying = true
        isPausedMidUtterance = false
        configureAudioSession()
        synthesizer.continueSpeaking()
        updateNowPlaying()
        delegate?.speechPlaybackStateDidChange(self)
    }

    /// Jumps to the start of the next paragraph.
    public func skipForward() {
        guard speakableIndex + 1 < speakable.count else { return }
        jump(toSpeakableIndex: speakableIndex + 1)
    }

    /// Jumps to the start of the current paragraph, or the previous one when
    /// already at its start.
    public func skipBackward() {
        let target = utteranceStartOffset > 0 || lastSpokenAttributedRange != nil
            ? speakableIndex
            : max(0, speakableIndex - 1)
        jump(toSpeakableIndex: utteranceStartOffset == 0 && target == speakableIndex
            ? max(0, speakableIndex - 1) : target)
    }

    public func cycleRate() {
        let steps: [Float] = [0.8, 1.0, 1.2, 1.5]
        let next = steps[((steps.firstIndex(of: rateFactor) ?? 1) + 1) % steps.count]
        rateFactor = next
        if isPlaying || isPausedMidUtterance {
            // Rate applies per-utterance: restart the current word's block tail.
            let resumeOffset = lastSpokenAttributedRange
                .flatMap { blockPosition(forAttributedLocation: $0.location) }
            synthesizer.stopSpeaking(at: .immediate)
            isPausedMidUtterance = false
            if let resumeOffset {
                speakableIndex = resumeOffset.speakableIndex
                utteranceStartOffset = resumeOffset.offsetInBlock
            }
            if isPlaying {
                speakCurrent()
            }
        }
        delegate?.speechPlaybackStateDidChange(self)
    }

    public func stop() {
        isPlaying = false
        isPausedMidUtterance = false
        synthesizer.stopSpeaking(at: .immediate)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        teardownRemoteCommands()
        ReaderAudioSession.deactivate()
        delegate?.speechPlaybackStateDidChange(self)
    }

    // MARK: - Speaking

    private func jump(toSpeakableIndex index: Int) {
        synthesizer.stopSpeaking(at: .immediate)
        isPausedMidUtterance = false
        speakableIndex = min(max(0, index), max(0, speakable.count - 1))
        utteranceStartOffset = 0
        if isPlaying {
            speakCurrent()
        }
    }

    private func speakCurrent() {
        guard let block = speakable[safe: speakableIndex] else {
            isPlaying = false
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            delegate?.speechDidFinishArticle(self)
            delegate?.speechPlaybackStateDidChange(self)
            return
        }
        let blockText = block.text as NSString
        let startOffset = min(utteranceStartOffset, blockText.length)
        let remaining = blockText.substring(from: startOffset)
        guard !remaining.trimmingCharacters(in: .whitespaces).isEmpty else {
            utteranceStartOffset = 0
            speakableIndex += 1
            speakCurrent()
            return
        }
        let utterance = AVSpeechUtterance(string: remaining)
        let rate = min(AVSpeechUtteranceDefaultSpeechRate * rateFactor, AVSpeechUtteranceMaximumSpeechRate)
        engine.configure(utterance, rate: rate)
        utterance.postUtteranceDelay = 0.25
        synthesizer.speak(utterance)
    }

    /// Maps an attributed-string location back to a speakable block + offset.
    private func blockPosition(
        forAttributedLocation location: Int
    ) -> (speakableIndex: Int, offsetInBlock: Int)? {
        for (index, block) in speakable.enumerated() {
            guard let range = blockTextRanges[safe: block.blockIndex] ?? nil else { continue }
            if location < range.location + range.length {
                return (index, max(0, location - range.location))
            }
        }
        return nil
    }

    // MARK: - Audio session & media controls

    private func configureAudioSession() {
        ReaderAudioSession.activate()
    }

    private func setupRemoteCommands() {
        // Clear any prior targets first — `play()` calls this each time, and the
        // command center is a shared singleton, so without this a play/pause/play
        // cycle would stack duplicate handlers and fire each one repeatedly.
        teardownRemoteCommands()
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            self?.resume(); return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.pause(); return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause(); return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.skipForward(); return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.skipBackward(); return .success
        }
    }

    private func teardownRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
    }

    private func updateNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: nowPlayingTitle,
            MPMediaItemPropertyArtist: "Lune",
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
    }
}

extension SpeechController: AVSpeechSynthesizerDelegate {
    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        guard let block = speakable[safe: speakableIndex],
              let blockRange = blockTextRanges[safe: block.blockIndex] ?? nil else { return }
        let attributedRange = NSRange(
            location: blockRange.location + utteranceStartOffset + characterRange.location,
            length: characterRange.length)
        lastSpokenAttributedRange = attributedRange
        let wordIndex = wordMap.wordIndex(nearCharacterIndex: attributedRange.location)
        delegate?.speech(self, willSpeakAttributedRange: attributedRange, wordIndex: wordIndex)
    }

    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
    ) {
        guard isPlaying else { return }
        utteranceStartOffset = 0
        speakableIndex += 1
        speakCurrent()
    }
}

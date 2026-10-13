//
//  SpeechRenderer.swift
//  LunaAudioPlayback
//

import AVFoundation

/// One word-level timing marker captured during offline synthesis of a block.
///
/// Word markers are strictly OPTIONAL: a `RenderedSegment` with an empty
/// `wordMarkers` array is still fully playable — callers fall back to
/// block-level granularity (resume/highlight per block, not per word). See the
/// spike finding documented on `SpeechRenderer.render(_:)` below for why this
/// matters on the simulator.
public struct WordMarker: Equatable {
    /// Character range within the utterance's speech string (UTF-16), exactly
    /// as reported by `AVSpeechSynthesizerDelegate
    /// .speechSynthesizer(_:willSpeakRangeOfSpeechString:utterance:)`.
    public var utteranceRange: NSRange
    /// Sample offset — in `RenderedSegment.format`'s sample rate — within this
    /// segment's rendered audio where this word begins.
    public var sampleOffset: AVAudioFramePosition

    public init(utteranceRange: NSRange, sampleOffset: AVAudioFramePosition) {
        self.utteranceRange = utteranceRange
        self.sampleOffset = sampleOffset
    }
}

/// The offline-rendered audio for one `AudioScript.SpokenBlock`: PCM buffers
/// (already normalized to `format`), any word markers captured along the way,
/// and the segment's total duration. `ArticleAudioEngine` schedules these
/// sequentially; it never synthesizes anything itself.
public struct RenderedSegment: Equatable {
    public var blockIndex: Int
    public var buffers: [AVAudioPCMBuffer]
    public var wordMarkers: [WordMarker]
    public var duration: TimeInterval
    public var format: AVAudioFormat

    public init(
        blockIndex: Int, buffers: [AVAudioPCMBuffer], wordMarkers: [WordMarker],
        duration: TimeInterval, format: AVAudioFormat
    ) {
        self.blockIndex = blockIndex
        self.buffers = buffers
        self.wordMarkers = wordMarkers
        self.duration = duration
        self.format = format
    }
}

/// Offline speech synthesis, one `AudioScript.SpokenBlock` at a time, via
/// `AVSpeechSynthesizer.write(_:toBufferCallback:)` — never live `speak()`
/// (which is documented to stall/cut off in the background; see
/// `claudedocs/audio-playback-plan.md`).
///
/// Renders always happen at the utterance's natural/default rate.
/// User-selected playback speed is applied downstream by
/// `ArticleAudioEngine`'s time-pitch unit, never by re-synthesizing at a
/// different rate — so there's no separate "announcement" render path either:
/// announcements are ordinary renders, and it's `ArticleAudioEngine` that pins
/// its time-pitch rate to 1.0 while an announcement segment is actually
/// playing (see `ArticleAudioEngine.schedule(_:rateMode:completion:)`).
///
/// One render is in flight at a time by design (callers `await` sequentially);
/// `active` below enforces that at the type level.
public final class SpeechRenderer: NSObject {

    public enum RenderError: Error, Equatable {
        /// `write()` produced no callback (buffer or delegate) at all within
        /// `renderTimeout`. Safety net for the simulator's documented
        /// quirk where voice assets can silently fail to render at all —
        /// see the SPIKE comment on `render(_:)`.
        case timedOut
        case formatCreationFailed
        case conversionFailed
    }

    /// Wall-clock budget for one block's offline synthesis before giving up.
    /// Generous: real paragraphs render in well under a second of wall time.
    /// This only guards against the simulator stalling entirely.
    public var renderTimeout: TimeInterval = 15

    /// Canonical output format every `RenderedSegment.buffers` element is
    /// normalized to (float32, deinterleaved), established from the very first
    /// buffer this renderer instance ever receives. `nil` until the first
    /// successful, non-empty render — see `normalize(_:blockIndex:)`.
    public private(set) var canonicalFormat: AVAudioFormat?

    // Wiring read-aloud at launch must not start the speech service. Create it
    // only for the first render, serialized with the renderer's existing lock.
    private var synthesizer: AVSpeechSynthesizer?
    private let stateLock = NSLock()
    private var active: ActiveRender?

    public override init() {
        super.init()
    }

    // MARK: - Rendering

    /// SPIKE FINDING (confirmed empirically, iPhone 17 Pro / iOS 26.2
    /// simulator, `SpeechRendererSpikeTests.testWillSpeakRangeFiresDuringWrite`):
    /// YES — `speechSynthesizer(_:willSpeakRangeOfSpeechString:utterance:)` DOES
    /// fire during `write()`, interleaved with the buffer callback, the same as
    /// it does during live `speak()`. On this simulator/OS combination both the
    /// audio buffers and the word markers came through non-empty on every run.
    ///
    /// That said, this is exactly why every marker here stays OPTIONAL and
    /// every layer above must still treat a zero-marker (or zero-buffer)
    /// segment as valid, just less precise (block-level resume/highlighting
    /// granularity, not word-level): the spike test itself `XCTSkip`s with a
    /// clear message rather than failing if some *other* simulator/OS
    /// combination silently produces zero buffers/callbacks — the known quirk
    /// documented on `AudioVoiceResolution` is that voice asset rendering can
    /// no-op on *some* simulators, and there's no guarantee every future
    /// OS/device pairing behaves like the one this was verified on.
    public func render(_ block: AudioScript.SpokenBlock) async throws -> RenderedSegment {
        let utterance = AVSpeechUtterance(string: block.text)
        utterance.voice = AudioVoiceResolution.resolveBestVoice()
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate

        let raw = try await withThrowingTaskGroup(of: RawRender.self) { group -> RawRender in
            group.addTask { try await self.performWrite(utterance) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(self.renderTimeout * 1_000_000_000))
                // The abandoned `write()` call keeps running in the background
                // (there's no API to cancel it); clear `active` so any
                // straggler buffer/delegate callbacks it produces after this
                // point are silently dropped by `handle(buffer:)` instead of
                // corrupting whatever render() call comes next.
                self.clearActiveAfterTimeout()
                throw RenderError.timedOut
            }
            guard let first = try await group.next() else { throw RenderError.timedOut }
            group.cancelAll()
            return first
        }

        return try normalize(raw, blockIndex: block.blockIndex)
    }

    private func performWrite(_ utterance: AVSpeechUtterance) async throws -> RawRender {
        try await withCheckedThrowingContinuation { continuation in
            let render = ActiveRender(continuation: continuation)
            stateLock.lock()
            let synthesizer: AVSpeechSynthesizer
            if let existing = self.synthesizer {
                synthesizer = existing
            } else {
                synthesizer = AVSpeechSynthesizer()
                synthesizer.delegate = self
                self.synthesizer = synthesizer
            }
            active = render
            stateLock.unlock()
            synthesizer.write(utterance) { [weak self] buffer in
                self?.handle(buffer: buffer)
            }
        }
    }

    private func clearActiveAfterTimeout() {
        stateLock.lock()
        active = nil
        stateLock.unlock()
    }

    private func handle(buffer: AVAudioBuffer) {
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        stateLock.lock()
        guard let render = active else { stateLock.unlock(); return }
        if pcm.frameLength == 0 {
            // `write`'s documented end-of-utterance sentinel: a final buffer
            // with zero frames signals there is no more audio for this
            // utterance.
            active = nil
            stateLock.unlock()
            render.continuation.resume(returning: RawRender(
                buffers: render.buffers, ranges: render.ranges, nativeFormat: render.nativeFormat))
            return
        }
        if render.nativeFormat == nil { render.nativeFormat = pcm.format }
        render.buffers.append(pcm)
        render.framesSoFar += AVAudioFramePosition(pcm.frameLength)
        stateLock.unlock()
    }

    // MARK: - Normalization

    private static let fallbackFormat = AVAudioFormat(standardFormatWithSampleRate: 22050, channels: 1)!

    /// Converts every raw buffer to `canonicalFormat` (establishing it from
    /// `raw.nativeFormat` on the first call) and rescales word-marker sample
    /// offsets from native to canonical sample time.
    private func normalize(_ raw: RawRender, blockIndex: Int) throws -> RenderedSegment {
        guard let nativeFormat = raw.nativeFormat, !raw.buffers.isEmpty else {
            // Empty synthesis (the simulator quirk above, or a genuinely empty
            // block). Still a valid, playable-nothing segment: the engine and
            // everything above it must treat a zero-buffer segment as
            // instant/skippable, never as an error.
            return RenderedSegment(
                blockIndex: blockIndex, buffers: [], wordMarkers: [],
                duration: 0, format: canonicalFormat ?? Self.fallbackFormat)
        }

        let target: AVAudioFormat
        if let canonicalFormat {
            target = canonicalFormat
        } else {
            guard let created = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: nativeFormat.sampleRate,
                channels: nativeFormat.channelCount, interleaved: false
            ) else { throw RenderError.formatCreationFailed }
            canonicalFormat = created
            target = created
        }

        let ratio = target.sampleRate / nativeFormat.sampleRate
        let converted: [AVAudioPCMBuffer]
        do {
            converted = try AudioFormatConversion.convert(raw.buffers, from: nativeFormat, to: target)
        } catch {
            throw RenderError.conversionFailed
        }
        let totalFrames = converted.reduce(AVAudioFramePosition(0)) { $0 + AVAudioFramePosition($1.frameLength) }

        let markers = Self.makeWordMarkers(from: raw.ranges, sampleRateRatio: ratio)

        return RenderedSegment(
            blockIndex: blockIndex, buffers: converted, wordMarkers: markers,
            duration: Double(totalFrames) / target.sampleRate, format: target)
    }

    /// Pure mapping from captured (character range, native-sample-offset-at-
    /// callback-time) pairs to `WordMarker`s rescaled into the canonical
    /// sample-rate space. Factored out (not inlined into `normalize`) so it's
    /// unit-testable with synthetic data, independent of real speech
    /// synthesis — see the fake-data marker-mapping tests in `LunaTests`.
    static func makeWordMarkers(
        from ranges: [(range: NSRange, nativeFrameOffset: AVAudioFramePosition)],
        sampleRateRatio ratio: Double
    ) -> [WordMarker] {
        ranges.map { entry in
            WordMarker(
                utteranceRange: entry.range,
                sampleOffset: AVAudioFramePosition((Double(entry.nativeFrameOffset) * ratio).rounded()))
        }
    }

    // MARK: - Internal render state

    private final class ActiveRender {
        let continuation: CheckedContinuation<RawRender, Error>
        var buffers: [AVAudioPCMBuffer] = []
        var ranges: [(range: NSRange, nativeFrameOffset: AVAudioFramePosition)] = []
        var nativeFormat: AVAudioFormat?
        var framesSoFar: AVAudioFramePosition = 0

        init(continuation: CheckedContinuation<RawRender, Error>) {
            self.continuation = continuation
        }
    }

    private struct RawRender {
        var buffers: [AVAudioPCMBuffer]
        var ranges: [(range: NSRange, nativeFrameOffset: AVAudioFramePosition)]
        var nativeFormat: AVAudioFormat?
    }
}

extension SpeechRenderer: AVSpeechSynthesizerDelegate {
    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let render = active else { return }
        render.ranges.append((range: characterRange, nativeFrameOffset: render.framesSoFar))
    }
}

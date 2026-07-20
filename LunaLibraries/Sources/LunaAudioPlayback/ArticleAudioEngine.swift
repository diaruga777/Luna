//
//  ArticleAudioEngine.swift
//  LunaAudioPlayback
//

import AVFoundation

/// How a scheduled segment's playback rate relates to the engine's current
/// user-selected `rate`.
public enum SegmentRateMode: Sendable {
    /// Plays at whatever `rate` (the time-pitch unit's rate) currently is, and
    /// keeps tracking live changes to it — the normal case for article body
    /// segments.
    case followsUserRate
    /// Pinned to natural (1.0×) for exactly the span this segment is actually
    /// heard, regardless of `rate` — used for autoplay announcements ("Now
    /// Reading — <title>"), which always speak at 1.0× per the product
    /// decision in `claudedocs/audio-playback-plan.md`. The engine restores
    /// the prior `rate` the instant this segment's last buffer has been heard.
    case pinnedToNatural
}

public enum ArticleAudioEngineError: Error, Equatable {
    case engineStartFailed
    case manualRenderingNotEnabled
    case manualRenderingFailed
}

/// The long-lived playback graph: `AVAudioPlayerNode` -> `AVAudioUnitTimePitch`
/// -> `mainMixerNode`. Deliberately dumb — it has no idea what an article or a
/// queue is: buffers (from `SpeechRenderer`) and tones (from `ToneLibrary`) go
/// in via `schedule`/`scheduleTone`, audio comes out, and it exposes a
/// sample-accurate playhead plus a low-water-mark signal so a higher layer
/// (Phase 2's `AudioPlaybackCenter`) knows when to render more. It does not
/// touch `AVAudioSession` beyond what's needed to run in tests, and it does
/// not observe interruptions/route changes — that's session-policy work for
/// Phase 2.
///
/// User-selected playback speed is `timePitch.rate`: rendered audio is never
/// re-synthesized when the user changes speed, only re-pitched/re-timed in
/// place by this node.
public final class ArticleAudioEngine {

    /// The format every scheduled buffer (segments and tones) must already be
    /// in — normally `SpeechRenderer.canonicalFormat`. Connecting the graph
    /// with this format up front means no per-buffer format surprises.
    public let format: AVAudioFormat

    /// User-selected playback speed multiplier (`AVAudioUnitTimePitch.rate`).
    /// Changing it re-times/re-pitches whatever is currently flowing through
    /// the node graph in real time; it does not affect buffers already
    /// rendered or already played.
    public var rate: Float {
        get { timePitch.rate }
        set { timePitch.rate = newValue }
    }

    /// Below this many seconds of scheduled-but-not-yet-consumed audio,
    /// `needsMoreAudioHandler` fires once (until more is scheduled). Phase 2
    /// wires this to "render the next block and schedule it".
    public var lowWaterMark: TimeInterval = 12

    /// Invoked (on the main queue) when queued audio drops below
    /// `lowWaterMark`. Fires at most once per drop below the mark — scheduling
    /// more audio resets the latch.
    public var needsMoreAudioHandler: (() -> Void)?

    public var isPlaying: Bool { playerNode.isPlaying }

    /// Elapsed playback time, in seconds, accounting for every
    /// `resetAndSchedule(from:)` rebase. Sample-accurate: derived from the
    /// player node's own render clock (`lastRenderTime`/`playerTime`), not from
    /// synthesis or scheduling callbacks. Pausing does not reset this — only
    /// `resetAndSchedule(from:)` (an explicit seek) rebases it; ordinary
    /// `pause()`/`play()` leave the player node's render clock running in
    /// place, which is exactly what makes elapsed time keep meaning across a
    /// pause/resume.
    public var currentTime: TimeInterval {
        guard let nodeTime = playerNode.lastRenderTime, nodeTime.isSampleTimeValid,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime), playerTime.isSampleTimeValid
        else { return Double(baseFrameOffset) / format.sampleRate }
        return Double(baseFrameOffset + playerTime.sampleTime) / format.sampleRate
    }

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()

    private var baseFrameOffset: AVAudioFramePosition = 0
    private var queuedDuration: TimeInterval = 0
    private var hasSignaledLowWater = false
    private var toneBuffers: [ToneAsset: AVAudioPCMBuffer] = [:]

    /// - Parameter manualRendering: when `true`, the engine runs in
    ///   `AVAudioEngine`'s offline manual-rendering mode instead of driving
    ///   real hardware output. Test-only — see `renderOffline(maxFrames:)`.
    public init(format: AVAudioFormat, manualRendering: Bool = false) throws {
        self.format = format
        engine.attach(playerNode)
        engine.attach(timePitch)
        engine.connect(playerNode, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        if manualRendering {
            do {
                try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
            } catch {
                throw ArticleAudioEngineError.engineStartFailed
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw ArticleAudioEngineError.engineStartFailed
        }
        playerNode.play()
    }

    deinit {
        if engine.isRunning { engine.stop() }
    }

    // MARK: - Transport

    public func play() { playerNode.play() }

    public func pause() { playerNode.pause() }

    /// Seek primitive: stops the node (clearing every buffer queued on it),
    /// rebases the playhead to `time`, and leaves the node running so
    /// subsequently scheduled buffers play immediately. Word-index-based seek
    /// logic (mapping a seek target to which segment/buffer to re-render and
    /// schedule) is Phase 2's job — this just provides the clock rebase.
    public func resetAndSchedule(from time: TimeInterval) {
        playerNode.stop()
        baseFrameOffset = AVAudioFramePosition((time * format.sampleRate).rounded())
        queuedDuration = 0
        hasSignaledLowWater = false
        playerNode.play()
    }

    // MARK: - Scheduling

    /// The completion type used for the LAST buffer of a schedule (segment or
    /// tone): `.dataPlayedBack` — "actually heard" semantics, accounting for
    /// device output latency — when actually driving a real audio device, but
    /// `.dataRendered` in manual-rendering (offline) mode, where
    /// `.dataPlayedBack` is documented to never fire at all ("Applicable only
    /// when the engine is rendering to/from an audio device" — confirmed
    /// empirically too: every completion-callback-dependent test hung/timed
    /// out under `manualRendering: true` until this switched to
    /// `.dataRendered`). `.dataRendered` still means "actually output by the
    /// player", just without the device-latency accounting — the right
    /// tradeoff for deterministic offline tests.
    private var lastBufferCallbackType: AVAudioPlayerNodeCompletionCallbackType {
        engine.manualRenderingMode == .offline ? .dataRendered : .dataPlayedBack
    }

    /// Schedules one rendered segment's buffers, in order, on the player node.
    ///
    /// - The LAST buffer uses `lastBufferCallbackType` — "actually heard"
    ///   semantics on a real device — so `completion` fires only once the
    ///   listener has truly heard the end of the segment, not merely once
    ///   it's been handed to the render graph.
    /// - Earlier buffers use `.dataConsumed` (pipeline-ahead scheduling): each
    ///   one firing decrements `queuedDuration` and may trip
    ///   `needsMoreAudioHandler`.
    /// - `rateMode == .pinnedToNatural` pins `rate` to 1.0 synchronously, right
    ///   here, before any of this segment's buffers are scheduled, and
    ///   restores the prior rate in the same last-buffer callback that also
    ///   fires `completion`.
    ///
    ///   Note `AVAudioPlayerNodeCompletionCallbackType` is a plain enum, not an
    ///   option set — a single `scheduleBuffer` call can only ask for one
    ///   callback type, so there's no "start" event to hook for the pin on a
    ///   single buffer without a second, duplicate schedule of the same audio.
    ///   Pinning at schedule time instead of at a rendered-first-buffer event
    ///   is correct for how this is actually called: an announcement segment
    ///   is only ever scheduled once nothing else is queued ahead of it (the
    ///   caller — Phase 2's `AudioPlaybackCenter` — schedules it exactly when
    ///   the preceding chime/segment has finished), so nothing already queued
    ///   at the old rate is retroactively affected.
    public func schedule(
        _ segment: RenderedSegment, rateMode: SegmentRateMode = .followsUserRate,
        completion: (() -> Void)? = nil
    ) {
        guard !segment.buffers.isEmpty else {
            DispatchQueue.main.async { completion?() }
            return
        }
        queuedDuration += segment.duration
        hasSignaledLowWater = false
        let savedRate = timePitch.rate
        if rateMode == .pinnedToNatural { timePitch.rate = 1.0 }
        let lastIndex = segment.buffers.count - 1

        for (index, buffer) in segment.buffers.enumerated() {
            let isLast = index == lastIndex
            let bufferDuration = Double(buffer.frameLength) / format.sampleRate

            playerNode.scheduleBuffer(
                buffer, at: nil, options: [],
                completionCallbackType: isLast ? lastBufferCallbackType : .dataConsumed
            ) { [weak self] _ in
                guard let self else { return }
                DispatchQueue.main.async {
                    self.queuedDuration -= bufferDuration
                    self.checkLowWaterMark()
                    if isLast {
                        if rateMode == .pinnedToNatural { self.timePitch.rate = savedRate }
                        completion?()
                    }
                }
            }
        }
    }

    /// Schedules a bundled chime (loaded/converted to `format` once, then
    /// cached) as its own single buffer between segments — same node, same
    /// audio session, sample-accurate sequencing.
    public func scheduleTone(_ asset: ToneAsset, completion: (() -> Void)? = nil) throws {
        let buffer = try cachedToneBuffer(asset)
        let toneDuration = Double(buffer.frameLength) / format.sampleRate
        queuedDuration += toneDuration
        hasSignaledLowWater = false
        playerNode.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: lastBufferCallbackType) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                self.queuedDuration -= toneDuration
                self.checkLowWaterMark()
                completion?()
            }
        }
    }

    private func cachedToneBuffer(_ asset: ToneAsset) throws -> AVAudioPCMBuffer {
        if let cached = toneBuffers[asset] { return cached }
        let buffer = try ToneLibrary.loadBuffer(asset, format: format)
        toneBuffers[asset] = buffer
        return buffer
    }

    private func checkLowWaterMark() {
        guard !hasSignaledLowWater, queuedDuration < lowWaterMark else { return }
        hasSignaledLowWater = true
        needsMoreAudioHandler?()
    }

    // MARK: - Test-only manual rendering

    /// Pumps the offline manual-rendering graph forward by up to `maxFrames`,
    /// synchronously driving whatever scheduled-buffer completion callbacks
    /// that much progress triggers. Only valid on an engine created with
    /// `manualRendering: true`; throws otherwise. Lets tests exercise
    /// scheduling/playhead/rate-pinning behavior deterministically, without a
    /// real audio output device.
    @discardableResult
    public func renderOffline(maxFrames: AVAudioFrameCount = 4096) throws -> AVAudioEngineManualRenderingStatus {
        guard engine.manualRenderingMode == .offline else {
            throw ArticleAudioEngineError.manualRenderingNotEnabled
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: maxFrames) else {
            throw ArticleAudioEngineError.manualRenderingFailed
        }
        do {
            return try engine.renderOffline(maxFrames, to: buffer)
        } catch {
            throw ArticleAudioEngineError.manualRenderingFailed
        }
    }
}

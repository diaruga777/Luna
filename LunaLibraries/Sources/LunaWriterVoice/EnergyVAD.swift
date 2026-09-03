import Accelerate
import AVFoundation
import Foundation

/// `EnergyVAD`'s timing parameters, ported from gazeread's Silero VAD gate
/// (`voice.js`) onto a plain RMS energy threshold.
public struct EnergyVADConfiguration: Sendable {
    public var frameDuration: TimeInterval
    public var thresholdDecibels: Float
    public var preRollDuration: TimeInterval
    public var hangoverDuration: TimeInterval
    public var minimumSpeechDuration: TimeInterval

    public init(
        frameDuration: TimeInterval = 0.03,
        thresholdDecibels: Float = -38,
        preRollDuration: TimeInterval = 0.25,
        hangoverDuration: TimeInterval = 0.4,
        minimumSpeechDuration: TimeInterval = 0.25
    ) {
        self.frameDuration = frameDuration
        self.thresholdDecibels = thresholdDecibels
        self.preRollDuration = preRollDuration
        self.hangoverDuration = hangoverDuration
        self.minimumSpeechDuration = minimumSpeechDuration
    }

    /// Frames to keep buffered ahead of an onset, so a transcriber hears the
    /// word that triggered it rather than the word after it.
    public var preRollFrameCount: Int {
        Int((preRollDuration / frameDuration).rounded(.up))
    }
}

/// A speech boundary the energy gate has detected.
public enum VoiceActivityEvent: Equatable, Sendable {
    case onset
    case end
}

/// RMS energy gate over fixed-size frames — pure: no audio session, no
/// threads, no clock of its own.
///
/// `.onset` fires on the very first frame above threshold, before anything
/// downstream has a transcript, so a caller can snapshot what is being read
/// as early as gazeread's neural VAD does. A run that never reaches
/// `minimumSpeechDuration` before the trailing silence exceeds
/// `hangoverDuration` never gets an `.end` — its `.onset` stands (a brief,
/// harmless UI pulse), but no utterance follows it.
public final class EnergyVAD {
    public let configuration: EnergyVADConfiguration
    private var speechStart: Date?
    private var lastAboveThresholdAt: Date?

    public init(configuration: EnergyVADConfiguration = EnergyVADConfiguration()) {
        self.configuration = configuration
    }

    /// The RMS level of `samples`, in dBFS. `-infinity` for silence.
    public static func decibels(ofRMS samples: [Float]) -> Float {
        guard !samples.isEmpty else { return -.infinity }
        let meanSquare = samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)
        let rms = sqrt(meanSquare)
        guard rms > 0 else { return -.infinity }
        return 20 * log10(rms)
    }

    /// Feeds one frame's samples at its capture time and returns any events
    /// it causes. Frames must arrive in order and roughly `frameDuration`
    /// apart, including silent ones — a gap in the input reads as continuous
    /// speech rather than as silence.
    public func ingest(_ samples: [Float], at time: Date) -> [VoiceActivityEvent] {
        ingest(decibels: Self.decibels(ofRMS: samples), at: time)
    }

    /// Feeds one frame already reduced to decibels. The buffer adapter below
    /// uses this to avoid allocating a fresh `[Float]` per frame; `ingest(_:at:)`
    /// stays the entry point for callers (and tests) that already hold samples.
    public func ingest(decibels: Float, at time: Date) -> [VoiceActivityEvent] {
        let isAboveThreshold = decibels >= configuration.thresholdDecibels
        var events: [VoiceActivityEvent] = []

        if isAboveThreshold {
            if speechStart == nil {
                speechStart = time
                events.append(.onset)
            }
            lastAboveThresholdAt = time
        } else if let lastAboveThresholdAt, let speechStart {
            let silence = time.timeIntervalSince(lastAboveThresholdAt)
            if silence >= configuration.hangoverDuration {
                let speechDuration = lastAboveThresholdAt.timeIntervalSince(speechStart)
                if speechDuration >= configuration.minimumSpeechDuration {
                    events.append(.end)
                }
                self.speechStart = nil
                self.lastAboveThresholdAt = nil
            }
        }
        return events
    }

    /// Discards any speech run in progress without emitting `.end`.
    public func reset() {
        speechStart = nil
        lastAboveThresholdAt = nil
    }
}

/// Slices an `AVAudioPCMBuffer` tap callback into `EnergyVAD`'s fixed-size
/// frames, so production code never hand-rolls the sample math `EnergyVADTests`
/// exercises directly on plain arrays.
public enum EnergyVADBufferAdapter {
    /// Slices `buffer` into `configuration.frameDuration`-sized windows and
    /// reduces each straight to decibels over the buffer's own pointer —
    /// `vDSP_measqv`, no per-frame `[Float]` copy.
    public static func frames(
        in buffer: AVAudioPCMBuffer,
        configuration: EnergyVADConfiguration,
        startingAt bufferStart: Date
    ) -> [(decibels: Float, time: Date)] {
        guard let channelData = buffer.floatChannelData else { return [] }
        let frameLength = Int(buffer.frameLength)
        let sampleRate = buffer.format.sampleRate
        guard sampleRate > 0, frameLength > 0 else { return [] }
        let samplesPerFrame = max(1, Int((configuration.frameDuration * sampleRate).rounded()))
        let channel = channelData[0]

        var result: [(decibels: Float, time: Date)] = []
        var offset = 0
        while offset < frameLength {
            let count = min(samplesPerFrame, frameLength - offset)
            var meanSquare: Float = 0
            vDSP_measqv(channel + offset, 1, &meanSquare, vDSP_Length(count))
            let rms = sqrt(meanSquare)
            let decibels = rms > 0 ? 20 * log10(rms) : -Float.infinity
            let time = bufferStart.addingTimeInterval(Double(offset) / sampleRate)
            result.append((decibels, time))
            offset += count
        }
        return result
    }
}

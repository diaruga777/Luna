import AVFoundation
import Foundation
import Speech

/// The iOS 26 transcriber: `SpeechAnalyzer` + `SpeechTranscriber` over the
/// same `AVAudioEngine` tap and `EnergyVAD`/`UtteranceSegmenter` pipeline as
/// `SFSpeechTranscriber`, using the framework's own volatile/final result
/// stream instead of a recognition-task callback.
@available(iOS 26, *)
public final class SpeechAnalyzerTranscriber: SpeechTranscribing {

    public weak var delegate: SpeechTranscribingDelegate?

    private let locale: Locale
    private let vad: EnergyVAD
    private let segmenter: UtteranceSegmenter
    private let audioEngine = AVAudioEngine()
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var recognitionTask: Task<Void, Never>?
    private var isRunning = false

    public init(
        locale: Locale = .current,
        vad: EnergyVAD = EnergyVAD(),
        segmenter: UtteranceSegmenter = UtteranceSegmenter()
    ) {
        self.locale = locale
        self.vad = vad
        self.segmenter = segmenter
    }

    public var isAvailable: Bool {
        SpeechTranscriber.isAvailable
    }

    public var unavailabilityReason: SpeechUnavailability? {
        SpeechTranscriber.isAvailable ? nil : .unsupported
    }

    public func start() throws {
        guard !isRunning else { return }
        guard SpeechTranscriber.isAvailable else {
            throw SpeechTranscribingError.unavailable(.unsupported)
        }
        guard AVAudioApplication.shared.recordPermission == .granted else {
            throw SpeechTranscribingError.unavailable(.microphoneDenied)
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true)

        segmenter.reset()
        vad.reset()

        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            continuation.yield(AnalyzerInput(buffer: buffer))
            self?.ingestVAD(buffer: buffer)
        }
        audioEngine.prepare()
        try audioEngine.start()
        isRunning = true

        recognitionTask = Task { [weak self, segmenter] in
            do {
                try await analyzer.start(inputSequence: stream)
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    let finished = result.isFinal ? segmenter.receiveFinal(text) : segmenter.receivePartial(text)
                    guard let finished else { continue }
                    await self?.notifyUtterance(finished.text)
                }
            } catch {
                // The stream ends on `stop()`; anything else just stops
                // quietly — there is no synchronous caller left to throw to.
            }
        }
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        inputContinuation?.finish()
        inputContinuation = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func ingestVAD(buffer: AVAudioPCMBuffer) {
        let now = Date()
        for frame in EnergyVADBufferAdapter.frames(in: buffer, configuration: vad.configuration, startingAt: now) {
            for event in vad.ingest(frame.samples, at: frame.time) where event == .onset {
                Task { @MainActor [weak self] in self?.delegate?.speechDidDetectOnset() }
            }
        }
    }

    @MainActor
    private func notifyUtterance(_ text: String) {
        delegate?.speechDidFinishUtterance(text)
    }
}

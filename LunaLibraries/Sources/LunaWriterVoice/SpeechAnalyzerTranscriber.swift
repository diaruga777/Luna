import AVFoundation
import Foundation
import Speech

/// The iOS 26 transcriber: `SpeechAnalyzer` + `SpeechTranscriber` over the
/// same `AVAudioEngine` tap and `EnergyVAD`/`UtteranceSegmenter` pipeline as
/// `SFSpeechTranscriber`, using the framework's own volatile/final result
/// stream instead of a recognition-task callback.
///
/// Unlike `SFSpeechRecognitionTask`, `SpeechTranscriber.results` keeps
/// yielding across many final segments on one analyzer — there is no
/// per-session restart to drive here, only the tap/VAD/segmenter pipeline
/// `SFSpeechTranscriber` also runs, guarded by the same kind of private queue.
@available(iOS 26, *)
public final class SpeechAnalyzerTranscriber: SpeechTranscribing {

    public weak var delegate: SpeechTranscribingDelegate?

    private let locale: Locale
    private let module: SpeechTranscriber
    private let engine: SpeechAudioEngine
    private let vad: EnergyVAD
    private let segmenter: UtteranceSegmenter
    private let stateQueue = DispatchQueue(label: "com.hsanabria.luna.writer.voice.speechanalyzer")

    private var isRunning = false
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var recognitionTask: Task<Void, Never>?
    private var clockReference = AudioClockReference()

    private var localeAssetStatus: AssetInventory.Status?
    private var localeAssetCheck: Task<Void, Never>?

    public init(
        locale: Locale = .current,
        vad: EnergyVAD = EnergyVAD(),
        segmenter: UtteranceSegmenter = UtteranceSegmenter(),
        engine: SpeechAudioEngine = SystemSpeechAudioEngine()
    ) {
        self.locale = locale
        self.module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        self.vad = vad
        self.segmenter = segmenter
        self.engine = engine
    }

    public var isAvailable: Bool { unavailabilityReason == nil }

    public var unavailabilityReason: SpeechUnavailability? {
        guard SpeechTranscriber.isAvailable else { return .unsupported }
        if let localeAssetStatus, localeAssetStatus != .installed { return .noOnDeviceModel }
        return SpeechPermissionCheck.unavailability()
    }

    public func start() throws {
        guard !isRunning else { return }
        guard SpeechTranscriber.isAvailable else {
            throw SpeechTranscribingError.unavailable(.unsupported)
        }
        if let localeAssetStatus, localeAssetStatus != .installed {
            throw SpeechTranscribingError.unavailable(.noOnDeviceModel)
        }
        if let reason = SpeechPermissionCheck.unavailability() {
            throw SpeechTranscribingError.unavailable(reason)
        }

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement)
        try audioSession.setActive(true)

        stateQueue.sync {
            segmenter.reset()
            vad.reset()
            clockReference.reset()
        }

        let analyzer = SpeechAnalyzer(modules: [module])
        self.analyzer = analyzer
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation

        engine.installTap(bufferSize: 4096) { [weak self] buffer, time in
            guard let self else { return }
            continuation.yield(AnalyzerInput(buffer: buffer))
            self.stateQueue.sync { self.ingestVAD(buffer: buffer, at: time) }
        }
        engine.prepare()
        try engine.start()
        isRunning = true

        let module = self.module
        recognitionTask = Task { [weak self] in
            guard let self else { return }
            do {
                // The results loop subscribes BEFORE `analyzer.start` runs —
                // starting first would consume input with nothing draining
                // `module.results`, since `start` does not return until the
                // stream ends.
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { [weak self] in
                        for try await result in module.results {
                            let text = String(result.text.characters)
                            self?.handleResult(text: text, isFinal: result.isFinal)
                        }
                    }
                    group.addTask {
                        try await analyzer.start(inputSequence: stream)
                    }
                    try await group.next()
                    group.cancelAll()
                }
            } catch {
                self.handleRecognitionFailure(error)
            }
        }
        ensureLocaleAssetInstalled()
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        engine.removeTap()
        engine.stop()
        inputContinuation?.finish()
        inputContinuation = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        let analyzer = self.analyzer
        self.analyzer = nil
        Task { try? await analyzer?.finalizeAndFinishThroughEndOfInput() }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// Runs on the results task, off main and off the tap thread — routed
    /// through `stateQueue` like every other caller of `segmenter`.
    private func handleResult(text: String, isFinal: Bool) {
        let finished: Utterance? = stateQueue.sync {
            isFinal ? segmenter.receiveFinal(text) : segmenter.receivePartial(text)
        }
        guard let finished else { return }
        notifyUtterance(finished.text)
    }

    /// The results loop or `analyzer.start` threw. Surfaced here (rather than
    /// swallowed) so a caller inspecting `lastError` can tell a real failure
    /// from `stop()`'s own stream teardown; either way this session is done.
    public private(set) var lastError: Error?

    private func handleRecognitionFailure(_ error: Error) {
        lastError = error
        guard isRunning else { return }
        stop()
    }

    private func ingestVAD(buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        let bufferStart = clockReference.date(for: time)
        var sawOnset = false
        for frame in EnergyVADBufferAdapter.frames(in: buffer, configuration: vad.configuration, startingAt: bufferStart) {
            for event in vad.ingest(decibels: frame.decibels, at: frame.time) where event == .onset {
                sawOnset = true
            }
        }
        let closed = segmenter.tick()
        if sawOnset { notifyOnset() }
        if let closed { notifyUtterance(closed.text) }
    }

    /// Checks whether `locale`'s on-device asset is installed and, if it is
    /// merely supported rather than installed, requests installation — so a
    /// caller that retries after this resolves sees `.noOnDeviceModel` clear
    /// on its own rather than needing its own asset-management code.
    private func ensureLocaleAssetInstalled() {
        guard localeAssetCheck == nil else { return }
        let module = self.module
        localeAssetCheck = Task { [weak self] in
            let status = await AssetInventory.status(forModules: [module])
            self?.localeAssetStatus = status
            guard status == .supported else { return }
            guard let request = try? await AssetInventory.assetInstallationRequest(supporting: [module])
            else { return }
            try? await request.downloadAndInstall()
            self?.localeAssetStatus = await AssetInventory.status(forModules: [module])
        }
    }

    private func notifyOnset() {
        if Thread.isMainThread {
            delegate?.speechDidDetectOnset()
        } else {
            DispatchQueue.main.async { [weak self] in self?.delegate?.speechDidDetectOnset() }
        }
    }

    private func notifyUtterance(_ text: String) {
        if Thread.isMainThread {
            delegate?.speechDidFinishUtterance(text)
        } else {
            DispatchQueue.main.async { [weak self] in self?.delegate?.speechDidFinishUtterance(text) }
        }
    }
}

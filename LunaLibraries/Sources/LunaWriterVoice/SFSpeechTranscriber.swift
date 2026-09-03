import AVFoundation
import Foundation
import Speech

/// The iOS 18 baseline transcriber: an `AVAudioEngine` input tap feeds an
/// on-device `SFSpeechRecognizer` request, with `EnergyVAD` reading the same
/// tap for an early onset and `UtteranceSegmenter` turning partial/final
/// results into `Utterance`s.
public final class SFSpeechTranscriber: NSObject, SpeechTranscribing {

    public weak var delegate: SpeechTranscribingDelegate?

    private let recognizer: SFSpeechRecognizer?
    private let vad: EnergyVAD
    private let segmenter: UtteranceSegmenter
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var isRunning = false

    public init(
        locale: Locale = .current,
        vad: EnergyVAD = EnergyVAD(),
        segmenter: UtteranceSegmenter = UtteranceSegmenter()
    ) {
        self.recognizer = SFSpeechRecognizer(locale: locale)
        self.vad = vad
        self.segmenter = segmenter
        super.init()
    }

    public var isAvailable: Bool {
        guard let recognizer else { return false }
        return recognizer.isAvailable && recognizer.supportsOnDeviceRecognition
    }

    public var unavailabilityReason: SpeechUnavailability? {
        guard let recognizer else { return .unsupported }
        guard recognizer.supportsOnDeviceRecognition else { return .noOnDeviceModel }
        guard recognizer.isAvailable else { return .unsupported }
        return nil
    }

    public func start() throws {
        guard !isRunning else { return }
        guard let recognizer, recognizer.supportsOnDeviceRecognition else {
            throw SpeechTranscribingError.unavailable(unavailabilityReason ?? .noOnDeviceModel)
        }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw SpeechTranscribingError.unavailable(.permissionDenied)
        }
        guard AVAudioApplication.shared.recordPermission == .granted else {
            throw SpeechTranscribingError.unavailable(.microphoneDenied)
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        self.request = request

        segmenter.reset()
        vad.reset()

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            self?.ingestVAD(buffer: buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
        isRunning = true

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                self.handle(transcription: result.bestTranscription.formattedString, isFinal: result.isFinal)
            }
            if error != nil || result?.isFinal == true {
                self.stop()
            }
        }
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func ingestVAD(buffer: AVAudioPCMBuffer) {
        let now = Date()
        for frame in EnergyVADBufferAdapter.frames(in: buffer, configuration: vad.configuration, startingAt: now) {
            for event in vad.ingest(frame.samples, at: frame.time) where event == .onset {
                notifyOnset()
            }
        }
    }

    private func handle(transcription text: String, isFinal: Bool) {
        let finished = isFinal ? segmenter.receiveFinal(text) : segmenter.receivePartial(text)
        guard let finished else { return }
        notifyUtterance(finished.text)
    }

    private func notifyOnset() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.delegate?.speechDidDetectOnset() }
            return
        }
        delegate?.speechDidDetectOnset()
    }

    private func notifyUtterance(_ text: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.delegate?.speechDidFinishUtterance(text) }
            return
        }
        delegate?.speechDidFinishUtterance(text)
    }
}

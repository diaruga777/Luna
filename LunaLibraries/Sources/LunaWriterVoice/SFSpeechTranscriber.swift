import AVFoundation
import Foundation
import Speech

/// One recognition attempt's live connection between audio buffers and a
/// transcriber's results — the request plus the task it drives, sealed behind
/// a protocol so a test can fake a final result or an error without
/// `SFSpeechRecognizer`.
public protocol SpeechRecognitionSession: AnyObject {
    func append(_ buffer: AVAudioPCMBuffer)
    func finish()
    func cancel()
}

/// Builds a `SpeechRecognitionSession` against a specific recognizer.
public protocol SpeechRecognitionSessionMaking {
    /// `onResult` may fire many times before `onError` (or a final result)
    /// ends the session. `onError`'s `Error?` is nil when the session ended
    /// on a final result rather than a failure.
    func makeSession(
        onResult: @escaping (String, Bool) -> Void,
        onError: @escaping (Error?) -> Void
    ) -> SpeechRecognitionSession?
}

private final class SystemSpeechRecognitionSession: SpeechRecognitionSession {
    private let request: SFSpeechAudioBufferRecognitionRequest
    private let task: SFSpeechRecognitionTask

    init(request: SFSpeechAudioBufferRecognitionRequest, task: SFSpeechRecognitionTask) {
        self.request = request
        self.task = task
    }

    func append(_ buffer: AVAudioPCMBuffer) { request.append(buffer) }
    func finish() { request.endAudio() }
    func cancel() { task.cancel() }
}

/// The real recognizer, on-device only.
public final class SFSpeechRecognitionSessionMaker: SpeechRecognitionSessionMaking {
    private let recognizer: SFSpeechRecognizer

    public init(recognizer: SFSpeechRecognizer) {
        self.recognizer = recognizer
    }

    public func makeSession(
        onResult: @escaping (String, Bool) -> Void,
        onError: @escaping (Error?) -> Void
    ) -> SpeechRecognitionSession? {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        let task = recognizer.recognitionTask(with: request) { result, error in
            if let result { onResult(result.bestTranscription.formattedString, result.isFinal) }
            if error != nil || result?.isFinal == true { onError(error) }
        }
        return SystemSpeechRecognitionSession(request: request, task: task)
    }
}

/// The iOS 18 baseline transcriber: an `AVAudioEngine` input tap feeds a
/// `SpeechRecognitionSession`, with `EnergyVAD` reading the same tap for an
/// early onset and `UtteranceSegmenter` turning partial/final results into
/// `Utterance`s.
///
/// A recognition session ends on its own after one final result — `stateQueue`
/// is what lets the tap callback (the audio render thread), a session's result
/// callback (Speech's own queue) and `start()`/`stop()` (the caller's thread)
/// all touch `vad`/`segmenter`/`session` without racing.
public final class SFSpeechTranscriber: NSObject, SpeechTranscribing {

    public weak var delegate: SpeechTranscribingDelegate?

    private let recognizer: SFSpeechRecognizer?
    private let sessionMaker: SpeechRecognitionSessionMaking?
    /// False when a caller injected its own `sessionMaker` — a test double
    /// stands in for `SFSpeechRecognizer` entirely, so the hardware/model
    /// check below is the production recognizer's precondition, not this
    /// session source's.
    private let usesSystemRecognizer: Bool
    private let engine: SpeechAudioEngine
    private let vad: EnergyVAD
    private let segmenter: UtteranceSegmenter
    private let stateQueue = DispatchQueue(label: "com.hsanabria.luna.writer.voice.sfspeech")

    private var isRunning = false
    private var session: SpeechRecognitionSession?
    private var clockReference = AudioClockReference()
    private var lifecycleObservers: [NSObjectProtocol] = []

    public init(
        locale: Locale = .current,
        vad: EnergyVAD = EnergyVAD(),
        segmenter: UtteranceSegmenter = UtteranceSegmenter(),
        engine: SpeechAudioEngine = SystemSpeechAudioEngine(),
        sessionMaker: SpeechRecognitionSessionMaking? = nil
    ) {
        let recognizer = SFSpeechRecognizer(locale: locale)
        self.recognizer = recognizer
        self.vad = vad
        self.segmenter = segmenter
        self.engine = engine
        self.usesSystemRecognizer = sessionMaker == nil
        self.sessionMaker = sessionMaker ?? recognizer.map(SFSpeechRecognitionSessionMaker.init)
        super.init()
    }

    public var isAvailable: Bool { unavailabilityReason == nil }

    public var unavailabilityReason: SpeechUnavailability? {
        if usesSystemRecognizer {
            guard let recognizer else { return .unsupported }
            guard recognizer.supportsOnDeviceRecognition else { return .noOnDeviceModel }
            guard recognizer.isAvailable else { return .unsupported }
        }
        return SpeechPermissionCheck.unavailability()
    }

    public func start() throws {
        guard !isRunning else { return }
        if usesSystemRecognizer {
            guard let recognizer, recognizer.supportsOnDeviceRecognition else {
                throw SpeechTranscribingError.unavailable(unavailabilityReason ?? .noOnDeviceModel)
            }
        }
        guard let sessionMaker else {
            throw SpeechTranscribingError.unavailable(.unsupported)
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
        openSession(using: sessionMaker)
        installTap()

        engine.prepare()
        try engine.start()
        isRunning = true
        observeLifecycle()
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        removeLifecycleObservers()
        engine.removeTap()
        engine.stop()
        stateQueue.sync {
            session?.finish()
            session?.cancel()
            session = nil
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func installTap() {
        engine.installTap(bufferSize: 2048) { [weak self] buffer, time in
            guard let self else { return }
            self.stateQueue.sync {
                self.session?.append(buffer)
                self.ingestVAD(buffer: buffer, at: time)
            }
        }
    }

    /// Opens a fresh session against the still-running engine. Called from
    /// `start()` and again on every final result or error — never from
    /// `stop()`'s own teardown, which is the caller's to end.
    private func openSession(using maker: SpeechRecognitionSessionMaking) {
        let opened = maker.makeSession(
            onResult: { [weak self] text, isFinal in
                self?.handleResult(text: text, isFinal: isFinal)
            },
            onError: { [weak self] _ in
                self?.handleSessionEnded()
            })
        stateQueue.sync { self.session = opened }
    }

    /// Runs on the session's own callback thread — never main, never the tap
    /// thread — so `segmenter` access goes through `stateQueue` like every
    /// other caller's does.
    private func handleResult(text: String, isFinal: Bool) {
        let finished: Utterance? = stateQueue.sync {
            isFinal ? segmenter.receiveFinal(text) : segmenter.receivePartial(text)
        }
        guard let finished else { return }
        notifyUtterance(finished.text)
    }

    private func handleSessionEnded() {
        // Runs on the session's own callback thread: read `isRunning` through
        // `stateQueue` rather than trusting a value written on the caller's.
        let stillRunning = stateQueue.sync { self.isRunning }
        guard stillRunning, let sessionMaker else { return }
        openSession(using: sessionMaker)
    }

    /// Called with the tap held (already on `stateQueue`): reduces the buffer
    /// to fixed-size decibel frames and drives the VAD and the segmenter's
    /// ~20 Hz tick from the tap's own rate.
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

    // MARK: - Lifecycle

    /// `queue: nil` runs the handler synchronously on whichever thread posts
    /// the notification — AVFoundation always posts these three on main, so
    /// this is already main-thread execution, without `queue: .main`'s extra
    /// run-loop hop (which would also make the handler unreachable from a
    /// test that posts and asserts on the same turn).
    private func observeLifecycle() {
        let center = NotificationCenter.default
        lifecycleObservers = [
            center.addObserver(
                forName: AVAudioSession.interruptionNotification, object: nil, queue: nil
            ) { [weak self] note in self?.handleInterruption(note) },
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil
            ) { [weak self] _ in self?.recoverAfterConfigurationChange() },
            center.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil
            ) { [weak self] _ in self?.recoverAfterConfigurationChange() },
        ]
    }

    private func removeLifecycleObservers() {
        let center = NotificationCenter.default
        lifecycleObservers.forEach(center.removeObserver)
        lifecycleObservers.removeAll()
    }

    private func handleInterruption(_ note: Notification) {
        guard isRunning,
              let info = note.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }
        switch type {
        case .began:
            engine.pause()
        case .ended:
            let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            guard AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume)
            else { return }
            recoverAfterConfigurationChange()
        @unknown default:
            break
        }
    }

    /// A route change or an engine configuration change invalidates the tap's
    /// format. Reinstall it against the node's current format and keep going.
    private func recoverAfterConfigurationChange() {
        guard isRunning else { return }
        engine.removeTap()
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            installTap()
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
        } catch {
            stop()
        }
    }

    // MARK: - Delegate hops

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

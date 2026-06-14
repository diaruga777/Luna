//
//  RSVPViewController.swift
//  Clip
//

import AVFoundation
import UIKit

/// RSVP (one-word-at-a-time) speed reader, ReadMaxx-style: dark screen, fixed
/// focal column with a guideline, red ORP letter, word-length-aware timing with
/// sentence/paragraph pauses, scrubbing, live speed adjustment, and an optional
/// read-aloud mode where speech paces the display instead of the WPM timer.
final class RSVPViewController: UIViewController {

    /// Fired once when playback reaches the last word.
    var onFinishedReading: (() -> Void)?

    private let item: ReadingListItem
    private let engine: RSVPEngine
    private let store = ReadingListStore.shared

    private var currentIndex = 0
    private var isPlaying = false
    private var timer: Timer?
    private var wpm: Double = ReaderSettings.baseWPM

    // Read-aloud pacing: when on, whole sentences are spoken (natural prosody,
    // normal pace) and the display flashes each word as it's voiced — the WPM
    // setting is ignored.
    private let isSpeechMode: Bool
    private let synthesizer = AVSpeechSynthesizer()
    /// First word index of the sentence currently being spoken.
    private var speechSentenceBase = 0
    /// UTF-16 offset of each word within the current utterance string.
    private var speechWordOffsets: [Int] = []

    private let wordLabel = UILabel()
    private let guidelineTop = UIView()
    private let guidelineBottom = UIView()
    private let hairlineTop = UIView()
    private let hairlineBottom = UIView()
    private let playPauseButton = UIButton(type: .system)
    private let scrubber = UISlider()
    private let statusLabel = UILabel()
    private let wpmDownButton = UIButton(type: .system)
    private let wpmUpButton = UIButton(type: .system)

    private let sentenceHaptic = UIImpactFeedbackGenerator(style: .light)

    /// Horizontal position of the focal (ORP) column, as a fraction of width.
    private static let focalFraction: CGFloat = 0.4
    /// Target characters visible on one line — the font is sized so a word this
    /// long fits, and longer words split (`WordSplitter`).
    private static let targetCharactersAcross = 15

    /// Sized at init from the device width so `targetCharactersAcross`
    /// characters fit beside the focal column without running off-screen.
    private let wordFont: UIFont

    init(item: ReadingListItem, content: ArticleContent, audioEnabled: Bool = false) {
        self.item = item
        self.isSpeechMode = audioEnabled
        self.wordFont = Self.makeWordFont(forWidth: UIScreen.main.bounds.width)
        self.engine = RSVPEngine(
            content: content, maxCharactersPerWord: Self.targetCharactersAcross)
        super.init(nibName: nil, bundle: nil)
        if let resume = item.lastWordIndex, engine.words.indices.contains(resume) {
            currentIndex = resume
        } else if ReaderSettings.eyeTrackingEnabled,
                  let gazeIndex = item.eyeTrackedWordIndex,
                  engine.words.indices.contains(gazeIndex) {
            // First RSVP entry for this article: pick up from the last word the
            // eyes were tracked on.
            currentIndex = gazeIndex
        }
        synthesizer.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Picks the monospaced font size so `targetCharactersAcross` characters
    /// fit beside the focal column. The right side binds: a word that long has
    /// up to `target − maxORP` characters after the ORP (ORP index caps at 3),
    /// and those must fit between the focal column and the right margin.
    private static func makeWordFont(forWidth width: CGFloat) -> UIFont {
        let probe = UIFont.monospacedSystemFont(ofSize: 100, weight: .medium)
        let advanceRatio = ("0" as NSString)
            .size(withAttributes: [.font: probe]).width / 100
        guard advanceRatio > 0, width > 0 else {
            return UIFont.monospacedSystemFont(ofSize: 30, weight: .medium)
        }
        let rightMargin: CGFloat = 20
        let rightBudget = max(120, width * (1 - focalFraction) - rightMargin)
        let suffixCharacters = CGFloat(targetCharactersAcross - 3)
        let characterWidth = rightBudget / suffixCharacters
        let size = min(44, max(20, (characterWidth / advanceRatio).rounded()))
        return UIFont.monospacedSystemFont(ofSize: size, weight: .medium)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        configureGuidelines()
        configureWordLabel()
        configureControls()

        if isSpeechMode {
            // Read-aloud paces the display; prepare the audio session up front.
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try? AVAudioSession.sharedInstance().setActive(true)
        }

        view.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(togglePlayPause)))

        showWord(at: currentIndex)
        updateStatus()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutGuidelines()
        showWord(at: currentIndex)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        pause()
        saveProgress()
    }

    // MARK: - Setup

    private func configureGuidelines() {
        for line in [guidelineTop, guidelineBottom] {
            line.backgroundColor = .systemRed
            view.addSubview(line)
        }
        for hairline in [hairlineTop, hairlineBottom] {
            hairline.backgroundColor = .separator
            view.addSubview(hairline)
        }
    }

    private func layoutGuidelines() {
        let focalX = view.bounds.width * Self.focalFraction
        let centerY = view.bounds.midY - 40
        let wordHalfHeight: CGFloat = 36
        // Vertical notches above/below the focal letter…
        guidelineTop.frame = CGRect(x: focalX - 1, y: centerY - wordHalfHeight - 14, width: 2, height: 14)
        guidelineBottom.frame = CGRect(x: focalX - 1, y: centerY + wordHalfHeight, width: 2, height: 14)
        // …connected by horizontal hairlines bounding the word area.
        hairlineTop.frame = CGRect(x: 24, y: centerY - wordHalfHeight, width: view.bounds.width - 48, height: 1)
        hairlineBottom.frame = CGRect(x: 24, y: centerY + wordHalfHeight, width: view.bounds.width - 48, height: 1)
    }

    private func configureWordLabel() {
        wordLabel.font = wordFont
        wordLabel.textColor = .label
        view.addSubview(wordLabel)
    }

    private func configureControls() {
        var playConfig = UIButton.Configuration.plain()
        playConfig.image = UIImage(systemName: "play.fill")
        playConfig.baseForegroundColor = .label
        playConfig.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 28)
        playPauseButton.configuration = playConfig
        playPauseButton.addTarget(self, action: #selector(togglePlayPause), for: .touchUpInside)

        scrubber.minimumValue = 0
        scrubber.maximumValue = Float(max(engine.words.count - 1, 1))
        scrubber.value = Float(currentIndex)
        scrubber.minimumTrackTintColor = .systemRed
        scrubber.addTarget(self, action: #selector(scrubbed), for: .valueChanged)

        statusLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center

        wpmDownButton.setTitle("−25", for: .normal)
        wpmUpButton.setTitle("+25", for: .normal)
        for button in [wpmDownButton, wpmUpButton] {
            button.setTitleColor(.label, for: .normal)
            button.titleLabel?.font = .monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
        }
        wpmDownButton.addTarget(self, action: #selector(wpmDown), for: .touchUpInside)
        wpmUpButton.addTarget(self, action: #selector(wpmUp), for: .touchUpInside)

        // Plain container with explicit constraints so the play button sits
        // exactly on the screen's center line, with symmetric speed buttons.
        let speedRow = UIView()
        for button in [playPauseButton, wpmDownButton, wpmUpButton] {
            button.translatesAutoresizingMaskIntoConstraints = false
            speedRow.addSubview(button)
        }

        let controls = UIStackView(arrangedSubviews: [scrubber, statusLabel, speedRow])
        controls.axis = .vertical
        controls.spacing = 12
        controls.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controls)

        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            controls.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
            controls.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            speedRow.heightAnchor.constraint(equalToConstant: 56),
            playPauseButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            playPauseButton.centerYAnchor.constraint(equalTo: speedRow.centerYAnchor),
            wpmDownButton.centerXAnchor.constraint(equalTo: view.centerXAnchor, constant: -110),
            wpmDownButton.centerYAnchor.constraint(equalTo: speedRow.centerYAnchor),
            wpmUpButton.centerXAnchor.constraint(equalTo: view.centerXAnchor, constant: 110),
            wpmUpButton.centerYAnchor.constraint(equalTo: speedRow.centerYAnchor),
        ])
    }

    // MARK: - Word display

    /// Positions the word so the ORP letter sits exactly on the focal column,
    /// with the ORP letter tinted red.
    private func showWord(at index: Int) {
        guard engine.words.indices.contains(index) else { return }
        let word = engine.words[index]
        let characters = Array(word.text)
        let orp = min(word.orpIndex, max(characters.count - 1, 0))

        let attributed = NSMutableAttributedString(
            string: word.text,
            attributes: [.font: wordFont, .foregroundColor: UIColor.label])
        let orpStart = String(characters.prefix(orp)).utf16.count
        let orpLength = String(characters[orp]).utf16.count
        attributed.addAttribute(
            .foregroundColor, value: UIColor.systemRed,
            range: NSRange(location: orpStart, length: orpLength))
        wordLabel.attributedText = attributed
        wordLabel.sizeToFit()

        let prefixWidth = NSAttributedString(
            string: String(characters.prefix(orp)),
            attributes: [.font: wordFont]).size().width
        let orpWidth = NSAttributedString(
            string: String(characters[orp]),
            attributes: [.font: wordFont]).size().width

        let focalX = view.bounds.width * Self.focalFraction
        let centerY = view.bounds.midY - 40
        wordLabel.frame.origin = CGPoint(
            x: focalX - prefixWidth - orpWidth / 2,
            y: centerY - wordLabel.bounds.height / 2)
    }

    // MARK: - Playback

    private func play() {
        guard !engine.words.isEmpty else { return }
        if currentIndex >= engine.words.count - 1 {
            currentIndex = 0
        }
        isPlaying = true
        playPauseButton.configuration?.image = UIImage(systemName: "pause.fill")
        if isSpeechMode {
            speakCurrentSentence()
        } else {
            scheduleNext()
        }
    }

    private func pause() {
        isPlaying = false
        timer?.invalidate()
        timer = nil
        synthesizer.stopSpeaking(at: .immediate)
        playPauseButton.configuration?.image = UIImage(systemName: "play.fill")
        saveProgress()
    }

    // MARK: - Read-aloud pacing

    /// Speaks from the current word to the end of the sentence as ONE
    /// utterance — natural prosody at normal speech pace — and records each
    /// word's offset so the display can flash along.
    private func speakCurrentSentence() {
        guard isPlaying, engine.words.indices.contains(currentIndex) else { return }
        var end = currentIndex
        while end < engine.words.count - 1,
              !engine.words[end].endsSentence,
              !engine.words[end].endsParagraph,
              end - currentIndex < 39 {
            end += 1
        }

        var text = ""
        speechWordOffsets = []
        for word in engine.words[currentIndex...end] {
            if !text.isEmpty { text += " " }
            speechWordOffsets.append((text as NSString).length)
            text += word.text
        }
        speechSentenceBase = currentIndex

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = SpeechVoice.best
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.postUtteranceDelay = 0.12
        synthesizer.speak(utterance)
    }

    @objc private func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    private func scheduleNext() {
        timer?.invalidate()
        let interval = engine.duration(at: currentIndex, wpm: wpm)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.advance()
        }
    }

    private func advance() {
        guard isPlaying else { return }
        let word = engine.words[currentIndex]
        if word.endsSentence || word.endsParagraph {
            sentenceHaptic.impactOccurred()
        }
        guard currentIndex < engine.words.count - 1 else {
            pause()
            onFinishedReading?()
            return
        }
        currentIndex += 1
        showWord(at: currentIndex)
        scrubber.value = Float(currentIndex)
        updateStatus()
        scheduleNext()
    }

    // MARK: - Controls

    @objc private func scrubbed() {
        pause()
        currentIndex = Int(scrubber.value)
        showWord(at: currentIndex)
        updateStatus()
    }

    @objc private func wpmDown() { adjustWPM(by: -25) }
    @objc private func wpmUp() { adjustWPM(by: 25) }

    private func adjustWPM(by delta: Double) {
        wpm = min(max(wpm + delta, 100), 900)
        ReaderSettings.baseWPM = wpm
        updateStatus()
    }

    private func updateStatus() {
        let percent = engine.words.isEmpty
            ? 0 : Int((Double(currentIndex + 1) / Double(engine.words.count)) * 100)
        statusLabel.text = "\(percent)% · \(Int(wpm)) wpm"
    }

    private func saveProgress() {
        store.setLastWordIndex(currentIndex, for: item.id)
        if engine.words.count > 1 {
            store.setReadingProgress(
                Double(currentIndex) / Double(engine.words.count - 1), for: item.id)
        }
    }
}

extension RSVPViewController: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        guard isSpeechMode, isPlaying else { return }
        // Map the spoken range to a word in the current sentence and flash it.
        var wordOffset = 0
        for (index, offset) in speechWordOffsets.enumerated() {
            if offset <= characterRange.location { wordOffset = index } else { break }
        }
        let wordIndex = speechSentenceBase + wordOffset
        guard wordIndex != currentIndex, engine.words.indices.contains(wordIndex) else { return }
        currentIndex = wordIndex
        showWord(at: currentIndex)
        scrubber.value = Float(currentIndex)
        updateStatus()
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
    ) {
        guard isSpeechMode, isPlaying else { return }
        let sentenceEnd = speechSentenceBase + max(0, speechWordOffsets.count - 1)
        sentenceHaptic.impactOccurred()
        guard sentenceEnd < engine.words.count - 1 else {
            currentIndex = engine.words.count - 1
            pause()
            onFinishedReading?()
            return
        }
        currentIndex = sentenceEnd + 1
        showWord(at: currentIndex)
        scrubber.value = Float(currentIndex)
        updateStatus()
        speakCurrentSentence()
    }
}

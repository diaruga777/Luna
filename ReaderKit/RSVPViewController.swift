//
//  RSVPViewController.swift
//  Clip
//

import AVFoundation
import UIKit

/// RSVP (one-word-at-a-time) speed reader, ReadMaxx-style: a liquid-glass focus
/// capsule behind the focal word, the ORP letter tinted in the reading accent,
/// word-length-aware timing with sentence/paragraph pauses, scrubbing, live
/// speed adjustment, and an optional read-aloud mode where speech paces the
/// display instead of the WPM timer.
final class RSVPViewController: UIViewController, ReaderPositionTracking {

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
    /// Created lazily so the SILENT speed reader never instantiates a speech
    /// synthesizer — instantiating one can claim the system audio session and
    /// interrupt other audio (e.g. Picture-in-Picture video). Only read-aloud
    /// mode ever touches it.
    private lazy var synthesizer: AVSpeechSynthesizer = {
        let synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = self
        return synthesizer
    }()
    /// First word index of the sentence currently being spoken.
    private var speechSentenceBase = 0
    /// UTF-16 offset of each word within the current utterance string.
    private var speechWordOffsets: [Int] = []

    private let wordLabel = UILabel()
    /// Liquid-glass capsule behind the focal word, replacing the old red
    /// guideline notches.
    /// Glass reticule marks above and below the ORP letter (replaces the pill).
    private let reticuleTop = GlassStyle.reticuleMark()
    private let reticuleBottom = GlassStyle.reticuleMark()
    private let playPauseButton = UIButton(type: .system)
    private let scrubber = UISlider()
    private let controlsStack = UIStackView()
    /// Sharing affordances; nil → the end-of-article share view never reveals.
    private let shareProvider: ReaderShareProviding?
    /// Revealed (above the controls) when the reader reaches the end.
    private lazy var shareView = makeShareView()
    private var didRevealShare = false
    private let statusLabel = UILabel()
    private let wpmDownButton = UIButton(type: .system)
    private let wpmUpButton = UIButton(type: .system)

    private let sentenceHaptic = UIImpactFeedbackGenerator(style: .light)

    /// A glass pill below the word showing the link of the currently-displayed
    /// linkified word; tapping it opens the inline reader. Persists while link
    /// words show, plus a short buffer afterward.
    private let linkPill = UIButton(type: .system)
    private var linkPillURL: URL?
    private var linkPillHideTimer: Timer?
    private let playPauseTap = UITapGestureRecognizer()

    /// Horizontal position of the focal (ORP) column, as a fraction of width.
    private static let focalFraction: CGFloat = 0.4
    /// Target characters visible on one line — the font is sized so a word this
    /// long fits, and longer words split (`WordSplitter`).
    private static let targetCharactersAcross = 15

    /// Sized at init from the device width so `targetCharactersAcross`
    /// characters fit beside the focal column without running off-screen.
    private let wordFont: UIFont

    init(item: ReadingListItem, content: ArticleContent, audioEnabled: Bool = false,
         shareProvider: ReaderShareProviding? = nil, resumeWordIndex: Int? = nil) {
        self.item = item
        self.isSpeechMode = audioEnabled
        self.shareProvider = shareProvider
        // Cap the sizing width so the word/font stays readable on wide screens
        // (iPad / landscape) rather than scaling up to the full display width.
        self.wordFont = Self.makeWordFont(forWidth: min(UIScreen.main.bounds.width, 600))
        self.engine = RSVPEngine(
            content: content, maxCharactersPerWord: Self.targetCharactersAcross)
        super.init(nibName: nil, bundle: nil)
        if let resume = resumeWordIndex, engine.words.indices.contains(resume) {
            // Carried over from another reader mode — start exactly there.
            currentIndex = resume
        } else if let resume = item.lastWordIndex, engine.words.indices.contains(resume) {
            currentIndex = resume
        } else if ReaderSettings.eyeTrackingEnabled,
                  let gazeIndex = item.eyeTrackedWordIndex,
                  engine.words.indices.contains(gazeIndex) {
            // First RSVP entry for this article: pick up from the last word the
            // eyes were tracked on.
            currentIndex = gazeIndex
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The focal word currently displayed — carried to other modes on a switch.
    var currentReadingWordIndex: Int? { currentIndex }

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

        configureFocusPill()
        configureWordLabel()
        configureLinkPill()
        configureControls()

        // NB: the audio session is NOT touched here — only when read-aloud
        // actually starts playing (see `play()`), so opening the silent speed
        // reader never interrupts other audio / Picture-in-Picture.

        playPauseTap.addTarget(self, action: #selector(togglePlayPause))
        playPauseTap.delegate = self
        view.addGestureRecognizer(playPauseTap)

        showWord(at: currentIndex)
        updateStatus()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutFocusPill()
        layoutLinkPill()
        showWord(at: currentIndex)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        pause()
        saveProgress()
    }

    /// Read-aloud uses a non-mixing category so it takes over playback; pairing
    /// every deactivation with `.notifyOthersOnDeactivation` lets interrupted
    /// audio (e.g. Picture-in-Picture video) RESUME rather than stay stopped.
    private func activateAudioSession() { ReaderAudioSession.activate() }
    private func deactivateAudioSession() { ReaderAudioSession.deactivate() }

    // MARK: - Setup

    private func configureFocusPill() {
        view.addSubview(reticuleTop)
        view.addSubview(reticuleBottom)
    }

    /// Positions the two reticule marks as short vertical bars centered on the
    /// focal column, just above and below the word band, pointing at the ORP
    /// letter.
    private func layoutFocusPill() {
        let focalX = view.bounds.width * Self.focalFraction
        let centerY = view.bounds.midY - 40
        let wordHalfHeight: CGFloat = 30
        let markWidth: CGFloat = 7
        let markHeight: CGFloat = 20
        let gap: CGFloat = 10
        reticuleTop.frame = CGRect(
            x: focalX - markWidth / 2, y: centerY - wordHalfHeight - gap - markHeight,
            width: markWidth, height: markHeight)
        reticuleBottom.frame = CGRect(
            x: focalX - markWidth / 2, y: centerY + wordHalfHeight + gap,
            width: markWidth, height: markHeight)
        if #unavailable(iOS 26.0) {
            reticuleTop.layer.cornerRadius = markWidth / 2
            reticuleBottom.layer.cornerRadius = markWidth / 2
        }
    }

    private func configureWordLabel() {
        wordLabel.font = wordFont
        wordLabel.textColor = .label
        view.addSubview(wordLabel)
    }

    private func configureLinkPill() {
        var config = UIButton.Configuration.gray()
        config.cornerStyle = .capsule
        config.image = UIImage(systemName: "link")
        config.imagePadding = 6
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 12)
        // Desaturated text/icon so the pill stays quiet behind the reading word.
        config.baseForegroundColor = .secondaryLabel
        config.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 14, bottom: 7, trailing: 14)
        linkPill.configuration = config
        linkPill.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
        linkPill.alpha = 0
        linkPill.addTarget(self, action: #selector(linkPillTapped), for: .touchUpInside)
        view.addSubview(linkPill)
    }

    /// Centers the link pill below the focal word band.
    private func layoutLinkPill() {
        let centerY = view.bounds.midY - 40
        let maxWidth = view.bounds.width - 64
        let fitted = linkPill.systemLayoutSizeFitting(
            CGSize(width: maxWidth, height: 40),
            withHorizontalFittingPriority: .fittingSizeLevel,
            verticalFittingPriority: .required)
        let width = min(max(fitted.width, 80), maxWidth)
        linkPill.frame = CGRect(
            x: (view.bounds.width - width) / 2, y: centerY + 84, width: width, height: 36)
    }

    /// Shows/refreshes the pill for a linkified word, or starts the post-link
    /// buffer when a non-link word arrives (a new link replaces it immediately).
    private func updateLinkPill(for url: URL?) {
        if let url {
            linkPillHideTimer?.invalidate()
            linkPillHideTimer = nil
            if url != linkPillURL {
                linkPillURL = url
                let host = url.host?.replacingOccurrences(of: "www.", with: "") ?? url.absoluteString
                linkPill.configuration?.title = host
                view.setNeedsLayout()
            }
            if linkPill.alpha < 1 {
                UIView.animate(withDuration: 0.2) { self.linkPill.alpha = 1 }
            }
        } else if linkPillURL != nil, linkPillHideTimer == nil {
            linkPillHideTimer = Timer.scheduledTimer(withTimeInterval: 1.4, repeats: false) {
                [weak self] _ in self?.hideLinkPill()
            }
        }
    }

    private func hideLinkPill() {
        linkPillHideTimer?.invalidate()
        linkPillHideTimer = nil
        linkPillURL = nil
        UIView.animate(withDuration: 0.25) { self.linkPill.alpha = 0 }
    }

    @objc private func linkPillTapped() {
        guard let url = linkPillURL else { return }
        pause()
        // No outer text to split here, so the card grows out from the screen's
        // center (nil peeks) and the ✕ / chevron compress it shut.
        let inline = SplitWebOverlayViewController(
            url: url, shareProvider: shareProvider, lineHeight: 0,
            cutY: view.bounds.midY, topHalf: nil, bottomHalf: nil)
        inline.modalPresentationStyle = .overFullScreen
        present(inline, animated: false)
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
        scrubber.minimumTrackTintColor = GlassStyle.readingAccent
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

        controlsStack.addArrangedSubview(scrubber)
        controlsStack.addArrangedSubview(statusLabel)
        controlsStack.addArrangedSubview(speedRow)
        controlsStack.axis = .vertical
        controlsStack.spacing = 12
        controlsStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controlsStack)

        // Hidden until the reader finishes; sits above the controls so it never
        // obscures them.
        shareView.isHidden = true
        shareView.alpha = 0
        shareView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(shareView)

        NSLayoutConstraint.activate([
            controlsStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            controlsStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
            controlsStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            shareView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            shareView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            shareView.bottomAnchor.constraint(equalTo: controlsStack.topAnchor, constant: -16),
            speedRow.heightAnchor.constraint(equalToConstant: 56),
            playPauseButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            playPauseButton.centerYAnchor.constraint(equalTo: speedRow.centerYAnchor),
            wpmDownButton.centerXAnchor.constraint(equalTo: view.centerXAnchor, constant: -110),
            wpmDownButton.centerYAnchor.constraint(equalTo: speedRow.centerYAnchor),
            wpmUpButton.centerXAnchor.constraint(equalTo: view.centerXAnchor, constant: 110),
            wpmUpButton.centerYAnchor.constraint(equalTo: speedRow.centerYAnchor),
        ])
    }

    // MARK: - End-of-article share

    private func makeShareView() -> ArticleShareView {
        let suggestionName = shareProvider?.suggestedFriendName(forURLString: item.urlString)
        return ArticleShareView(
            suggestionName: suggestionName,
            onShare: { [weak self] in
                guard let self else { return }
                self.shareProvider?.presentShareSheet(
                    urlString: self.item.urlString, title: self.item.title,
                    from: self, sourceView: self.shareView)
            },
            onSendSuggested: { [weak self] in
                guard let self else { return }
                self.shareProvider?.sendToSuggestedFriend(
                    urlString: self.item.urlString, title: self.item.title, from: self)
            })
    }

    private func revealShareView() {
        // No share affordance in the share sheet or for non-shareable items.
        guard shareProvider != nil, item.isShareable, !didRevealShare else { return }
        didRevealShare = true
        shareView.isHidden = false
        UIView.animate(withDuration: 0.3) { self.shareView.alpha = 1 }
    }

    // MARK: - Word display

    /// Positions the word so the ORP letter sits exactly on the focal column,
    /// with the ORP letter tinted in the reading accent.
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
            .foregroundColor, value: GlassStyle.readingAccent,
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

        updateLinkPill(for: word.url)
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
            activateAudioSession()
            speakCurrentSentence()
        } else {
            scheduleNext()
        }
    }

    private func pause() {
        isPlaying = false
        timer?.invalidate()
        timer = nil
        // Only touch speech/audio in read-aloud mode — the silent reader must
        // never instantiate the synthesizer or claim the audio session.
        if isSpeechMode {
            synthesizer.stopSpeaking(at: .immediate)
            deactivateAudioSession()
        }
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
            revealShareView()
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
            revealShareView()
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

extension RSVPViewController: UIGestureRecognizerDelegate {
    /// The full-screen play/pause tap must ignore touches that land on any
    /// interactive control — the ±25 speed buttons, the play/pause button, the
    /// scrubber, and the link pill — so those taps reach the control instead of
    /// being cancelled by the full-screen tap (which `cancelsTouchesInView`).
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch
    ) -> Bool {
        var hitView = touch.view
        while let candidate = hitView {
            if candidate is UIControl { return false }
            hitView = candidate.superview
        }
        return true
    }
}

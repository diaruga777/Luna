//
//  AudioMiniPlayerView.swift
//  Luna
//
//  The persistent read-aloud mini-player bar (Phase 3 of
//  claudedocs/audio-playback-plan.md): a floating glass bar hosted at window
//  level by `MiniPlayerHostViewController`, showing the playing article's
//  thumbnail + title, the same transport controls as the old in-reader footer
//  (paragraph back / play-pause / paragraph forward / rate), an autoplay
//  toggle, and a `MoonHorizonProgressBar`.
//
//  The view is deliberately PASSIVE: it renders a `Display` value and exposes
//  control closures — the host observes `AudioPlaybackCenter` and feeds it.
//  That keeps it directly snapshot-testable (`AudioMiniPlayerTests`).
//

import LunaAudioPlayback
import LunaDesignSystem
import UIKit
import LunaModels

final class AudioMiniPlayerView: UIView {

    // MARK: - Modes

    /// How the bar presents for a given playback state: gone when idle, the
    /// full floating bar normally, and a slimmed strip (title + autoplay +
    /// progress only) docked above RSVP's circular controls when RSVP is
    /// frontmost in speech mode — RSVP's own glass circles already provide
    /// the transport controls there. Pure so `AudioMiniPlayerTests` pins it.
    enum BarMode: Equatable {
        case hidden
        case full
        case slim
    }

    static func barMode(state: AudioPlaybackState, hasMeldAnchor: Bool) -> BarMode {
        if case .idle = state { return .hidden }
        return hasMeldAnchor ? .slim : .full
    }

    static let fullHeight: CGFloat = 62
    static let slimHeight: CGFloat = 52

    // MARK: - Display value

    /// Everything the bar shows, as plain values (buildable in tests without
    /// a playback center). During `.announcing` the host passes the UPCOMING
    /// item's info with `isUpNext` set.
    struct Display: Equatable {
        var title: String
        var isUpNext: Bool
        var thumbnailPath: String?
        var isPlaying: Bool
        var rate: Float
        var isAutoplayOn: Bool
    }

    // MARK: - Control hooks (wired by the host)

    var onTapArticle: (() -> Void)?
    var onSkipBack: (() -> Void)?
    var onPlayPause: (() -> Void)?
    var onSkipForward: (() -> Void)?
    var onCycleRate: (() -> Void)?
    var onToggleAutoplay: (() -> Void)?

    // MARK: - Subviews

    private let glass = UIVisualEffectView(effect: GlassStyle.barEffect())
    private let thumbnailView = UIImageView()
    private let titleLabel = UILabel()
    private let skipBackButton = UIButton(type: .system)
    private let playPauseButton = UIButton(type: .system)
    private let skipForwardButton = UIButton(type: .system)
    private let rateButton = UIButton(type: .system)
    private let autoplayButton = UIButton(type: .system)
    private let progressBar = MoonHorizonProgressBar()
    private let row = UIStackView()
    private var rowHeightConstraint: NSLayoutConstraint?

    private(set) var mode: BarMode = .full
    private var display: Display?
    /// Guards async thumbnail decodes against landing on a newer article.
    private var thumbnailToken: UInt64 = 0
    /// Already-decoded, downsampled thumbnails, keyed by file path (NSCache is
    /// thread-safe).
    nonisolated(unsafe) private static let decodedThumbnails: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 8
        return cache
    }()

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 20
        layer.cornerCurve = .continuous
        clipsToBounds = true

        glass.frame = bounds
        glass.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(glass)

        thumbnailView.contentMode = .scaleAspectFill
        thumbnailView.clipsToBounds = true
        thumbnailView.layer.cornerRadius = 8
        thumbnailView.layer.cornerCurve = .continuous
        thumbnailView.backgroundColor = LunaColors.quaternaryFill

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = LunaColors.primaryText
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentHuggingPriority(.defaultLow - 10, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        configureIconButton(skipBackButton, symbol: "backward.frame.fill", pointSize: 14,
                            accessibilityLabel: L10n.string("Reader_audio_previousParagraphAccessibilityLabel"), action: #selector(skipBackTapped))
        configureIconButton(playPauseButton, symbol: "play.fill", pointSize: 20,
                            accessibilityLabel: L10n.string("Reader_audio_playAccessibilityLabel"), action: #selector(playPauseTapped))
        configureIconButton(skipForwardButton, symbol: "forward.frame.fill", pointSize: 14,
                            accessibilityLabel: L10n.string("Reader_audio_nextParagraphAccessibilityLabel"), action: #selector(skipForwardTapped))

        rateButton.setTitle(L10n.string("Reader_audio_rateOneXTitle"), for: .normal)
        rateButton.titleLabel?.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        rateButton.setTitleColor(LunaColors.primaryText, for: .normal)
        rateButton.accessibilityLabel = L10n.string("Common_playbackSpeed")
        rateButton.addTarget(self, action: #selector(rateTapped), for: .touchUpInside)

        configureIconButton(autoplayButton, symbol: "text.line.first.and.arrowtriangle.forward",
                            pointSize: 15, accessibilityLabel: L10n.string("Reader_audio_autoplayNextAccessibilityLabel"),
                            action: #selector(autoplayTapped))

        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(thumbnailView)
        row.addArrangedSubview(titleLabel)
        row.addArrangedSubview(skipBackButton)
        row.addArrangedSubview(playPauseButton)
        row.addArrangedSubview(skipForwardButton)
        row.addArrangedSubview(rateButton)
        row.addArrangedSubview(autoplayButton)
        row.setCustomSpacing(2, after: skipBackButton)
        row.setCustomSpacing(2, after: playPauseButton)
        row.setCustomSpacing(6, after: skipForwardButton)
        // Content is overlaid as SIBLINGS above the glass rather than inside
        // `glass.contentView`: no vibrancy is wanted here, and layers hosted
        // inside `UIGlassEffect`'s content view don't rasterize through
        // `layer.render(in:)` (verified empirically on the iOS 26 sim — the
        // snapshot tests, and any layer-tree capture, would show an empty bar).
        addSubview(row)

        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.showsActivityPulse = false
        addSubview(progressBar)

        let rowHeight = row.heightAnchor.constraint(equalToConstant: 36)
        rowHeightConstraint = rowHeight
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            rowHeight,
            thumbnailView.widthAnchor.constraint(equalToConstant: 36),
            thumbnailView.heightAnchor.constraint(equalToConstant: 36),
            progressBar.topAnchor.constraint(equalTo: row.bottomAnchor, constant: 2),
            progressBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            progressBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            progressBar.heightAnchor.constraint(equalToConstant: 14),
        ])

        // Tap anywhere that isn't a control → open the playing article.
        let tap = UITapGestureRecognizer(target: self, action: #selector(barTapped(_:)))
        tap.delegate = self
        addGestureRecognizer(tap)

        isAccessibilityElement = false
        accessibilityIdentifier = "audio-mini-player"
        setMode(.full)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func configureIconButton(
        _ button: UIButton, symbol: String, pointSize: CGFloat,
        accessibilityLabel: String, action: Selector
    ) {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: symbol)
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: pointSize)
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 5, bottom: 6, trailing: 5)
        config.baseForegroundColor = LunaColors.primaryText
        button.configuration = config
        button.accessibilityLabel = accessibilityLabel
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    // MARK: - Applying state

    /// Full ↔ slim presentation: slim (docked above RSVP's own controls)
    /// keeps only the title, the autoplay toggle, and the progress bar.
    func setMode(_ newMode: BarMode) {
        guard newMode != .hidden else { return } // visibility is the host's job
        mode = newMode
        let slim = newMode == .slim
        thumbnailView.isHidden = slim
        skipBackButton.isHidden = slim
        playPauseButton.isHidden = slim
        skipForwardButton.isHidden = slim
        rateButton.isHidden = slim
        rowHeightConstraint?.constant = slim ? 26 : 36
    }

    func apply(_ display: Display) {
        guard display != self.display else { return }
        let previousPath = self.display?.thumbnailPath
        self.display = display

        titleLabel.text = display.isUpNext
            ? L10n.string("Reader_audio_upNextTitle", display.title) : display.title
        titleLabel.textColor = display.isUpNext ? LunaColors.secondaryText : LunaColors.primaryText
        playPauseButton.configuration?.image = UIImage(
            systemName: display.isPlaying ? "pause.fill" : "play.fill")
        playPauseButton.accessibilityLabel = display.isPlaying
            ? L10n.string("Reader_audio_pauseAccessibilityLabel") : L10n.string("Reader_audio_playAccessibilityLabel")
        rateButton.setTitle(
            display.rate == 1.0 ? "1×" : String(format: "%g×", display.rate), for: .normal)
        autoplayButton.tintColor = display.isAutoplayOn ? GlassStyle.readingAccent : LunaColors.secondaryText
        autoplayButton.accessibilityValue = display.isAutoplayOn
            ? L10n.string("Reader_audio_autoplayOnAccessibilityValue") : L10n.string("Reader_audio_autoplayOffAccessibilityValue")

        if display.thumbnailPath != previousPath {
            loadThumbnail(path: display.thumbnailPath)
        }
    }

    func setProgress(_ fraction: Double, animated: Bool) {
        progressBar.setProgress(Float(fraction), animated: animated)
    }

    // MARK: - Thumbnail

    private func loadThumbnail(path: String?) {
        thumbnailToken &+= 1
        let token = thumbnailToken
        guard let path else {
            thumbnailView.image = nil
            return
        }
        if let cached = Self.decodedThumbnails.object(forKey: path as NSString) {
            thumbnailView.image = cached
            return
        }
        thumbnailView.image = nil
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 2
        Task.detached(priority: .userInitiated) {
            let image = ImageDownsampling.decode(path: path, scale: scale, maxPixelSize: 72 * scale)
            if let image { Self.decodedThumbnails.setObject(image, forKey: path as NSString) }
            await MainActor.run { [weak self] in
                guard let self, self.thumbnailToken == token, let image else { return }
                self.thumbnailView.image = image
            }
        }
    }

    // MARK: - Actions

    @objc private func skipBackTapped() { onSkipBack?() }
    @objc private func playPauseTapped() { onPlayPause?() }
    @objc private func skipForwardTapped() { onSkipForward?() }
    @objc private func rateTapped() { onCycleRate?() }
    @objc private func autoplayTapped() { onToggleAutoplay?() }

    @objc private func barTapped(_ recognizer: UITapGestureRecognizer) {
        onTapArticle?()
    }
}

extension AudioMiniPlayerView: UIGestureRecognizerDelegate {
    /// The whole-bar tap must ignore touches landing on any control, so
    /// button taps reach the buttons (same pattern as RSVP's full-screen tap).
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch
    ) -> Bool {
        var view = touch.view
        while let candidate = view {
            if candidate is UIControl { return false }
            view = candidate.superview
        }
        return true
    }
}

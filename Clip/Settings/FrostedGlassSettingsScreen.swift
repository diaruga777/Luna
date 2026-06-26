//
//  FrostedGlassSettingsScreen.swift
//  Clip
//

import UIKit
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers
import ClipContentRendering

/// Experimental controls for the Frosted-Glass-Neon visual effect: the frost,
/// glow, and tone parameters (each across its range), the ripple-transition
/// parameters, and a live media preview pinned to the bottom — pick a photo/
/// video/GIF and tap it to fire the wave that animates the effect in and out.
final class FrostedGlassSettingsScreen: UIViewController, UITableViewDataSource, UITableViewDelegate,
                                    PHPickerViewControllerDelegate {

    /// A labelled, live-updating slider bound to one persisted parameter.
    private struct SliderSpec {
        let title: String
        let range: ClosedRange<Double>
        let get: () -> Double
        let set: (Double) -> Void
        var format: (Double) -> String = { String(format: "%.2f", $0) }
    }

    private enum Section: Int, CaseIterable {
        case frost, glow, tone, ripple
    }

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)

    // MARK: Slider groups

    private lazy var frostSliders: [SliderSpec] = [
        SliderSpec(title: "Frost Blur", range: FrostedGlassSettings.frostRadiusRange,
                   get: { FrostedGlassSettings.frostRadius }, set: { FrostedGlassSettings.frostRadius = $0 },
                   format: { String(format: "%.0f pt", $0) }),
        SliderSpec(title: "Frost Scatter", range: FrostedGlassSettings.frostScatterRange,
                   get: { FrostedGlassSettings.frostScatter }, set: { FrostedGlassSettings.frostScatter = $0 }),
    ]

    // Glow section = these sliders, then Neon Tint (color) + Additive Glow (toggle).
    private lazy var glowSliders: [SliderSpec] = [
        SliderSpec(title: "Glow Threshold", range: FrostedGlassSettings.glowThresholdRange,
                   get: { FrostedGlassSettings.glowThreshold }, set: { FrostedGlassSettings.glowThreshold = $0 }),
        SliderSpec(title: "Glow Intensity", range: FrostedGlassSettings.glowIntensityRange,
                   get: { FrostedGlassSettings.glowIntensity }, set: { FrostedGlassSettings.glowIntensity = $0 },
                   format: { String(format: "%.2f×", $0) }),
        SliderSpec(title: "Glow Radius", range: FrostedGlassSettings.glowRadiusRange,
                   get: { FrostedGlassSettings.glowRadius }, set: { FrostedGlassSettings.glowRadius = $0 },
                   format: { String(format: "%.0f pt", $0) }),
    ]

    private lazy var toneSliders: [SliderSpec] = [
        SliderSpec(title: "Saturation", range: FrostedGlassSettings.saturationRange,
                   get: { FrostedGlassSettings.saturation }, set: { FrostedGlassSettings.saturation = $0 },
                   format: { String(format: "%.2f×", $0) }),
        SliderSpec(title: "Brightness", range: FrostedGlassSettings.brightnessRange,
                   get: { FrostedGlassSettings.brightness }, set: { FrostedGlassSettings.brightness = $0 },
                   format: { String(format: "%.2f×", $0) }),
    ]

    private lazy var rippleSliders: [SliderSpec] = [
        SliderSpec(title: "Push Distance", range: FrostedGlassSettings.ripplePushRange,
                   get: { FrostedGlassSettings.ripplePush }, set: { FrostedGlassSettings.ripplePush = $0 },
                   format: { String(format: "%.0f pt", $0) }),
        SliderSpec(title: "Wave Speed", range: FrostedGlassSettings.rippleSpeedRange,
                   get: { FrostedGlassSettings.rippleSpeed }, set: { FrostedGlassSettings.rippleSpeed = $0 },
                   format: { String(format: "%.0f pt/s", $0) }),
        SliderSpec(title: "Ring Width", range: FrostedGlassSettings.rippleWidthRange,
                   get: { FrostedGlassSettings.rippleWidth }, set: { FrostedGlassSettings.rippleWidth = $0 },
                   format: { String(format: "%.0f pt", $0) }),
        SliderSpec(title: "Reveal Edge", range: FrostedGlassSettings.rippleEdgeRange,
                   get: { FrostedGlassSettings.rippleEdge }, set: { FrostedGlassSettings.rippleEdge = $0 },
                   format: { String(format: "%.0f pt", $0) }),
        SliderSpec(title: "Dispersion λ", range: FrostedGlassSettings.rippleWavelengthRange,
                   get: { FrostedGlassSettings.rippleWavelength }, set: { FrostedGlassSettings.rippleWavelength = $0 },
                   format: { $0 < 1 ? "Off" : String(format: "%.0f pt", $0) }),
        SliderSpec(title: "Dispersion Decay", range: FrostedGlassSettings.rippleDecayRange,
                   get: { FrostedGlassSettings.rippleDecay }, set: { FrostedGlassSettings.rippleDecay = $0 },
                   format: { String(format: "%.0f pt", $0) }),
        SliderSpec(title: "Duration", range: FrostedGlassSettings.rippleDurationRange,
                   get: { FrostedGlassSettings.rippleDuration }, set: { FrostedGlassSettings.rippleDuration = $0 },
                   format: { $0 < 0.01 ? "Auto" : String(format: "%.2f s", $0) }),
    ]

    // MARK: Live media footer

    private let footer = UIView()
    private let stageView = UIView()
    private let mediaImageView = UIImageView()
    private let stagePlaceholder = UILabel()
    private var mediaEffect: FrostedGlassEffectView?

    // Fullscreen toggle: the stage is pinned to the footer normally and to the whole
    // view when expanded. Both constraint sets are swapped on toggle.
    private let fullscreenButton = UIButton(type: .system)
    private var footerStageConstraints: [NSLayoutConstraint] = []
    private var fullscreenStageConstraints: [NSLayoutConstraint] = []
    private var isStageFullscreen = false

    private var player: AVPlayer?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var videoLink: CADisplayLink?
    private var videoOrientation: CGImagePropertyOrientation?
    private let ciContext = CIContext(options: nil)
    private var loopObserver: NSObjectProtocol?

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Frosted Neon"
        view.backgroundColor = .systemGroupedBackground
        navigationItem.largeTitleDisplayMode = .never

        tableView.dataSource = self
        tableView.delegate = self
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)

        buildFooter()

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: footer.topAnchor),

            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 260),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        ensureMediaEffect()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        ensureMediaEffect()
    }

    deinit {
        videoLink?.invalidate()
        if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
    }

    /// Push the latest config to the live footer preview so every control change is
    /// reflected immediately. (Values are persisted by the slider/control setters.)
    private func settingsChanged() {
        mediaEffect?.config = footerConfig()
    }

    /// The config for the footer preview.
    private func footerConfig() -> FrostedGlassConfig {
        FrostedGlassSettings.currentConfig
    }

    // MARK: Table structure

    func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .frost: return frostSliders.count
        case .glow: return glowSliders.count + 2   // sliders + tint color + additive toggle
        case .tone: return toneSliders.count
        case .ripple: return rippleSliders.count
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .frost: return "Frosted Glass"
        case .glow: return "Neon Glow"
        case .tone: return "Tone"
        case .ripple: return "Ripple Transition"
        }
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .glow:
            return "The brightest parts of the content bloom into a soft neon glow, "
                + "tinted toward the chosen colour."
        case .ripple:
            return "Tap the preview below to fire the wave, which sweeps the effect in "
                + "and out from the touch point with a ripple through the glass. "
                + "Dispersion λ adds trailing ripples; Duration Auto fits the wave to the view."
        default:
            return nil
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch Section(rawValue: indexPath.section)! {
        case .frost:
            return sliderCell(frostSliders[indexPath.row])
        case .glow:
            if indexPath.row < glowSliders.count { return sliderCell(glowSliders[indexPath.row]) }
            if indexPath.row == glowSliders.count { return tintColorCell() }
            return additiveGlowToggleCell()
        case .tone:
            return sliderCell(toneSliders[indexPath.row])
        case .ripple:
            return sliderCell(rippleSliders[indexPath.row])
        }
    }

    // MARK: Cell builders

    private func makeToggle(isOn: Bool, action: Selector) -> UISwitch {
        let toggle = UISwitch()
        toggle.isOn = isOn
        toggle.addTarget(self, action: action, for: .valueChanged)
        return toggle
    }


    private func sliderCell(_ spec: SliderSpec) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none

        let titleLabel = UILabel()
        titleLabel.text = spec.title
        titleLabel.font = .systemFont(ofSize: 15)

        let valueLabel = UILabel()
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        valueLabel.textColor = .secondaryLabel
        valueLabel.text = spec.format(spec.get())

        let header = UIStackView(arrangedSubviews: [titleLabel, UIView(), valueLabel])
        header.axis = .horizontal

        let slider = UISlider()
        slider.minimumValue = Float(spec.range.lowerBound)
        slider.maximumValue = Float(spec.range.upperBound)
        slider.value = Float(spec.get())
        slider.addAction(UIAction { [weak self] _ in
            let v = Double(slider.value)
            spec.set(v)
            valueLabel.text = spec.format(v)
            self?.settingsChanged()
        }, for: .valueChanged)

        let stack = UIStackView(arrangedSubviews: [header, slider])
        stack.axis = .vertical
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -8),
        ])
        return cell
    }

    private func tintColorCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.text = "Neon Tint"
        cell.contentConfiguration = content
        cell.selectionStyle = .none

        let well = UIColorWell()
        well.supportsAlpha = true
        well.selectedColor = FrostedGlassSettings.tint
        well.addAction(UIAction { [weak self, weak well] _ in
            guard let color = well?.selectedColor else { return }
            FrostedGlassSettings.tint = color
            self?.settingsChanged()
        }, for: .valueChanged)
        cell.accessoryView = well
        return cell
    }

    private func additiveGlowToggleCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.text = "Additive Glow"
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        cell.accessoryView = makeToggle(
            isOn: FrostedGlassSettings.additiveGlow, action: #selector(additiveGlowToggled(_:)))
        return cell
    }

    @objc private func additiveGlowToggled(_ toggle: UISwitch) {
        FrostedGlassSettings.additiveGlow = toggle.isOn
        settingsChanged()
    }

    // MARK: Footer (live preview)

    private func buildFooter() {
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.backgroundColor = .secondarySystemGroupedBackground
        let topLine = UIView()
        topLine.backgroundColor = .separator
        topLine.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(topLine)
        view.addSubview(footer)

        let caption = UILabel()
        caption.text = "Live Preview — tap to ripple the effect in / out"
        caption.font = .systemFont(ofSize: 12, weight: .medium)
        caption.textColor = .secondaryLabel
        caption.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(caption)

        stageView.backgroundColor = .black
        stageView.clipsToBounds = true
        stageView.layer.cornerRadius = 12
        stageView.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(stageView)

        mediaImageView.contentMode = .scaleAspectFill
        mediaImageView.clipsToBounds = true
        mediaImageView.backgroundColor = .black
        mediaImageView.translatesAutoresizingMaskIntoConstraints = false
        stageView.addSubview(mediaImageView)

        stagePlaceholder.text = "Choose a photo, video, or GIF"
        stagePlaceholder.font = .systemFont(ofSize: 14)
        stagePlaceholder.textColor = .secondaryLabel
        stagePlaceholder.textAlignment = .center
        stagePlaceholder.translatesAutoresizingMaskIntoConstraints = false
        stageView.addSubview(stagePlaceholder)

        let chooseButton = UIButton(type: .system)
        var cfg = UIButton.Configuration.gray()
        cfg.title = "Choose"
        cfg.image = UIImage(systemName: "photo.on.rectangle.angled")
        cfg.imagePadding = 6
        cfg.cornerStyle = .medium
        chooseButton.configuration = cfg
        chooseButton.addAction(UIAction { [weak self] _ in self?.presentPicker() }, for: .touchUpInside)
        chooseButton.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(chooseButton)

        // Fullscreen toggle, overlaid on the stage's top-right corner.
        var fsCfg = UIButton.Configuration.plain()
        fsCfg.image = UIImage(systemName: "arrow.up.left.and.arrow.down.right")
        fsCfg.baseForegroundColor = .white
        fsCfg.background.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        fsCfg.background.cornerRadius = 14
        fullscreenButton.configuration = fsCfg
        fullscreenButton.translatesAutoresizingMaskIntoConstraints = false
        fullscreenButton.addAction(UIAction { [weak self] _ in self?.toggleFullscreen() }, for: .touchUpInside)
        footer.addSubview(fullscreenButton)

        // The ripple tap is handled by the effect view itself (set `ripplesOnTap`
        // in `ensureMediaEffect`), which is the view actually on top of the stage.

        // Stage placement when docked in the footer.
        footerStageConstraints = [
            stageView.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 8),
            stageView.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 16),
            stageView.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -16),
            stageView.bottomAnchor.constraint(equalTo: footer.safeAreaLayoutGuide.bottomAnchor, constant: -10),
        ]
        // Stage placement when expanded to fill the screen.
        fullscreenStageConstraints = [
            stageView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            stageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stageView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ]

        NSLayoutConstraint.activate([
            topLine.topAnchor.constraint(equalTo: footer.topAnchor),
            topLine.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            topLine.heightAnchor.constraint(equalToConstant: 1),

            caption.topAnchor.constraint(equalTo: footer.topAnchor, constant: 10),
            caption.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 20),

            chooseButton.centerYAnchor.constraint(equalTo: caption.centerYAnchor),
            chooseButton.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -16),

            fullscreenButton.topAnchor.constraint(equalTo: stageView.topAnchor, constant: 8),
            fullscreenButton.trailingAnchor.constraint(equalTo: stageView.trailingAnchor, constant: -8),
            fullscreenButton.widthAnchor.constraint(equalToConstant: 38),
            fullscreenButton.heightAnchor.constraint(equalToConstant: 38),

            mediaImageView.topAnchor.constraint(equalTo: stageView.topAnchor),
            mediaImageView.leadingAnchor.constraint(equalTo: stageView.leadingAnchor),
            mediaImageView.trailingAnchor.constraint(equalTo: stageView.trailingAnchor),
            mediaImageView.bottomAnchor.constraint(equalTo: stageView.bottomAnchor),

            stagePlaceholder.centerXAnchor.constraint(equalTo: stageView.centerXAnchor),
            stagePlaceholder.centerYAnchor.constraint(equalTo: stageView.centerYAnchor),
        ])
        NSLayoutConstraint.activate(footerStageConstraints)
    }

    /// Swap the stage between its docked footer slot and a full-screen presentation,
    /// switching the media to aspect-fit so the whole frame is visible when expanded.
    private func toggleFullscreen() {
        isStageFullscreen.toggle()
        let symbol = isStageFullscreen
            ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
        fullscreenButton.configuration?.image = UIImage(systemName: symbol)
        mediaImageView.contentMode = isStageFullscreen ? .scaleAspectFit : .scaleAspectFill

        if isStageFullscreen {
            NSLayoutConstraint.deactivate(footerStageConstraints)
            NSLayoutConstraint.activate(fullscreenStageConstraints)
        } else {
            NSLayoutConstraint.deactivate(fullscreenStageConstraints)
            NSLayoutConstraint.activate(footerStageConstraints)
        }
        UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseInOut) {
            self.view.layoutIfNeeded()
        } completion: { _ in
            self.mediaEffect?.setNeedsCapture()
        }
        mediaEffect?.setNeedsCapture()
    }

    /// Apply the effect to the stage once it is laid out. The effect re-renders the
    /// stage every frame, so media changes and live setting tweaks flow through.
    private func ensureMediaEffect() {
        guard mediaEffect == nil, stageView.bounds.width > 0 else { return }
        let effect = stageView.applyFrostedGlass(footerConfig())
        effect?.ripplesOnTap = true   // tap the stage to fire the ripple transition
        mediaEffect = effect
    }

    // MARK: Picking

    private func presentPicker() {
        var config = PHPickerConfiguration()
        config.selectionLimit = 1
        config.filter = .any(of: [.images, .videos])
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider else { return }
        teardownVideo()

        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            loadVideo(from: provider)
        } else if provider.hasItemConformingToTypeIdentifier(UTType.gif.identifier) {
            loadGIF(from: provider)
        } else if provider.canLoadObject(ofClass: UIImage.self) {
            loadImage(from: provider)
        }
    }

    private func loadImage(from provider: NSItemProvider) {
        provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
            guard let image = object as? UIImage else { return }
            // Bake the EXIF orientation into the pixels so the GPU capture (which
            // ignores `UIImage.imageOrientation`) always renders it upright.
            let upright = image.normalizedUp()
            DispatchQueue.main.async { self?.show(image: upright) }
        }
    }

    private func loadGIF(from provider: NSItemProvider) {
        provider.loadDataRepresentation(forTypeIdentifier: UTType.gif.identifier) { [weak self] data, _ in
            guard let data, let animated = Self.animatedImage(fromGIF: data) else { return }
            DispatchQueue.main.async { self?.show(image: animated) }
        }
    }

    private func loadVideo(from provider: NSItemProvider) {
        provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { [weak self] url, _ in
            guard let url else { return }
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(url.pathExtension.isEmpty ? "mov" : url.pathExtension)
            try? FileManager.default.removeItem(at: dest)
            do { try FileManager.default.copyItem(at: url, to: dest) } catch { return }
            DispatchQueue.main.async { self?.playVideo(url: dest) }
        }
    }

    // MARK: Presentation

    private func show(image: UIImage) {
        stagePlaceholder.isHidden = true
        mediaImageView.image = image
        ensureMediaEffect()
        if image.images != nil {
            // Animated GIF: drive a per-frame re-capture so the effect tracks motion.
            mediaImageView.startAnimating()
            startLiveLink()
        } else {
            // Static image: stop any prior animation/link and capture exactly once.
            mediaImageView.stopAnimating()
            teardownLiveLink()
            mediaEffect?.setNeedsCapture()
        }
    }

    private func playVideo(url: URL) {
        stagePlaceholder.isHidden = true
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
        item.add(output)
        videoOutput = output

        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        self.player = player

        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak player] _ in
            player?.seek(to: .zero)
            player?.play()
        }

        // Resolve the track's display rotation so portrait clips render upright.
        Task { [weak self] in
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let transform = try? await track.load(.preferredTransform) {
                await MainActor.run { self?.videoOrientation = transform.ciOrientation }
            }
        }

        startLiveLink()
        player.play()
        ensureMediaEffect()
    }

    /// Drives per-frame re-capture for live media (video or animated GIF). Routed
    /// through a weak proxy: a CADisplayLink retains its target and we retain the
    /// link, so targeting `self` directly would leak the screen and keep decoding.
    private func startLiveLink() {
        teardownLiveLink()
        let link = CADisplayLink(target: VideoLinkProxy(self), selector: #selector(VideoLinkProxy.tick))
        link.add(to: .main, forMode: .common)
        videoLink = link
    }

    private func teardownLiveLink() {
        videoLink?.invalidate()
        videoLink = nil
    }

    fileprivate func liveTick() {
        if videoOutput != nil { readVideoFrame() }
        // Animated GIF frames advance inside the image view; either way, the captured
        // content changed this frame, so ask the effect to re-capture.
        mediaEffect?.setNeedsCapture()
    }

    private func readVideoFrame() {
        guard let output = videoOutput else { return }
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: time),
              let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
        else { return }
        var ciImage = CIImage(cvPixelBuffer: buffer)
        if let orientation = videoOrientation { ciImage = ciImage.oriented(orientation) }
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        mediaImageView.stopAnimating()
        mediaImageView.image = UIImage(cgImage: cgImage)
    }

    private func teardownVideo() {
        teardownLiveLink()
        player?.pause()
        player = nil
        videoOutput = nil
        videoOrientation = nil
        if let loopObserver {
            NotificationCenter.default.removeObserver(loopObserver)
            self.loopObserver = nil
        }
    }

    // MARK: GIF decoding

    private static func animatedImage(fromGIF data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }

        var frames: [UIImage] = []
        var totalDuration: Double = 0
        for index in 0..<count {
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            frames.append(UIImage(cgImage: cgImage))
            totalDuration += frameDuration(source: source, index: index)
        }
        guard !frames.isEmpty else { return nil }
        if totalDuration <= 0 { totalDuration = Double(frames.count) / 30.0 }
        return UIImage.animatedImage(with: frames, duration: totalDuration)
    }

    private static func frameDuration(source: CGImageSource, index: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        else { return 0.1 }
        let unclamped = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double
        let clamped = gif[kCGImagePropertyGIFDelayTime] as? Double
        let delay = unclamped ?? clamped ?? 0.1
        return delay < 0.011 ? 0.1 : delay
    }
}

/// Weak relay for the video `CADisplayLink` so the link doesn't strongly retain the
/// screen (which would leak it and keep decoding frames after it's dismissed).
private final class VideoLinkProxy {
    weak var target: FrostedGlassSettingsScreen?
    init(_ target: FrostedGlassSettingsScreen) { self.target = target }
    @objc func tick() { target?.liveTick() }
}

private extension UIImage {
    /// Returns a copy whose pixels are already rotated/mirrored to the `.up`
    /// orientation, so consumers that ignore `imageOrientation` render it correctly.
    func normalizedUp() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in draw(in: CGRect(origin: .zero, size: size)) }
    }
}

private extension CGAffineTransform {
    /// Maps a video track's preferred transform to the equivalent image orientation.
    /// Decoded from the rotation angle (via `atan2`) so it's robust to transforms
    /// that also carry a scale, which literal matrix-entry matching would miss.
    var ciOrientation: CGImagePropertyOrientation {
        let degrees = Int((atan2(b, a) * 180 / .pi).rounded())
        switch (degrees % 360 + 360) % 360 {
        case 90: return .right    // portrait
        case 270: return .left    // portrait upside-down
        case 180: return .down    // landscape (rotated 180°)
        default: return .up       // identity / landscape right
        }
    }
}

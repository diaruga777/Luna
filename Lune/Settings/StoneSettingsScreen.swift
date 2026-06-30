//
//  StoneSettingsScreen.swift
//  Lune
//

import LuneReadingListUI
import LuneDesignSystem
import UIKit
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers
import LuneContentRendering

/// Experimental controls for the Frosted-Glass-Neon visual effect: the frost,
/// glow, and tone parameters (each across its range), the ripple-transition
/// parameters, and a live media preview pinned to the bottom — pick a photo/
/// video/GIF and tap it to fire the wave that animates the effect in and out.
final class StoneSettingsScreen: UIViewController, UITableViewDataSource, UITableViewDelegate,
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
        case body, tone, stylize, ripple
    }

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    /// In-content header in place of the nav bar, so it's part of the Dot Matrix wipe.
    private let header = NavHeaderBar()

    /// Which stone this screen edits, and its namespaced settings store.
    private let material: StoneConfig.Material
    private let settings: StoneSettings

    init(material: StoneConfig.Material) {
        self.material = material
        self.settings = StoneSettings(material)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Slider groups

    // Body section = these sliders, then the stone Tint colour cell.
    private lazy var bodySliders: [SliderSpec] = [
        SliderSpec(title: "Frost Blur", range: StoneSettings.blurRange,
                   get: { self.settings.blurRadius }, set: { self.settings.blurRadius = $0 },
                   format: { String(format: "%.0f pt", $0) }),
        SliderSpec(title: "Grain", range: StoneSettings.grainRange,
                   get: { self.settings.grain }, set: { self.settings.grain = $0 }),
        SliderSpec(title: "Refraction", range: StoneSettings.distortionRange,
                   get: { self.settings.distortion }, set: { self.settings.distortion = $0 },
                   format: { String(format: "%.0f pt", $0) }),
        SliderSpec(title: "Translucency", range: StoneSettings.translucencyRange,
                   get: { self.settings.translucency }, set: { self.settings.translucency = $0 }),
        SliderSpec(title: "Surface Scale", range: StoneSettings.surfaceScaleRange,
                   get: { self.settings.surfaceScale }, set: { self.settings.surfaceScale = $0 },
                   format: { String(format: "%.0f pt", $0) }),
    ]

    private lazy var toneSliders: [SliderSpec] = [
        SliderSpec(title: "Saturation", range: StoneSettings.saturationRange,
                   get: { self.settings.saturation }, set: { self.settings.saturation = $0 },
                   format: { String(format: "%.2f×", $0) }),
        SliderSpec(title: "Brightness", range: StoneSettings.brightnessRange,
                   get: { self.settings.brightness }, set: { self.settings.brightness = $0 },
                   format: { String(format: "%.2f×", $0) }),
    ]

    private lazy var stylizeSliders: [SliderSpec] = [
        SliderSpec(title: "Chromatic Aberration", range: StoneSettings.chromaticRange,
                   get: { self.settings.chromaticAberration }, set: { self.settings.chromaticAberration = $0 },
                   format: { $0 < 0.1 ? "Off" : String(format: "%.1f px", $0) }),
        SliderSpec(title: "Scanlines", range: StoneSettings.scanlineStrengthRange,
                   get: { self.settings.scanlineStrength }, set: { self.settings.scanlineStrength = $0 },
                   format: { $0 < 0.01 ? "Off" : String(format: "%.0f%%", $0 * 100) }),
        SliderSpec(title: "Scanline Spacing", range: StoneSettings.scanlineSpacingRange,
                   get: { self.settings.scanlineSpacing }, set: { self.settings.scanlineSpacing = $0 },
                   format: { String(format: "%.0f px", $0) }),
    ]

    private lazy var rippleSliders: [SliderSpec] = [
        SliderSpec(title: "Push Distance", range: StoneSettings.ripplePushRange,
                   get: { self.settings.ripplePush }, set: { self.settings.ripplePush = $0 },
                   format: { String(format: "%.0f pt", $0) }),
        SliderSpec(title: "Wave Speed", range: StoneSettings.rippleSpeedRange,
                   get: { self.settings.rippleSpeed }, set: { self.settings.rippleSpeed = $0 },
                   format: { String(format: "%.0f pt/s", $0) }),
        SliderSpec(title: "Ring Width", range: StoneSettings.rippleWidthRange,
                   get: { self.settings.rippleWidth }, set: { self.settings.rippleWidth = $0 },
                   format: { String(format: "%.0f pt", $0) }),
        SliderSpec(title: "Reveal Edge", range: StoneSettings.rippleEdgeRange,
                   get: { self.settings.rippleEdge }, set: { self.settings.rippleEdge = $0 },
                   format: { String(format: "%.0f pt", $0) }),
        SliderSpec(title: "Dispersion λ", range: StoneSettings.rippleWavelengthRange,
                   get: { self.settings.rippleWavelength }, set: { self.settings.rippleWavelength = $0 },
                   format: { $0 < 1 ? "Off" : String(format: "%.0f pt", $0) }),
        SliderSpec(title: "Dispersion Decay", range: StoneSettings.rippleDecayRange,
                   get: { self.settings.rippleDecay }, set: { self.settings.rippleDecay = $0 },
                   format: { String(format: "%.0f pt", $0) }),
        SliderSpec(title: "Duration", range: StoneSettings.rippleDurationRange,
                   get: { self.settings.rippleDuration }, set: { self.settings.rippleDuration = $0 },
                   format: { $0 < 0.01 ? "Auto" : String(format: "%.2f s", $0) }),
    ]

    // MARK: Live media footer

    private let footer = UIView()
    private let stageView = UIView()        // stable layout host (effect + fullscreen)
    private let contentView = UIView()      // throwaway view the effect captures
    private let mediaImageView = UIImageView()
    private let stagePlaceholder = UILabel()
    private var mediaEffect: StoneEffectView?

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
        view.backgroundColor = .systemGroupedBackground

        tableView.dataSource = self
        tableView.delegate = self
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)

        buildFooter()

        header.title = material.title
        header.setLeadingControls([NavHeaderBar.backButton(target: self, action: #selector(headerBack))])
        let headerBottom = header.mount(in: self)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: headerBottom),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: footer.topAnchor),

            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 260),
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
    }

    @objc private func headerBack() {
        if let navigationController, navigationController.viewControllers.count > 1 {
            navigationController.popViewController(animated: true)
        } else {
            dismiss(animated: true)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        ensureMediaEffect()
        // Detached capture view gets no automatic layout — size it to the stage.
        if contentView.bounds.size != stageView.bounds.size {
            contentView.frame = CGRect(origin: .zero, size: stageView.bounds.size)
            contentView.layoutIfNeeded()
            mediaEffect?.setNeedsCapture()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        ensureMediaEffect()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-effectSampleImage"), mediaImageView.image == nil {
            show(image: Self.debugSampleImage(size: contentView.bounds.size))
        }
        #endif
    }

    #if DEBUG
    /// A procedural, content-rich test image (gradient + shapes + text) so the stone
    /// material can be eyeballed over real pixels in the simulator.
    static func debugSampleImage(size: CGSize) -> UIImage {
        let s = size.width > 0 ? size : CGSize(width: 370, height: 200)
        let r = UIGraphicsImageRenderer(size: s)
        return r.image { ctx in
            let c = ctx.cgContext
            let cols = [UIColor.systemTeal.cgColor, UIColor.systemIndigo.cgColor, UIColor.systemOrange.cgColor]
            let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: cols as CFArray, locations: [0, 0.5, 1])!
            c.drawLinearGradient(grad, start: .zero, end: CGPoint(x: s.width, y: s.height), options: [])
            UIColor.white.withAlphaComponent(0.9).setFill()
            c.fillEllipse(in: CGRect(x: s.width * 0.55, y: s.height * 0.2, width: s.height * 0.5, height: s.height * 0.5))
            UIColor.systemPink.setFill()
            c.fill(CGRect(x: s.width * 0.1, y: s.height * 0.55, width: s.width * 0.35, height: s.height * 0.3))
            let str = NSAttributedString(string: "STONE", attributes: [
                .font: UIFont.systemFont(ofSize: s.height * 0.28, weight: .heavy),
                .foregroundColor: UIColor.white])
            str.draw(at: CGPoint(x: s.width * 0.08, y: s.height * 0.1))
        }
    }
    #endif

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
    private func footerConfig() -> StoneConfig {
        settings.currentConfig
    }

    // MARK: Table structure

    func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .body: return bodySliders.count + 1   // sliders + tint colour cell
        case .tone: return toneSliders.count
        case .stylize: return stylizeSliders.count
        case .ripple: return rippleSliders.count + 2   // + reveal-mode picker + angle
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .body: return material == .jellystone ? "Sea Glass" : "Lune"
        case .tone: return "Tone"
        case .stylize: return "Stylize"
        case .ripple: return "Ripple Transition"
        }
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .body:
            return material == .jellystone
                ? "A cheerful pastel sea-glass pebble: a fuzzy, grainy translucency that "
                    + "fades from a clear rim to a coloured, milky centre. Colour Reach sets "
                    + "how far the colour spreads; Translucency how strongly it veils the image."
                : "A milky, semi-transparent lune: a cloudy translucency with a cool cast, "
                    + "clear at the rim and frosted toward the centre."
        case .ripple:
            return "Tap the preview below to fire the wave, which sweeps the effect in "
                + "and out from the touch point. Dispersion λ adds trailing ripples; "
                + "Duration Auto fits the wave to the view."
        default:
            return nil
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch Section(rawValue: indexPath.section)! {
        case .body:
            if indexPath.row < bodySliders.count { return sliderCell(bodySliders[indexPath.row]) }
            return tintColorCell()
        case .tone:
            return sliderCell(toneSliders[indexPath.row])
        case .stylize:
            return sliderCell(stylizeSliders[indexPath.row])
        case .ripple:
            switch indexPath.row {
            case 0: return revealModeCell()
            case 1: return revealAngleCell()
            default: return sliderCell(rippleSliders[indexPath.row - 2])
            }
        }
    }

    /// Segmented control choosing the transition wavefront shape.
    private func revealModeCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        let control = UISegmentedControl(items: StoneConfig.RevealMode.allCases.map(\.title))
        control.selectedSegmentIndex = settings.revealMode.rawValue
        control.apportionsSegmentWidthsByContent = true
        control.addAction(UIAction { [weak self] _ in
            if let mode = StoneConfig.RevealMode(rawValue: control.selectedSegmentIndex) {
                self?.settings.revealMode = mode
                self?.settingsChanged()
            }
        }, for: .valueChanged)
        embed(control, in: cell)
        return cell
    }

    private func revealAngleCell() -> UITableViewCell {
        sliderCell(SliderSpec(
            title: "Reveal Angle", range: StoneSettings.revealAngleRange,
            get: { self.settings.revealAngle }, set: { self.settings.revealAngle = $0 },
            format: { String(format: "%.0f°", $0 * 180 / .pi) }))
    }

    /// Pins a control inside a cell's content view with standard margins.
    private func embed(_ control: UIView, in cell: UITableViewCell) {
        control.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(control)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            control.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            control.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 8),
            control.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -8),
        ])
    }

    // MARK: Cell builders

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
        content.text = "Stone Colour"
        cell.contentConfiguration = content
        cell.selectionStyle = .none

        let well = UIColorWell()
        well.supportsAlpha = true
        well.selectedColor = settings.tint
        well.addAction(UIAction { [weak self, weak well] _ in
            guard let color = well?.selectedColor else { return }
            self?.settings.tint = color
            self?.settingsChanged()
        }, for: .valueChanged)
        cell.accessoryView = well
        return cell
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

        // `contentView` is the captured view, deliberately kept OUT of the on-screen
        // hierarchy: CARenderer renders an arbitrary layer tree, and an on-screen
        // captured layer triggers a UIKit/CARenderer tug-of-war that corrupts on
        // resize. Detached, we drive its bounds by hand to match the stage.
        contentView.backgroundColor = .black
        contentView.frame = stageView.bounds

        mediaImageView.contentMode = .scaleAspectFill
        mediaImageView.clipsToBounds = true
        mediaImageView.backgroundColor = .black
        mediaImageView.frame = contentView.bounds
        mediaImageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(mediaImageView)

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
        // In the stage (not the footer) so it stays tappable when the stage is
        // fullscreen and drawn above the 260pt footer's frame.
        stageView.addSubview(fullscreenButton)

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

            // contentView + mediaImageView are frame-driven (see buildFooter); only
            // the placeholder stays Auto-Laid-out, centered in the stable stageView.
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

        // Reparent the stage to the top-level view when fullscreen so its whole area
        // is hit-testable (a stage parented to the 260pt footer can't receive touches
        // above the footer's frame — the exit button included).
        if isStageFullscreen {
            NSLayoutConstraint.deactivate(footerStageConstraints)
            view.addSubview(stageView)
            NSLayoutConstraint.activate(fullscreenStageConstraints)
        } else {
            NSLayoutConstraint.deactivate(fullscreenStageConstraints)
            footer.addSubview(stageView)
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
        contentView.frame = CGRect(origin: .zero, size: stageView.bounds.size)
        contentView.layoutIfNeeded()   // detached view: lay out its image by hand
        // Capture the throwaway `contentView`; host the effect on the stable stageView.
        let effect = stageView.applyStone(footerConfig(), capturing: contentView)
        effect?.ripplesOnTap = true   // tap the stage to fire the ripple transition
        mediaEffect = effect
        stageView.bringSubviewToFront(stagePlaceholder)
        stageView.bringSubviewToFront(fullscreenButton)
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
        // Most clips are <=30fps and the effect hides the difference; cap the tick so
        // we don't decode/capture/render at 120Hz on ProMotion for no visible gain.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        videoLink = link
    }

    private func teardownLiveLink() {
        videoLink?.invalidate()
        videoLink = nil
    }

    fileprivate func liveTick() {
        if videoOutput != nil {
            // Only re-capture when a NEW video frame was actually decoded — otherwise
            // we'd force a capture + shader pass on every tick with no new content.
            if readVideoFrame() { mediaEffect?.setNeedsCapture() }
        } else {
            // Animated GIF: frames advance inside the image view, so re-capture each tick.
            mediaEffect?.setNeedsCapture()
        }
    }

    /// Decodes the current video frame into the image view. Returns true iff a new
    /// frame was available (so callers only re-capture when something changed).
    @discardableResult
    private func readVideoFrame() -> Bool {
        guard let output = videoOutput else { return false }
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: time),
              let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
        else { return false }
        var ciImage = CIImage(cvPixelBuffer: buffer)
        if let orientation = videoOrientation { ciImage = ciImage.oriented(orientation) }
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return false }
        mediaImageView.stopAnimating()
        mediaImageView.image = UIImage(cgImage: cgImage)
        return true
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
    weak var target: StoneSettingsScreen?
    init(_ target: StoneSettingsScreen) { self.target = target }
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

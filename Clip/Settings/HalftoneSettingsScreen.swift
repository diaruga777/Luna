//
//  HalftoneSettingsScreen.swift
//  Clip
//

import UIKit
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers
import ClipContentRendering

/// Experimental controls for the Halftone visual effect: a master toggle that
/// overlays the effect on the entire app UI, the full set of tunable parameters
/// (each exposed across its maximum range), the ripple-transition parameters, and
/// a live media preview pinned to the bottom — pick a photo/video/GIF and tap it
/// to fire the ripple that animates the effect in and out.
final class HalftoneSettingsScreen: UIViewController, UITableViewDataSource, UITableViewDelegate,
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
        case grid, shape, dots, gaps, ripple, drag
    }

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)

    // MARK: Slider groups

    private lazy var gridSliders: [SliderSpec] = [
        SliderSpec(title: "Cell Size", range: HalftoneSettings.cellSizeRange,
                   get: { HalftoneSettings.cellSize }, set: { HalftoneSettings.cellSize = $0 },
                   format: { String(format: "%.0f pt", $0) }),
        SliderSpec(title: "Dot Spacing", range: HalftoneSettings.dotSpacingRange,
                   get: { HalftoneSettings.dotSpacing }, set: { HalftoneSettings.dotSpacing = $0 },
                   format: { String(format: "%.2f×", $0) }),
        SliderSpec(title: "Grid Angle", range: HalftoneSettings.gridAngleRange,
                   get: { HalftoneSettings.gridAngle }, set: { HalftoneSettings.gridAngle = $0 },
                   format: { String(format: "%.0f°", $0 * 180 / .pi) }),
        SliderSpec(title: "Jitter", range: HalftoneSettings.jitterRange,
                   get: { HalftoneSettings.jitter }, set: { HalftoneSettings.jitter = $0 }),
    ]

    private lazy var dotSliders: [SliderSpec] = [
        SliderSpec(title: "Dot Size", range: HalftoneSettings.dotScaleRange,
                   get: { HalftoneSettings.dotScale }, set: { HalftoneSettings.dotScale = $0 },
                   format: { String(format: "%.2f×", $0) }),
        SliderSpec(title: "Dot Opacity", range: HalftoneSettings.dotOpacityRange,
                   get: { HalftoneSettings.dotOpacity }, set: { HalftoneSettings.dotOpacity = $0 }),
        SliderSpec(title: "Edge Softness", range: HalftoneSettings.edgeSoftnessRange,
                   get: { HalftoneSettings.edgeSoftness }, set: { HalftoneSettings.edgeSoftness = $0 },
                   format: { String(format: "%.1f px", $0) }),
        SliderSpec(title: "Brightness Boost", range: HalftoneSettings.brightnessBoostRange,
                   get: { HalftoneSettings.brightnessBoost }, set: { HalftoneSettings.brightnessBoost = $0 },
                   format: { String(format: "%.2f×", $0) }),
    ]

    private lazy var gapSliders: [SliderSpec] = [
        SliderSpec(title: "Gap Opacity", range: HalftoneSettings.gapAlphaRange,
                   get: { HalftoneSettings.gapColorAlpha }, set: { HalftoneSettings.gapColorAlpha = $0 }),
        SliderSpec(title: "Gap Blur", range: HalftoneSettings.gapBlurRange,
                   get: { HalftoneSettings.gapBlur }, set: { HalftoneSettings.gapBlur = $0 },
                   format: { String(format: "%.0f px", $0) }),
        SliderSpec(title: "Gap Source Mix", range: HalftoneSettings.gapSourceMixRange,
                   get: { HalftoneSettings.gapSourceMix }, set: { HalftoneSettings.gapSourceMix = $0 }),
    ]

    private lazy var rippleSliders: [SliderSpec] = [
        SliderSpec(title: "Push Distance", range: HalftoneSettings.ripplePushRange,
                   get: { HalftoneSettings.ripplePush }, set: { HalftoneSettings.ripplePush = $0 },
                   format: { String(format: "%.0f pt", $0) }),
        SliderSpec(title: "Wave Speed", range: HalftoneSettings.rippleSpeedRange,
                   get: { HalftoneSettings.rippleSpeed }, set: { HalftoneSettings.rippleSpeed = $0 },
                   format: { String(format: "%.0f pt/s", $0) }),
        SliderSpec(title: "Ring Width", range: HalftoneSettings.rippleWidthRange,
                   get: { HalftoneSettings.rippleWidth }, set: { HalftoneSettings.rippleWidth = $0 },
                   format: { String(format: "%.0f pt", $0) }),
        SliderSpec(title: "Reveal Edge", range: HalftoneSettings.rippleEdgeRange,
                   get: { HalftoneSettings.rippleEdge }, set: { HalftoneSettings.rippleEdge = $0 },
                   format: { String(format: "%.0f pt", $0) }),
        SliderSpec(title: "Dispersion λ", range: HalftoneSettings.rippleWavelengthRange,
                   get: { HalftoneSettings.rippleWavelength }, set: { HalftoneSettings.rippleWavelength = $0 },
                   format: { $0 < 1 ? "Off" : String(format: "%.0f pt", $0) }),
        SliderSpec(title: "Dispersion Decay", range: HalftoneSettings.rippleDecayRange,
                   get: { HalftoneSettings.rippleDecay }, set: { HalftoneSettings.rippleDecay = $0 },
                   format: { String(format: "%.0f pt", $0) }),
        SliderSpec(title: "Duration", range: HalftoneSettings.rippleDurationRange,
                   get: { HalftoneSettings.rippleDuration }, set: { HalftoneSettings.rippleDuration = $0 },
                   format: { $0 < 0.01 ? "Auto" : String(format: "%.2f s", $0) }),
    ]

    private lazy var dragSliders: [SliderSpec] = [
        SliderSpec(title: "Reach", range: HalftoneSettings.dragRadiusRange,
                   get: { HalftoneSettings.dragRadius }, set: { HalftoneSettings.dragRadius = $0 },
                   format: { String(format: "%.0f pt", $0) }),
        SliderSpec(title: "Strength", range: HalftoneSettings.dragStrengthRange,
                   get: { HalftoneSettings.dragStrength }, set: { HalftoneSettings.dragStrength = $0 },
                   format: { String(format: "%.2f×", $0) }),
        SliderSpec(title: "Snap-Back Distance", range: HalftoneSettings.dragMaxDistanceRange,
                   get: { HalftoneSettings.dragMaxDistance }, set: { HalftoneSettings.dragMaxDistance = $0 },
                   format: { String(format: "%.0f pt", $0) }),
    ]

    // MARK: Live media footer

    private let footer = UIView()
    private let stageView = UIView()
    private let mediaImageView = UIImageView()
    private let stagePlaceholder = UILabel()
    private var mediaEffect: HalftoneEffectView?

    // Fullscreen toggle (item 7): the stage is pinned to the footer normally and to
    // the whole view when expanded. Both constraint sets are swapped on toggle.
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
        title = "Halftone Effect"
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
    private func footerConfig() -> HalftoneConfig {
        HalftoneSettings.currentConfig
    }

    // MARK: Table structure

    func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .grid: return gridSliders.count
        case .shape: return 2
        case .dots: return dotSliders.count + 3
        case .gaps: return gapSliders.count + 1
        case .ripple: return rippleSliders.count
        case .drag: return dragSliders.count
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .grid: return "Grid"
        case .shape: return "Dot Shape"
        case .dots: return "Dots"
        case .gaps: return "Gaps (space between dots)"
        case .ripple: return "Ripple Transition"
        case .drag: return "Drag (finger-follow)"
        }
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .ripple:
            return "Tap the preview below to fire the ripple, which reveals the dots at "
                + "an expanding wavefront and pushes them outward. Reveal Edge softens the "
                + "wavefront. Dispersion λ adds trailing ripples; set it to Off for a single "
                + "clean ring. Duration Auto fits the wave to the view."
        case .drag:
            return "Drag across the preview and the dots near your finger follow it, like "
                + "paint pulled across water, snapping back once you pass the snap-back "
                + "distance. Strength 0 turns this off."
        case .dots:
            return "Transparent Background hides the un-rippled image so a tap reveals the "
                + "dots over a clear background (and hides them again)."
        default:
            return nil
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch Section(rawValue: indexPath.section)! {
        case .grid:
            return sliderCell(gridSliders[indexPath.row])
        case .shape:
            return indexPath.row == 0 ? shapePickerCell() : cornerRadiusCell()
        case .dots:
            if indexPath.row < dotSliders.count { return sliderCell(dotSliders[indexPath.row]) }
            switch indexPath.row - dotSliders.count {
            case 0: return averageCellToggleCell()
            case 1: return greyscaleToggleCell()
            default: return transparentBackgroundToggleCell()
            }
        case .gaps:
            if indexPath.row == 0 { return gapColorCell() }
            return sliderCell(gapSliders[indexPath.row - 1])
        case .ripple:
            return sliderCell(rippleSliders[indexPath.row])
        case .drag:
            return sliderCell(dragSliders[indexPath.row])
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

    private func shapePickerCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        let control = UISegmentedControl(items: HalftoneSettings.ShapeKind.allCases.map(\.title))
        control.selectedSegmentIndex = HalftoneSettings.shapeKind.rawValue
        control.addAction(UIAction { [weak self] _ in
            if let kind = HalftoneSettings.ShapeKind(rawValue: control.selectedSegmentIndex) {
                HalftoneSettings.shapeKind = kind
                self?.settingsChanged()
            }
        }, for: .valueChanged)
        embed(control, in: cell)
        return cell
    }

    private func cornerRadiusCell() -> UITableViewCell {
        sliderCell(SliderSpec(
            title: "Corner Radius", range: HalftoneSettings.cornerRadiusRange,
            get: { HalftoneSettings.cornerRadius }, set: { HalftoneSettings.cornerRadius = $0 }))
    }

    private func averageCellToggleCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.text = "Average Cell"
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        cell.accessoryView = makeToggle(
            isOn: HalftoneSettings.averageCell, action: #selector(averageCellToggled(_:)))
        return cell
    }

    @objc private func averageCellToggled(_ toggle: UISwitch) {
        HalftoneSettings.averageCell = toggle.isOn
        settingsChanged()
    }

    private func greyscaleToggleCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.text = "Greyscale"
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        cell.accessoryView = makeToggle(
            isOn: HalftoneSettings.monochrome, action: #selector(greyscaleToggled(_:)))
        return cell
    }

    @objc private func greyscaleToggled(_ toggle: UISwitch) {
        HalftoneSettings.monochrome = toggle.isOn
        settingsChanged()
    }

    private func transparentBackgroundToggleCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.text = "Transparent Background"
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        cell.accessoryView = makeToggle(
            isOn: HalftoneSettings.transparentBackground, action: #selector(transparentBackgroundToggled(_:)))
        return cell
    }

    @objc private func transparentBackgroundToggled(_ toggle: UISwitch) {
        HalftoneSettings.transparentBackground = toggle.isOn
        settingsChanged()
    }

    private func gapColorCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.text = "Gap Color"
        cell.contentConfiguration = content
        cell.selectionStyle = .none

        let well = UIColorWell()
        well.supportsAlpha = true
        well.selectedColor = HalftoneSettings.gapColor
        well.addAction(UIAction { [weak self, weak well] _ in
            guard let color = well?.selectedColor else { return }
            HalftoneSettings.gapColor = color
            self?.settingsChanged()
        }, for: .valueChanged)
        cell.accessoryView = well
        return cell
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
            footer.clipsToBounds = false
        } else {
            NSLayoutConstraint.deactivate(fullscreenStageConstraints)
            NSLayoutConstraint.activate(footerStageConstraints)
        }
        UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseInOut) {
            self.view.layoutIfNeeded()
        } completion: { _ in
            // The stage changed size and the image its fit — force a fresh capture.
            self.mediaEffect?.setNeedsCapture()
        }
        // Re-capture continuously through the resize animation so it tracks live.
        mediaEffect?.setNeedsCapture()
    }

    /// Apply the effect to the stage once it is laid out. The effect re-renders the
    /// stage every frame, so media changes and live setting tweaks flow through.
    private func ensureMediaEffect() {
        guard mediaEffect == nil, stageView.bounds.width > 0 else { return }
        let effect = stageView.applyHalftone(footerConfig())
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
            // Animated GIF: drive a per-frame re-capture so the dots track the motion.
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
    weak var target: HalftoneSettingsScreen?
    init(_ target: HalftoneSettingsScreen) { self.target = target }
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
    var ciOrientation: CGImagePropertyOrientation {
        switch (a, b, c, d) {
        case (0, 1, -1, 0): return .right   // portrait
        case (0, -1, 1, 0): return .left    // portrait upside-down
        case (-1, 0, 0, -1): return .down   // landscape left
        default: return .up                 // identity / landscape right
        }
    }
}

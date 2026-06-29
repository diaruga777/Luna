//
//  DotMatrixSettingsScreen.swift
//  Clip
//

import ClipReadingListUI
import UIKit
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers
import ClipContentRendering

/// Experimental controls for the DotMatrix visual effect: a master toggle that
/// overlays the effect on the entire app UI, the full set of tunable parameters
/// (each exposed across its maximum range), the ripple-transition parameters, and
/// a live media preview pinned to the bottom — pick a photo/video/GIF and tap it
/// to fire the ripple that animates the effect in and out.
final class DotMatrixSettingsScreen: UIViewController, UITableViewDataSource, UITableViewDelegate,
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
        case grid, shape, dots, gaps, stylize, ripple, drag
    }

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)

    // MARK: Slider groups

    private lazy var gridSliders: [SliderSpec] = [
        SliderSpec(title: "Cell Size", range: DotMatrixSettings.cellSizeRange,
                   get: { DotMatrixSettings.cellSize }, set: { DotMatrixSettings.cellSize = $0 },
                   format: { String(format: "%.0f pt", $0) }),
        SliderSpec(title: "Dot Spacing", range: DotMatrixSettings.dotSpacingRange,
                   get: { DotMatrixSettings.dotSpacing }, set: { DotMatrixSettings.dotSpacing = $0 },
                   format: { String(format: "%.2f×", $0) }),
        SliderSpec(title: "Grid Angle", range: DotMatrixSettings.gridAngleRange,
                   get: { DotMatrixSettings.gridAngle }, set: { DotMatrixSettings.gridAngle = $0 },
                   format: { String(format: "%.0f°", $0 * 180 / .pi) }),
        SliderSpec(title: "Jitter", range: DotMatrixSettings.jitterRange,
                   get: { DotMatrixSettings.jitter }, set: { DotMatrixSettings.jitter = $0 }),
    ]

    private lazy var dotSliders: [SliderSpec] = [
        SliderSpec(title: "Dot Size", range: DotMatrixSettings.dotScaleRange,
                   get: { DotMatrixSettings.dotScale }, set: { DotMatrixSettings.dotScale = $0 },
                   format: { String(format: "%.2f×", $0) }),
        SliderSpec(title: "Dot Opacity", range: DotMatrixSettings.dotOpacityRange,
                   get: { DotMatrixSettings.dotOpacity }, set: { DotMatrixSettings.dotOpacity = $0 }),
        SliderSpec(title: "Edge Softness", range: DotMatrixSettings.edgeSoftnessRange,
                   get: { DotMatrixSettings.edgeSoftness }, set: { DotMatrixSettings.edgeSoftness = $0 },
                   format: { String(format: "%.1f px", $0) }),
        SliderSpec(title: "Brightness Boost", range: DotMatrixSettings.brightnessBoostRange,
                   get: { DotMatrixSettings.brightnessBoost }, set: { DotMatrixSettings.brightnessBoost = $0 },
                   format: { String(format: "%.2f×", $0) }),
    ]

    private lazy var gapSliders: [SliderSpec] = [
        SliderSpec(title: "Gap Opacity", range: DotMatrixSettings.gapAlphaRange,
                   get: { DotMatrixSettings.gapColorAlpha }, set: { DotMatrixSettings.gapColorAlpha = $0 }),
        SliderSpec(title: "Gap Blur", range: DotMatrixSettings.gapBlurRange,
                   get: { DotMatrixSettings.gapBlur }, set: { DotMatrixSettings.gapBlur = $0 },
                   format: { String(format: "%.0f px", $0) }),
        SliderSpec(title: "Gap Source Mix", range: DotMatrixSettings.gapSourceMixRange,
                   get: { DotMatrixSettings.gapSourceMix }, set: { DotMatrixSettings.gapSourceMix = $0 }),
    ]

    private lazy var rippleSliders: [SliderSpec] = [
        SliderSpec(title: "Push Distance", range: DotMatrixSettings.ripplePushRange,
                   get: { DotMatrixSettings.ripplePush }, set: { DotMatrixSettings.ripplePush = $0 },
                   format: { String(format: "%.0f pt", $0) }),
        SliderSpec(title: "Wave Speed", range: DotMatrixSettings.rippleSpeedRange,
                   get: { DotMatrixSettings.rippleSpeed }, set: { DotMatrixSettings.rippleSpeed = $0 },
                   format: { String(format: "%.0f pt/s", $0) }),
        SliderSpec(title: "Ring Width", range: DotMatrixSettings.rippleWidthRange,
                   get: { DotMatrixSettings.rippleWidth }, set: { DotMatrixSettings.rippleWidth = $0 },
                   format: { String(format: "%.0f pt", $0) }),
        SliderSpec(title: "Reveal Edge", range: DotMatrixSettings.rippleEdgeRange,
                   get: { DotMatrixSettings.rippleEdge }, set: { DotMatrixSettings.rippleEdge = $0 },
                   format: { String(format: "%.0f pt", $0) }),
        SliderSpec(title: "Dispersion λ", range: DotMatrixSettings.rippleWavelengthRange,
                   get: { DotMatrixSettings.rippleWavelength }, set: { DotMatrixSettings.rippleWavelength = $0 },
                   format: { $0 < 1 ? "Off" : String(format: "%.0f pt", $0) }),
        SliderSpec(title: "Dispersion Decay", range: DotMatrixSettings.rippleDecayRange,
                   get: { DotMatrixSettings.rippleDecay }, set: { DotMatrixSettings.rippleDecay = $0 },
                   format: { String(format: "%.0f pt", $0) }),
        SliderSpec(title: "Duration", range: DotMatrixSettings.rippleDurationRange,
                   get: { DotMatrixSettings.rippleDuration }, set: { DotMatrixSettings.rippleDuration = $0 },
                   format: { $0 < 0.01 ? "Auto" : String(format: "%.2f s", $0) }),
    ]

    private lazy var stylizeSliders: [SliderSpec] = [
        SliderSpec(title: "Posterize", range: DotMatrixSettings.posterizeRange,
                   get: { DotMatrixSettings.posterizeLevels }, set: { DotMatrixSettings.posterizeLevels = $0 },
                   format: { $0 < 1.5 ? "Off" : String(format: "%.0f levels", $0) }),
        SliderSpec(title: "Chromatic Aberration", range: DotMatrixSettings.chromaticRange,
                   get: { DotMatrixSettings.chromaticAberration }, set: { DotMatrixSettings.chromaticAberration = $0 },
                   format: { $0 < 0.1 ? "Off" : String(format: "%.1f px", $0) }),
        SliderSpec(title: "Scanlines", range: DotMatrixSettings.scanlineStrengthRange,
                   get: { DotMatrixSettings.scanlineStrength }, set: { DotMatrixSettings.scanlineStrength = $0 },
                   format: { $0 < 0.01 ? "Off" : String(format: "%.0f%%", $0 * 100) }),
        SliderSpec(title: "Scanline Spacing", range: DotMatrixSettings.scanlineSpacingRange,
                   get: { DotMatrixSettings.scanlineSpacing }, set: { DotMatrixSettings.scanlineSpacing = $0 },
                   format: { String(format: "%.0f px", $0) }),
    ]

    private lazy var dragSliders: [SliderSpec] = [
        SliderSpec(title: "Reach", range: DotMatrixSettings.dragRadiusRange,
                   get: { DotMatrixSettings.dragRadius }, set: { DotMatrixSettings.dragRadius = $0 },
                   format: { String(format: "%.0f pt", $0) }),
        SliderSpec(title: "Strength", range: DotMatrixSettings.dragStrengthRange,
                   get: { DotMatrixSettings.dragStrength }, set: { DotMatrixSettings.dragStrength = $0 },
                   format: { String(format: "%.2f×", $0) }),
        SliderSpec(title: "Snap-Back Distance", range: DotMatrixSettings.dragMaxDistanceRange,
                   get: { DotMatrixSettings.dragMaxDistance }, set: { DotMatrixSettings.dragMaxDistance = $0 },
                   format: { String(format: "%.0f pt", $0) }),
    ]

    // MARK: Live media footer

    private let footer = UIView()
    private let stageView = UIView()        // stable layout host (effect + fullscreen)
    private let contentView = UIView()      // throwaway view the effect captures
    private let mediaImageView = UIImageView()
    private let stagePlaceholder = UILabel()
    private var mediaEffect: DotMatrixEffectView?

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
        title = "DotMatrix Effect"
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
        // The captured content view is detached from the hierarchy, so it never gets
        // automatic layout — size it to match the stage and lay it out by hand, then
        // ask the effect to re-capture (e.g. on the fullscreen toggle).
        if contentView.bounds.size != stageView.bounds.size {
            contentView.frame = CGRect(origin: .zero, size: stageView.bounds.size)
            contentView.layoutIfNeeded()
            mediaEffect?.setNeedsCapture()
        }
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
    private func footerConfig() -> DotMatrixConfig {
        DotMatrixSettings.currentConfig
    }

    // MARK: Table structure

    func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .grid: return gridSliders.count
        case .shape: return 2
        case .dots: return dotSliders.count + 3
        case .gaps: return gapSliders.count + 1
        case .stylize: return stylizeSliders.count
        case .ripple: return rippleSliders.count + 2   // + reveal-mode picker + angle
        case .drag: return dragSliders.count
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .grid: return "Grid"
        case .shape: return "Dot Shape"
        case .dots: return "Dots"
        case .gaps: return "Gaps (space between dots)"
        case .stylize: return "Stylize"
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
        case .stylize:
            return sliderCell(stylizeSliders[indexPath.row])
        case .ripple:
            switch indexPath.row {
            case 0: return revealModeCell()
            case 1: return revealAngleCell()
            default: return sliderCell(rippleSliders[indexPath.row - 2])
            }
        case .drag:
            return sliderCell(dragSliders[indexPath.row])
        }
    }

    /// Segmented control choosing the transition wavefront shape.
    private func revealModeCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        let control = UISegmentedControl(items: DotMatrixConfig.RevealMode.allCases.map(\.title))
        control.selectedSegmentIndex = DotMatrixSettings.revealMode.rawValue
        control.apportionsSegmentWidthsByContent = true
        control.addAction(UIAction { [weak self] _ in
            if let mode = DotMatrixConfig.RevealMode(rawValue: control.selectedSegmentIndex) {
                DotMatrixSettings.revealMode = mode
                self?.settingsChanged()
            }
        }, for: .valueChanged)
        embed(control, in: cell)
        return cell
    }

    private func revealAngleCell() -> UITableViewCell {
        sliderCell(SliderSpec(
            title: "Reveal Angle", range: DotMatrixSettings.revealAngleRange,
            get: { DotMatrixSettings.revealAngle }, set: { DotMatrixSettings.revealAngle = $0 },
            format: { String(format: "%.0f°", $0 * 180 / .pi) }))
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
        let control = UISegmentedControl(items: DotMatrixSettings.ShapeKind.allCases.map(\.title))
        control.selectedSegmentIndex = DotMatrixSettings.shapeKind.rawValue
        control.addAction(UIAction { [weak self] _ in
            if let kind = DotMatrixSettings.ShapeKind(rawValue: control.selectedSegmentIndex) {
                DotMatrixSettings.shapeKind = kind
                self?.settingsChanged()
            }
        }, for: .valueChanged)
        embed(control, in: cell)
        return cell
    }

    private func cornerRadiusCell() -> UITableViewCell {
        sliderCell(SliderSpec(
            title: "Corner Radius", range: DotMatrixSettings.cornerRadiusRange,
            get: { DotMatrixSettings.cornerRadius }, set: { DotMatrixSettings.cornerRadius = $0 }))
    }

    private func averageCellToggleCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.text = "Average Cell"
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        cell.accessoryView = makeToggle(
            isOn: DotMatrixSettings.averageCell, action: #selector(averageCellToggled(_:)))
        return cell
    }

    @objc private func averageCellToggled(_ toggle: UISwitch) {
        DotMatrixSettings.averageCell = toggle.isOn
        settingsChanged()
    }

    private func greyscaleToggleCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.text = "Greyscale"
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        cell.accessoryView = makeToggle(
            isOn: DotMatrixSettings.monochrome, action: #selector(greyscaleToggled(_:)))
        return cell
    }

    @objc private func greyscaleToggled(_ toggle: UISwitch) {
        DotMatrixSettings.monochrome = toggle.isOn
        settingsChanged()
    }

    private func transparentBackgroundToggleCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.text = "Transparent Background"
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        cell.accessoryView = makeToggle(
            isOn: DotMatrixSettings.transparentBackground, action: #selector(transparentBackgroundToggled(_:)))
        return cell
    }

    @objc private func transparentBackgroundToggled(_ toggle: UISwitch) {
        DotMatrixSettings.transparentBackground = toggle.isOn
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
        well.selectedColor = DotMatrixSettings.gapColor
        well.addAction(UIAction { [weak self, weak well] _ in
            guard let color = well?.selectedColor else { return }
            DotMatrixSettings.gapColor = color
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

        // `contentView` is the view the effect CAPTURES — and it is deliberately kept
        // OUT of the on-screen view hierarchy. CARenderer renders an arbitrary layer
        // tree into a texture; if the captured view were on-screen, UIKit would keep
        // re-parenting its layer under the stage while CARenderer claims it as a render
        // root, and that tug-of-war corrupts on resize (use-after-free). Detached, its
        // layer is ours alone. We drive its bounds manually to match the stage.
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
        // Lives in the stage (not the footer): in fullscreen the stage covers the
        // screen, and a button parented to the 260pt footer would be drawn outside the
        // footer's bounds and so never receive touches above it.
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
        // Stage placement when expanded to fill the screen. Pinned to `view` (the
        // stage is reparented there in toggleFullscreen) — NOT the 260pt footer, or
        // it would be sized/positioned relative to the footer region.
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
        // is hit-testable: parented to the 260pt footer, anything the stage draws
        // above the footer's frame can't receive touches (the exit button included).
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
        contentView.frame = CGRect(origin: .zero, size: stageView.bounds.size)
        contentView.layoutIfNeeded()   // detached view: lay out its image by hand
        // Capture the throwaway `contentView`; host the effect on the stable stageView.
        let effect = stageView.applyDotMatrix(footerConfig(), capturing: contentView)
        effect?.ripplesOnTap = true   // tap the stage to fire the ripple transition
        mediaEffect = effect
        // Keep the hint + fullscreen button above the effect overlay (and tappable).
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
        // Most clips are <=30fps and the dot grid hides the difference; cap the tick so
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
    weak var target: DotMatrixSettingsScreen?
    init(_ target: DotMatrixSettingsScreen) { self.target = target }
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

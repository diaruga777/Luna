//
//  RabbitHoleTransitionSettingsScreen.swift
//  Clip
//
//  Tuning UI for the RabbitHole reader's two-phase pixel-mosaic transition. Each row
//  edits one `RabbitHoleTransitionSettings` value live; the changes take effect on the
//  next dive / pop / overscroll.
//

import UIKit

final class RabbitHoleTransitionSettingsScreen: UITableViewController {

    private enum Section: Int, CaseIterable {
        case cellSize, phase1, phase2, stagger, color, reset
    }

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Transition Animation"
        navigationItem.largeTitleDisplayMode = .never
    }

    override func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 1 }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .cellSize: return "Pixel Size"
        case .phase1: return "Phase 1 · Dissolve to Pixels"
        case .phase2: return "Phase 2 · Sharpen to Final"
        case .stagger: return "Pixel Stagger"
        case .color: return "Color"
        case .reset: return nil
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .cellSize: return "Size of one mosaic block. Bigger = chunkier pixels."
        case .phase1: return "How long the existing view takes to dissolve, one random pixel at a time, into a pixelated version of the page you tapped."
        case .phase2: return "How long the pixelated page takes to sharpen into the final, readable view."
        case .stagger: return "How spread out the per-pixel reveal is. Left: every pixel flips at once. Right: strictly one pixel at a time."
        case .color: return "Render the dissolve in greyscale instead of full colour."
        case .reset: return nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch Section(rawValue: indexPath.section)! {
        case .cellSize:
            return sliderCell(
                value: Double(RabbitHoleTransitionSettings.pixelSize),
                range: RabbitHoleTransitionSettings.pixelSizeRange,
                minCaption: "6 pt", maxCaption: "64 pt",
                format: { String(format: "%.0f pt", $0) },
                onChange: { RabbitHoleTransitionSettings.pixelSize = CGFloat($0) })
        case .phase1:
            return sliderCell(
                value: RabbitHoleTransitionSettings.phase1Duration,
                range: RabbitHoleTransitionSettings.phase1DurationRange,
                minCaption: "0.1 s", maxCaption: "2.0 s",
                format: { String(format: "%.2f s", $0) },
                onChange: { RabbitHoleTransitionSettings.phase1Duration = $0 })
        case .phase2:
            return sliderCell(
                value: RabbitHoleTransitionSettings.phase2Duration,
                range: RabbitHoleTransitionSettings.phase2DurationRange,
                minCaption: "0.05 s", maxCaption: "1.5 s",
                format: { String(format: "%.2f s", $0) },
                onChange: { RabbitHoleTransitionSettings.phase2Duration = $0 })
        case .stagger:
            return sliderCell(
                value: Double(RabbitHoleTransitionSettings.stagger),
                range: RabbitHoleTransitionSettings.staggerRange,
                minCaption: "Together", maxCaption: "Sequential",
                format: { String(format: "%.0f%%", $0 * 100) },
                onChange: { RabbitHoleTransitionSettings.stagger = CGFloat($0) })
        case .color:
            return monochromeCell()
        case .reset:
            return resetCell()
        }
    }

    // MARK: - Cells

    /// A labelled slider that reports its value live and persists each change.
    private func sliderCell(value: Double, range: ClosedRange<Double>,
                            minCaption: String, maxCaption: String,
                            format: @escaping (Double) -> String,
                            onChange: @escaping (Double) -> Void) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none

        let valueLabel = UILabel()
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        valueLabel.textColor = .secondaryLabel
        valueLabel.textAlignment = .right
        valueLabel.text = format(value)

        let slider = ClosureSlider()
        slider.minimumValue = Float(range.lowerBound)
        slider.maximumValue = Float(range.upperBound)
        slider.value = Float(value)
        slider.onChange = { newValue in
            let v = Double(newValue)
            onChange(v)
            valueLabel.text = format(v)
        }

        let endLabels = UIStackView(arrangedSubviews: [endCaption(minCaption), UIView(), endCaption(maxCaption)])
        endLabels.axis = .horizontal
        endLabels.distribution = .fill

        let stack = UIStackView(arrangedSubviews: [valueLabel, slider, endLabels])
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -10),
        ])
        return cell
    }

    private func monochromeCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        var content = cell.defaultContentConfiguration()
        content.text = "Monochrome"
        cell.contentConfiguration = content
        cell.accessoryView = makeToggle(
            isOn: RabbitHoleTransitionSettings.monochrome, action: #selector(monochromeToggled(_:)))
        return cell
    }

    @objc private func monochromeToggled(_ toggle: UISwitch) {
        RabbitHoleTransitionSettings.monochrome = toggle.isOn
    }

    private func resetCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.text = "Reset to Defaults"
        content.textProperties.color = .systemRed
        content.textProperties.alignment = .center
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard Section(rawValue: indexPath.section) == .reset else { return }
        RabbitHoleTransitionSettings.resetToDefaults()
        tableView.reloadData()
    }

    private func endCaption(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabel
        return label
    }
}

/// A slider that calls a closure on every value change (avoids one @objc target per row).
private final class ClosureSlider: UISlider {
    var onChange: ((Float) -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        addTarget(self, action: #selector(valueChanged), for: .valueChanged)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    @objc private func valueChanged() { onChange?(value) }
}

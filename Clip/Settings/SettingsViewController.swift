//
//  SettingsViewController.swift
//  Clip
//

import UIKit

/// App settings: reading speed, reader appearance, list info, eye tracking,
/// the action-button shortcut, and the Safari extension status — a native
/// inset-grouped table.
final class SettingsViewController: UITableViewController {

    private enum Section: Int, CaseIterable {
        case speed
        case appearance
        case listInfo
        case eyeTracking
        case actionButton
        case extensionStatus
    }

    private let wpmLabel = UILabel()
    private var safariStatusText = ""

    init() {
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        navigationItem.largeTitleDisplayMode = .never
        refreshSafariStatus()
    }

    // MARK: - Table structure

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .speed: return 1
        case .appearance: return 2
        case .listInfo: return 2
        case .eyeTracking: return 1
        case .actionButton: return 2
        case .extensionStatus: return 1
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .speed: return "RSVP Reading Speed"
        case .appearance: return "Reader Appearance"
        case .listInfo: return "Reading List"
        case .eyeTracking: return "Eye Tracking"
        case .actionButton: return "Action Button"
        case .extensionStatus: return "Safari Extension"
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .speed:
            return nil
        case .appearance:
            return nil
        case .listInfo:
            return "Show an estimated reading time and your progress on each article."
        case .eyeTracking:
            return "Uses the front camera (on supported devices) to estimate the last word you read, so audio and RSVP can start there. Turning this off clears all stored estimates."
        case .actionButton:
            return "Save the Safari page you're reading with one press of the Action Button: enable the Clip Safari extension (Settings → Apps → Safari → Extensions), install the shortcut below, then pick \"Clip Safari Page\" in Settings → Action Button."
        case .extensionStatus:
            return safariStatusText
        }
    }

    // MARK: - Cells

    override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()

        switch Section(rawValue: indexPath.section)! {
        case .speed:
            wpmLabel.text = "\(Int(ReaderSettings.baseWPM)) wpm"
            wpmLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
            wpmLabel.textColor = .secondaryLabel
            wpmLabel.sizeToFit()

            let slider = UISlider()
            slider.minimumValue = 100
            slider.maximumValue = 900
            slider.value = Float(ReaderSettings.baseWPM)
            slider.addTarget(self, action: #selector(wpmChanged(_:)), for: .valueChanged)
            slider.translatesAutoresizingMaskIntoConstraints = false
            wpmLabel.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(slider)
            cell.contentView.addSubview(wpmLabel)
            NSLayoutConstraint.activate([
                slider.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
                slider.centerYAnchor.constraint(equalTo: cell.contentView.centerYAnchor),
                wpmLabel.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 12),
                wpmLabel.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
                wpmLabel.centerYAnchor.constraint(equalTo: cell.contentView.centerYAnchor),
                wpmLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 70),
                cell.contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
            ])
            cell.selectionStyle = .none
            // No content configuration — it would replace the manual subviews.
            return cell

        case .appearance:
            if indexPath.row == 0 {
                content.text = "Serif Font"
                cell.accessoryView = makeSwitch(
                    isOn: ReaderSettings.useSerifFont, action: #selector(serifToggled(_:)))
            } else {
                content.text = "Text Size"
                let sizes = ["S", "M", "L", "XL"]
                let control = UISegmentedControl(items: sizes)
                let scales: [Double] = [0.85, 1.0, 1.15, 1.3]
                control.selectedSegmentIndex = scales.firstIndex(of: ReaderSettings.fontScale) ?? 1
                control.addTarget(self, action: #selector(textSizeChanged(_:)), for: .valueChanged)
                cell.accessoryView = control
            }
            cell.selectionStyle = .none

        case .listInfo:
            if indexPath.row == 0 {
                content.text = "Reading Time"
                cell.accessoryView = makeSwitch(
                    isOn: ReaderSettings.showReadingTime, action: #selector(readingTimeToggled(_:)))
            } else {
                content.text = "Reading Progress"
                cell.accessoryView = makeSwitch(
                    isOn: ReaderSettings.showReadingProgress, action: #selector(progressToggled(_:)))
            }
            cell.selectionStyle = .none

        case .eyeTracking:
            content.text = "Track Reading Position"
            cell.accessoryView = makeSwitch(
                isOn: ReaderSettings.eyeTrackingEnabled, action: #selector(eyeTrackingToggled(_:)))
            cell.selectionStyle = .none

        case .actionButton:
            if indexPath.row == 0 {
                content.text = "Install Shortcut"
                content.textProperties.color = view.tintColor ?? .systemBlue
                content.image = UIImage(systemName: "square.and.arrow.down")
            } else {
                content.text = "Open Shortcuts"
                content.textProperties.color = view.tintColor ?? .systemBlue
                content.image = UIImage(systemName: "arrow.up.forward.app")
            }

        case .extensionStatus:
            content.text = "Refresh Status"
            content.textProperties.color = view.tintColor ?? .systemBlue
            content.image = UIImage(systemName: "arrow.clockwise")
        }

        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Section(rawValue: indexPath.section)! {
        case .actionButton:
            if indexPath.row == 0 {
                installShortcut(from: tableView.cellForRow(at: indexPath) ?? view)
            } else if let url = URL(string: "shortcuts://") {
                UIApplication.shared.open(url)
            }
        case .extensionStatus:
            refreshSafariStatus()
            tableView.reloadSections(
                IndexSet(integer: Section.extensionStatus.rawValue), with: .none)
        default:
            break
        }
    }

    // MARK: - Controls

    private func makeSwitch(isOn: Bool, action: Selector) -> UISwitch {
        let toggle = UISwitch()
        toggle.isOn = isOn
        toggle.addTarget(self, action: action, for: .valueChanged)
        return toggle
    }

    @objc private func wpmChanged(_ slider: UISlider) {
        let rounded = Double((Int(slider.value) / 10) * 10)
        ReaderSettings.baseWPM = rounded
        wpmLabel.text = "\(Int(rounded)) wpm"
    }

    @objc private func serifToggled(_ toggle: UISwitch) {
        ReaderSettings.useSerifFont = toggle.isOn
    }

    @objc private func textSizeChanged(_ control: UISegmentedControl) {
        let scales: [Double] = [0.85, 1.0, 1.15, 1.3]
        ReaderSettings.fontScale = scales[max(0, min(control.selectedSegmentIndex, scales.count - 1))]
    }

    @objc private func readingTimeToggled(_ toggle: UISwitch) {
        ReaderSettings.showReadingTime = toggle.isOn
        NotificationCenter.default.post(name: .readingListChanged, object: nil)
    }

    @objc private func progressToggled(_ toggle: UISwitch) {
        ReaderSettings.showReadingProgress = toggle.isOn
        NotificationCenter.default.post(name: .readingListChanged, object: nil)
    }

    @objc private func eyeTrackingToggled(_ toggle: UISwitch) {
        ReaderSettings.eyeTrackingEnabled = toggle.isOn
        if !toggle.isOn {
            ReadingListStore.shared.clearAllEyeTracking()
        }
    }

    /// Offers the bundled, signed "Clip Safari Page" shortcut. Sharing the file
    /// to the Shortcuts app imports it with one confirmation tap. (A sheet-free
    /// install would require hosting the shortcut as an iCloud link —
    /// shortcuts://import-workflow rejects local file URLs.)
    private func installShortcut(from sourceView: UIView) {
        guard let bundled = Bundle.main.url(
            forResource: "Clip Safari Page", withExtension: "shortcut")
        else { return }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("Clip Safari Page.shortcut")
        try? FileManager.default.removeItem(at: tmp)
        try? FileManager.default.copyItem(at: bundled, to: tmp)

        let activity = UIActivityViewController(activityItems: [tmp], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = sourceView
        present(activity, animated: true)
    }

    private func refreshSafariStatus() {
        if let url = SafariURLStore.lastURL {
            let when = SafariURLStore.lastDate.map {
                RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date())
            } ?? "unknown time"
            safariStatusText = "Last tracked URL (\(when)): \(url)"
        } else {
            safariStatusText = "No URL tracked yet. Enable the Clip extension in Safari (Settings → Apps → Safari → Extensions) and browse to a page."
        }
    }
}

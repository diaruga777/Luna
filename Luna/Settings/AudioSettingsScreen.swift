//
//  AudioSettingsScreen.swift
//  Luna
//

import LunaAudioPlayback
import LunaDesignSystem
import UIKit

/// Read-aloud playback preferences (claudedocs/audio-playback-plan.md,
/// Phase 3): the autoplay-next-article toggle, the Apple Intelligence
/// listening-cleanup toggle (`AudioSettings.isIntelligentTrimmingEnabled`,
/// consumed by the Phase-4 trimming pipeline), and a link to the Voice
/// screen (enhanced-voice install status).
final class AudioSettingsScreen: NavHeaderTableController {

    private enum Section: Int, CaseIterable { case autoplay, cleanup, voice }

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        headerTitle = "Audio"
        super.viewDidLoad()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 1 }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .autoplay: return "Listening"
        case .cleanup: return nil
        case .voice: return nil
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .autoplay:
            return "When an article finishes, mark it read and continue with the next "
                + "unread article — after a chime and a short \u{201C}Now Reading\u{201D} announcement."
        case .cleanup:
            return "Skip photo captions, bylines, related-link lists, and other non-article "
                + "text when reading aloud. Uses Apple Intelligence on this device — nothing "
                + "leaves your iPhone — and falls back to Luna's built-in cleanup automatically "
                + "when it isn't available."
        case .voice:
            return "Luna reads aloud with enhanced Apple voices when they're installed."
        }
    }

    override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()

        switch Section(rawValue: indexPath.section)! {
        case .autoplay:
            content.text = "Autoplay Next Article"
            cell.selectionStyle = .none
            cell.accessoryView = makeToggle(
                isOn: AudioSettings.isAutoplayEnabled, action: #selector(autoplayToggled(_:)))
        case .cleanup:
            content.text = "Clean Up Articles for Listening"
            content.secondaryText = "Apple Intelligence"
            content.secondaryTextProperties.color = LunaColors.secondaryText
            content.secondaryTextProperties.font = .systemFont(ofSize: 12)
            cell.selectionStyle = .none
            cell.accessoryView = makeToggle(
                isOn: AudioSettings.isIntelligentTrimmingEnabled, action: #selector(cleanupToggled(_:)))
        case .voice:
            content.text = "Voice"
            content.image = UIImage(systemName: "speaker.wave.2")
            cell.accessoryType = .disclosureIndicator
        }

        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard Section(rawValue: indexPath.section) == .voice else { return }
        navigationController?.pushViewController(VoiceSettingsScreen(), animated: true)
    }

    @objc private func autoplayToggled(_ toggle: UISwitch) {
        AudioSettings.isAutoplayEnabled = toggle.isOn
    }

    @objc private func cleanupToggled(_ toggle: UISwitch) {
        AudioSettings.isIntelligentTrimmingEnabled = toggle.isOn
    }
}

//
//  AudioSettingsScreen.swift
//  Luna
//

import LunaAudioPlayback
import LunaDesignSystem
import LunaReaderUI
import UIKit
import LunaModels

/// Read-aloud playback preferences (claudedocs/audio-playback-plan.md,
/// Phase 3): the autoplay-next-article toggle, the Apple Intelligence
/// listening-cleanup toggle (`AudioSettings.isIntelligentTrimmingEnabled`,
/// consumed by the Phase-4 trimming pipeline), and enhanced-voice status/setup.
final class AudioSettingsScreen: NavHeaderTableController {

    private enum Section: Int, CaseIterable { case autoplay, cleanup, voice }

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        headerTitle = L10n.string("Audio")
        super.viewDidLoad()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        Section(rawValue: section) == .voice ? 2 : 1
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .autoplay: return L10n.string("Listening")
        case .cleanup: return nil
        case .voice: return L10n.string("Read-Aloud Voice")
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .autoplay:
            return L10n.string("When an article finishes, mark it read and continue with the next unread article — after a chime and a short \u{201C}Now Reading\u{201D} announcement.")
        case .cleanup:
            return L10n.string("Skip photo captions, bylines, related-link lists, and other non-article text when reading aloud. Uses Apple Intelligence on this device — nothing leaves your iPhone — and falls back to Luna's built-in cleanup automatically when it isn't available.")
        case .voice:
            return L10n.string("Luna reads aloud with enhanced Apple voices when they're installed, otherwise the built-in system voice. Install enhanced voices in iOS Settings → Accessibility → Spoken Content → Voices.")
        }
    }

    override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()

        switch Section(rawValue: indexPath.section)! {
        case .autoplay:
            content.text = L10n.string("Autoplay Next Article")
            cell.selectionStyle = .none
            cell.accessoryView = makeToggle(
                isOn: AudioSettings.isAutoplayEnabled, action: #selector(autoplayToggled(_:)))
        case .cleanup:
            content.text = L10n.string("Clean Up Articles for Listening")
            content.secondaryText = L10n.string("Apple Intelligence")
            content.secondaryTextProperties.color = LunaColors.secondaryText
            content.secondaryTextProperties.font = .systemFont(ofSize: 12)
            cell.selectionStyle = .none
            cell.accessoryView = makeToggle(
                isOn: AudioSettings.isIntelligentTrimmingEnabled, action: #selector(cleanupToggled(_:)))
        case .voice:
            if indexPath.row == 0 {
                let installed = VoiceModelStore.isAppleEnhancedInstalled
                content.text = installed
                    ? L10n.string("Enhanced voices installed")
                    : L10n.string("Not installed")
                content.image = UIImage(
                    systemName: installed ? "checkmark.circle.fill" : "xmark.circle")
                content.imageProperties.tintColor =
                    installed ? .systemGreen : LunaColors.secondaryText
                cell.selectionStyle = .none
            } else {
                content.text = L10n.string("Install Enhanced Voices")
                content.textProperties.color = view.tintColor
                cell.accessoryType = .disclosureIndicator
                cell.selectionStyle = .default
            }
        }

        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard Section(rawValue: indexPath.section) == .voice, indexPath.row == 1 else { return }
        VoiceInstallLink.open()
    }

    @objc private func autoplayToggled(_ toggle: UISwitch) {
        AudioSettings.isAutoplayEnabled = toggle.isOn
    }

    @objc private func cleanupToggled(_ toggle: UISwitch) {
        AudioSettings.isIntelligentTrimmingEnabled = toggle.isOn
    }
}

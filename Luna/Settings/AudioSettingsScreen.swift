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
        headerTitle = L10n.string("Common_audio")
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
        case .autoplay: return L10n.string("Settings_audio_listeningSectionHeader")
        case .cleanup: return nil
        case .voice: return L10n.string("Settings_audio_voiceSectionHeader")
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .autoplay:
            return L10n.string("Settings_audio_autoplayFooter")
        case .cleanup:
            return L10n.string("Settings_audio_cleanupFooter")
        case .voice:
            return L10n.string("Settings_audio_voiceFooter")
        }
    }

    override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()

        switch Section(rawValue: indexPath.section)! {
        case .autoplay:
            content.text = L10n.string("Settings_audio_autoplayToggleLabel")
            cell.selectionStyle = .none
            cell.accessoryView = makeToggle(
                isOn: AudioSettings.isAutoplayEnabled, action: #selector(autoplayToggled(_:)))
        case .cleanup:
            content.text = L10n.string("Settings_audio_cleanupToggleLabel")
            content.secondaryText = L10n.string("Settings_audio_cleanupToggleSecondary")
            content.secondaryTextProperties.color = LunaColors.secondaryText
            content.secondaryTextProperties.font = .systemFont(ofSize: 12)
            cell.selectionStyle = .none
            cell.accessoryView = makeToggle(
                isOn: AudioSettings.isIntelligentTrimmingEnabled, action: #selector(cleanupToggled(_:)))
        case .voice:
            if indexPath.row == 0 {
                let installed = VoiceModelStore.isAppleEnhancedInstalled
                content.text = installed
                    ? L10n.string("Settings_audio_voiceInstalledStatus")
                    : L10n.string("Settings_audio_voiceNotInstalledStatus")
                content.image = UIImage(
                    systemName: installed ? "checkmark.circle.fill" : "xmark.circle")
                content.imageProperties.tintColor =
                    installed ? .systemGreen : LunaColors.secondaryText
                cell.selectionStyle = .none
            } else {
                content.text = L10n.string("Settings_audio_installVoicesButton")
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

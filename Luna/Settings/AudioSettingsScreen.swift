//
//  AudioSettingsScreen.swift
//  Luna
//

import LunaAudioPlayback
import LunaDesignSystem
import LunaReaderUI
import UIKit
import LunaModels

/// Device and optional Gemini read-aloud preferences. Cloud consent and key
/// management live here; playback alone decides when audio may be generated.
final class AudioSettingsScreen: NavHeaderTableController {

    private enum Section: Int, CaseIterable { case autoplay, cleanup, gemini, voice }

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
        switch Section(rawValue: section)! {
        case .voice: return 2
        case .gemini: return 5
        default: return 1
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .autoplay: return L10n.string("Settings_audio_listeningSectionHeader")
        case .cleanup: return nil
        case .gemini: return L10n.string("Gemini_model")
        case .voice: return L10n.string("Gemini_deviceVoiceHeader")
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .autoplay:
            return L10n.string("Settings_audio_autoplayFooter")
        case .cleanup:
            return L10n.string("Settings_audio_cleanupFooter")
        case .voice:
            return AudioSettings.usesGeminiVoice
                ? L10n.string("Gemini_deviceVoiceFooter")
                : L10n.string("Settings_audio_voiceFooter")
        case .gemini:
            return L10n.string("Gemini_privacy")
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
        case .gemini:
            switch indexPath.row {
            case 0:
                content.text = L10n.string("Gemini_toggle")
                cell.selectionStyle = .none
                cell.accessoryView = makeToggle(isOn: AudioSettings.usesGeminiVoice, action: #selector(geminiToggled(_:)))
            case 1:
                content.text = L10n.string("Gemini_key")
                content.secondaryText = GeminiSpeechCredential.apiKey?.isEmpty == false ? L10n.string("Gemini_savedKey") : L10n.string("Gemini_noKey")
                cell.accessoryType = .disclosureIndicator
            case 2:
                content.text = L10n.string("Gemini_getKey")
                cell.accessoryType = .disclosureIndicator
            case 3:
                content.text = L10n.string("Gemini_limits")
                cell.accessoryType = .disclosureIndicator
            default:
                content.text = L10n.string("Gemini_deleteAudio")
                content.textProperties.color = .systemRed
            }
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
        if Section(rawValue: indexPath.section) == .voice, indexPath.row == 1 { VoiceInstallLink.open() }
        guard Section(rawValue: indexPath.section) == .gemini else { return }
        switch indexPath.row {
        case 1: editGeminiKey()
        case 2: UIApplication.shared.open(URL(string: "https://aistudio.google.com/api-keys")!)
        case 3: UIApplication.shared.open(URL(string: "https://aistudio.google.com/rate-limit")!)
        case 4:
            let alert = UIAlertController(title: L10n.string("Gemini_deleteTitle"), message: L10n.string("Gemini_deleteMessage"), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: L10n.string("Gemini_cancel"), style: .cancel))
            alert.addAction(UIAlertAction(title: L10n.string("Gemini_delete"), style: .destructive) { [weak self] _ in
                Task { @MainActor in
                    do { try await GeminiArticleSpeech.shared.clearCache() }
                    catch { self?.showGeminiError(error.localizedDescription) }
                }
            })
            present(alert, animated: true)
        default: break
        }
    }

    @objc private func geminiToggled(_ toggle: UISwitch) {
        if toggle.isOn, GeminiSpeechCredential.apiKey?.isEmpty != false {
            toggle.isOn = false
            editGeminiKey(enableAfterSave: true)
            return
        }
        AudioSettings.usesGeminiVoice = toggle.isOn
    }

    private func editGeminiKey(enableAfterSave: Bool = false) {
        let alert = UIAlertController(title: L10n.string("Gemini_keyTitle"), message: L10n.string("Gemini_keyMessage"), preferredStyle: .alert)
        alert.addTextField {
            $0.placeholder = L10n.string("Gemini_pasteKey")
            $0.isSecureTextEntry = true
            $0.autocapitalizationType = .none
            $0.autocorrectionType = .no
            $0.textContentType = .password
        }
        alert.addAction(UIAlertAction(title: L10n.string("Gemini_cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.string("Gemini_save"), style: .default) { [weak self, weak alert] _ in
            guard let key = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return }
            GeminiSpeechCredential.apiKey = key
            guard GeminiSpeechCredential.apiKey == key else {
                self?.showGeminiError(L10n.string("Gemini_saveError"))
                return
            }
            if enableAfterSave { AudioSettings.usesGeminiVoice = true }
            self?.tableView.reloadData()
        })
        if GeminiSpeechCredential.apiKey != nil {
            alert.addAction(UIAlertAction(title: L10n.string("Gemini_removeKey"), style: .destructive) { [weak self] _ in
                GeminiSpeechCredential.apiKey = nil
                AudioSettings.usesGeminiVoice = false
                self?.tableView.reloadData()
            })
        }
        present(alert, animated: true)
    }

    private func showGeminiError(_ message: String) {
        let alert = UIAlertController(title: L10n.string("Gemini_audio"), message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.string("Gemini_ok"), style: .default))
        present(alert, animated: true)
    }

    @objc private func autoplayToggled(_ toggle: UISwitch) {
        AudioSettings.isAutoplayEnabled = toggle.isOn
    }

    @objc private func cleanupToggled(_ toggle: UISwitch) {
        AudioSettings.isIntelligentTrimmingEnabled = toggle.isOn
    }
}

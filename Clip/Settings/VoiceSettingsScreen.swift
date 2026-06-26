//
//  VoiceSettingsScreen.swift
//  Clip
//

import UIKit

/// Text-to-speech engine picker. One row per `VoiceEngineKind` showing its name,
/// a state line, a trailing control (availability text, a Download/Delete button
/// for neural engines, or a deep-link for enhanced voices), and a checkmark to
/// SELECT it. Selection is only permitted once the engine is available
/// (basic always; appleEnhanced when an enhanced voice is installed; piper/
/// kokoro once downloaded). Deleting a neural model removes its files and, if it
/// was selected, falls back to a safe engine.
final class VoiceSettingsScreen: UITableViewController {

    private let engines = VoiceEngineKind.allCases
    /// One download manager per neural engine, created lazily while downloading.
    private var downloaders: [VoiceEngineKind: VoiceModelDownloadManager] = [:]
    /// Last reported state per engine, for rendering progress.
    private var downloadStates: [VoiceEngineKind: VoiceModelDownloadManager.State] = [:]

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Voice"
        navigationItem.largeTitleDisplayMode = .never
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData()
    }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        engines.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        "Read-Aloud Voice"
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "Pick the voice for read-aloud. Neural voices must be downloaded before "
            + "they can be selected. Enhanced Apple voices are installed from iOS "
            + "Settings → Accessibility → Spoken Content → Voices."
    }

    override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let kind = engines[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.text = kind.displayName
        content.secondaryText = stateLine(for: kind)
        content.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = content

        // Selection checkmark — only the SELECTED engine shows it.
        let isSelected = VoiceModelStore.selectedEngine == kind
        cell.accessoryType = isSelected ? .checkmark : .none

        // Trailing control: Download/Delete for neural engines, a guidance
        // button for appleEnhanced when missing, nothing for basic.
        cell.accessoryView = trailingControl(for: kind)

        // Selecting the row chooses the engine when it's available.
        cell.selectionStyle = VoiceModelStore.isAvailable(kind) ? .default : .none
        return cell
    }

    /// The subtitle line describing availability / download state.
    private func stateLine(for kind: VoiceEngineKind) -> String {
        switch kind {
        case .basic:
            return kind.summary
        case .appleEnhanced:
            return VoiceModelStore.isAvailable(kind)
                ? "Installed and ready."
                : "No enhanced voice installed — add one in iOS Settings."
        case .piper, .kokoro:
            if case .downloading(let fraction) = downloadStates[kind] {
                return "Downloading… \(Int(fraction * 100))%"
            }
            if case .failed(let message) = downloadStates[kind] {
                return "Download failed: \(message)"
            }
            if VoiceModelStore.isDownloaded(kind) {
                return "Model downloaded — neural playback arriving in a later "
                    + "update (using enhanced voice meanwhile)."
            }
            let mb = VoiceModelRegistry.totalApproximateBytes(for: kind) / 1_000_000
            return "Not downloaded · ~\(mb) MB. Must download first to select."
        }
    }

    /// The trailing control for the row.
    private func trailingControl(for kind: VoiceEngineKind) -> UIView? {
        switch kind {
        case .basic:
            return nil
        case .appleEnhanced:
            if VoiceModelStore.isAvailable(kind) { return nil }
            return makeButton(title: "iOS Settings", action: #selector(openSpokenContentSettings))
        case .piper, .kokoro:
            if case .downloading = downloadStates[kind] {
                let spinner = UIActivityIndicatorView(style: .medium)
                spinner.startAnimating()
                return spinner
            }
            if VoiceModelStore.isDownloaded(kind) {
                let button = makeButton(title: "Delete", action: #selector(deleteTapped(_:)))
                button.tag = kind.tag
                button.setTitleColor(.systemRed, for: .normal)
                return button
            }
            let button = makeButton(title: "Download", action: #selector(downloadTapped(_:)))
            button.tag = kind.tag
            return button
        }
    }

    private func makeButton(title: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        button.addTarget(self, action: action, for: .touchUpInside)
        button.sizeToFit()
        return button
    }

    // MARK: - Selection

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let kind = engines[indexPath.row]
        guard VoiceModelStore.isAvailable(kind) else {
            presentInfoAlert(
                title: "Not Available Yet",
                message: kind.requiresDownload
                    ? "Download this voice first, then select it."
                    : "Install an enhanced voice in iOS Settings → Accessibility "
                        + "→ Spoken Content → Voices, then select it here.")
            return
        }
        VoiceModelStore.selectedEngine = kind
        tableView.reloadData()
    }

    // MARK: - Actions

    @objc private func downloadTapped(_ sender: UIButton) {
        guard let kind = VoiceEngineKind.fromTag(sender.tag) else { return }
        let manager = VoiceModelDownloadManager(kind: kind)
        downloaders[kind] = manager
        manager.onStateChange = { [weak self] state in
            self?.downloadStates[kind] = state
            if case .finished = state { self?.downloaders[kind] = nil }
            if case .failed = state { self?.downloaders[kind] = nil }
            self?.reloadRow(for: kind)
        }
        downloadStates[kind] = .downloading(fractionCompleted: 0)
        reloadRow(for: kind)
        manager.start()
    }

    @objc private func deleteTapped(_ sender: UIButton) {
        guard let kind = VoiceEngineKind.fromTag(sender.tag) else { return }
        let alert = UIAlertController(
            title: "Delete \(kind.displayName)?",
            message: "This removes the downloaded model files. You can download it again later.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            VoiceModelStore.deleteModel(for: kind)
            self?.downloadStates[kind] = .idle
            self?.tableView.reloadData()
        })
        present(alert, animated: true)
    }

    @objc private func openSpokenContentSettings() {
        // Best effort: there is no public deep-link into Accessibility → Spoken
        // Content; try App-Prefs paths, falling back to the app's own page.
        let candidates = [
            "App-Prefs:root=ACCESSIBILITY",
            "App-Prefs:",
            UIApplication.openSettingsURLString,
        ]
        openFirstAvailable(candidates, at: 0)
    }

    private func openFirstAvailable(_ candidates: [String], at index: Int) {
        guard index < candidates.count, let url = URL(string: candidates[index]) else { return }
        UIApplication.shared.open(url, options: [:]) { [weak self] success in
            if !success { self?.openFirstAvailable(candidates, at: index + 1) }
        }
    }

    private func reloadRow(for kind: VoiceEngineKind) {
        guard let row = engines.firstIndex(of: kind) else { return }
        tableView.reloadRows(at: [IndexPath(row: row, section: 0)], with: .none)
    }
}

// MARK: - Button tagging

private extension VoiceEngineKind {
    /// A stable integer tag so a button can identify its engine.
    var tag: Int { (VoiceEngineKind.allCases.firstIndex(of: self) ?? 0) + 1 }

    static func fromTag(_ tag: Int) -> VoiceEngineKind? {
        let index = tag - 1
        return allCases.indices.contains(index) ? allCases[index] : nil
    }
}

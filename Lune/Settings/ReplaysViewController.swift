//
//  ReplaysViewController.swift
//  Lune
//

import LuneStorage
import LuneModels
import LuneDesignSystem
import UIKit

/// Diagnostics → Replays: lists every stored `Replay` by its item URL. Tapping a
/// row shares that replay's export zip (`UIActivityViewController`). Rows whose
/// state is `failed` or `userReported` show a red warning icon. Reached from the
/// Diagnostics settings screen.
final class ReplaysViewController: NavHeaderTableController {

    private let recorder: ReplayRecording
    private var replays: [StoredReplay] = []

    private static let explanation =
        "Replays record all data and events for a save and are useful for "
        + "diagnostics. Tap a replay to share its export."

    init(recorder: ReplayRecording = ReplayRecorder.shared) {
        self.recorder = recorder
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        headerTitle = "Replays"
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "replay")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    private func reload() {
        Task {
            let stored = await recorder.storedReplays()
            await MainActor.run {
                self.replays = stored
                self.tableView.reloadData()
            }
        }
    }

    // MARK: - Table

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        max(replays.count, 0)
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        Self.explanation
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        replays.isEmpty ? "No replays recorded yet." : nil
    }

    override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "replay", for: indexPath)
        let replay = replays[indexPath.row]
        var config = cell.defaultContentConfiguration()
        config.text = displayURL(replay.itemURLString)
        config.secondaryText = "\(label(for: replay.state)) · \(formatted(replay.createdAt))"
        config.textProperties.numberOfLines = 1
        config.textProperties.lineBreakMode = .byTruncatingMiddle
        cell.contentConfiguration = config

        // A red warning icon flags a failed or user-reported save.
        if replay.state == .failed || replay.state == .userReported {
            let warning = UIImageView(image: UIImage(systemName: "exclamationmark.triangle.fill"))
            warning.tintColor = .systemRed
            cell.accessoryView = warning
        } else {
            cell.accessoryView = nil
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let replay = replays[indexPath.row]
        guard FileManager.default.fileExists(atPath: replay.zipURL.path) else {
            presentMissingExport()
            return
        }
        let activity = UIActivityViewController(activityItems: [replay.zipURL], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = tableView.cellForRow(at: indexPath)
        present(activity, animated: true)
    }

    // MARK: - Formatting

    /// A compact, human-readable form of the item URL for the row title.
    private func displayURL(_ urlString: String) -> String {
        guard let url = URL(string: urlString) else { return urlString }
        let host = url.host?.replacingOccurrences(of: "www.", with: "") ?? urlString
        let path = url.path
        return path.isEmpty || path == "/" ? host : host + path
    }

    private func label(for state: Replay.ReplayState) -> String {
        switch state {
        case .inProgress: return "In Progress"
        case .failed: return "Failed"
        case .success: return "Success"
        case .userReported: return "Reported"
        }
    }

    private func formatted(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func presentMissingExport() {
        let alert = UIAlertController(
            title: "Export Missing",
            message: "This replay's export file is no longer available.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

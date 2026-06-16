//
//  ExperimentalSettingsScreen.swift
//  Clip
//

import UIKit

/// Experimental features, off by default. Currently: on-device semantic sharing
/// suggestions, which index the content of saved articles/videos and suggest
/// sharing a new save with a friend when it's conceptually similar to things
/// already shared with them.
final class ExperimentalSettingsScreen: UITableViewController {

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Experimental"
        navigationItem.largeTitleDisplayMode = .never
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 1 }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        "Semantic Sharing Suggestions"
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "Indexes the content of saved articles and videos on-device, then suggests sharing a new save with a friend when it's conceptually similar to things you've shared with them before. Indexing runs only while the app is open (never in the background Shortcut), to keep memory use low. Off by default."
    }

    override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var content = cell.defaultContentConfiguration()
        content.text = "Suggest by Content Similarity"
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        let toggle = UISwitch()
        toggle.isOn = SemanticSharingSettings.isEnabled
        toggle.addTarget(self, action: #selector(toggled(_:)), for: .valueChanged)
        cell.accessoryView = toggle
        return cell
    }

    @objc private func toggled(_ sender: UISwitch) {
        SemanticSharingSettings.isEnabled = sender.isOn
        if sender.isOn { SemanticIndexer.shared.scheduleRun() }
    }
}

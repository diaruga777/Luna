//
//  AutoSendBySourceScreen.swift
//  Luna
//

import LunaReadingListUI
import LunaSend
import LunaModels
import LunaDesignSystem
import UIKit

/// Per-capture-source auto-send configuration for one ereader destination
/// Lets the user choose which sources auto-send: App Intents
/// (Shortcuts) and in-app saves via the send mode, plus on/off for email and
/// the share sheet & paste.
final class AutoSendBySourceScreen: NavHeaderTableController {

    private enum SourceRow: Int, CaseIterable { case appIntents, email, shareAndPaste }

    private let destinationID: String
    private let destinationName: String

    init(destinationID: String, destinationName: String) {
        self.destinationID = destinationID
        self.destinationName = destinationName
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        headerTitle = "Forwarding Settings"
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        SourceRow.allCases.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        "Forwarding settings: \(destinationName)"
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "Choose which saves \(destinationName) receives automatically.\n\nWith \"Double Save\", saving twice in rapid succession forwards. (e.g. 2 Action Button presses)."
    }

    override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var content = cell.defaultContentConfiguration()
        cell.accessoryView = nil
        cell.selectionStyle = .none
        configureSourceRow(SourceRow(rawValue: indexPath.row)!, content: &content, cell: cell)
        cell.contentConfiguration = content
        return cell
    }

    private func configureSourceRow(
        _ row: SourceRow,
        content: inout UIListContentConfiguration,
        cell: UITableViewCell
    ) {
        switch row {
        case .appIntents:
            content.text = CaptureSource.appIntent.displayName
            cell.accessoryView = makeModeButton()
        case .email:
            content.text = CaptureSource.email.displayName
            cell.accessoryView = makeToggle(
                isOn: SourceSendSettings.emailEnabled(forDestination: destinationID)
            ) { [weak self] isOn in
                guard let self else { return }
                SourceSendSettings.setEmailEnabled(isOn, forDestination: self.destinationID)
            }
        case .shareAndPaste:
            content.text = "Share Sheet & Paste"
            cell.accessoryView = makeToggle(
                isOn: SourceSendSettings.shareAndPasteEnabled(forDestination: destinationID)
            ) { [weak self] isOn in
                guard let self else { return }
                SourceSendSettings.setShareAndPasteEnabled(isOn, forDestination: self.destinationID)
            }
        }
    }

    private func makeToggle(isOn: Bool, onChange: @escaping (Bool) -> Void) -> UISwitch {
        let toggle = UISwitch()
        toggle.isOn = isOn
        toggle.addAction(UIAction { [weak toggle] _ in onChange(toggle?.isOn ?? false) }, for: .valueChanged)
        return toggle
    }

    private func makeModeButton() -> UIButton {
        let button = UIButton(type: .system)
        button.showsMenuAsPrimaryAction = true
        button.changesSelectionAsPrimaryAction = true
        let current = SourceSendSettings.appIntentsMode(forDestination: destinationID)
        button.menu = UIMenu(children: ArticleSendMode.allCases.map { mode in
            UIAction(title: mode.displayName, state: mode == current ? .on : .off) { [weak self] _ in
                guard let self else { return }
                SourceSendSettings.setAppIntentsMode(mode, forDestination: self.destinationID)
                self.tableView.reloadData()
            }
        })
        button.sizeToFit()
        return button
    }
}

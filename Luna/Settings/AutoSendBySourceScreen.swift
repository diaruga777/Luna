//
//  AutoSendBySourceScreen.swift
//  Luna
//

import LunaSavesUI
import LunaSend
import LunaModels
import LunaDesignSystem
import UIKit

/// Per-capture-source auto-send configuration for one ereader destination.
/// Lets the user choose which sources auto-send: App Intents (Shortcuts) and
/// in-app saves through the send mode, plus on/off switches for email and the
/// share sheet and paste.
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
        headerTitle = L10n.string("Settings_autoSend_title")
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        SourceRow.allCases.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        L10n.string("Settings_autoSend_sectionHeader", destinationName)
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        L10n.string("Settings_autoSend_sectionFooter", destinationName)
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
            content.text = L10n.string("Settings_autoSend_shareAndPasteLabel")
            cell.accessoryView = makeToggle(
                isOn: SourceSendSettings.shareAndPasteEnabled(forDestination: destinationID)
            ) { [weak self] isOn in
                guard let self else { return }
                SourceSendSettings.setShareAndPasteEnabled(isOn, forDestination: self.destinationID)
            }
        }
    }

    private func makeModeButton() -> UIButton {
        let button = UIButton(type: .system)
        button.showsMenuAsPrimaryAction = true
        button.changesSelectionAsPrimaryAction = true
        let current = SourceSendSettings.appIntentsMode(forDestination: destinationID)
        let configurableModes: [ArticleSendMode] = [.off, .allSaves]
        button.menu = UIMenu(children: configurableModes.map { mode in
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

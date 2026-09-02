//
//  PluginChoiceScreen.swift
//  LunaPluginUI
//
//  A `choice` settings field (§11.1): a plain picker list, one checkmark.
//

import LunaDesignSystem
import LunaModels
import LunaPluginKit
import UIKit

public final class PluginChoiceScreen: NavHeaderTableController {

    private let field: PluginSettingField
    private var selectedID: String?
    private let onSelect: (String) -> Void

    public init(field: PluginSettingField, selectedID: String?, onSelect: @escaping (String) -> Void) {
        self.field = field
        self.selectedID = selectedID
        self.onSelect = onSelect
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    public override func viewDidLoad() {
        headerTitle = field.label
        super.viewDidLoad()
    }

    public override func numberOfSections(in tableView: UITableView) -> Int { 1 }

    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        field.options.count
    }

    public override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let option = field.options[indexPath.row]
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.textLabel?.text = option.label
        cell.accessoryType = option.id == selectedID ? .checkmark : .none
        return cell
    }

    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let option = field.options[indexPath.row]
        selectedID = option.id
        onSelect(option.id)
        tableView.reloadData()
    }
}

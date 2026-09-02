//
//  PluginDetailScreen.swift
//  LunaPluginUI
//
//  One plugin's settings screen (§11.1, §11.2): the enable switch, status,
//  capabilities in plain language, the rendered settings schema, the source
//  view, and delete for an imported plugin.
//

import LunaDesignSystem
import LunaModels
import LunaPluginExport
import LunaPluginKit
import UIKit

/// The empty acknowledgement a UI-driven `onAction`/`onSettingsChanged` call
/// decodes. Neither hook returns anything the screen needs to read.
struct PluginHookAck: Decodable {}

public final class PluginDetailScreen: NavHeaderTableController {

    private enum Row: Equatable {
        case enable
        case reenable
        case description(String)
        case runsInBackground
        case capability(PluginCapabilityName)
        case field(PluginSettingField)
        case autoSend
        case showSource
        case delete
    }

    private struct RowSection {
        let header: String?
        let footer: String?
        let rows: [Row]
    }

    private let catalog: PluginCatalogProviding
    private let settingsStore: PluginSettingsStoring
    private let invoker: PluginHookInvoking?

    private var listing: PluginListing
    private var values: [String: String] = [:]
    private var sections: [RowSection] = []

    public init(
        listing: PluginListing, catalog: PluginCatalogProviding,
        settingsStore: PluginSettingsStoring, invoker: PluginHookInvoking?
    ) {
        self.listing = listing
        self.catalog = catalog
        self.settingsStore = settingsStore
        self.invoker = invoker
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    public override func viewDidLoad() {
        headerTitle = listing.summary.name
        super.viewDidLoad()
        reloadValues()
    }

    private func reloadValues() {
        values = settingsStore.allValuesJSON(pluginID: listing.summary.id)
        rebuildSections()
        tableView.reloadData()
    }

    private func rebuildSections() {
        var result: [RowSection] = []

        var statusRows: [Row] = [.enable]
        if case .stopped = listing.status { statusRows.append(.reenable) }
        result.append(
            RowSection(
                header: nil, footer: PluginCapabilityCopy.sentence(for: listing.status),
                rows: statusRows))

        var aboutRows: [Row] = []
        if let description = listing.description, !description.isEmpty {
            aboutRows.append(.description(description))
        }
        if listing.runsInBackground { aboutRows.append(.runsInBackground) }
        if !aboutRows.isEmpty {
            result.append(RowSection(header: L10n.string("Plugins_aboutSectionHeader"), footer: nil, rows: aboutRows))
        }

        if !listing.capabilities.isEmpty {
            result.append(
                RowSection(
                    header: L10n.string("Plugins_consentCapabilitiesHeader"), footer: nil,
                    rows: listing.capabilities.map { .capability($0) }))
        }

        var settingsRows: [Row] = listing.settings.map { .field($0) }
        // A destination decides which capture sources auto-send to it, the
        // same question the two Swift destinations answer. The row appears
        // only where an app installed the screen that answers it.
        if isDestination, PluginDestinationAutoSend.presenter != nil {
            settingsRows.append(.autoSend)
        }
        if !settingsRows.isEmpty {
            result.append(
                RowSection(
                    header: L10n.string("Plugins_settingsSectionHeader"), footer: nil,
                    rows: settingsRows))
        }

        result.append(RowSection(header: nil, footer: nil, rows: [.showSource]))

        if !listing.summary.isBundled {
            result.append(RowSection(header: nil, footer: nil, rows: [.delete]))
        }

        sections = result
    }

    // MARK: - Table

    public override func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].rows.count
    }

    public override func tableView(
        _ tableView: UITableView, titleForHeaderInSection section: Int
    ) -> String? { sections[section].header }

    public override func tableView(
        _ tableView: UITableView, titleForFooterInSection section: Int
    ) -> String? { sections[section].footer }

    public override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        switch sections[indexPath.section].rows[indexPath.row] {
        case .enable: return enableCell()
        case .reenable: return reenableCell()
        case .description(let text): return textCell(text)
        case .runsInBackground: return textCell(L10n.string("Plugins_runsInBackgroundLine"))
        case .capability(let capability): return textCell("•  " + PluginCapabilityCopy.sentence(for: capability))
        case .field(let field): return fieldCell(field)
        case .autoSend: return autoSendCell()
        case .showSource: return actionCell(L10n.string("Plugins_showSourceRow"), destructive: false)
        case .delete: return actionCell(L10n.string("Plugins_deleteRow"), destructive: true)
        }
    }

    private func enableCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        cell.textLabel?.text = L10n.string("Plugins_enableRow")
        let toggle = UISwitch()
        toggle.isOn = enableSwitchIsOn
        toggle.addTarget(self, action: #selector(enableToggled(_:)), for: .valueChanged)
        cell.accessoryView = toggle
        return cell
    }

    /// A stopped plugin is still "on" in the user's mental model — it was
    /// disabled BY the runtime after repeated timeouts, not by a deliberate
    /// switch-off — so the toggle reads as on and `.reenable` is the row that
    /// clears the stopped state.
    private var enableSwitchIsOn: Bool {
        switch listing.status {
        case .enabled, .stopped: return true
        case .disabled, .loadFailed: return false
        }
    }

    private var isDestination: Bool { listing.summary.export?.isDestination == true }

    private var destinationID: String {
        PluginDestinationLegacyIDs.destinationID(forPluginID: listing.summary.id)
    }

    private func autoSendCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        cell.textLabel?.text = L10n.string("Plugins_autoSendRow")
        cell.detailTextLabel?.text = listing.summary.export?.title
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    private func reenableCell() -> UITableViewCell {
        actionCell(L10n.string("Plugins_reenableRow"), destructive: false)
    }

    private func textCell(_ text: String) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        cell.textLabel?.text = text
        cell.textLabel?.numberOfLines = 0
        return cell
    }

    private func actionCell(_ text: String, destructive: Bool) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.textLabel?.text = text
        cell.textLabel?.textColor = destructive ? LunaColors.errorAccent : .tintColor
        return cell
    }

    // MARK: - Settings fields

    private func fieldCell(_ field: PluginSettingField) -> UITableViewCell {
        switch field.type {
        case .text, .email, .url, .password, .number:
            // A secret never round-trips into the field: the store reads it
            // back as an empty JSON string when set, so the box starts blank
            // with a "set" placeholder rather than showing dots a plugin
            // author could mistake for the actual value and resave verbatim.
            let isSetSecret = field.isSecret && values[field.key] != nil
            return PluginFieldEditCell(
                field: field, currentValue: isSetSecret ? "" : displayValue(for: field),
                placeholderOverride: isSetSecret ? L10n.string("Plugins_secretSetPlaceholder") : nil,
                hasValue: isSetSecret || values[field.key] != nil
            ) { [weak self] text in self?.commitTextField(field, text: text) }
        case .toggle:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.selectionStyle = .none
            cell.textLabel?.text = field.label
            let toggle = UISwitch()
            toggle.isOn = PluginSettingValueCoding.decodeBool(values[field.key])
            toggle.addAction(
                UIAction { [weak self] action in
                    guard let toggle = action.sender as? UISwitch else { return }
                    self?.commitValue(
                        field, json: PluginSettingValueCoding.encodeBool(toggle.isOn))
                }, for: .valueChanged)
            cell.accessoryView = toggle
            return cell
        case .choice:
            let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
            cell.textLabel?.text = field.label
            let selectedID = PluginSettingValueCoding.decodeString(values[field.key])
            cell.detailTextLabel?.text = field.options.first { $0.id == selectedID }?.label
            cell.accessoryType = .disclosureIndicator
            markIfRequiredAndEmpty(cell, field: field, isEmpty: selectedID == nil)
            return cell
        case .pairedDevice:
            let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
            cell.textLabel?.text = field.label
            let value = PluginSettingValueCoding.decodeString(values[field.key])
            cell.detailTextLabel?.text = value ?? L10n.string("Plugins_pairedDeviceNotPaired")
            let button = UIButton(configuration: .plain())
            button.configuration?.title = value == nil
                ? L10n.string("Plugins_pairButton") : L10n.string("Plugins_unpairButton")
            button.addAction(
                UIAction { [weak self] _ in self?.invokeAction(for: field) }, for: .touchUpInside)
            button.sizeToFit()
            cell.accessoryView = button
            return cell
        case .action:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.textLabel?.text = field.label
            cell.textLabel?.textColor = .tintColor
            return cell
        case .info:
            let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
            cell.selectionStyle = .none
            cell.textLabel?.text = field.label
            cell.detailTextLabel?.text = field.help ?? PluginSettingValueCoding.decodeString(values[field.key])
            cell.detailTextLabel?.numberOfLines = 0
            return cell
        }
    }

    /// The text a non-secret field shows on load. A secret's display text is
    /// decided at the call site instead — it never round-trips through here.
    private func displayValue(for field: PluginSettingField) -> String {
        PluginSettingValueCoding.decodeString(values[field.key])
            ?? PluginSettingValueCoding.decodeNumber(values[field.key]).map { String($0) } ?? ""
    }

    private func markIfRequiredAndEmpty(_ cell: UITableViewCell, field: PluginSettingField, isEmpty: Bool) {
        guard field.isRequired, isEmpty else { return }
        cell.textLabel?.textColor = LunaColors.errorAccent
    }

    private func commitTextField(_ field: PluginSettingField, text: String) {
        guard !field.isSecret || !text.isEmpty else { return }
        switch field.type {
        case .number:
            guard let number = Double(text) else { return }
            commitValue(field, json: PluginSettingValueCoding.encodeNumber(number))
        default:
            commitValue(field, json: PluginSettingValueCoding.encodeString(text))
        }
    }

    private func commitValue(_ field: PluginSettingField, json: String) {
        do {
            try settingsStore.setValueJSON(json, pluginID: listing.summary.id, key: field.key)
            values[field.key] = json
            notifySettingsChanged(key: field.key, valueJSON: json)
        } catch {
            presentError(error)
        }
    }

    private func notifySettingsChanged(key: String, valueJSON: String) {
        guard let invoker else { return }
        struct Argument: Encodable { let key: String; let value: PluginRawJSON }
        Task { @MainActor in
            _ = await invoker.invoke(
                .onSettingsChanged, pluginID: listing.summary.id,
                argument: Argument(key: key, value: PluginRawJSON(json: valueJSON)),
                timeout: 5, decode: PluginHookAck.self)
        }
    }

    private func invokeAction(for field: PluginSettingField) {
        guard let invoker else { return }
        struct Argument: Encodable { let key: String }
        Task { @MainActor in
            _ = await invoker.invoke(
                .onAction, pluginID: listing.summary.id, argument: Argument(key: field.key),
                timeout: 30, decode: PluginHookAck.self)
            self.reloadValues()
        }
    }

    // MARK: - Selection

    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch sections[indexPath.section].rows[indexPath.row] {
        case .reenable: reenable()
        case .autoSend: presentAutoSend()
        case .showSource: showSource()
        case .delete: confirmDelete()
        case .field(let field):
            switch field.type {
            case .choice: pushChoice(for: field)
            case .action: invokeAction(for: field)
            default: break
            }
        default: break
        }
    }

    private func pushChoice(for field: PluginSettingField) {
        let selectedID = PluginSettingValueCoding.decodeString(values[field.key])
        let screen = PluginChoiceScreen(field: field, selectedID: selectedID) { [weak self] id in
            self?.commitValue(field, json: PluginSettingValueCoding.encodeString(id))
        }
        navigationController?.pushViewController(screen, animated: true)
    }

    private func presentAutoSend() {
        PluginDestinationAutoSend.presenter?.presentAutoSend(
            destinationID: destinationID,
            displayName: listing.summary.export?.title ?? listing.summary.name,
            from: self)
    }

    private func showSource() {
        let source = catalog.sourceText(pluginID: listing.summary.id) ?? ""
        navigationController?.pushViewController(
            PluginSourceViewController(pluginName: listing.summary.name, sourceText: source),
            animated: true)
    }

    @objc private func enableToggled(_ toggle: UISwitch) {
        setEnabled(toggle.isOn)
    }

    private func reenable() { setEnabled(true) }

    private func setEnabled(_ enabled: Bool) {
        do {
            try catalog.setEnabled(enabled, pluginID: listing.summary.id)
            if let refreshed = catalog.listing(pluginID: listing.summary.id) { listing = refreshed }
            reloadValues()
        } catch {
            presentError(error)
        }
    }

    private func confirmDelete() {
        let alert = UIAlertController(
            title: L10n.string("Plugins_deleteConfirmTitle"),
            message: L10n.string("Plugins_deleteConfirmMessage", listing.summary.name),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.string("Common_cancel"), style: .cancel))
        alert.addAction(
            UIAlertAction(title: L10n.string("Plugins_deleteRow"), style: .destructive) {
                [weak self] _ in self?.delete()
            })
        present(alert, animated: true)
    }

    private func delete() {
        do {
            try catalog.delete(pluginID: listing.summary.id)
            navigationController?.popViewController(animated: true)
        } catch {
            presentError(error)
        }
    }

    private func presentError(_ error: Error) {
        let alert = UIAlertController(
            title: L10n.string("Plugins_actionFailedTitle"), message: error.localizedDescription,
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.string("Common_ok"), style: .default))
        present(alert, animated: true)
    }
}

/// Wraps an already-encoded JSON fragment so it can sit inside another
/// `Encodable` payload without a round trip through a concrete Swift type.
private struct PluginRawJSON: Encodable {
    let json: String
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        let data = Data(json.utf8)
        if let value = try? JSONDecoder().decode(JSONPassthrough.self, from: data) {
            try container.encode(value)
        } else {
            try container.encodeNil()
        }
    }
}

/// A decode target that accepts any JSON shape, so `PluginRawJSON` can
/// re-encode whatever `PluginSettingValueCoding` produced.
private enum JSONPassthrough: Codable {
    case string(String), number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        self = .null
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

/// An inline-editable settings row: a label and a text field, keyboard typed
/// to the field's schema type.
private final class PluginFieldEditCell: UITableViewCell {

    private let valueField = UITextField()
    private let onCommit: (String) -> Void

    init(
        field: PluginSettingField, currentValue: String, placeholderOverride: String? = nil,
        hasValue: Bool? = nil, onCommit: @escaping (String) -> Void
    ) {
        self.onCommit = onCommit
        super.init(style: .default, reuseIdentifier: nil)
        selectionStyle = .none
        textLabel?.text = field.label

        valueField.text = currentValue
        valueField.placeholder = placeholderOverride ?? field.placeholder
        valueField.textAlignment = .right
        valueField.isSecureTextEntry = field.isSecret
        valueField.autocapitalizationType = .none
        valueField.autocorrectionType = .no
        switch field.type {
        case .email: valueField.keyboardType = .emailAddress
        case .url: valueField.keyboardType = .URL
        case .number: valueField.keyboardType = .decimalPad
        default: valueField.keyboardType = .default
        }
        valueField.addTarget(self, action: #selector(editingEnded), for: .editingDidEnd)
        valueField.addTarget(self, action: #selector(editingEnded), for: .editingDidEndOnExit)
        valueField.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(valueField)
        NSLayoutConstraint.activate([
            valueField.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            valueField.trailingAnchor.constraint(
                equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            valueField.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.6),
        ])
        let isEmpty = hasValue.map { !$0 } ?? currentValue.isEmpty
        if field.isRequired, isEmpty {
            textLabel?.textColor = LunaColors.errorAccent
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    @objc private func editingEnded() {
        onCommit(valueField.text ?? "")
    }
}

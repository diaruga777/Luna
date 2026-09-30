import LunaKeyboardCore
import LunaKeyboardUI
import LunaStorage
import UIKit
import UniformTypeIdentifiers

final class KeyboardPreferencesController: KeyboardTableController {
  private var values: [String: String] = [:]
  init() { super.init(title: "Preferences") }
  required init?(coder: NSCoder) { fatalError("init(coder:)") }
  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    values = (try? store.preferences()) ?? [:]
    tableView.reloadData()
  }
  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    KeyboardPreferences.toggles.count + 1
  }
  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath)
    -> UITableViewCell
  {
    if indexPath.row == KeyboardPreferences.toggles.count {
      let c = cell("Theme", detail: KeyboardPreferences(values: values).theme.rawValue)
      c.accessoryType = .disclosureIndicator
      return c
    }
    let setting = KeyboardPreferences.toggles[indexPath.row]
    let c = cell(setting.1)
    let toggle = UISwitch()
    toggle.isOn = KeyboardPreferences(values: values).enabled(setting.0)
    toggle.addAction(
      UIAction { [weak self, weak toggle] _ in
        guard let self, let toggle else { return }
        do {
          try self.store.setPreference(setting.0, value: String(toggle.isOn))
          self.values[setting.0] = String(toggle.isOn)
        } catch {
          toggle.isOn.toggle()
          self.failure(error)
        }
      }, for: .valueChanged)
    c.accessoryView = toggle
    c.selectionStyle = .none
    return c
  }
  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    guard indexPath.row == KeyboardPreferences.toggles.count else { return }
    let menu = UIAlertController(title: "Keyboard Theme", message: nil, preferredStyle: .actionSheet)
    for theme in KeyboardTheme.allCases {
      menu.addAction(UIAlertAction(title: theme.rawValue, style: .default) { [weak self] _ in
        guard let self else { return }
        do {
          try self.store.setPreference("theme", value: theme.rawValue)
          self.values["theme"] = theme.rawValue; self.tableView.reloadData()
        } catch { self.failure(error) }
      })
    }
    menu.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    menu.popoverPresentationController?.sourceView = tableView.cellForRow(at: indexPath)
    present(menu, animated: true)
  }
}

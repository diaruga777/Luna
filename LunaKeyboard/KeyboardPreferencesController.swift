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
    KeyboardPreferences.toggles.count
  }
  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath)
    -> UITableViewCell
  {
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
}

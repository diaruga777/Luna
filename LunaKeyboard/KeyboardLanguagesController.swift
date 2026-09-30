import LunaKeyboardCore
import LunaKeyboardUI
import LunaStorage
import UIKit
import UniformTypeIdentifiers

final class KeyboardLanguagesController: KeyboardTableController {
  private var values: [String: String] = [:]
  init() { super.init(title: "Languages") }
  required init?(coder: NSCoder) { fatalError("init(coder:)") }
  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    values = (try? store.preferences()) ?? [:]
    tableView.reloadData()
  }
  override func numberOfSections(in tableView: UITableView) -> Int { 2 }
  override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String?
  { section == 0 ? "Primary" : "Secondary" }
  override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String?
  {
    section == 1
      ? "A secondary dictionary uses additional system memory. Leave it off if you type in one language."
      : nil
  }
  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    KeyboardPreferences.languages.count + (section == 1 ? 1 : 0)
  }
  private func item(_ indexPath: IndexPath) -> (String, String) {
    indexPath.section == 1 && indexPath.row == 0
      ? ("", "None")
      : KeyboardPreferences.languages[indexPath.row - (indexPath.section == 1 ? 1 : 0)]
  }
  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath)
    -> UITableViewCell
  {
    let r = item(indexPath)
    let c = cell(r.1)
    let key = indexPath.section == 0 ? "language" : "secondaryLanguage"
    if (values[key] ?? (indexPath.section == 0 ? "en" : "")) == r.0 { c.accessoryType = .checkmark }
    return c
  }
  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    let key = indexPath.section == 0 ? "language" : "secondaryLanguage"
    do {
      try store.setPreference(key, value: item(indexPath).0)
      values[key] = item(indexPath).0
      tableView.reloadData()
    } catch { failure(error) }
  }
}

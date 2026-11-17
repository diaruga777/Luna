import LunaKeyboardCore
import LunaKeyboardUI
import LunaStorage
import UIKit
import UniformTypeIdentifiers

final class KeyboardHomeController: KeyboardTableController {
  init() { super.init(title: "Luna Keyboard") }
  required init?(coder: NSCoder) { fatalError("init(coder:)") }
  override func viewDidLoad() {
    super.viewDidLoad()
    let header = UIView(frame: CGRect(x: 0, y: 0, width: 360, height: 96))
    let icon = UIImageView(image: UIImage(named: "KeyboardArtwork"))
    icon.frame = CGRect(x: 24, y: 8, width: 80, height: 80)
    icon.layer.cornerRadius = 19
    icon.clipsToBounds = true
    header.addSubview(icon)
    tableView.tableHeaderView = header
  }
  override func numberOfSections(in tableView: UITableView) -> Int { 2 }
  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    section == 0 ? 3 : 4
  }
  override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String?
  { section == 0 ? "Setup" : "Settings" }
  override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String?
  {
    section == 0
      ? "In Settings, go to General → Keyboard → Keyboards to add Luna. Turn on Allow Full Access for shortcuts, saved links, and GIF search. Double-tap Space to search. Your typing stays on your device. Media searches send only your search terms."
      : nil
  }
  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath)
    -> UITableViewCell
  {
    let rows: [(String, String?, String)] =
      indexPath.section == 0
      ? [
        ("Set Up Keyboard", nil, "keyboard"),
        ("Try It Out", nil, "text.cursor"),
        ("Keyboard Quest", "Practice keyboard gestures", "gamecontroller"),
      ]
      : [
        ("Shortcuts", "Words, emoji, images and GIFs", "text.badge.plus"),
        ("Personal Dictionary", nil, "character.book.closed"),
        ("Languages", nil, "globe"),
        ("Preferences", "Typing, feedback and Luna suggestions", "slider.horizontal.3"),
      ]
    let r = rows[indexPath.row]
    let c = cell(r.0, detail: r.1, icon: r.2)
    c.accessoryType = .disclosureIndicator
    return c
  }
  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    if indexPath.section == 0, indexPath.row == 0 {
      UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
      return
    }
    let controller: UIViewController
    if indexPath.section == 0 {
      controller = indexPath.row == 2 ? KeyboardTutorialController() : KeyboardTryoutController()
    } else {
      switch indexPath.row {
      case 0: controller = KeyboardShortcutsController()
      case 1: controller = KeyboardDictionaryController()
      case 2: controller = KeyboardLanguagesController()
      default: controller = KeyboardPreferencesController()
      }
    }
    navigationController?.pushViewController(controller, animated: true)
  }
}

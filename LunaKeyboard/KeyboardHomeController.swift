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
    let header = UIView(frame: CGRect(x: 0, y: 0, width: 360, height: 175))
    let icon = UIImageView(image: UIImage(named: "KeyboardArtwork"))
    icon.frame = CGRect(x: 24, y: 8, width: 80, height: 80)
    icon.layer.cornerRadius = 19
    icon.clipsToBounds = true
    header.addSubview(icon)
    let label = UILabel(frame: CGRect(x: 24, y: 105, width: 320, height: 50))
    label.text = "Your words. Your shortcuts.\nEverything you save in Luna."
    label.numberOfLines = 2
    label.font = .preferredFont(forTextStyle: .body)
    label.textColor = .secondaryLabel
    header.addSubview(label)
    tableView.tableHeaderView = header
  }
  override func numberOfSections(in tableView: UITableView) -> Int { 2 }
  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    section == 0 ? 2 : 4
  }
  override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String?
  { section == 0 ? "GET STARTED" : "MAKE IT YOURS" }
  override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String?
  {
    section == 0
      ? "Add Luna Keyboard in Settings → General → Keyboard → Keyboards. Full Access lets the keyboard read your Luna shortcuts and saved links, and enables GIF and image search. Typing stays on your device. Search terms are sent only when you use media search."
      : nil
  }
  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath)
    -> UITableViewCell
  {
    let rows =
      indexPath.section == 0
      ? [
        ("Set Up Keyboard", "Add Luna Keyboard in Settings", "keyboard"),
        ("Try It Out", "Type, slide, and explore text styles", "text.cursor"),
      ]
      : [
        ("Shortcuts", "Words, emoji, images and GIFs", "text.badge.plus"),
        ("Personal Dictionary", "Words that should stay yours", "character.book.closed"),
        ("Languages", "Primary and optional secondary language", "globe"),
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
      controller = KeyboardTryoutController()
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

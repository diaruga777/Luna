import LunaKeyboardCore
import LunaKeyboardUI
import LunaStorage
import UIKit
import UniformTypeIdentifiers

class KeyboardTableController: UITableViewController {
  let store = KeyboardStore()
  init(title: String) {
    super.init(style: .insetGrouped)
    self.title = title
  }
  required init?(coder: NSCoder) { fatalError("init(coder:)") }
  override func viewDidLoad() {
    super.viewDidLoad()
    tableView.backgroundColor = .black
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
  }
  func cell(_ title: String, detail: String? = nil, icon: String? = nil) -> UITableViewCell {
    let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
    cell.backgroundColor = UIColor(white: 0.07, alpha: 1)
    var config = cell.defaultContentConfiguration()
    config.text = title
    config.secondaryText = detail
    config.secondaryTextProperties.color = .secondaryLabel
    config.image = icon.flatMap { UIImage(systemName: $0) }
    cell.contentConfiguration = config
    return cell
  }
  func failure(_ error: Error) {
    let alert = UIAlertController(
      title: "Couldn’t Save", message: error.localizedDescription, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    present(alert, animated: true)
  }
}

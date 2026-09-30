import LunaKeyboardCore
import LunaKeyboardUI
import LunaStorage
import UIKit
import UniformTypeIdentifiers

final class KeyboardDictionaryController: KeyboardTableController {
  private var words: [String] = []
  private var language = "en"
  init() { super.init(title: "Personal Dictionary") }
  required init?(coder: NSCoder) { fatalError("init(coder:)") }
  override func viewDidLoad() {
    super.viewDidLoad()
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      systemItem: .add, primaryAction: UIAction { [weak self] _ in self?.addWord() })
  }
  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    language = (try? store.preferences()["language"]) ?? "en"
    reload()
  }
  private func reload() {
    words = (try? store.dictionary(language: language, limit: 500)) ?? []
    tableView.reloadData()
  }
  private func addWord() {
    let a = UIAlertController(title: "Add a Word", message: nil, preferredStyle: .alert)
    a.addTextField {
      $0.autocapitalizationType = .none
      $0.autocorrectionType = .no
    }
    a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    a.addAction(
      UIAlertAction(title: "Add", style: .default) { [weak self, weak a] _ in
        guard let self, let word = a?.textFields?.first?.text else { return }
        do {
          try self.store.setWord(word, language: self.language, included: true)
          self.reload()
        } catch { self.failure(error) }
      })
    present(a, animated: true)
  }
  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    words.count
  }
  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath)
    -> UITableViewCell
  { cell(words[indexPath.row]) }
  override func tableView(
    _ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle,
    forRowAt indexPath: IndexPath
  ) {
    do {
      try store.setWord(words[indexPath.row], language: language, included: false)
      reload()
    } catch { failure(error) }
  }
}

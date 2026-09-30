import LunaKeyboardCore
import LunaKeyboardUI
import LunaStorage
import UIKit
import UniformTypeIdentifiers

final class KeyboardShortcutsController: KeyboardTableController, UIDocumentPickerDelegate {
  private var shortcuts: [KeyboardShortcut] = []
  private var builtin: [(text: String, name: String)] = []
  private let catalog = KeyboardCatalog()
  init() { super.init(title: "Shortcuts") }
  required init?(coder: NSCoder) { fatalError("init(coder:)") }
  override func viewDidLoad() {
    super.viewDidLoad()
    navigationItem.rightBarButtonItems = [
      UIBarButtonItem(
        systemItem: .add, primaryAction: UIAction { [weak self] _ in self?.edit(nil) }),
      UIBarButtonItem(
        image: UIImage(systemName: "photo.badge.plus"),
        primaryAction: UIAction { [weak self] _ in self?.importMedia() }),
    ]
    let search = UISearchController(searchResultsController: nil)
    search.searchResultsUpdater = self
    search.obscuresBackgroundDuringPresentation = false
    search.searchBar.placeholder = "Search shortcuts and every emoji"
    navigationItem.searchController = search
  }
  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    reload()
  }
  private func reload() {
    shortcuts = (try? store.shortcuts(limit: 500)) ?? []
    builtin = catalog.browseGlyphs(
      query: navigationItem.searchController?.searchBar.text ?? "", limit: 100)
    tableView.reloadData()
  }
  override func numberOfSections(in tableView: UITableView) -> Int { 2 }
  override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String?
  { section == 0 ? "Your shortcuts" : "Built-in emoji and text art" }
  override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String?
  {
    section == 1
      ? "Every Unicode emoji has keyword mappings, including skin tones, flags and joined sequences. Search for a name or keyword; tap a result to give it your own keywords."
      : nil
  }
  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    section == 0 ? shortcuts.count : builtin.count
  }
  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath)
    -> UITableViewCell
  {
    if indexPath.section == 1 {
      let r = builtin[indexPath.row]
      return cell(r.text, detail: r.name)
    }
    let r = shortcuts[indexPath.row]
    let c = cell(
      r.text, detail: r.keywords.joined(separator: ", "), icon: r.kind == "text" ? nil : "photo")
    c.accessoryType = .disclosureIndicator
    return c
  }
  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    if indexPath.section == 0 {
      edit(shortcuts[indexPath.row])
    } else {
      let r = builtin[indexPath.row]
      edit(.init(keywords: [r.name], text: r.text))
    }
  }
  override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
    indexPath.section == 0
  }
  override func tableView(
    _ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle,
    forRowAt indexPath: IndexPath
  ) {
    do {
      try store.delete(id: shortcuts[indexPath.row].id)
      reload()
    } catch { failure(error) }
  }
  private func edit(_ existing: KeyboardShortcut?, importing: URL? = nil) {
    let a = UIAlertController(
      title: existing == nil ? "New Shortcut" : "Edit Shortcut",
      message: "Separate keywords with commas. Keywords may be whole phrases.",
      preferredStyle: .alert)
    a.addTextField {
      $0.placeholder = "Keywords"
      $0.text = existing?.keywords.joined(separator: ", ")
      $0.autocapitalizationType = .none
      $0.autocorrectionType = .no
    }
    a.addTextField {
      $0.placeholder = importing == nil ? "Replacement text" : "Title"
      $0.text = existing?.text
      $0.autocapitalizationType = .none
    }
    a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    a.addAction(
      UIAlertAction(title: "Save", style: .default) { [weak self, weak a] _ in
        guard let self, let fields = a?.textFields, let keys = fields[0].text,
          let text = fields[1].text, !keys.trimmingCharacters(in: .whitespaces).isEmpty,
          !text.isEmpty
        else { return }
        var entry = existing ?? .init(keywords: [], text: text)
        entry.text = text
        entry.keywords = keys.components(separatedBy: ",")
        if let importing {
          entry.kind = importing.pathExtension.lowercased() == "gif" ? "gif" : "image"
        }
        do {
          try self.store.save(entry, importing: importing)
          self.reload()
        } catch { self.failure(error) }
      })
    present(a, animated: true)
  }
  private func importMedia() {
    let picker = UIDocumentPickerViewController(
      forOpeningContentTypes: [.image, .gif], asCopy: true)
    picker.delegate = self
    present(picker, animated: true)
  }
  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL])
  {
    guard let url = urls.first else { return }
    edit(nil, importing: url)
  }
}
extension KeyboardShortcutsController: UISearchResultsUpdating {
  func updateSearchResults(for searchController: UISearchController) { reload() }
}

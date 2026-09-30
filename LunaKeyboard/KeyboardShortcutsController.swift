import LunaKeyboardCore
import LunaKeyboardUI
import LunaStorage
import PhotosUI
import UIKit
import UniformTypeIdentifiers

final class KeyboardShortcutsController: KeyboardTableController, UIDocumentPickerDelegate, PHPickerViewControllerDelegate {
  private var shortcuts: [KeyboardShortcut] = []
  private var builtin: [(text: String, name: String)] = []
  private var repairing: KeyboardShortcut?
  private var exportedFile: URL?
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
        primaryAction: UIAction { [weak self] _ in self?.importOptions() }),
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
    let query = navigationItem.searchController?.searchBar.text ?? ""
    shortcuts = ((try? store.shortcuts(limit: 500)) ?? []).filter {
      query.isEmpty || $0.text.localizedCaseInsensitiveContains(query)
        || $0.keywords.contains { $0.localizedCaseInsensitiveContains(query) }
    }
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
      r.text, detail: (store.mediaIsMissing(r) ? "Missing file · tap to repair. " : "")
        + r.keywords.joined(separator: ", ") + (r.suggestWhileTyping ? "" : " · Lookup only")
        + (r.isCosmetic ? " · Cosmetic" : ""), icon: r.kind == "text" ? nil : "photo")
    c.accessoryType = .disclosureIndicator
    return c
  }
  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    if indexPath.section == 0 {
      shortcutOptions(shortcuts[indexPath.row], anchor: tableView.cellForRow(at: indexPath))
    } else {
      let r = builtin[indexPath.row]
      edit(.init(keywords: [r.name], text: r.text, isCosmetic: true))
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
      message: "Separate keywords with commas. Lookup keeps it in Saved search only. Cosmetic suggestions are never applied automatically.",
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
    a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
      if let importing, importing.deletingLastPathComponent() == FileManager.default.temporaryDirectory {
        try? FileManager.default.removeItem(at: importing)
      }
    })
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
          if let importing, importing.deletingLastPathComponent() == FileManager.default.temporaryDirectory {
            try? FileManager.default.removeItem(at: importing)
          }
        } catch { self.failure(error) }
      })
    present(a, animated: true)
  }
  private func shortcutOptions(_ entry: KeyboardShortcut, anchor: UIView?) {
    let menu = UIAlertController(title: entry.text, message: store.mediaIsMissing(entry)
      ? "The media file is missing. Choose it again from Photos or Files, or remove this shortcut." : nil, preferredStyle: .actionSheet)
    menu.addAction(UIAlertAction(title: "Edit", style: .default) { [weak self] _ in self?.edit(entry) })
    menu.addAction(UIAlertAction(title: entry.suggestWhileTyping ? "Use for Lookup Only" : "Suggest While Typing", style: .default) { [weak self] _ in
      var updated = entry; updated.suggestWhileTyping.toggle(); self?.saveOptions(updated)
    })
    if entry.kind == "text" {
      menu.addAction(UIAlertAction(title: entry.isCosmetic ? "Use as Text Replacement" : "Mark as Cosmetic", style: .default) { [weak self] _ in
        var updated = entry; updated.isCosmetic.toggle(); self?.saveOptions(updated)
      })
    }
    if entry.kind != "text" {
      menu.addAction(UIAlertAction(title: "Replace Media…", style: .default) { [weak self] _ in
        self?.repairing = entry; self?.importOptions()
      })
    }
    if !store.mediaIsMissing(entry) {
      menu.addAction(UIAlertAction(title: "Share Shortcut…", style: .default) { [weak self] _ in self?.share(entry, anchor: anchor) })
    }
    menu.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
      guard let self else { return }
      do { try self.store.delete(id: entry.id); self.reload() } catch { self.failure(error) }
    })
    menu.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    menu.popoverPresentationController?.sourceView = anchor ?? view
    present(menu, animated: true)
  }
  private func saveOptions(_ entry: KeyboardShortcut) {
    do { try store.save(entry); reload() } catch { failure(error) }
  }
  private func share(_ entry: KeyboardShortcut, anchor: UIView?) {
    do {
      let archive = try KeyboardShortcutArchive(shortcut: entry, store: store)
      let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".lunakeyboard")
      try JSONEncoder().encode(archive).write(to: url, options: .atomic)
      exportedFile = url
      let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
      sheet.popoverPresentationController?.sourceView = anchor ?? view
      sheet.completionWithItemsHandler = { [weak self] _, _, _, _ in
        try? FileManager.default.removeItem(at: url); self?.exportedFile = nil
      }
      present(sheet, animated: true)
    } catch { failure(error) }
  }
  private func importOptions() {
    let menu = UIAlertController(title: "Import", message: "Pick a photo and add keywords to suggest it while typing.", preferredStyle: .actionSheet)
    menu.addAction(UIAlertAction(title: "Photo Library", style: .default) { [weak self] _ in
      var config = PHPickerConfiguration()
      config.filter = .images; config.selectionLimit = 1
      let picker = PHPickerViewController(configuration: config)
      picker.delegate = self; self?.present(picker, animated: true)
    })
    menu.addAction(UIAlertAction(title: "Files or Shared Shortcut", style: .default) { [weak self] _ in
      let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.image, .gif, .data], asCopy: true)
      picker.delegate = self; self?.present(picker, animated: true)
    })
    menu.addAction(UIAlertAction(title: "Remove Missing Media Shortcuts", style: .destructive) { [weak self] _ in
      guard let self else { return }
      let confirm = UIAlertController(title: "Remove missing shortcuts?", message: "Their keywords will also be deleted. You can instead replace a missing file from its shortcut menu.", preferredStyle: .alert)
      confirm.addAction(UIAlertAction(title: "Cancel", style: .cancel))
      confirm.addAction(UIAlertAction(title: "Remove", style: .destructive) { [weak self] _ in
        guard let self else { return }
        do { _ = try self.store.removeMissingMedia(); self.reload() } catch { self.failure(error) }
      })
      self.present(confirm, animated: true)
    })
    menu.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in self?.repairing = nil })
    menu.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItems?.last
    present(menu, animated: true)
  }
  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let url = urls.first else { return }
    if ["lunakeyboard", "json"].contains(url.pathExtension.lowercased()) {
      do {
        let archive = try KeyboardShortcutArchive.read(url)
        let preview = UIAlertController(title: "Import Shortcut", message: archive.text + "\nKeywords: " + archive.keywords.joined(separator: ", "), preferredStyle: .alert)
        preview.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        preview.addAction(UIAlertAction(title: "Import", style: .default) { [weak self] _ in
          guard let self else { return }
          do { try archive.save(to: self.store); self.reload() } catch { self.failure(error) }
        })
        present(preview, animated: true)
      } catch { failure(error) }
      repairing = nil
    } else {
      edit(repairing, importing: url); repairing = nil
    }
  }
  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    guard let provider = results.first?.itemProvider else { repairing = nil; return }
    let type = provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .image) == true } ?? UTType.image.identifier
    provider.loadFileRepresentation(forTypeIdentifier: type) { [weak self] url, error in
      guard let url else {
        DispatchQueue.main.async { self?.failure(error ?? CocoaError(.fileReadUnknown)) }; return
      }
      do {
        let ext = url.pathExtension.isEmpty ? (UTType(type)?.preferredFilenameExtension ?? "png") : url.pathExtension
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 8 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        try FileManager.default.copyItem(at: url, to: copy)
        DispatchQueue.main.async {
          guard let self else { try? FileManager.default.removeItem(at: copy); return }
          self.edit(self.repairing, importing: copy); self.repairing = nil
        }
      } catch { DispatchQueue.main.async { self?.failure(error) } }
    }
  }

}
extension KeyboardShortcutsController: UISearchResultsUpdating {
  func updateSearchResults(for searchController: UISearchController) { reload() }
}

import UIKit
import LunaModels
import LunaWriterModels
import LunaWriterStorage

/// A book's table of contents, with chapter ordering across its collections.
final class ChaptersViewController: UITableViewController, LibraryChangeObserving {
    private let library: WriterLibraryStoring
    private let organizer: ChapterOrganizer
    private let book: WriterGroup
    private let currentID: DocumentID?
    private let onOpen: (WriterDocument) -> Void
    private var sections: [ChapterOrganizer.ChapterSection] = []

    init(library: WriterLibraryStoring, textStore: DocumentTextStoring, book: WriterGroup,
         currentID: DocumentID?, onOpen: @escaping (WriterDocument) -> Void) {
        self.library = library
        self.organizer = ChapterOrganizer(library: library, textStore: textStore)
        self.book = book
        self.currentID = currentID
        self.onOpen = onOpen
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }
    deinit { library.removeObserver(self) }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = book.name
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(done))
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(image: UIImage(systemName: "plus"), menu: UIMenu(children: [
                UIAction(title: L10n.string("WriterLibrary_polish_newChapter"), image: UIImage(systemName: "doc.badge.plus")) { [weak self] _ in self?.addChapter(in: self?.book.id) },
                UIAction(title: L10n.string("WriterLibrary_polish_newCollection"), image: UIImage(systemName: "folder.badge.plus")) { [weak self] _ in self?.addCollection() },
                UIAction(title: L10n.string("WriterLibrary_polish_addExistingDocument"), image: UIImage(systemName: "doc.text")) { [weak self] _ in self?.addExisting() },
            ])), editButtonItem,
        ]
        navigationItem.rightBarButtonItems?.first?.accessibilityLabel = L10n.string("Common_add")
        library.addObserver(self)
        reload()
    }

    private func reload() {
        do { sections = try organizer.contents(of: book.id); tableView.reloadData() }
        catch { showError(error) }
    }

    func libraryDidChange(_ change: LibraryChange) { reload() }
    @objc private func done() { dismiss(animated: true) }

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].chapters.count + 1 }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        String(repeating: "  ", count: sections[section].depth) + sections[section].group.name
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let chapters = sections[indexPath.section].chapters
        if indexPath.row == chapters.count {
            cell.textLabel?.text = L10n.string("WriterLibrary_polish_addChapter")
            cell.textLabel?.textColor = .tintColor
            cell.imageView?.image = UIImage(systemName: "plus")
            return cell
        }
        let chapter = chapters[indexPath.row]
        cell.textLabel?.text = "\(indexPath.row + 1). \(chapter.title)"
        cell.textLabel?.numberOfLines = 0
        cell.detailTextLabel?.text = chapter.snippet
        cell.detailTextLabel?.numberOfLines = 3
        cell.accessoryType = chapter.id == currentID ? .checkmark : .none
        if chapter.id == currentID { cell.accessibilityTraits.insert(.selected) }
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let section = sections[indexPath.section]
        if indexPath.row == section.chapters.count { addChapter(in: section.group.id); return }
        let chapter = section.chapters[indexPath.row]
        dismiss(animated: true) { self.onOpen(chapter) }
    }
    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        indexPath.row < sections[indexPath.section].chapters.count
    }
    override func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle { .none }
    override func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool { false }
    override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        indexPath.row < sections[indexPath.section].chapters.count
    }
    override func tableView(_ tableView: UITableView, targetIndexPathForMoveFromRowAt sourceIndexPath: IndexPath,
                            toProposedIndexPath proposedDestinationIndexPath: IndexPath) -> IndexPath {
        let count = sections[proposedDestinationIndexPath.section].chapters.count
        return IndexPath(row: min(proposedDestinationIndexPath.row,
                                  max(0, count - (sourceIndexPath.section == proposedDestinationIndexPath.section ? 1 : 0))),
                         section: proposedDestinationIndexPath.section)
    }
    override func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        do {
            try library.moveDocument(sections[sourceIndexPath.section].chapters[sourceIndexPath.row].id,
                                     to: sections[destinationIndexPath.section].group.id, at: destinationIndexPath.row)
            reload()
        } catch { reload(); showError(error) }
    }

    private func addChapter(in group: GroupID?) {
        guard let group else { return }
        askForName(title: L10n.string("WriterLibrary_polish_newChapter")) { [weak self] name in
            guard let self else { return }
            do {
                let chapter = try self.organizer.appendChapter(in: group, title: name)
                self.dismiss(animated: true) { self.onOpen(chapter) }
            } catch { self.showError(error) }
        }
    }
    private func addCollection() {
        askForName(title: L10n.string("WriterLibrary_polish_newCollection")) { [weak self] name in
            guard let self else { return }
            do { _ = try self.organizer.createBook(named: name, parent: self.book.id); self.reload() }
            catch { self.showError(error) }
        }
    }
    private func addExisting() {
        let picker = SheetPickerViewController(library: library) { [weak self] id in
            guard let self else { return }
            do {
                let count = try self.library.documents(in: self.book.id, sort: .manual).count
                try self.library.moveDocument(id, to: self.book.id, at: count)
            } catch { self.showError(error) }
        }
        picker.title = L10n.string("WriterLibrary_polish_addToBook")
        present(UINavigationController(rootViewController: picker), animated: true)
    }
    private func askForName(title: String, completion: @escaping (String) -> Void) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addTextField { $0.placeholder = L10n.string("WriterLibrary_polish_titlePlaceholder") }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.string("WriterLibrary_polish_create"), style: .default) { _ in
            let name = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else { return }
            completion(name)
        })
        present(alert, animated: true)
    }
    private func showError(_ error: Error) {
        let alert = UIAlertController(title: L10n.string("WriterLibrary_polish_updateBookError"), message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

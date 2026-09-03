import UIKit
import LunaDesignSystem
import LunaModels
import LunaWriterModels
import LunaWriterStorage

/// Edits one sheet's keywords, or adds a single keyword to several sheets at
/// once (the multi-select "Keyword" toolbar action).
public final class KeywordEditorViewController: UITableViewController {

    private let library: WriterLibraryStoring
    private let documentIDs: [DocumentID]
    private var keywords: [String]
    private let textField = UITextField()

    /// Editing one sheet's own keyword list.
    public init(library: WriterLibraryStoring, document: WriterDocument) {
        self.library = library
        self.documentIDs = [document.id]
        self.keywords = document.keywords
        super.init(style: .insetGrouped)
    }

    /// Adding one new keyword across several sheets.
    public init(library: WriterLibraryStoring, documentIDs: [DocumentID]) {
        self.library = library
        self.documentIDs = documentIDs
        self.keywords = []
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.string("WriterLibrary_keyword_title")
        tableView.backgroundColor = LunaColors.background
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: L10n.string("Common_cancel"), style: .plain, target: self, action: #selector(cancelTapped))
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: L10n.string("Common_done"), style: .done, target: self, action: #selector(doneTapped))
    }

    @objc private func cancelTapped() { dismiss(animated: true) }

    @objc private func doneTapped() {
        let candidate = (textField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if documentIDs.count == 1, let id = documentIDs.first {
            applyKeywords(candidate.isEmpty ? keywords : normalizedAppend(candidate), to: id)
        } else if !candidate.isEmpty {
            for id in documentIDs {
                guard var document = try? library.document(id) else { continue }
                document.keywords = Self.normalized(document.keywords + [candidate])
                _ = try? library.update(document)
            }
        }
        dismiss(animated: true)
    }

    private func normalizedAppend(_ keyword: String) -> [String] {
        Self.normalized(keywords + [keyword])
    }

    private static func normalized(_ keywords: [String]) -> [String] {
        var seen = Set<String>()
        return keywords.filter { seen.insert($0).inserted }
    }

    @discardableResult
    private func applyKeywords(_ keywords: [String], to id: DocumentID) -> Bool {
        guard var document = try? library.document(id) else { return false }
        document.keywords = keywords
        guard (try? library.update(document)) != nil else { return false }
        return true
    }

    /// Removes one existing keyword from the single sheet being edited.
    public func removeKeyword(_ keyword: String) {
        keywords.removeAll { $0 == keyword }
        if let id = documentIDs.first, documentIDs.count == 1 {
            applyKeywords(keywords, to: id)
        }
        tableView.reloadData()
    }

    public override func numberOfSections(in tableView: UITableView) -> Int { documentIDs.count == 1 ? 2 : 1 }

    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? 1 : keywords.count
    }

    public override func tableView(
        _ tableView: UITableView, titleForHeaderInSection section: Int
    ) -> String? {
        section == 0 ? nil : L10n.string("WriterLibrary_keyword_currentSectionHeader")
    }

    public override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        if indexPath.section == 0 {
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            textField.placeholder = L10n.string("WriterLibrary_keyword_addPlaceholder")
            textField.textColor = LunaColors.primaryText
            textField.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(textField)
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: 16),
                textField.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -16),
                textField.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 8),
                textField.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -8),
            ])
            cell.backgroundColor = LunaColors.secondaryBackground
            return cell
        }
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.textLabel?.text = keywords[indexPath.row]
        cell.backgroundColor = LunaColors.secondaryBackground
        return cell
    }

    public override func tableView(
        _ tableView: UITableView, canEditRowAt indexPath: IndexPath
    ) -> Bool {
        indexPath.section == 1
    }

    public override func tableView(
        _ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath
    ) {
        guard editingStyle == .delete, indexPath.section == 1 else { return }
        removeKeyword(keywords[indexPath.row])
    }
}

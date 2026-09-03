import UIKit
import LunaDesignSystem
import LunaModels
import LunaWriterModels
import LunaWriterStorage
import LunaWriterText

/// The notes panel for one open sheet: notes in relevance order when a
/// `NoteRelevanceProviding` witness has scores, else recency; a compose field
/// at the bottom; swipe to delete; tap an anchored row to jump the editor
/// there.
public final class DocumentNotesPanelViewController: UIViewController {

    private let notesStore: NoteStoring
    private let noteIndex: NoteIndexing
    private let textStore: DocumentTextStoring
    private var document: WriterDocument

    /// The open editor a tap on an anchored row focuses. Weak: the panel
    /// outlives neither the editor nor the container that owns both.
    public weak var editor: (UIViewController & DocumentEditing)?
    public weak var relevance: NoteRelevanceProviding?

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let composeBar = UIView()
    private let composeField = UITextField()

    private(set) var rows: [WriterNote] = []
    private(set) var orphanedNoteIDs: Set<NoteID> = []

    public init(
        notesStore: NoteStoring, noteIndex: NoteIndexing, textStore: DocumentTextStoring,
        document: WriterDocument
    ) {
        self.notesStore = notesStore
        self.noteIndex = noteIndex
        self.textStore = textStore
        self.document = document
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.string("WriterLibrary_notes_title")
        view.backgroundColor = LunaColors.background
        configureTableView()
        configureComposeBar()
        reload()
    }

    private func configureTableView() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = LunaColors.background
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Note")
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
    }

    private func configureComposeBar() {
        composeBar.backgroundColor = LunaColors.secondaryBackground
        composeField.placeholder = L10n.string("WriterLibrary_notes_composePlaceholder")
        composeField.textColor = LunaColors.primaryText
        composeField.returnKeyType = .send
        composeField.delegate = self
        composeField.translatesAutoresizingMaskIntoConstraints = false
        composeBar.translatesAutoresizingMaskIntoConstraints = false
        composeBar.addSubview(composeField)
        view.addSubview(composeBar)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: composeBar.topAnchor),

            composeBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composeBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composeBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            composeField.leadingAnchor.constraint(equalTo: composeBar.leadingAnchor, constant: 16),
            composeField.trailingAnchor.constraint(equalTo: composeBar.trailingAnchor, constant: -16),
            composeField.topAnchor.constraint(equalTo: composeBar.topAnchor, constant: 10),
            composeField.bottomAnchor.constraint(equalTo: composeBar.bottomAnchor, constant: -10),
        ])
    }

    // MARK: - Data

    public func reload() {
        var notes = (try? notesStore.notes(for: document.id)) ?? []
        if let scores = relevance?.relevanceScores(for: document.id), !scores.isEmpty {
            notes.sort { (scores[$0.id] ?? -Double.greatestFiniteMagnitude) > (scores[$1.id] ?? -Double.greatestFiniteMagnitude) }
        } else {
            notes.sort { $0.updatedAt > $1.updatedAt }
        }
        rows = notes
        orphanedNoteIDs = Self.orphanedNotes(notes, document: document, textStore: textStore)
        tableView.reloadData()
    }

    private static func orphanedNotes(
        _ notes: [WriterNote], document: WriterDocument, textStore: DocumentTextStoring
    ) -> Set<NoteID> {
        guard let text = try? textStore.loadText(document) else { return [] }
        let nsText = text as NSString
        var orphaned: Set<NoteID> = []
        for note in notes {
            guard let anchor = note.anchor else { continue }
            if TextAnchorResolver.resolve(anchor, in: nsText) == nil { orphaned.insert(note.id) }
        }
        return orphaned
    }

    // MARK: - Compose

    @discardableResult
    public func composeNote(_ text: String) -> WriterNote? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let note = WriterNote(documentIDs: [document.id], text: trimmed, source: .typed)
        guard (try? notesStore.insert(note)) != nil else { return nil }
        _ = try? notesStore.attach(note.id, to: document.id, attachment: .manual)
        _ = try? noteIndex.index(note)
        reload()
        return note
    }

    @discardableResult
    public func deleteNote(_ id: NoteID) -> Bool {
        guard (try? notesStore.delete(id)) != nil else { return false }
        _ = try? noteIndex.remove(id)
        reload()
        return true
    }

    public func selectNote(at index: Int) {
        guard index < rows.count, let anchor = rows[index].anchor else { return }
        editor?.focus(on: anchor)
    }
}

extension DocumentNotesPanelViewController: UITableViewDataSource, UITableViewDelegate {
    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }

    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Note", for: indexPath)
        let note = rows[indexPath.row]
        cell.textLabel?.numberOfLines = 3
        cell.backgroundColor = LunaColors.secondaryBackground
        if note.anchor != nil {
            let orphaned = orphanedNoteIDs.contains(note.id)
            cell.textLabel?.text = (orphaned ? "⚠︎ " : "") + note.text
            cell.textLabel?.textColor = orphaned ? LunaColors.tertiaryText : LunaColors.primaryText
        } else {
            cell.textLabel?.text = note.text
            cell.textLabel?.textColor = LunaColors.primaryText
        }
        return cell
    }

    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        selectNote(at: indexPath.row)
    }

    public func tableView(
        _ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        let note = rows[indexPath.row]
        let delete = UIContextualAction(style: .destructive, title: L10n.string("Common_delete")) {
            [weak self] _, _, completion in
            completion(self?.deleteNote(note.id) ?? false)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }
}

extension DocumentNotesPanelViewController: UITextFieldDelegate {
    public func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        composeNote(textField.text ?? "")
        textField.text = ""
        return true
    }
}

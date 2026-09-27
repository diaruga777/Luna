import UIKit
import LunaDesignSystem
import LunaModels
import LunaWriterModels
import LunaWriterStorage
import LunaWriterText

/// Notes for one document, newest first. Capture several lines, then save;
/// tap a note to edit it, or an anchored note to jump to its text.
public final class DocumentNotesPanelViewController: UIViewController {

    private let library: WriterLibraryStoring
    private let notesStore: NoteStoring
    private let textStore: DocumentTextStoring
    private var document: WriterDocument

    /// The open editor a tap on an anchored row focuses. Weak: the panel
    /// outlives neither the editor nor the container that owns both.
    public weak var editor: (UIViewController & DocumentEditing)?

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let composeBar = UIView()
    let composeField = UITextView()
    let saveButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private let composePlaceholder = UILabel()
    private let errorLabel = UILabel()
    private let emptyLabel = UILabel()
    private let leadingSeparator = UIView()

    /// A hairline on the leading edge, for the side-by-side host where the
    /// panel shares the editor's background.
    public var showsLeadingSeparator: Bool = false {
        didSet { leadingSeparator.isHidden = !showsLeadingSeparator }
    }
    private var editingNote: WriterNote?
    private var isSaving = false
    private let saveQueue = DispatchQueue(label: "com.luna.writer.notes.save", qos: .userInitiated)

    private(set) var rows: [WriterNote] = []
    private(set) var orphanedNoteIDs: Set<NoteID> = []

    public init(
        library: WriterLibraryStoring, notesStore: NoteStoring,
        textStore: DocumentTextStoring, document: WriterDocument
    ) {
        self.library = library
        self.notesStore = notesStore
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
        library.addObserver(self)
    }

    deinit { library.removeObserver(self) }

    /// A panel with nothing in it is opened to write; the keyboard comes up
    /// without a second tap.
    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if rows.isEmpty, editingNote == nil { composeField.becomeFirstResponder() }
    }

    private func configureTableView() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = LunaColors.background
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: L10n.string("WriterLibrary_polish_noteTitle"))
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        emptyLabel.text = L10n.string("WriterLibrary_notes_emptyMessage")
        emptyLabel.font = .preferredFont(forTextStyle: .body)
        emptyLabel.adjustsFontForContentSizeCategory = true
        emptyLabel.textColor = LunaColors.secondaryText
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        tableView.backgroundView = emptyLabel
        leadingSeparator.backgroundColor = LunaColors.separator
        leadingSeparator.isHidden = !showsLeadingSeparator
        leadingSeparator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(leadingSeparator)
        NSLayoutConstraint.activate([
            leadingSeparator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            leadingSeparator.topAnchor.constraint(equalTo: view.topAnchor),
            leadingSeparator.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            leadingSeparator.widthAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),
        ])
    }

    private func configureComposeBar() {
        composeBar.backgroundColor = LunaColors.secondaryBackground
        composeField.font = .preferredFont(forTextStyle: .body)
        composeField.adjustsFontForContentSizeCategory = true
        composeField.textColor = LunaColors.primaryText
        composeField.backgroundColor = .clear
        composeField.delegate = self
        composeField.accessibilityLabel = L10n.string("WriterLibrary_notes_composePlaceholder")
        composePlaceholder.text = L10n.string("WriterLibrary_notes_composePlaceholder")
        composePlaceholder.font = .preferredFont(forTextStyle: .body)
        composePlaceholder.textColor = LunaColors.tertiaryText
        composePlaceholder.isUserInteractionEnabled = false
        saveButton.setTitle(L10n.string("Common_save"), for: .normal)
        saveButton.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)
        cancelButton.setTitle(L10n.string("Common_cancel"), for: .normal)
        cancelButton.addTarget(self, action: #selector(cancelEditing), for: .touchUpInside)
        cancelButton.isHidden = true
        errorLabel.font = .preferredFont(forTextStyle: .caption1)
        errorLabel.textColor = .systemRed
        errorLabel.numberOfLines = 0
        errorLabel.isHidden = true
        let buttons = UIStackView(arrangedSubviews: [cancelButton, UIView(), saveButton])
        buttons.axis = .horizontal
        let content = UIStackView(arrangedSubviews: [composeField, errorLabel, buttons])
        content.axis = .vertical
        content.spacing = 4
        content.translatesAutoresizingMaskIntoConstraints = false
        composeBar.translatesAutoresizingMaskIntoConstraints = false
        composePlaceholder.translatesAutoresizingMaskIntoConstraints = false
        composeBar.addSubview(content)
        composeBar.addSubview(composePlaceholder)
        view.addSubview(composeBar)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: composeBar.topAnchor),
            composeBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composeBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composeBar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            content.leadingAnchor.constraint(equalTo: composeBar.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: composeBar.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: composeBar.topAnchor, constant: 8),
            content.bottomAnchor.constraint(equalTo: composeBar.bottomAnchor, constant: -8),
            composeField.heightAnchor.constraint(equalToConstant: 96),
            composePlaceholder.leadingAnchor.constraint(equalTo: composeField.leadingAnchor, constant: 5),
            composePlaceholder.topAnchor.constraint(equalTo: composeField.topAnchor, constant: 8),
            saveButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        updateComposeState()
    }

    // MARK: - Data

    public func reload() {
        let notes = ((try? notesStore.notes(for: document.id)) ?? []).sorted {
            $0.updatedAt > $1.updatedAt
        }
        rows = notes
        orphanedNoteIDs = Self.orphanedNotes(notes, document: document, textStore: textStore)
        emptyLabel.isHidden = !notes.isEmpty
        tableView.reloadData()
    }

    private static func orphanedNotes(
        _ notes: [WriterNote], document: WriterDocument, textStore: DocumentTextStoring
    ) -> Set<NoteID> {
        guard notes.contains(where: { $0.anchor != nil }),
              let text = try? textStore.loadText(document) else { return [] }
        let nsText = text as NSString
        var orphaned: Set<NoteID> = []
        for note in notes {
            guard let anchor = note.anchor else { continue }
            if TextAnchorResolver.resolve(anchor, in: nsText) == nil { orphaned.insert(note.id) }
        }
        return orphaned
    }

    // MARK: - Compose

    /// A Done action can save the draft before dismissing the panel. Errors
    /// leave both the text and the panel in place so the writer can retry.
    public func saveDraft(completion: @escaping (Bool) -> Void = { _ in }) {
        guard !isSaving else { completion(false); return }
        let text = composeField.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { completion(true); return }
        var note = editingNote ?? WriterNote(documentIDs: [document.id], text: text)
        note.text = text
        let isNew = editingNote == nil
        let store = notesStore
        isSaving = true
        updateComposeState()
        saveQueue.async { [self, note] in
            let result = Result {
                if isNew { try store.insert(note) } else { try store.update(note) }
            }
            DispatchQueue.main.async { [self] in
                isSaving = false
                switch result {
                case .success:
                    composeField.text = ""
                    editingNote = nil
                    cancelButton.isHidden = true
                    errorLabel.isHidden = true
                    reload()
                    updateComposeState()
                    completion(true)
                case .failure:
                    errorLabel.text = L10n.string("WriterLibrary_notes_saveFailed")
                    errorLabel.isHidden = false
                    updateComposeState()
                    completion(false)
                }
            }
        }
    }

    @objc private func saveTapped() { saveDraft() }

    private func updateComposeState() {
        let hasText = !composeField.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        composePlaceholder.isHidden = !composeField.text.isEmpty
        saveButton.isEnabled = hasText && !isSaving
        composeField.isEditable = !isSaving
        cancelButton.isEnabled = !isSaving
        // Do not let a swipe discard a draft. Done saves before closing.
        navigationController?.isModalInPresentation = hasText || isSaving
    }

    private func editNote(_ note: WriterNote) {
        guard !isSaving else { return }
        guard composeField.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            composeField.becomeFirstResponder()
            return
        }
        editingNote = note
        composeField.text = note.text
        cancelButton.isHidden = false
        updateComposeState()
        composeField.becomeFirstResponder()
    }

    @objc private func cancelEditing() {
        editingNote = nil
        composeField.text = ""
        cancelButton.isHidden = true
        errorLabel.isHidden = true
        updateComposeState()
    }

    @discardableResult
    public func deleteNote(_ id: NoteID) -> Bool {
        guard (try? notesStore.delete(id)) != nil else { return false }
        reload()
        return true
    }

    public func selectNote(at index: Int) {
        guard rows.indices.contains(index) else { return }
        if let anchor = rows[index].anchor {
            editor?.focus(on: anchor)
        } else {
            editNote(rows[index])
        }
    }
}

extension DocumentNotesPanelViewController: UITableViewDataSource, UITableViewDelegate {
    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }

    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: L10n.string("WriterLibrary_polish_noteTitle"), for: indexPath)
        let note = rows[indexPath.row]
        cell.textLabel?.numberOfLines = 0
        cell.textLabel?.font = .preferredFont(forTextStyle: .body)
        cell.textLabel?.adjustsFontForContentSizeCategory = true
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

    public func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath,
                          point: CGPoint) -> UIContextMenuConfiguration? {
        let note = rows[indexPath.row]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [UIAction(title: L10n.string("WriterLibrary_notes_edit"),
                                      image: UIImage(systemName: "pencil")) { _ in self?.editNote(note) }])
        }
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

extension DocumentNotesPanelViewController: UITextViewDelegate {
    public func textViewDidChange(_ textView: UITextView) { updateComposeState() }
}

extension DocumentNotesPanelViewController: LibraryChangeObserving {
    /// A note added elsewhere while the panel is open — via "@", voice, or an
    /// intent — was invisible until the panel was reopened (organiser #31).
    public func libraryDidChange(_ change: LibraryChange) {
        switch change {
        case .notes(let id) where id == nil || id == document.id:
            reload()
        default:
            break
        }
    }
}

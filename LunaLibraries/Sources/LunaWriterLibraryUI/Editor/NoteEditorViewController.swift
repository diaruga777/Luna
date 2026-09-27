import UIKit
import LunaModels
import LunaWriterModels
import LunaWriterStorage

/// A full, scrollable note editor shared by All Notes and document notes.
final class NoteEditorViewController: UIViewController, UITextViewDelegate {
    private let store: NoteStoring
    private let library: WriterLibraryStoring
    private var note: WriterNote
    private let isNew: Bool
    private let textView = UITextView()
    private let onOpen: (WriterDocument) -> Void

    init(note: WriterNote?, store: NoteStoring, library: WriterLibraryStoring,
         onOpen: @escaping (WriterDocument) -> Void) {
        self.note = note ?? WriterNote(text: "")
        self.isNew = note == nil
        self.store = store
        self.library = library
        self.onOpen = onOpen
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = isNew ? L10n.string("WriterLibrary_polish_newNote") : L10n.string("WriterLibrary_polish_noteTitle")
        view.backgroundColor = .systemBackground
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.text = note.text
        textView.delegate = self
        textView.textContainerInset = UIEdgeInsets(top: 20, left: 16, bottom: 20, right: 16)
        textView.accessibilityLabel = L10n.string("WriterLibrary_polish_noteText")
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(barButtonSystemItem: .save, target: self, action: #selector(save)),
            UIBarButtonItem(image: UIImage(systemName: "link"), menu: linksMenu()),
        ]
        navigationItem.rightBarButtonItems?.last?.accessibilityLabel = L10n.string("WriterLibrary_polish_linkedDocuments")
        textViewDidChange(textView)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if isNew { textView.becomeFirstResponder() }
    }

    func textViewDidChange(_ textView: UITextView) {
        navigationItem.rightBarButtonItems?.first?.isEnabled = !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        navigationController?.isModalInPresentation = textView.text != note.text
    }

    private func linksMenu() -> UIMenu {
        var actions = note.documentIDs.compactMap { id -> UIMenuElement? in
            guard let document = try? library.document(id), document.trashedAt == nil else { return nil }
            return UIAction(title: document.title, image: UIImage(systemName: "doc.text")) { [weak self] _ in
                guard let self else { return }
                self.saveAndClose { self.onOpen(document) }
            }
        }
        if !isNew {
            actions.append(UIAction(title: L10n.string("WriterLibrary_polish_linkDocument"), image: UIImage(systemName: "link.badge.plus")) { [weak self] _ in
                guard let self else { return }
                let picker = SheetPickerViewController(library: self.library) { [weak self] id in
                    guard let self else { return }
                    do {
                        try self.store.attach(self.note.id, to: id, attachment: .manual)
                        self.note = try self.store.note(self.note.id) ?? self.note
                        self.navigationItem.rightBarButtonItems?.last?.menu = self.linksMenu()
                    } catch { self.showError(error) }
                }
                self.present(UINavigationController(rootViewController: picker), animated: true)
            })
        }
        return UIMenu(title: L10n.string("WriterLibrary_polish_linkedDocuments"), children: actions)
    }

    @objc private func cancel() {
        guard textView.text != note.text else { dismiss(animated: true); return }
        let alert = UIAlertController(title: L10n.string("WriterLibrary_polish_discardChanges"), message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.string("WriterLibrary_polish_keepEditing"), style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.string("WriterLibrary_polish_discard"), style: .destructive) { [weak self] _ in self?.dismiss(animated: true) })
        present(alert, animated: true)
    }

    @objc private func save() { saveAndClose() }

    private func saveAndClose(completion: (() -> Void)? = nil) {
        var updated = note
        updated.text = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !updated.text.isEmpty else { return }
        do {
            if isNew { try store.insert(updated) } else { try store.update(updated) }
            dismiss(animated: true, completion: completion)
        } catch { showError(error) }
    }

    private func showError(_ error: Error) {
        let alert = UIAlertController(title: L10n.string("WriterLibrary_polish_saveNoteError"), message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

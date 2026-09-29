import UIKit
import LunaDesignSystem
import LunaModels
import LunaWriterModels
import LunaWriterStorage

/// Lets the writer pick one existing sheet — the Inbox's "Attach to…" flow
/// for an unattached note. A one-shot modal flow, same shape as
/// `MoveDestinationPicker`.
public final class SheetPickerViewController: UITableViewController {

    private let library: WriterLibraryStoring
    private let onPick: (DocumentID) -> Void
    private var documents: [WriterDocument] = []

    public init(library: WriterLibraryStoring, onPick: @escaping (DocumentID) -> Void) {
        self.library = library
        self.onPick = onPick
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.string("WriterLibrary_sheets_attachToTitle")
        tableView.backgroundColor = .systemGroupedBackground
        tableView.cellLayoutMarginsFollowReadableWidth = true
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: L10n.string("Common_cancel"), style: .plain, target: self,
            action: #selector(cancelTapped))
        documents = ((try? library.documents(matching: FilterPredicate(), scope: nil)) ?? [])
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    @objc private func cancelTapped() { dismiss(animated: true) }

    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        documents.count
    }

    public override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let document = documents[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = document.title.isEmpty ? L10n.string("Common_untitled") : document.title
        cell.detailTextLabel?.text = document.snippet
        cell.detailTextLabel?.textColor = LunaColors.secondaryText
        cell.backgroundColor = .secondarySystemGroupedBackground
        cell.textLabel?.font = .preferredFont(forTextStyle: .body)
        cell.textLabel?.adjustsFontForContentSizeCategory = true
        cell.textLabel?.numberOfLines = 0
        cell.detailTextLabel?.adjustsFontForContentSizeCategory = true
        return cell
    }

    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onPick(documents[indexPath.row].id)
        dismiss(animated: true)
    }
}

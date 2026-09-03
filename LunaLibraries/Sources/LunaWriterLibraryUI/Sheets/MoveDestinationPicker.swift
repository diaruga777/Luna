import UIKit
import LunaDesignSystem
import LunaModels
import LunaWriterModels
import LunaWriterStorage

/// Lets the writer pick a group to move one or more sheets into. A one-shot
/// modal flow: `onPick` runs at most once, for the single in-flight
/// presentation this controller exists for.
public final class MoveDestinationPicker: UITableViewController {

    private struct Row { let group: WriterGroup; let depth: Int }

    private let library: WriterLibraryStoring
    private let onPick: (GroupID) -> Void
    private var rows: [Row] = []

    public init(library: WriterLibraryStoring, onPick: @escaping (GroupID) -> Void) {
        self.library = library
        self.onPick = onPick
        super.init(style: .plain)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.string("WriterLibrary_move_title")
        tableView.backgroundColor = LunaColors.background
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: L10n.string("Common_cancel"), style: .plain, target: self,
            action: #selector(cancelTapped))
        buildRows()
    }

    @objc private func cancelTapped() { dismiss(animated: true) }

    private func buildRows() {
        let groups = ((try? library.groups()) ?? []).filter { $0.kind != .trash }
        let byParent = Dictionary(grouping: groups, by: \.parentID)
        var result: [Row] = []
        func append(parent: GroupID?, depth: Int) {
            let children = (byParent[parent] ?? []).sorted { $0.sortIndex < $1.sortIndex }
            for child in children {
                result.append(Row(group: child, depth: depth))
                append(parent: child.id, depth: depth + 1)
            }
        }
        append(parent: nil, depth: 0)
        rows = result
    }

    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.count
    }

    public override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let row = rows[indexPath.row]
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.textLabel?.text = row.group.name
        cell.imageView?.image = UIImage(systemName: row.group.iconName)
        cell.indentationLevel = row.depth
        cell.backgroundColor = LunaColors.secondaryBackground
        return cell
    }

    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let group = rows[indexPath.row].group
        onPick(group.id)
        dismiss(animated: true)
    }
}

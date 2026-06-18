//
//  CatchUpDeleteReadView.swift
//  Clip
//

import UIKit

/// The end-of-catch-up "delete read items?" screen: a prompt near the top and,
/// below it, a table of the read items (like the reading list's Read section) in
/// multi-select radio state — all selected by default. Rows can't be opened or
/// long-pressed; tapping anywhere toggles selection. The host watches
/// `onSelectionChanged` to flip the prompt/button between "Delete All" and
/// "Delete Selected".
final class CatchUpDeleteReadView: UIView, UITableViewDataSource, UITableViewDelegate {

    private let items: [ReadingListItem]
    private let store: ReadingListStore
    private let titleLabel = UILabel()
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var didSelectAll = false

    /// Called with (selectedCount, total) whenever selection changes.
    var onSelectionChanged: ((Int, Int) -> Void)?

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    /// The ids the user wants deleted (the selected rows).
    var selectedItemIDs: [UUID] {
        (tableView.indexPathsForSelectedRows ?? []).map { items[$0.row].id }
    }

    var selectedCount: Int { tableView.indexPathsForSelectedRows?.count ?? 0 }
    var total: Int { items.count }

    init(items: [ReadingListItem], store: ReadingListStore) {
        self.items = items
        self.store = store
        super.init(frame: .zero)

        titleLabel.font = .systemFont(ofSize: 26, weight: .bold)
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .clear
        tableView.allowsMultipleSelectionDuringEditing = true
        tableView.setEditing(true, animated: false)
        tableView.register(ReadingListItemCell.self, forCellReuseIdentifier: ReadingListItemCell.reuseID)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tableView)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            tableView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
            tableView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Select every row once, the first time the table has them.
        guard !didSelectAll, !items.isEmpty else { return }
        didSelectAll = true
        for row in 0..<items.count {
            tableView.selectRow(
                at: IndexPath(row: row, section: 0), animated: false, scrollPosition: .none)
        }
        notifySelection()
    }

    func updateTitle(allSelected: Bool) {
        titleLabel.text = allSelected ? "Delete all read items?" : "Delete selected items?"
    }

    private func notifySelection() {
        onSelectionChanged?(selectedCount, total)
        updateTitle(allSelected: selectedCount == total)
    }

    // MARK: - Table

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { items.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = items[indexPath.row]
        let cell = tableView.dequeueReusableCell(
            withIdentifier: ReadingListItemCell.reuseID, for: indexPath) as? ReadingListItemCell
            ?? ReadingListItemCell(style: .default, reuseIdentifier: ReadingListItemCell.reuseID)
        cell.configure(
            title: item.title ?? item.urlString, titleColor: .label,
            subtitle: subtitle(for: item), thumbnail: thumbnail(for: item),
            showsDisclosure: false,
            reuseKey: "delete|\(item.id.uuidString)|\(item.thumbnailFileName ?? "")")
        cell.showsReorderControl = false
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) { notifySelection() }
    func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) { notifySelection() }

    private func subtitle(for item: ReadingListItem) -> NSAttributedString {
        var parts: [String] = []
        if let host = item.url?.host?.replacingOccurrences(of: "www.", with: "") { parts.append(host) }
        parts.append(Self.formatter.string(from: item.bumpDate ?? item.dateAdded))
        return NSAttributedString(
            string: parts.joined(separator: " · "),
            attributes: [.foregroundColor: UIColor.tertiaryLabel])
    }

    private func thumbnail(for item: ReadingListItem) -> ReadingListItemCell.Thumbnail {
        if let fileName = item.thumbnailFileName {
            return .art(path: store.articlesDirectory.appendingPathComponent(fileName).path)
        }
        if let platform = item.contentPlatform,
           let module = PlatformRegistry.shared.module(for: platform) {
            return .logo(assetName: platform.logoAssetName, glyph: module.glyphSymbolName)
        }
        return .none
    }
}

//
//  ReadingListViewController.swift
//  Clip
//

import UIKit

/// The home screen. Two sections: unread articles (unopened bright, opened
/// dimmed, intermingled chronologically) and finished articles below, with a
/// delete-all button. Tap to read; swipe to delete or jump into RSVP.
final class ReadingListViewController: UITableViewController {

    init() {
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private let store = ReadingListStore.shared
    private var unreadItems: [ReadingListItem] = []
    private var readItems: [ReadingListItem] = []

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Reading List"
        navigationController?.navigationBar.prefersLargeTitles = true

        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .add, target: self, action: #selector(addTapped))
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "gearshape"), style: .plain,
            target: self, action: #selector(settingsTapped))

        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(pulledToRefresh), for: .valueChanged)

        NotificationCenter.default.addObserver(
            self, selector: #selector(reload), name: .readingListChanged, object: nil)
        reload()
    }

    @objc private func reload() {
        let all = store.items()
        unreadItems = all.filter { $0.readState != .read }
        readItems = all.filter { $0.readState == .read }
        tableView.reloadData()
    }

    @objc private func pulledToRefresh() {
        ReadingListIngestor.shared.ingestAllPending()
        reload()
        refreshControl?.endRefreshing()
    }

    // MARK: - Add

    @objc private func addTapped() {
        let alert = UIAlertController(
            title: "Save a Link", message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "https://…"
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.text = UIPasteboard.general.url?.absoluteString
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak alert] _ in
            guard var text = alert?.textFields?.first?.text?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
            else { return }
            if !text.hasPrefix("http") { text = "https://" + text }
            ReadingListIngestor.shared.saveAndIngest(urlString: text)
        })
        present(alert, animated: true)
    }

    @objc private func settingsTapped() {
        navigationController?.pushViewController(SettingsViewController(), animated: true)
    }

    @objc private func deleteAllReadTapped() {
        let alert = UIAlertController(
            title: "Delete \(readItems.count) read article\(readItems.count == 1 ? "" : "s")?",
            message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Delete All Read", style: .destructive) { [weak self] _ in
            self?.store.deleteAllRead()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    // MARK: - Table

    private func item(at indexPath: IndexPath) -> ReadingListItem {
        indexPath.section == 0 ? unreadItems[indexPath.row] : readItems[indexPath.row]
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? unreadItems.count : readItems.count
    }

    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        if section == 0 {
            guard !unreadItems.isEmpty else { return nil }
            let header = UIView()
            let label = UILabel()
            label.text = "Unread"
            label.font = .preferredFont(forTextStyle: .headline)
            label.textColor = .secondaryLabel
            label.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 20),
                label.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            ])
            return header
        }
        guard !readItems.isEmpty else { return nil }

        let header = UIView()
        let label = UILabel()
        label.text = "Read"
        label.font = .preferredFont(forTextStyle: .headline)
        label.textColor = .secondaryLabel

        let deleteButton = UIButton(type: .system)
        deleteButton.setTitle("Delete All", for: .normal)
        deleteButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        deleteButton.tintColor = .systemRed
        deleteButton.addTarget(self, action: #selector(deleteAllReadTapped), for: .touchUpInside)

        label.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(label)
        header.addSubview(deleteButton)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 20),
            label.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            deleteButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -20),
            deleteButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])
        return header
    }

    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        if section == 0 { return unreadItems.isEmpty ? 0 : 36 }
        return readItems.isEmpty ? 0 : 44
    }

    override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let item = item(at: indexPath)

        var config = cell.defaultContentConfiguration()
        config.text = item.title ?? item.urlString
        let host = item.url?.host ?? ""
        let stateSuffix: String
        switch item.state {
        case .pending: stateSuffix = " · downloading…"
        case .failed: stateSuffix = " · failed (pull to retry)"
        case .ready: stateSuffix = ""
        }
        var infoParts = [host, dateFormatter.string(from: item.dateAdded)]
        if ReaderSettings.showReadingTime, let words = item.wordCount, words > 0 {
            infoParts.append("\(max(1, Int((Double(words) / 220.0).rounded(.up)))) min")
        }
        if ReaderSettings.showReadingProgress, item.readState != .read,
           let progress = item.readingProgress, progress > 0.01 {
            infoParts.append("\(Int(progress * 100))%")
        }
        config.secondaryText = infoParts.joined(separator: " · ") + stateSuffix
        // Unopened articles pop; anything touched fades back (but stays legible).
        config.textProperties.color = item.readState == .unopened ? .label : .secondaryLabel
        config.secondaryTextProperties.color = item.readState == .unopened
            ? .secondaryLabel : .tertiaryLabel
        config.textProperties.numberOfLines = 2
        cell.contentConfiguration = config
        cell.accessoryType = item.state == .ready ? .disclosureIndicator : .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let item = item(at: indexPath)
        guard item.state == .ready, let content = store.content(for: item) else { return }
        let reader = ReaderViewController(item: item, content: content)
        navigationController?.pushViewController(reader, animated: true)
    }

    override func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        let item = item(at: indexPath)
        let delete = UIContextualAction(style: .destructive, title: "Delete") {
            [weak self] _, _, done in
            self?.store.delete(item)
            done(true)
        }
        let speedRead = UIContextualAction(style: .normal, title: "RSVP") {
            [weak self] _, _, done in
            guard let self, item.state == .ready,
                  let content = self.store.content(for: item) else { done(false); return }
            let reader = ReaderViewController(item: item, content: content, forceMode: .rsvp)
            self.navigationController?.pushViewController(reader, animated: true)
            done(true)
        }
        speedRead.backgroundColor = .systemIndigo
        return UISwipeActionsConfiguration(actions: [delete, speedRead])
    }
}

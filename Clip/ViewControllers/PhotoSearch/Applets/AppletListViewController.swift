//
//  AppletListViewController.swift
//  clipper
//

import UIKit

/// Lists the user's applets with their capture counts, and routes to create/edit.
final class AppletListViewController: UITableViewController {

    private let context: PhotoSearchContext
    private lazy var manager = AppletManager(context: context)
    private var applets: [Applet] = []

    private static let cellID = "appletCell"

    init(context: PhotoSearchContext) {
        self.context = context
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Applets"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .add, target: self, action: #selector(addApplet)
        )
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    private func reload() {
        applets = manager.list()
        tableView.reloadData()
        updateEmptyState()
    }

    private func updateEmptyState() {
        guard applets.isEmpty else {
            tableView.backgroundView = nil
            return
        }
        let label = UILabel()
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .body)
        label.text = "No applets yet.\nTap + to make a rule like “a dog” and Pouch will count matching photos."
        tableView.backgroundView = label
    }

    @objc private func addApplet() {
        pushEditor(for: nil)
    }

    private func pushEditor(for applet: Applet?) {
        let editor = AppletEditViewController(context: context, applet: applet)
        editor.onChange = { [weak self] in self?.reload() }
        navigationController?.pushViewController(editor, animated: true)
    }

    // MARK: - Table view

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        applets.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.cellID)
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: Self.cellID)
        let applet = applets[indexPath.row]
        var content = UIListContentConfiguration.subtitleCell()
        content.text = applet.name
        let captures = "\(applet.captureCount) capture\(applet.captureCount == 1 ? "" : "s")"
        content.secondaryText = applet.notifyOnCapture ? "\(captures) · notifications on" : captures
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        pushEditor(for: applets[indexPath.row])
    }

    override func tableView(
        _ tableView: UITableView,
        commit editingStyle: UITableViewCell.EditingStyle,
        forRowAt indexPath: IndexPath
    ) {
        guard editingStyle == .delete else { return }
        manager.delete(applets[indexPath.row])
        reload()
    }
}

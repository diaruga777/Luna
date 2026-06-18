//
//  SearchViewController.swift
//  Clip
//

import UIKit

/// Lets `SearchViewController` reuse the reading list's cell rendering, open
/// behavior, and long-press menu so search rows look and act exactly like list
/// rows. Implemented by `ReadingListViewController`.
protocol ReadingListItemPresenting: AnyObject {
    /// Configures a reused `ReadingListItemCell` for `item` (title, subtitle,
    /// thumbnail) identically to the reading list.
    func configureItemCell(_ cell: ReadingListItemCell, for item: ReadingListItem)
    /// The long-press menu for a search result — same actions as the list MINUS
    /// "Edit List", always WITH "Bump to Top" (which re-sorts the list for when the
    /// user returns). `onChange` is called after a mutation so search can refresh.
    func searchResultMenu(
        for item: ReadingListItem, sourceView: UIView, presenter: UIViewController,
        onChange: @escaping () -> Void) -> UIMenu
}

/// Search over the saved reading list, hosted IN PLACE over the reading list (a
/// child VC cross-faded in — no modal page transition): a bottom search field
/// (focused immediately) with results listed above it. Two result streams merge —
/// instant string matches first, then semantic nearest-neighbours — both
/// refreshed on every keystroke. Rows reuse `ReadingListItemCell` and the list's
/// rendering + menu via `ReadingListItemPresenting`. The host wires `onExit`
/// (the X / done) and `onOpen` (a tapped result) to fade this out and act.
final class SearchViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    /// Called when the user leaves search (taps the X). The host fades this out.
    var onExit: (() -> Void)?
    /// Called when the user taps a result. The host fades search out, then opens it.
    var onOpen: ((ReadingListItem) -> Void)?

    private let engine: ReadingListSearching
    private weak var presenter: ReadingListItemPresenting?

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let searchField = UITextField()
    private let exitButton = UIButton(type: .system)

    private var results: [ReadingListItem] = []
    /// Runs semantic embeds one at a time, off-main (the NL model isn't reentrant).
    private let semanticQueue = DispatchQueue(label: "com.hpiddy.clip.search.semantic", qos: .userInitiated)
    /// Bumps on every keystroke so a late semantic result for an old query is dropped.
    private var queryToken = 0

    init(engine: ReadingListSearching, presenter: ReadingListItemPresenting) {
        self.engine = engine
        self.presenter = presenter
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setUpViews()

        // Build the search index off-main; re-run the current query when it lands.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.engine.prepare()
            DispatchQueue.main.async { self?.runSearch() }
        }
        // Nudge semantic indexing so freshly-saved items become searchable sooner.
        SemanticIndexer.shared.scheduleRun()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        searchField.becomeFirstResponder()
    }

    /// Focuses the field (shows the keyboard). Called by the host after the
    /// cross-fade in, since this VC's view is hosted manually (appearance callbacks
    /// aren't guaranteed to fire for a non-standard containment).
    func focusSearchField() {
        searchField.becomeFirstResponder()
    }

    private func setUpViews() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(ReadingListItemCell.self, forCellReuseIdentifier: ReadingListItemCell.reuseID)
        tableView.keyboardDismissMode = .interactive
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 92
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)

        // Bottom search bar: [X] [ search field (with inline clear) ].
        exitButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        exitButton.tintColor = .label
        exitButton.accessibilityLabel = "Exit search"
        exitButton.addAction(UIAction { [weak self] _ in self?.exitSearch() }, for: .touchUpInside)
        exitButton.setContentHuggingPriority(.required, for: .horizontal)
        exitButton.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholder = "Search your reading list"
        searchField.borderStyle = .roundedRect
        searchField.clearButtonMode = .whileEditing   // the inline x to clear the text
        searchField.autocorrectionType = .no
        searchField.autocapitalizationType = .none
        searchField.returnKeyType = .search
        searchField.enablesReturnKeyAutomatically = false
        searchField.addTarget(self, action: #selector(textChanged), for: .editingChanged)
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let bar = UIStackView(arrangedSubviews: [exitButton, searchField])
        bar.axis = .horizontal
        bar.spacing = 12
        bar.alignment = .center
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)

        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            // Sits just above the keyboard (collapses to the safe area when hidden).
            bar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8),

            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -8),
        ])
    }

    private func exitSearch() {
        searchField.resignFirstResponder()
        engine.release()
        onExit?()
    }

    @objc private func textChanged() { runSearch() }

    private func runSearch() {
        let query = searchField.text ?? ""
        queryToken += 1
        let token = queryToken

        // 1. String matches — instant, synchronous, shown first.
        let stringHits = engine.stringMatches(for: query)
        results = stringHits
        tableView.reloadData()

        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // 2. Semantic matches — off-main, appended (de-duped) when ready.
        let excluded = Set(stringHits.map(\.id))
        semanticQueue.async { [weak self] in
            guard let self else { return }
            let semantic = self.engine.semanticMatches(for: query, excluding: excluded)
            DispatchQueue.main.async {
                guard self.queryToken == token else { return }   // a newer keystroke superseded this
                let shown = Set(self.results.map(\.id))
                let fresh = semantic.filter { !shown.contains($0.id) }
                guard !fresh.isEmpty else { return }
                self.results += fresh
                self.tableView.reloadData()
            }
        }
    }

    // MARK: - UITableViewDataSource / Delegate

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { results.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: ReadingListItemCell.reuseID, for: indexPath) as? ReadingListItemCell
            ?? ReadingListItemCell(style: .default, reuseIdentifier: ReadingListItemCell.reuseID)
        let item = results[indexPath.row]
        presenter?.configureItemCell(cell, for: item)
        if AppEnvironment.isSimulator {
            cell.setSimulatorMenu(menu(for: item, sourceView: cell))
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        searchField.resignFirstResponder()
        engine.release()
        onOpen?(results[indexPath.row])
    }

    func tableView(
        _ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint
    ) -> UIContextMenuConfiguration? {
        let item = results[indexPath.row]
        let sourceView = tableView.cellForRow(at: indexPath) ?? tableView
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            self?.menu(for: item, sourceView: sourceView)
        }
    }

    private func menu(for item: ReadingListItem, sourceView: UIView) -> UIMenu {
        presenter?.searchResultMenu(
            for: item, sourceView: sourceView, presenter: self,
            onChange: { [weak self] in self?.runSearch() }) ?? UIMenu()
    }
}

extension SearchViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}

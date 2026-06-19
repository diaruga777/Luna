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

    /// Inset-grouped to match the reading list's cell insets and card styling.
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let searchField = UITextField()
    private let exitButton = UIButton(type: .system)
    private static let fieldHeight: CGFloat = 44

    private var results: [ReadingListItem] = []
    /// Caps the search bar above the bottom safe area; constant set from the window
    /// safe area in `viewDidLayoutSubviews`.
    private var barBottomCap: NSLayoutConstraint?
    /// The host's known top safe-area inset (status bar), passed in so the first
    /// layout is correct even before this hosted view's own window insets resolve.
    var topSafeAreaInset: CGFloat = 0
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
        // Match the inset-grouped reading list's background so cells look identical.
        view.backgroundColor = .systemGroupedBackground

        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(ReadingListItemCell.self, forCellReuseIdentifier: ReadingListItemCell.reuseID)
        tableView.keyboardDismissMode = .interactive
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 92
        tableView.backgroundColor = .clear
        // We pin the top explicitly to the safe area, so don't let the table add a
        // second adjustment (which pushed the first row under the status bar).
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)

        // X exit button — a liquid-glass circle.
        exitButton.configuration = GlassStyle.circularButtonConfiguration(symbol: "xmark", padding: 11)
        exitButton.tintColor = .label
        exitButton.accessibilityLabel = "Exit search"
        exitButton.addAction(UIAction { [weak self] _ in self?.exitSearch() }, for: .touchUpInside)
        exitButton.setContentHuggingPriority(.required, for: .horizontal)
        exitButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        exitButton.translatesAutoresizingMaskIntoConstraints = false

        // Search field inside a liquid-glass pill (fully rounded, not a squircle).
        searchField.placeholder = "Search everything"
        searchField.borderStyle = .none
        searchField.backgroundColor = .clear
        searchField.clearButtonMode = .whileEditing   // the inline x to clear the text
        searchField.autocorrectionType = .no
        searchField.autocapitalizationType = .none
        searchField.returnKeyType = .search
        searchField.enablesReturnKeyAutomatically = false
        searchField.addTarget(self, action: #selector(textChanged), for: .editingChanged)
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let fieldPill = UIVisualEffectView(effect: GlassStyle.barEffect())
        fieldPill.translatesAutoresizingMaskIntoConstraints = false
        if #available(iOS 26.0, *) {
            fieldPill.cornerConfiguration = .capsule()
        } else {
            fieldPill.layer.cornerRadius = Self.fieldHeight / 2   // true pill on the fallback
            fieldPill.layer.cornerCurve = .circular
            fieldPill.clipsToBounds = true
        }
        fieldPill.contentView.addSubview(searchField)
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: fieldPill.contentView.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: fieldPill.contentView.trailingAnchor, constant: -12),
            searchField.topAnchor.constraint(equalTo: fieldPill.contentView.topAnchor),
            searchField.bottomAnchor.constraint(equalTo: fieldPill.contentView.bottomAnchor),
        ])

        let bar = UIStackView(arrangedSubviews: [exitButton, fieldPill])
        bar.axis = .horizontal
        bar.spacing = 12
        bar.alignment = .center
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)

        // Rise above the keyboard when it's up (the guide tracks the real keyboard
        // frame), but never sit below the bottom safe area when it's down.
        let aboveKeyboard = bar.bottomAnchor.constraint(
            equalTo: view.keyboardLayoutGuide.topAnchor, constant: -10)
        aboveKeyboard.priority = .defaultHigh
        // Cap above the bottom safe area. The hosted view's own safe-area insets are
        // unreliable (the nav controller doesn't propagate them to a manually-added
        // subview once its bar is hidden), so the constant is set from the WINDOW's
        // safe area in viewDidLayoutSubviews.
        let bottomCap = bar.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -12)
        barBottomCap = bottomCap

        NSLayoutConstraint.activate([
            fieldPill.heightAnchor.constraint(equalToConstant: Self.fieldHeight),
            exitButton.widthAnchor.constraint(equalToConstant: Self.fieldHeight),
            exitButton.heightAnchor.constraint(equalToConstant: Self.fieldHeight),

            // Offset the X a bit more from the left edge (fixed, since the hosted
            // view's margins/safe-area are unreliable).
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            aboveKeyboard,
            bottomCap,

            // Full-bleed table; its TOP CONTENT INSET (status bar + 8) is applied
            // from the window safe area in viewDidLayoutSubviews so the first row
            // clears the status bar regardless of the hosted view's broken insets.
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -10),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Use the WINDOW's safe area (authoritative) rather than this hosted view's.
        let safe = view.window?.safeAreaInsets ?? view.safeAreaInsets
        let topInset = max(safe.top, topSafeAreaInset) + 28
        if abs(tableView.contentInset.top - topInset) > 0.5 {
            tableView.contentInset.top = topInset
            tableView.verticalScrollIndicatorInsets.top = topInset
        }
        barBottomCap?.constant = -(safe.bottom + 12)
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

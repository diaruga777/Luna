import UIKit

public extension VaultAccessibilityID {
    static let connectionStatus = "vault.connection.status"
    static let browse = "vault.browse"
    static let refresh = "vault.refresh"
    static let pairingDeviceID = "vault.pairing.local-device-id"
}

/// Search-first home for the Syncthing-backed Vault. It receives presentation
/// capabilities only; discovery, TLS, BEP sessions, and cache paths stay in
/// composition and lower layers.
/// Syncthing-backed home. The legacy `VaultRootViewController` remains the
/// compatibility shell until the app composition switches to this provider
/// driven surface; keeping a distinct type avoids two package-wide definitions
/// during the staged migration.
public final class VaultSyncthingHomeViewController: UIViewController, UITextFieldDelegate {
    private let runtime: any VaultPresentationProviding
    private let importHandler: (() -> Void)?
    private let openHandler: ((String) -> Void)?
    private let settingsController: (() -> UIViewController)?

    private let statusLabel = UILabel()
    private let searchField = UITextField()
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let recentsScroll = UIScrollView()
    private let recentsStack = UIStackView()
    private let resultsStack = UIStackView()
    private let refreshControl = UIRefreshControl()
    private var searchTask: Task<Void, Never>?
    private var loadGeneration = 0

    public init(runtime: any VaultPresentationProviding,
                importHandler: (() -> Void)? = nil,
                openHandler: ((String) -> Void)? = nil,
                settingsController: (() -> UIViewController)? = nil) {
        self.runtime = runtime
        self.importHandler = importHandler
        self.openHandler = openHandler
        self.settingsController = settingsController
        super.init(nibName: nil, bundle: nil)
    }

    deinit { searchTask?.cancel() }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = "Luna Vault"
        view.backgroundColor = .systemBackground
        configureNavigation()
        configureSearch()
        configureContent()
        reloadContent()
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadContent()
    }

    public func refresh() { reloadContent() }

    private func configureNavigation() {
        let settings = UIBarButtonItem(image: UIImage(systemName: "gearshape"), style: .plain,
                                       target: self, action: #selector(settingsTapped))
        settings.accessibilityIdentifier = VaultAccessibilityID.settings
        settings.accessibilityLabel = "Vault settings"
        let importing = UIBarButtonItem(image: UIImage(systemName: "square.and.arrow.down"), style: .plain,
                                        target: self, action: #selector(importTapped))
        importing.accessibilityIdentifier = VaultAccessibilityID.importButton
        importing.accessibilityLabel = "Import file"
        navigationItem.rightBarButtonItems = [settings, importing]
    }

    private func configureSearch() {
        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.textColor = .secondaryLabel
        statusLabel.accessibilityIdentifier = VaultAccessibilityID.connectionStatus
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholder = "Search names, text, and dates"
        searchField.accessibilityLabel = "Search your Vault"
        searchField.accessibilityIdentifier = VaultAccessibilityID.search
        searchField.borderStyle = .roundedRect
        searchField.returnKeyType = .search
        searchField.clearButtonMode = .whileEditing
        searchField.delegate = self
        searchField.addTarget(self, action: #selector(queryChanged), for: .editingChanged)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)
        view.addSubview(searchField)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: statusLabel.leadingAnchor),
            searchField.trailingAnchor.constraint(equalTo: statusLabel.trailingAnchor),
            searchField.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            searchField.heightAnchor.constraint(equalToConstant: 48),
        ])
    }

    private func configureContent() {
        stack.axis = .vertical
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false

        let browse = UIButton(type: .system)
        var configuration = UIButton.Configuration.tinted()
        configuration.title = "Browse folders"
        configuration.image = UIImage(systemName: "folder")
        configuration.imagePadding = 9
        configuration.cornerStyle = .medium
        browse.configuration = configuration
        browse.contentHorizontalAlignment = .leading
        browse.accessibilityIdentifier = VaultAccessibilityID.browse
        browse.accessibilityLabel = "Browse Vault folders"
        browse.addTarget(self, action: #selector(browseTapped), for: .touchUpInside)

        recentsStack.axis = .horizontal
        recentsStack.spacing = 10
        recentsStack.translatesAutoresizingMaskIntoConstraints = false
        recentsScroll.showsHorizontalScrollIndicator = false
        recentsScroll.accessibilityIdentifier = VaultAccessibilityID.recents
        recentsScroll.addSubview(recentsStack)
        NSLayoutConstraint.activate([
            recentsStack.leadingAnchor.constraint(equalTo: recentsScroll.contentLayoutGuide.leadingAnchor),
            recentsStack.trailingAnchor.constraint(equalTo: recentsScroll.contentLayoutGuide.trailingAnchor),
            recentsStack.topAnchor.constraint(equalTo: recentsScroll.contentLayoutGuide.topAnchor),
            recentsStack.bottomAnchor.constraint(equalTo: recentsScroll.contentLayoutGuide.bottomAnchor),
            recentsStack.heightAnchor.constraint(equalToConstant: 132),
            recentsScroll.heightAnchor.constraint(equalToConstant: 132),
        ])

        resultsStack.axis = .vertical
        resultsStack.spacing = 10
        resultsStack.accessibilityIdentifier = VaultAccessibilityID.results

        [browse, sectionLabel("Recent"), recentsScroll,
         sectionLabel("Results"), resultsStack].forEach(stack.addArrangedSubview)

        scrollView.alwaysBounceVertical = true
        scrollView.accessibilityIdentifier = VaultAccessibilityID.content
        refreshControl.accessibilityIdentifier = VaultAccessibilityID.refresh
        refreshControl.accessibilityLabel = "Refresh Vault"
        refreshControl.addTarget(self, action: #selector(refreshPulled), for: .valueChanged)
        scrollView.refreshControl = refreshControl
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 14),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -28),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -40),
        ])
    }

    @objc private func importTapped() { importHandler?() }

    @objc private func settingsTapped() {
        guard let controller = settingsController?() else { return }
        navigationController?.pushViewController(controller, animated: true)
    }

    @objc private func browseTapped() {
        let browse = VaultBrowseViewController(runtime: runtime, path: "", openHandler: openHandler)
        navigationController?.pushViewController(browse, animated: true)
    }

    @objc private func refreshPulled() {
        Task { [weak self] in
            guard let self else { return }
            await runtime.refresh()
            await MainActor.run {
                self.refreshControl.endRefreshing()
                self.reloadContent()
            }
        }
    }

    @objc private func queryChanged() { scheduleSearch(after: 250_000_000) }

    public func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        scheduleSearch(after: 0)
        textField.resignFirstResponder()
        return true
    }

    private func reloadContent() {
        loadGeneration += 1
        let generation = loadGeneration
        Task { [weak self] in
            guard let self else { return }
            async let status = runtime.connectionStatus()
            async let recents = runtime.recentFiles(limit: 12)
            let currentStatus = await status
            let recentResult: Result<[VaultPresentedFile], Error>
            do { recentResult = .success(try await recents) }
            catch { recentResult = .failure(error) }
            guard generation == self.loadGeneration else { return }
            statusLabel.text = currentStatus.rawValue
            statusLabel.accessibilityLabel = "Vault connection: \(currentStatus.rawValue)"
            switch recentResult {
            case .success(let items): renderRecents(items)
            case .failure: renderRecents([])
            }
            if normalizedQuery.isEmpty { renderResults([]) }
            else { scheduleSearch(after: 0) }
        }
    }

    private var normalizedQuery: String {
        (searchField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func scheduleSearch(after delay: UInt64) {
        searchTask?.cancel()
        let query = normalizedQuery
        guard !query.isEmpty else { renderResults([]); return }
        searchTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            guard let self, !Task.isCancelled else { return }
            let result = await vaultAsyncResult { [self] in try await self.runtime.search(query, limit: 40) }
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let items): renderResults(items)
            case .failure: renderMessage("Search is unavailable. Pull to refresh and try again.")
            }
        }
    }

    private func renderRecents(_ items: [VaultPresentedFile]) {
        removeArrangedSubviews(recentsStack)
        guard !items.isEmpty else {
            recentsStack.addArrangedSubview(emptyLabel("No recent files yet"))
            return
        }
        for item in items {
            let card = VaultFileCard(item: item, compact: true)
            card.accessibilityIdentifier = "vault.recent.\(safeID(item.id))"
            card.addAction(UIAction { [weak self] _ in self?.open(item) }, for: .touchUpInside)
            card.widthAnchor.constraint(equalToConstant: 210).isActive = true
            recentsStack.addArrangedSubview(card)
        }
    }

    private func renderResults(_ items: [VaultPresentedFile]) {
        removeArrangedSubviews(resultsStack)
        guard !items.isEmpty else {
            resultsStack.addArrangedSubview(emptyLabel(
                normalizedQuery.isEmpty ? "Search by name, extracted text, or modification date" : "No matching files"))
            return
        }
        for item in items {
            let row = VaultFileCard(item: item, compact: false)
            row.accessibilityIdentifier = "vault.result.\(safeID(item.id))"
            row.addAction(UIAction { [weak self] _ in self?.open(item) }, for: .touchUpInside)
            resultsStack.addArrangedSubview(row)
        }
    }

    private func renderMessage(_ message: String) {
        removeArrangedSubviews(resultsStack)
        resultsStack.addArrangedSubview(emptyLabel(message))
    }

    private func open(_ item: VaultPresentedFile) {
        if item.isDirectory {
            navigationController?.pushViewController(
                VaultBrowseViewController(runtime: runtime, path: item.path, openHandler: openHandler), animated: true)
        } else {
            openHandler?(item.id)
        }
    }

    private func sectionLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .title3)
        return label
    }

    private func emptyLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        return label
    }
}

/// Folder tree over the mirrored BEP file names. Navigation is local and
/// bounded; opening a file returns its opaque id to composition.
public final class VaultBrowseViewController: UITableViewController {
    private let runtime: any VaultPresentationProviding
    public let path: String
    private let openHandler: ((String) -> Void)?
    private var items: [VaultPresentedFile] = []

    public init(runtime: any VaultPresentationProviding, path: String,
                openHandler: ((String) -> Void)? = nil) {
        self.runtime = runtime
        self.path = path
        self.openHandler = openHandler
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = path.isEmpty ? "Browse" : (path.split(separator: "/").last.map(String.init) ?? "Browse")
        tableView.accessibilityIdentifier = "vault.browse.list"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "file")
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(refreshPulled), for: .valueChanged)
        loadChildren()
    }

    @objc private func refreshPulled() {
        Task { [weak self] in
            guard let self else { return }
            await runtime.refresh()
            await MainActor.run { self.loadChildren() }
        }
    }

    private func loadChildren() {
        Task { [weak self] in
            guard let self else { return }
            let result = await vaultAsyncResult { [self] in try await self.runtime.children(of: self.path) }
            guard case .success(let loaded) = result else {
                refreshControl?.endRefreshing()
                return
            }
            items = loaded
            tableView.reloadData()
            refreshControl?.endRefreshing()
        }
    }

    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        items.count
    }

    public override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = items[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "file", for: indexPath)
        var content = cell.defaultContentConfiguration()
        content.text = item.name
        content.secondaryText = VaultDateChipFormatter.string(from: item.modifiedAt)
        content.image = item.thumbnailData.flatMap(UIImage.init(data:))
            ?? UIImage(systemName: item.isDirectory ? "folder.fill" : "doc")
        content.imageProperties.maximumSize = CGSize(width: 44, height: 44)
        cell.contentConfiguration = content
        cell.accessoryType = item.isDirectory ? .disclosureIndicator : .none
        cell.accessibilityIdentifier = "vault.browse.item.\(safeID(item.id))"
        cell.accessibilityLabel = "\(item.name), modified \(VaultDateChipFormatter.string(from: item.modifiedAt))"
        return cell
    }

    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let item = items[indexPath.row]
        if item.isDirectory {
            navigationController?.pushViewController(
                VaultBrowseViewController(runtime: runtime, path: item.path, openHandler: openHandler), animated: true)
        } else {
            openHandler?(item.id)
        }
    }
}

private func vaultAsyncResult<T>(_ operation: @escaping () async throws -> T) async -> Result<T, Error> {
    do { return .success(try await operation()) }
    catch { return .failure(error) }
}

private final class VaultFileCard: UIControl {
    init(item: VaultPresentedFile, compact: Bool) {
        super.init(frame: .zero)
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 14
        isAccessibilityElement = true
        accessibilityTraits = .button

        let image = UIImageView(image: item.thumbnailData.flatMap(UIImage.init(data:))
            ?? UIImage(systemName: item.isDirectory ? "folder.fill" : "doc"))
        image.contentMode = .scaleAspectFill
        image.clipsToBounds = true
        image.layer.cornerRadius = 9
        image.tintColor = .secondaryLabel
        image.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            image.widthAnchor.constraint(equalToConstant: compact ? 52 : 60),
            image.heightAnchor.constraint(equalToConstant: compact ? 52 : 60),
        ])

        let title = UILabel()
        title.text = item.name
        title.font = .preferredFont(forTextStyle: compact ? .subheadline : .headline)
        title.numberOfLines = 2

        let snippet = UILabel()
        snippet.text = item.snippet
        snippet.font = .preferredFont(forTextStyle: .subheadline)
        snippet.textColor = .secondaryLabel
        snippet.numberOfLines = compact ? 1 : 2
        snippet.isHidden = item.snippet.isEmpty

        let date = PaddingLabel()
        date.text = VaultDateChipFormatter.string(from: item.modifiedAt)
        date.font = .preferredFont(forTextStyle: .caption2)
        date.textColor = .secondaryLabel
        date.backgroundColor = .tertiarySystemFill
        date.layer.cornerRadius = 7
        date.clipsToBounds = true

        let labels = UIStackView(arrangedSubviews: [title, snippet, date])
        labels.axis = .vertical
        labels.spacing = 5
        labels.alignment = .leading
        let row = UIStackView(arrangedSubviews: [image, labels])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            heightAnchor.constraint(greaterThanOrEqualToConstant: compact ? 108 : 88),
        ])
        accessibilityLabel = "\(item.name). \(item.snippet). Modified \(date.text ?? "")"
        accessibilityHint = item.isDirectory ? "Open folder" : "Open file"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class PaddingLabel: UILabel {
    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + 12, height: size.height + 6)
    }
}

enum VaultDateChipFormatter {
    private static let formatter: DateFormatter = {
        let value = DateFormatter()
        value.dateStyle = .medium
        value.timeStyle = .none
        value.doesRelativeDateFormatting = true
        return value
    }()

    static func string(from date: Date) -> String { formatter.string(from: date) }
}

private func removeArrangedSubviews(_ stack: UIStackView) {
    for view in stack.arrangedSubviews {
        stack.removeArrangedSubview(view)
        view.removeFromSuperview()
    }
}

private func safeID(_ value: String) -> String {
    Data(value.utf8).base64EncodedString()
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "=", with: "")
}

#if os(iOS)
import UIKit
import LunaCodeCore

public struct CodeBrowserItem: Sendable {
    public var path: String
    public var name: String
    public var directory: Bool
    public init(path: String, name: String, directory: Bool) { self.path = path; self.name = name; self.directory = directory }
    public var project: Bool { path.hasSuffix(".xcodeproj") || path.hasSuffix(".xcworkspace") }
}
public struct CodeBrowserPage: Sendable {
    public var items: [CodeBrowserItem]
    public var next: Int64?
    public init(items: [CodeBrowserItem], next: Int64?) { self.items = items; self.next = next }
}
@MainActor public final class CodeEnvironment {
    public let client: CodeClient
    public let drafts: CodeDraftStore
    public let browse: (String?, Int64, Bool) async throws -> CodeBrowserPage
    public let pairing: () -> UIViewController
    public let peerID: () -> String
    public let defaults: UserDefaults
    public var project: CodeProject? {
        get { defaults.data(forKey: "Code.project." + peerID()).flatMap { try? JSONDecoder().decode(CodeProject.self, from: $0) } }
        set { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "Code.project." + peerID()) }
    }
    public init(client: CodeClient, drafts: CodeDraftStore, defaults: UserDefaults = .standard,
                browse: @escaping (String?, Int64, Bool) async throws -> CodeBrowserPage,
                pairing: @escaping () -> UIViewController, peerID: @escaping () -> String) {
        self.client = client; self.drafts = drafts; self.defaults = defaults
        self.browse = browse; self.pairing = pairing; self.peerID = peerID
    }
}

@MainActor public final class CodeWorkspaceController: UISplitViewController {
    private let environment: CodeEnvironment
    private var editor: CodeEditorController!
    private var browser: CodeBrowserController!
    public init(environment: CodeEnvironment) {
        self.environment = environment
        super.init(style: .doubleColumn)
        preferredDisplayMode = .oneBesideSecondary
        preferredSplitBehavior = .tile
        primaryBackgroundStyle = .sidebar
        minimumPrimaryColumnWidth = 250; maximumPrimaryColumnWidth = 380
        preferredPrimaryColumnWidthFraction = 0.28
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    public override func viewDidLoad() {
        super.viewDidLoad()
        editor = CodeEditorController(environment: environment)
        browser = makeBrowser(path: nil)
        setViewController(UINavigationController(rootViewController: browser), for: .primary)
        setViewController(UINavigationController(rootViewController: editor), for: .secondary)
        editor.openFiles = { [weak self] in self?.show(.primary) }
        if let path = environment.defaults.string(forKey: "Code.lastFile." + environment.peerID()) {
            Task { self.show(.secondary); self.editor.open(path: path) }
        }
    }
    private func makeBrowser(path: String?) -> CodeBrowserController {
        let browser = CodeBrowserController(environment: environment, path: path)
        browser.open = { [weak self] item in
            guard let self else { return }
            if item.project {
                self.environment.project = CodeProject(path: item.path)
                self.show(.secondary); self.editor.configureProject()
            } else if item.directory {
                let next = self.makeBrowser(path: item.path)
                (self.viewController(for: .primary) as? UINavigationController)?.pushViewController(next, animated: true)
            } else { self.show(.secondary); self.editor.open(path: item.path) }
        }
        return browser
    }
}

@MainActor final class CodeBrowserController: UITableViewController, UISearchResultsUpdating {
    let environment: CodeEnvironment
    let path: String?
    var open: ((CodeBrowserItem) -> Void)?
    private var items: [CodeBrowserItem] = []
    private var nextOffset: Int64?
    private var loading = false
    private var hidden = false
    private let search = UISearchController(searchResultsController: nil)
    init(environment: CodeEnvironment, path: String?) { self.environment = environment; self.path = path; super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private var filtered: [CodeBrowserItem] {
        let query = search.searchBar.text ?? ""
        return items.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            .sorted { a, b in a.directory != b.directory ? a.directory : a.name.localizedStandardCompare(b.name) == .orderedAscending }
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = path.map { ($0 as NSString).lastPathComponent } ?? "Mac Files"
        navigationItem.largeTitleDisplayMode = .never
        search.searchResultsUpdater = self; search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = "Find in this folder"
        navigationItem.searchController = search
        navigationItem.rightBarButtonItems = [UIBarButtonItem(image: UIImage(systemName: "gearshape"), style: .plain, target: self, action: #selector(settings)),
            UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: UIMenu(children: [
                UIAction(title: "Show Hidden Files", image: UIImage(systemName: "eye")) { [weak self] _ in self?.hidden.toggle(); self?.load(reset: true) },
                UIAction(title: "Go to Path…", image: UIImage(systemName: "folder")) { [weak self] _ in self?.goToPath() }
            ]))]
        refreshControl = UIRefreshControl(); refreshControl?.addTarget(self, action: #selector(refresh), for: .valueChanged)
        tableView.keyboardDismissMode = .onDrag
        load(reset: true)
    }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); if items.isEmpty { load(reset: true) } }
    @objc private func refresh() { load(reset: true) }
    @objc private func settings() { navigationController?.pushViewController(environment.pairing(), animated: true) }
    private func goToPath() {
        let alert = UIAlertController(title: "Open Mac Path", message: "Enter a folder or source file path.", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "/Users/you/Projects"; $0.autocapitalizationType = .none; $0.autocorrectionType = .no }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Open Folder", style: .default) { [weak self] _ in
            guard let path = alert.textFields?.first?.text, path.hasPrefix("/") else { return }
            self?.open?(CodeBrowserItem(path: path, name: (path as NSString).lastPathComponent, directory: true))
        })
        alert.addAction(UIAlertAction(title: "Open File", style: .default) { [weak self] _ in
            guard let path = alert.textFields?.first?.text, path.hasPrefix("/") else { return }
            self?.open?(CodeBrowserItem(path: path, name: (path as NSString).lastPathComponent, directory: false))
        })
        present(alert, animated: true)
    }
    private func load(reset: Bool) {
        guard !loading else { return }; loading = true
        Task {
            defer { loading = false; refreshControl?.endRefreshing() }
            do {
                let page = try await environment.browse(path, reset ? 0 : nextOffset ?? 0, hidden)
                items = reset ? page.items : items + page.items; nextOffset = page.next
                tableView.backgroundView = nil; tableView.reloadData()
            } catch {
                let label = UILabel(); label.text = "Connect your Mac\n\n" + error.localizedDescription + "\n\nOpen Settings to pair once for Vault and Code. Pull down to retry."
                label.numberOfLines = 0; label.textAlignment = .center; label.textColor = .secondaryLabel
                label.font = .preferredFont(forTextStyle: .body); tableView.backgroundView = label
            }
        }
    }
    func updateSearchResults(for searchController: UISearchController) { tableView.reloadData() }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { filtered.count + (nextOffset == nil ? 0 : 1) }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        guard indexPath.row < filtered.count else { cell.textLabel?.text = "Load More"; return cell }
        let item = filtered[indexPath.row]
        cell.textLabel?.text = item.name; cell.textLabel?.font = .preferredFont(forTextStyle: .body)
        cell.imageView?.image = UIImage(systemName: item.project ? "hammer.fill" : item.directory ? "folder.fill" : "doc.text")
        cell.imageView?.tintColor = item.project ? .systemIndigo : .systemBlue
        cell.accessoryType = item.directory ? .disclosureIndicator : .none
        if item.project { cell.detailTextLabel?.text = "Select project & scheme" }
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.row < filtered.count else { load(reset: false); return }
        open?(filtered[indexPath.row])
    }
}
#endif

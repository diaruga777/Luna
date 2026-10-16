#if os(iOS)
import UIKit
import LunaCodeCore

@MainActor public final class CodeTabsController: UITabBarController, UITabBarControllerDelegate {
    private let environment: CodeEnvironment
    public init(environment: CodeEnvironment) { self.environment = environment; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    public override func viewDidLoad() {
        super.viewDidLoad()
        let workspace = CodeWorkspaceController(environment: environment)
        workspace.tabBarItem = UITabBarItem(title: "Project", image: UIImage(systemName: "curlybraces"), tag: 0)
        let builds = UINavigationController(rootViewController: CodeBuildsController(environment: environment))
        builds.tabBarItem = UITabBarItem(title: "Builds", image: UIImage(systemName: "play.rectangle"), tag: 1)
        viewControllers = [workspace, builds]
        selectedIndex = CodeBuildCatalog(defaults: environment.defaults).selectedTab
        delegate = self
    }
    public func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
        CodeBuildCatalog(defaults: environment.defaults).selectedTab = selectedIndex
    }
}

@MainActor final class CodeBuildsController: UITableViewController {
    private let environment: CodeEnvironment
    private var catalog: CodeBuildCatalog { CodeBuildCatalog(defaults: environment.defaults) }
    private var apps: [CodeBuildApp] { catalog.apps(peer: environment.peerID()) }
    private var devices: [CodeDevice] = []
    private var jobs: [String: CodeJob] = [:]
    private var discovery: Task<Void, Never>?
    private var poll: Timer?
    private var polling = false
    private var loading = false
    private var starting: String?
    private var peer = ""
    private var message: String?

    init(environment: CodeEnvironment) { self.environment = environment; super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { discovery?.cancel(); poll?.invalidate() }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Builds"
        tableView.accessibilityIdentifier = "CodeBuilds"
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "gearshape"), primaryAction: UIAction { [weak self] _ in
            guard let self else { return }; self.navigationController?.pushViewController(self.environment.pairing(), animated: true)
        })
        navigationItem.rightBarButtonItem?.accessibilityLabel = "Mac Connection"
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(refresh), for: .valueChanged)
        NotificationCenter.default.addObserver(self, selector: #selector(activate), name: UIApplication.didBecomeActiveNotification, object: nil)
        poll = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, (self.viewIfLoaded?.window != nil || self.presentedViewController?.viewIfLoaded?.window != nil), UIApplication.shared.applicationState == .active else { return }
                await self.refreshJobs()
            }
        }
    }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); activate() }
    @objc private func activate() {
        if peer != environment.peerID() {
            discovery?.cancel(); loading = false; peer = environment.peerID(); devices = []; jobs = [:]; starting = nil; message = nil
        }
        reload()
        if !loading { load(refreshAll: false) }
        Task { await refreshJobs() }
    }
    @objc private func refresh() { load(refreshAll: true) }
    private func load(refreshAll: Bool) {
        guard !loading else { return }
        loading = true; message = nil
        let peer = environment.peerID()
        let projects = environment.session.recentProjects(peer: peer)
        let paths = projects.filter { project in refreshAll || !apps.contains { $0.project.path == project.path } }
        reload()
        discovery = Task { [weak self] in
            guard let self else { return }
            defer { if peer == environment.peerID() { loading = false; refreshControl?.endRefreshing(); reload() } }
            do {
                let response = try await environment.client.call(CodeRequest(.devices))
                guard peer == environment.peerID(), !Task.isCancelled else { return }
                guard let phones = response.devices else { throw CodeFailure("Update Luna Mac to use phone builds.") }
                devices = phones
                if catalog.defaultDevice(peer: peer) == nil,
                   let phone = CodeBuildCatalog.resolveDevice(phones, preferred: nil, currentName: UIDevice.current.name) {
                    catalog.setDefaultDevice(phone.id, peer: peer)
                }
            } catch { if peer == environment.peerID() { message = error.localizedDescription } }
            for project in paths {
                guard peer == environment.peerID(), !Task.isCancelled else { return }
                do {
                    let schemes = try await environment.client.call(CodeRequest(.schemes, path: project.path)).schemes
                    var found: [CodeBuildApp] = []
                    for scheme in schemes {
                        guard peer == environment.peerID(), !Task.isCancelled else { return }
                        var request = CodeRequest(.apps, path: project.path)
                        request.project = CodeProject(path: project.path, scheme: scheme)
                        let response = try await environment.client.call(request)
                        guard peer == environment.peerID(), !Task.isCancelled else { return }
                        guard let discovered = response.apps else { throw CodeFailure("Update Luna Mac to use phone builds.") }
                        for app in discovered where !found.contains(where: { $0.bundleID == app.bundleID }) { found.append(app) }
                        // Publish each result immediately; keep existing cached rows until scanning completes.
                        var partial = catalog.apps(peer: peer).filter { $0.project.path == project.path }
                        for app in found where !partial.contains(where: { $0.bundleID == app.bundleID }) { partial.append(app) }
                        catalog.merge(partial, path: project.path, peer: peer); reload()
                    }
                    catalog.merge(found, path: project.path, peer: peer)
                    if found.isEmpty { message = "No runnable iOS apps found in " + (project.path as NSString).lastPathComponent + "." }
                } catch { if peer == environment.peerID() { message = error.localizedDescription } }
            }
        }
    }
    private func reload() {
        guard isViewLoaded else { return }
        tableView.reloadData()
        if apps.isEmpty {
            var config = loading ? UIContentUnavailableConfiguration.loading() : .empty()
            config.image = loading ? nil : UIImage(systemName: "iphone.and.arrow.forward")
            config.text = loading ? "Finding Apps…" : "Build to Your Phone"
            config.secondaryText = message ?? "Open a project in the Project tab. Its iOS apps will appear here with one-tap builds from main."
            if !loading {
                config.button.title = message == nil ? "Open Project" : "Retry"
                config.buttonProperties.primaryAction = UIAction { [weak self] _ in
                    guard let self else { return }
                    if self.message != nil { self.refresh() } else { self.tabBarController?.selectedIndex = 0; self.catalog.selectedTab = 0 }
                }
            }
            tableView.backgroundView = UIContentUnavailableView(configuration: config)
        } else { tableView.backgroundView = nil }
    }
    override func numberOfSections(in tableView: UITableView) -> Int { 1 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { apps.count }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { "Previously Opened Projects" }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if let message { return message + "\nPull to refresh. Cached apps remain available." }
        return loading ? "Finding app schemes on your Mac…" : "Builds use committed main by default. Use ••• to change a branch, scheme or phone. Pull to refresh apps and connected phones."
    }
    private func phone(for app: CodeBuildApp) -> CodeDevice? {
        CodeBuildCatalog.resolveDevice(devices, preferred: app.deviceID ?? catalog.defaultDevice(peer: environment.peerID()), currentName: UIDevice.current.name)
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let app = apps[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.selectionStyle = .none
        cell.textLabel?.text = app.name
        cell.textLabel?.font = .preferredFont(forTextStyle: .headline)
        cell.textLabel?.numberOfLines = 0
        let target = phone(for: app)?.name ?? (app.deviceID == nil ? "Default phone" : "Phone disconnected")
        let status = app.jobID.flatMap { jobs[$0]?.state.rawValue.capitalized }
        cell.detailTextLabel?.text = [(app.project.root as NSString).lastPathComponent + " · " + app.project.scheme, app.branch + " · " + target, status].compactMap { $0 }.joined(separator: "\n")
        cell.detailTextLabel?.numberOfLines = 0
        cell.detailTextLabel?.font = .preferredFont(forTextStyle: .caption1)
        cell.accessibilityIdentifier = "CodeBuildApp:" + app.project.scheme
        let play = UIButton(type: .system)
        var config = UIButton.Configuration.tinted(); config.image = UIImage(systemName: "play.fill"); config.cornerStyle = .capsule
        config.showsActivityIndicator = starting == app.key || app.jobID.flatMap { jobs[$0]?.state } == .running
        play.configuration = config
        play.accessibilityLabel = "Build and Run " + app.name
        play.accessibilityIdentifier = "CodeRun:" + app.project.scheme
        play.isEnabled = starting == nil && !jobs.values.contains { $0.state == .running }
        play.addAction(UIAction { [weak self] _ in self?.build(app) }, for: .touchUpInside)
        let more = UIButton(type: .system)
        more.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        more.accessibilityLabel = "Build Options for " + app.name
        more.accessibilityIdentifier = "CodeBuildOptions:" + app.project.scheme
        more.menu = menu(app); more.showsMenuAsPrimaryAction = true
        more.widthAnchor.constraint(equalToConstant: 44).isActive = true
        let controls = UIStackView(arrangedSubviews: [play, more]); controls.spacing = 8
        controls.frame = CGRect(x: 0, y: 0, width: 100, height: 44)
        cell.accessoryView = controls
        return cell
    }
    private func menu(_ app: CodeBuildApp) -> UIMenu {
        let defaults = UIAction(title: "Default Phone", state: app.deviceID == nil ? .on : .off) { [weak self] _ in self?.edit(app) { $0.deviceID = nil } }
        let phones = devices.map { device in
            UIAction(title: device.name, image: UIImage(systemName: "iphone"), state: app.deviceID == device.id ? .on : .off) { [weak self] _ in self?.edit(app) { $0.deviceID = device.id } }
        }
        var actions: [UIMenuElement] = [
            UIMenu(title: "Target Device", children: [defaults] + phones + [UIAction(title: "Refresh Connected Phones…") { [weak self] _ in self?.chooseDefaultPhone() }]),
            UIAction(title: "Branch: " + app.branch, image: UIImage(systemName: "arrow.triangle.branch")) { [weak self] _ in self?.chooseBranch(app) },
            UIAction(title: "Scheme: " + app.project.scheme, image: UIImage(systemName: "list.bullet")) { [weak self] _ in self?.chooseScheme(app) },
            UIAction(title: "Open in Project", image: UIImage(systemName: "curlybraces")) { [weak self] _ in
                guard let self else { return }
                var project = self.environment.session.recentProjects(peer: self.environment.peerID()).first { $0.path == app.project.path } ?? app.project
                project.scheme = app.project.scheme
                self.environment.project = project; self.tabBarController?.selectedIndex = 0; self.catalog.selectedTab = 0
            }
        ]
        if let id = app.jobID {
            actions.append(UIAction(title: "Build Log", image: UIImage(systemName: "terminal")) { [weak self] _ in self?.showLog(id) })
            if jobs[id]?.state == .running {
                actions.append(UIAction(title: "Cancel Build", image: UIImage(systemName: "stop"), attributes: .destructive) { [weak self] _ in self?.cancel(id) })
            }
        }
        return UIMenu(children: actions)
    }
    private func edit(_ app: CodeBuildApp, update: (inout CodeBuildApp) -> Void) {
        var rows = apps
        guard let index = rows.firstIndex(where: { $0.key == app.key }) else { return }
        update(&rows[index]); catalog.save(rows, peer: environment.peerID()); reload()
    }
    private func build(_ app: CodeBuildApp) {
        guard starting == nil else { return }
        starting = app.key; reload()
        let peer = environment.peerID()
        Task {
            defer { if peer == environment.peerID() { starting = nil; reload() } }
            do {
                guard let phones = try await environment.client.call(CodeRequest(.devices)).devices else { throw CodeFailure("Update Luna Mac to use phone builds.") }
                guard peer == environment.peerID() else { return }
                devices = phones
                guard let target = phone(for: app) else { chooseDefaultPhone(for: app); return }
                if catalog.defaultDevice(peer: peer) == nil { catalog.setDefaultDevice(target.id, peer: peer) }
                var request = CodeRequest(.runOnDevice); request.project = app.project
                request.deviceBuild = CodeDeviceBuild(branch: app.branch, deviceID: target.id)
                let response = try await environment.client.call(request)
                guard peer == environment.peerID(), let job = response.job else { return }
                jobs[job.id] = job; edit(app) { $0.jobID = job.id }; showLog(job.id)
            } catch { if peer == environment.peerID() { showError(error) } }
        }
    }
    private func chooseDefaultPhone(for app: CodeBuildApp? = nil) {
        choose(title: "Default Phone", load: { [environment] in
            guard let devices = try await environment.client.call(CodeRequest(.devices)).devices else { throw CodeFailure("Update Luna Mac to use phone builds.") }
            return devices
        }, label: { $0.name }, select: { [weak self] device in
            guard let self else { return }
            self.catalog.setDefaultDevice(device.id, peer: self.environment.peerID())
            if let app { self.edit(app) { $0.deviceID = nil }; self.build(self.appWithDefaultDevice(app)) }
            else { self.load(refreshAll: false) }
        })
    }
    private func appWithDefaultDevice(_ app: CodeBuildApp) -> CodeBuildApp { var result = app; result.deviceID = nil; return result }
    private func chooseBranch(_ app: CodeBuildApp) {
        choose(title: "Branch", load: { [environment] in
            try await environment.client.call(CodeRequest(.branches, path: app.project.path)).branches ?? []
        }, label: { $0 }, select: { [weak self] branch in self?.edit(app) { $0.branch = branch } })
    }
    private func chooseScheme(_ app: CodeBuildApp) {
        choose(title: "Build Scheme", load: { [environment] in
            try await environment.client.call(CodeRequest(.schemes, path: app.project.path)).schemes
        }, label: { $0 }, select: { [weak self] scheme in
            guard let self else { return }; let peer = self.environment.peerID()
            Task {
                do {
                    var request = CodeRequest(.apps, path: app.project.path); request.project = CodeProject(path: app.project.path, scheme: scheme)
                    let response = try await self.environment.client.call(request)
                    guard peer == self.environment.peerID() else { return }
                    guard var updated = response.apps?.first else { throw CodeFailure("This scheme does not run an iOS app.") }
                    updated.branch = app.branch; updated.deviceID = app.deviceID
                    var rows = self.apps.filter { $0.key != app.key && !($0.project.path == updated.project.path && $0.bundleID == updated.bundleID) }
                    rows.append(updated); self.catalog.save(rows, peer: peer); self.reload()
                } catch { if peer == self.environment.peerID() { self.showError(error) } }
            }
        })
    }
    private func choose<T>(title: String, load: @escaping () async throws -> [T], label: @escaping (T) -> String, select: @escaping (T) -> Void) {
        let peer = environment.peerID()
        let list = CodeListController(title: title, rows: []) { _ in }
        present(UINavigationController(rootViewController: list), animated: true); list.showLoading("Loading " + title + "…")
        Task {
            do {
                let values = try await load()
                guard peer == environment.peerID(), list.presentingViewController != nil || list.navigationController?.presentingViewController != nil else { return }
                list.setRows(values.map(label), emptyMessage: "No choices available. Check the project or phone connection on the Mac, then try again.") { [weak list, weak self] index in
                    guard let self, peer == self.environment.peerID() else { return }
                    list?.dismiss(animated: true) { select(values[index]) }
                }
            } catch { if peer == environment.peerID() { list.showMessage(error.localizedDescription) } }
        }
    }
    private func refreshJobs() async {
        guard !polling else { return }; polling = true
        defer { polling = false }
        let peer = environment.peerID()
        var changed = false
        for id in Set(apps.compactMap(\.jobID)) where jobs[id] == nil || jobs[id]?.state == .running {
            var request = CodeRequest(.job); request.jobID = id
            if let job = try? await environment.client.call(request).job, peer == environment.peerID() {
                changed = changed || jobs[id]?.state != job.state
                jobs[id] = job
                if let log = (presentedViewController as? UINavigationController)?.topViewController as? CodeLogController, log.jobID == job.id { log.update(job) }
            }
        }
        if changed, peer == environment.peerID() { reload() }
    }
    private func showLog(_ id: String) {
        let peer = environment.peerID()
        Task {
            do {
                if jobs[id] == nil {
                    var request = CodeRequest(.job); request.jobID = id
                    let job = try await environment.client.call(request).job
                    guard peer == environment.peerID() else { return }; jobs[id] = job
                }
                guard peer == environment.peerID(), let job = jobs[id], presentedViewController == nil else { return }
                let log = CodeLogController(job: job)
                present(UINavigationController(rootViewController: log), animated: true)
            } catch { if peer == environment.peerID() { showError(error) } }
        }
    }
    private func cancel(_ id: String) {
        let peer = environment.peerID()
        Task {
            do {
                var request = CodeRequest(.cancel); request.jobID = id
                let job = try await environment.client.call(request).job
                guard peer == environment.peerID() else { return }; jobs[id] = job; reload()
            } catch { if peer == environment.peerID() { showError(error) } }
        }
    }
    private func showError(_ error: Error) {
        let alert = UIAlertController(title: "Builds", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default)); present(alert, animated: true)
    }
}
#endif

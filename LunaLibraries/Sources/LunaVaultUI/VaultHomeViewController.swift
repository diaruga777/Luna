import LunaVaultBackend
import LunaVaultModels
import LunaVaultSearch
import LunaVaultSetup
import UIKit

/// Stable identifiers are part of the Vault UI contract and are used by
/// accessibility clients as well as deterministic simulator screens.
public enum VaultAccessibilityID {
    public static let search = "vault.search"
    public static let importButton = "vault.import"
    public static let content = "vault.content"
    public static let recents = "vault.recents"
    public static let groups = "vault.groups"
    public static let results = "vault.results"
    public static let setup = "vault.setup"
    public static let setupPolicy = "vault.setup.policy"
    public static let setupContinue = "vault.setup.continue"
    public static let recovery = "vault.recovery"
    public static let recoveryStatus = "vault.recovery.status"
    public static let recoveryRetry = "vault.recovery.retry"
    public static let recoveryReset = "vault.recovery.reset"
    public static let contentStatus = "vault.content.status"
    public static let contentRetry = "vault.content.retry"
    public static let settings = "vault.settings"
    public static let macPairing = "vault.settings.mac"
}

/// Search-first Vault home. File import, preview/rendering, extraction, and
/// backend transport remain host callbacks; this controller presents indexed
/// canonical objects and owns bounded UI work only.
public final class VaultRootViewController: UIViewController {
    private var services: VaultRuntimeServices?
    private let setupCoordinator: VaultSetupCoordinator?
    private var searchFacade: VaultSearchPresentationFacade?
    private let searchIndexLoader: (() throws -> VaultSearchIndex)?
    private let searchIndexProvider: (() -> VaultSearchIndex?)?
    private let servicesProvider: (() -> VaultRuntimeServices?)?
    private let importHandler: (() -> Void)?
    /// The host owns opening/previewing a canonical object. This UI never
    /// constructs a renderer or media player; aliases always resolve to the
    /// canonical object ID before reaching this seam.
    private let openHandler: ((VaultObjectID) -> Void)?
    private let settingsActions: VaultSettingsActions
    private let membershipModelVersionProvider: (() throws -> String)?

    private let searchField = UITextField()
    private let contentScroll = UIScrollView()
    private let contentStack = UIStackView()
    private let contentStatusPanel = UIStackView()
    private let contentStatusLabel = UILabel()
    private let contentRetryButton = UIButton(type: .system)
    private let setupPanel = UIStackView()
    private let recoveryPanel = UIStackView()
    private let recoveryStatusLabel = UILabel()
    private let recoveryRetryButton = UIButton(type: .system)
    private let recoveryResetButton = UIButton(type: .system)
    private let recentScroll = UIScrollView()
    private let recentStack = UIStackView()
    private let groupsStack = UIStackView()
    private let resultsStack = UIStackView()
    private let policyControl = UISegmentedControl(items: ["iPhone", "iCloud", "Mac"])
    private let setupButton = UIButton(type: .system)
    private var didAutofocus = false
    private var setupPolicy = VaultStoragePolicy(location: .device)
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = 0
    /// Guards a stale off-main `updateReadyContent()` load from overwriting a
    /// later one, the same way `searchGeneration` guards search completions.
    private var contentLoadGeneration = 0
    private var contentRetryAction: (() -> Void)?
    /// Which section put up the currently-shown content status. Lets one
    /// section's own completion clear its own status without erasing a
    /// still-relevant status a sibling section raised.
    private enum ContentStatusOrigin: Equatable { case groups, search, other }
    private var contentStatusOrigin: ContentStatusOrigin = .other

    public var onCreateManualGroup: ((String, [VaultObjectID]) throws -> Void)?
    public var onCreateQueryGroup: ((String, [VaultObjectID]) throws -> Void)?
    public var onAddMembership: ((VaultObjectID, UUID, String) throws -> Void)?

    public init(services: VaultRuntimeServices? = nil,
                setupCoordinator: VaultSetupCoordinator? = nil,
                searchIndex: VaultSearchIndex? = nil,
                searchIndexLoader: (() throws -> VaultSearchIndex)? = nil,
                searchIndexProvider: (() -> VaultSearchIndex?)? = nil,
                servicesProvider: (() -> VaultRuntimeServices?)? = nil,
                importHandler: (() -> Void)? = nil,
                openHandler: ((VaultObjectID) -> Void)? = nil,
                /// Deprecated spelling retained for source compatibility with
                /// the first Stage 5 fixture. Both spellings are canonical.
                previewHandler: ((VaultObjectID) -> Void)? = nil,
                settingsActions: VaultSettingsActions = VaultSettingsActions(),
                membershipModelVersionProvider: (() throws -> String)? = nil) {
        self.services = services
        self.setupCoordinator = setupCoordinator
        self.searchFacade = searchIndex.map { VaultSearchPresentationFacade(index: $0) }
        self.searchIndexLoader = searchIndexLoader
        self.searchIndexProvider = searchIndexProvider
        self.servicesProvider = servicesProvider
        self.importHandler = importHandler
        self.openHandler = openHandler ?? previewHandler
        self.settingsActions = settingsActions
        self.membershipModelVersionProvider = membershipModelVersionProvider
        if let configuredPolicy = setupCoordinator?.configuration.storagePolicy {
            self.setupPolicy = configuredPolicy
        }
        super.init(nibName: nil, bundle: nil)
    }

    deinit { searchTask?.cancel() }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "Luna Vault"
        let settings = UIBarButtonItem(image: UIImage(systemName: "gearshape"), style: .plain,
                                       target: self, action: #selector(settingsTapped))
        settings.accessibilityIdentifier = VaultAccessibilityID.settings
        settings.accessibilityLabel = "Vault settings"
        let importing = UIBarButtonItem(image: UIImage(systemName: "square.and.arrow.down"), style: .plain,
                                        target: self, action: #selector(importTapped))
        importing.accessibilityIdentifier = VaultAccessibilityID.importButton
        importing.accessibilityLabel = "Import file"
        navigationItem.rightBarButtonItems = [settings, importing]

        configureSearchField()
        configureContent()
        // Setup and recovery are siblings above the scroll view in z-order.
        // The scroll view is also disabled while either panel is active.
        configureSetupPanel()
        configureRecoveryPanel()
        renderState()
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        renderState()
    }

    /// Refreshes the bounded presentation after a host-owned operation (for
    /// example, a document-picker import) commits a new object/index row.
    /// The controller remains the owner of rendering; hosts never reach into
    /// its private stacks to force a reload.
    public func refresh() { renderState() }

    /// Deterministic seam for app-host and simulator tests. Production callers
    /// use the navigation item's action, while tests can exercise the exact
    /// import callback without relying on UIKit's private bar-button wiring.
    public func triggerImportForTesting() { importTapped() }

    /// Deterministic seam for app-host and simulator tests of result/recent
    /// routing. The argument is still the canonical opaque object ID.
    public func triggerOpenForTesting(_ objectID: VaultObjectID) {
        openCanonicalObject(objectID)
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        focusSearchIfReady()
    }

    @objc private func importTapped() { importHandler?() }

    @objc private func settingsTapped() {
        navigationController?.pushViewController(VaultSettingsViewController(
            setupCoordinator: setupCoordinator, macCredentialStore: makeMacCredentialStore(),
            actions: settingsActions), animated: true)
    }

    private func configureSearchField() {
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholder = "Search your vault"
        searchField.accessibilityLabel = "Search your Vault"
        searchField.accessibilityIdentifier = VaultAccessibilityID.search
        searchField.borderStyle = .roundedRect
        searchField.returnKeyType = .search
        searchField.clearButtonMode = .whileEditing
        searchField.addTarget(self, action: #selector(queryChanged), for: .editingChanged)
        searchField.delegate = self
        view.addSubview(searchField)
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            searchField.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            searchField.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            searchField.heightAnchor.constraint(equalToConstant: 48),
        ])
    }

    private func configureContent() {
        contentStack.axis = .vertical
        contentStack.spacing = 22
        contentStack.alignment = .fill
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        contentStatusPanel.axis = .vertical
        contentStatusPanel.spacing = 8
        contentStatusPanel.alignment = .center
        contentStatusLabel.numberOfLines = 0
        contentStatusLabel.textAlignment = .center
        contentStatusLabel.textColor = .secondaryLabel
        contentStatusLabel.accessibilityIdentifier = VaultAccessibilityID.contentStatus
        contentRetryButton.setTitle("Try again", for: .normal)
        contentRetryButton.accessibilityIdentifier = VaultAccessibilityID.contentRetry
        contentRetryButton.accessibilityLabel = "Retry Vault content"
        contentRetryButton.addTarget(self, action: #selector(retryContent), for: .touchUpInside)
        [contentStatusLabel, contentRetryButton].forEach(contentStatusPanel.addArrangedSubview)
        contentStatusPanel.isHidden = true

        recentStack.axis = .horizontal
        recentStack.spacing = 10
        recentScroll.showsHorizontalScrollIndicator = false
        recentScroll.accessibilityIdentifier = VaultAccessibilityID.recents
        recentScroll.accessibilityLabel = "Recent Vault files"
        recentScroll.addSubview(recentStack)
        recentStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            recentStack.leadingAnchor.constraint(equalTo: recentScroll.contentLayoutGuide.leadingAnchor),
            recentStack.trailingAnchor.constraint(equalTo: recentScroll.contentLayoutGuide.trailingAnchor),
            recentStack.topAnchor.constraint(equalTo: recentScroll.contentLayoutGuide.topAnchor),
            recentStack.bottomAnchor.constraint(equalTo: recentScroll.contentLayoutGuide.bottomAnchor),
            recentStack.heightAnchor.constraint(equalToConstant: 84),
        ])
        groupsStack.axis = .vertical
        groupsStack.spacing = 8
        groupsStack.accessibilityIdentifier = VaultAccessibilityID.groups
        groupsStack.accessibilityLabel = "Vault groups"
        resultsStack.axis = .vertical
        resultsStack.spacing = 8
        resultsStack.accessibilityIdentifier = VaultAccessibilityID.results
        resultsStack.accessibilityLabel = "Vault search results"

        contentScroll.translatesAutoresizingMaskIntoConstraints = false
        contentScroll.alwaysBounceVertical = true
        contentScroll.accessibilityIdentifier = VaultAccessibilityID.content
        contentScroll.accessibilityLabel = "Vault content"
        contentScroll.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: contentScroll.contentLayoutGuide.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: contentScroll.contentLayoutGuide.trailingAnchor, constant: -20),
            contentStack.topAnchor.constraint(equalTo: contentScroll.contentLayoutGuide.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: contentScroll.contentLayoutGuide.bottomAnchor, constant: -28),
            contentStack.widthAnchor.constraint(equalTo: contentScroll.frameLayoutGuide.widthAnchor, constant: -40),
            recentScroll.heightAnchor.constraint(equalToConstant: 84),
        ])
        contentStack.addArrangedSubview(contentStatusPanel)
        contentStack.addArrangedSubview(sectionHeader("Recent"))
        contentStack.addArrangedSubview(recentScroll)
        contentStack.addArrangedSubview(sectionHeader("Groups", action: #selector(newGroupTapped)))
        contentStack.addArrangedSubview(groupsStack)
        contentStack.addArrangedSubview(sectionHeader("Results"))
        contentStack.addArrangedSubview(resultsStack)
        view.addSubview(contentScroll)
        NSLayoutConstraint.activate([
            contentScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentScroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 18),
            contentScroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func configureSetupPanel() {
        styleOverlayPanel(setupPanel, identifier: VaultAccessibilityID.setup)
        let heading = labeledText("Set up your encrypted Vault", style: .headline)
        let detail = labeledText("Choose where the encrypted working copy lives. You can change this later in Settings.", style: .body)
        detail.textColor = .secondaryLabel
        policyControl.accessibilityLabel = "Vault storage location"
        policyControl.accessibilityIdentifier = VaultAccessibilityID.setupPolicy
        policyControl.selectedSegmentIndex = storageLocationIndex(setupPolicy.location)
        policyControl.addTarget(self, action: #selector(policyChanged), for: .valueChanged)
        setupButton.setTitle("Create Vault", for: .normal)
        setupButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        setupButton.accessibilityIdentifier = VaultAccessibilityID.setupContinue
        setupButton.accessibilityLabel = "Create Vault"
        setupButton.addTarget(self, action: #selector(completeSetup), for: .touchUpInside)
        [heading, detail, policyControl, setupButton].forEach(setupPanel.addArrangedSubview)
        addOverlayPanel(setupPanel)
    }

    private func configureRecoveryPanel() {
        styleOverlayPanel(recoveryPanel, identifier: VaultAccessibilityID.recovery)
        let heading = labeledText("Vault needs attention", style: .headline)
        recoveryStatusLabel.numberOfLines = 0
        recoveryStatusLabel.textColor = .secondaryLabel
        recoveryStatusLabel.accessibilityIdentifier = VaultAccessibilityID.recoveryStatus
        recoveryRetryButton.setTitle("Try again", for: .normal)
        recoveryRetryButton.accessibilityIdentifier = VaultAccessibilityID.recoveryRetry
        recoveryRetryButton.accessibilityLabel = "Retry Vault setup"
        recoveryRetryButton.addTarget(self, action: #selector(retrySetup), for: .touchUpInside)
        recoveryResetButton.setTitle("Reset Vault setup…", for: .normal)
        recoveryResetButton.setTitleColor(.systemRed, for: .normal)
        recoveryResetButton.accessibilityIdentifier = VaultAccessibilityID.recoveryReset
        recoveryResetButton.accessibilityLabel = "Reset Vault setup"
        recoveryResetButton.addTarget(self, action: #selector(confirmReset), for: .touchUpInside)
        [heading, recoveryStatusLabel, recoveryRetryButton, recoveryResetButton].forEach(recoveryPanel.addArrangedSubview)
        addOverlayPanel(recoveryPanel)
    }

    private func styleOverlayPanel(_ panel: UIStackView, identifier: String) {
        panel.axis = .vertical
        panel.spacing = 14
        panel.alignment = .fill
        panel.isLayoutMarginsRelativeArrangement = true
        panel.layoutMargins = UIEdgeInsets(top: 22, left: 22, bottom: 22, right: 22)
        panel.backgroundColor = .secondarySystemBackground
        panel.layer.cornerRadius = 16
        panel.accessibilityIdentifier = identifier
        panel.translatesAutoresizingMaskIntoConstraints = false
    }

    private func addOverlayPanel(_ panel: UIView) {
        view.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            panel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            panel.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 18),
            panel.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
        ])
    }

    private func sectionHeader(_ text: String, action: Selector? = nil) -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .center
        let label = labeledText(text, style: .title3)
        row.addArrangedSubview(label)
        row.addArrangedSubview(UIView())
        if let action {
            let button = UIButton(type: .system)
            button.setTitle("New", for: .normal)
            button.accessibilityIdentifier = "vault.groups.new"
            button.accessibilityLabel = "Create a new Vault group"
            button.addTarget(self, action: action, for: .touchUpInside)
            row.addArrangedSubview(button)
        }
        return row
    }

    @objc private func policyChanged() {
        let locations: [VaultStorageLocation] = [.device, .iCloud, .mac]
        setupPolicy = VaultStoragePolicy(location: locations[max(0, min(2, policyControl.selectedSegmentIndex))])
    }

    @objc private func completeSetup() {
        guard let setupCoordinator else { return }
        let state = setupCoordinator.completeFirstRun(policy: setupPolicy)
        if state.isReady {
            services = servicesProvider?()
            _ = ensureSearchFacade()
        }
        renderState()
        focusSearchIfReady()
    }

    @objc private func retrySetup() {
        _ = setupCoordinator?.load()
        renderState()
    }

    @objc private func confirmReset() {
        let alert = UIAlertController(title: "Reset Vault setup?",
            message: "This removes this device's Vault setup and root key. Existing encrypted files may become inaccessible.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Reset", style: .destructive) { [weak self] _ in
            _ = self?.setupCoordinator?.resetConfirmed()
            self?.services = nil
            self?.renderState()
        })
        present(alert, animated: true)
    }

    @objc private func queryChanged() { scheduleSearch(debounceNanoseconds: 250_000_000) }

    @objc private func retryContent() { contentRetryAction?() }

    private func renderState() {
        searchTask?.cancel()
        let state = setupCoordinator?.state
        let firstRun = state.map { if case .firstRun = $0 { return true }; return false } ?? false
        let recovery: Bool
        if let state {
            switch state { case .unavailable, .error: recovery = true; default: recovery = false }
        } else { recovery = false }
        setupPanel.isHidden = !firstRun
        recoveryPanel.isHidden = !recovery
        contentScroll.isHidden = firstRun || recovery
        contentScroll.isUserInteractionEnabled = !(firstRun || recovery)
        searchField.isEnabled = !(firstRun || recovery)
        if firstRun { hideContentStatus(); return }
        guard let state else { updateReadyContent(); return }
        switch state {
        case .firstRun:
            break
        case .ready(let policy):
            setupPolicy = policy
            // Settings can replace a Mac credential while keeping the same
            // storage policy. Resolve the host runtime on every ready render
            // and compare its complete identity, rather than policy alone;
            // unpair therefore also clears a previously-ready backend.
            if let servicesProvider {
                let resolved = servicesProvider()
                if services?.runtimeIdentity != resolved?.runtimeIdentity {
                    services = resolved
                }
            }
            updateReadyContent()
            if services?.isReady != true {
                let message = policy.location == .iCloud
                    ? "iCloud is unavailable. Check your Apple ID and iCloud Drive."
                    : policy.location == .mac
                    ? "Mac storage is unavailable. Pair or reconnect your Mac in Settings."
                    : "Vault storage needs attention."
                showContentStatus(message) { [weak self] in
                    self?.services = self?.servicesProvider?()
                    self?.renderState()
                }
            }
        case .unavailable(let reason):
            hideContentStatus()
            recoveryStatusLabel.text = setupMessage(reason)
            recoveryStatusLabel.accessibilityLabel = recoveryStatusLabel.text
        case .error(let failure):
            hideContentStatus()
            recoveryStatusLabel.text = "Vault setup could not finish (\(failure)). Try again or reset setup."
            recoveryStatusLabel.accessibilityLabel = recoveryStatusLabel.text
        }
    }

    private func ensureSearchFacade() -> Bool {
        if searchFacade != nil { return true }
        do {
            if let searchIndexLoader {
                searchFacade = VaultSearchPresentationFacade(index: try searchIndexLoader())
            } else if let index = searchIndexProvider?() {
                searchFacade = VaultSearchPresentationFacade(index: index)
            } else {
                throw VaultSearchError.sqlite("No search index provider is configured")
            }
            hideContentStatus()
            return true
        } catch {
            showContentStatus("The Vault index could not be opened. Check available storage, then try again.") { [weak self] in
                self?.searchFacade = nil
                self?.updateReadyContent()
            }
            return false
        }
    }

    /// `recent`, `groups`, and `queryGroups` are synchronous SQLite reads on
    /// the index's serial queue. Running all three from `viewWillAppear`
    /// blocked main for a bulk import's whole in-flight transaction; one
    /// `Task.detached` hop, mirroring the search debounce below, moves them
    /// off main while keeping each section's own error handling and message.
    private func updateReadyContent() {
        guard ensureSearchFacade(), let facade = searchFacade else { return }
        // A previous provider/runtime failure may have left the status panel
        // visible. A newly-ready runtime must clear that stale state before
        // rendering its content; the failure branch below restores it for
        // index errors.
        hideContentStatus()
        let query = normalizedQuery
        contentLoadGeneration += 1
        let generation = contentLoadGeneration
        Task { [weak self] in
            let snapshot = await Task.detached(priority: .userInitiated) {
                (recents: Result { try facade.recent(limit: 12) },
                 groups: Result { try facade.index.groups() },
                 queries: Result { try facade.index.queryGroups(limit: 100) })
            }.value
            guard let self, generation == self.contentLoadGeneration else { return }
            switch snapshot.recents {
            case .success(let recents):
                self.renderRecents(recents)
            case .failure:
                self.showContentStatus("The Vault index could not be read. Try opening it again.") { [weak self] in
                    self?.searchFacade = nil
                    self?.updateReadyContent()
                }
                return
            }
            if case .success(let semantic) = snapshot.groups, case .success(let queries) = snapshot.queries {
                self.renderGroups(semantic: semantic, queries: queries)
            } else {
                self.showGroupsUnavailable()
            }
            if query.isEmpty { self.renderResults([]) }
            else { self.scheduleSearch(debounceNanoseconds: 0) }
        }
    }

    private var normalizedQuery: String {
        (searchField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func scheduleSearch(debounceNanoseconds: UInt64) {
        searchGeneration += 1
        let generation = searchGeneration
        searchTask?.cancel()
        let query = normalizedQuery
        guard !query.isEmpty else { renderResults([]); return }
        guard ensureSearchFacade(), let facade = searchFacade else { return }
        searchTask = Task { [weak self, facade] in
            if debounceNanoseconds > 0 {
                do { try await Task.sleep(nanoseconds: debounceNanoseconds) }
                catch { return }
            }
            guard !Task.isCancelled else { return }
            let hits = await Task.detached(priority: .userInitiated) {
                try? facade.search(query, limit: 30)
            }.value
            guard !Task.isCancelled, let self, generation == self.searchGeneration else { return }
            if let hits {
                // A search completing must not clear a status panel a
                // sibling section (groups) put up moments earlier; it may
                // only clear its own.
                self.hideContentStatus(unlessShownFor: [.groups])
                self.renderResults(hits)
            } else {
                self.showContentStatus("Search is unavailable. Try again.", origin: .search) { [weak self] in
                    self?.scheduleSearch(debounceNanoseconds: 0)
                }
            }
        }
    }

    private func renderRecents(_ hits: [VaultSearchHit]) {
        removeArrangedSubviews(from: recentStack)
        if hits.isEmpty { recentStack.addArrangedSubview(emptyLabel("No recent files yet")); return }
        for hit in hits {
            let button = UIButton(type: .system)
            button.contentHorizontalAlignment = .left
            button.titleLabel?.numberOfLines = 2
            button.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
            button.setTitle("  \(hit.filename)\n  \(hit.snippet)", for: .normal)
            button.backgroundColor = .secondarySystemBackground
            button.layer.cornerRadius = 14
            button.accessibilityIdentifier = "vault.recent.\(hit.canonicalObjectID.rawValue.uuidString)"
            button.accessibilityLabel = "\(hit.filename). \(hit.snippet)"
            button.accessibilityHint = "Open recent Vault item"
            button.addAction(UIAction { [weak self] _ in self?.openCanonicalObject(hit.canonicalObjectID) }, for: .touchUpInside)
            button.widthAnchor.constraint(equalToConstant: 190).isActive = true
            button.heightAnchor.constraint(equalToConstant: 84).isActive = true
            recentStack.addArrangedSubview(button)
        }
    }

    /// Loads on main. Reserved for the one-off callers that already just
    /// wrote to the index (`createManualGroup`, `createQueryGroup`,
    /// `addMembership`) and need to reflect that write immediately;
    /// `updateReadyContent()` instead loads off main and calls
    /// `renderGroups(semantic:queries:)` directly with the result.
    private func renderGroups() {
        guard let index = searchFacade?.index else {
            removeArrangedSubviews(from: groupsStack)
            return
        }
        do {
            renderGroups(semantic: try index.groups(), queries: try index.queryGroups(limit: 100))
        } catch {
            showGroupsUnavailable()
        }
    }

    private func renderGroups(semantic: [VaultGroup], queries: [VaultQueryGroup]) {
        removeArrangedSubviews(from: groupsStack)
        if semantic.isEmpty && queries.isEmpty {
            groupsStack.addArrangedSubview(emptyLabel("Groups keep related files together."))
        }
        for group in semantic {
            let button = UIButton(type: .system)
            button.contentHorizontalAlignment = .left
            button.setTitle("\(group.label)  ·  \(group.memberIDs.count) files", for: .normal)
            button.accessibilityIdentifier = "vault.group.\(group.id.uuidString)"
            button.accessibilityLabel = "Group \(group.label), \(group.memberIDs.count) files"
            button.addAction(UIAction { [weak self] _ in self?.showGroup(group) }, for: .touchUpInside)
            groupsStack.addArrangedSubview(button)
        }
        for group in queries {
            let button = UIButton(type: .system)
            button.contentHorizontalAlignment = .left
            button.setTitle("Search: \(group.query)  ·  \(group.memberIDs.count) files", for: .normal)
            button.accessibilityIdentifier = "vault.query-group.\(group.id.uuidString)"
            button.accessibilityLabel = "Query group \(group.query), \(group.memberIDs.count) files"
            button.addAction(UIAction { [weak self] _ in self?.showQueryGroup(group) }, for: .touchUpInside)
            groupsStack.addArrangedSubview(button)
        }
    }

    private func showGroupsUnavailable() {
        removeArrangedSubviews(from: groupsStack)
        groupsStack.addArrangedSubview(emptyLabel("Groups are unavailable."))
        showContentStatus("Groups could not be loaded. Try reopening the index.", origin: .groups) { [weak self] in
            self?.searchFacade = nil
            self?.updateReadyContent()
        }
    }

    private func renderResults(_ hits: [VaultSearchHit]) {
        removeArrangedSubviews(from: resultsStack)
        if hits.isEmpty { resultsStack.addArrangedSubview(emptyLabel("Search by name or extracted text")); return }
        for hit in hits {
            let row = UIStackView()
            row.axis = .vertical
            row.spacing = 7
            row.isLayoutMarginsRelativeArrangement = true
            row.layoutMargins = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
            row.backgroundColor = .secondarySystemBackground
            row.layer.cornerRadius = 12
            let title = labeledText(hit.filename, style: .headline)
            let detail = labeledText(hit.snippet, style: .body)
            detail.textColor = .secondaryLabel
            let provenance = hit.isSymbolicAlias ? "Group alias · " : ""
            let fields = labeledText(provenance + hit.matchedFields.joined(separator: ", "), style: .caption1)
            fields.textColor = .tertiaryLabel
            let open = UIButton(type: .system)
            open.setTitle("Open", for: .normal)
            open.contentHorizontalAlignment = .leading
            open.accessibilityIdentifier = "vault.result.open.\(hit.canonicalObjectID.rawValue.uuidString)"
            open.accessibilityLabel = "Open \(hit.filename)"
            open.addAction(UIAction { [weak self] _ in self?.openCanonicalObject(hit.canonicalObjectID) }, for: .touchUpInside)
            let add = UIButton(type: .system)
            add.setTitle("Add to group", for: .normal)
            add.contentHorizontalAlignment = .leading
            add.accessibilityIdentifier = "vault.result.add-to-group.\(hit.canonicalObjectID.rawValue.uuidString)"
            add.accessibilityLabel = "Add \(hit.filename) to a group"
            add.addAction(UIAction { [weak self] _ in self?.showAddToGroup(for: hit.canonicalObjectID) }, for: .touchUpInside)
            [title, detail, fields, open, add].forEach(row.addArrangedSubview)
            row.accessibilityIdentifier = "vault.result.\(hit.canonicalObjectID.rawValue.uuidString)"
            resultsStack.addArrangedSubview(row)
        }
    }

    private func showGroup(_ group: VaultGroup) {
        showInfo(title: group.label,
            message: "\(group.memberIDs.count) files · \(group.frozen ? "Manual" : "Semantic") group")
    }

    private func showQueryGroup(_ group: VaultQueryGroup) {
        showInfo(title: group.query,
            message: "\(group.memberIDs.count) files · \(group.live ? "Live" : "Snapshot") query group")
    }

    private func showInfo(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Done", style: .default))
        present(alert, animated: true)
    }

    @objc private func newGroupTapped() {
        let sheet = UIAlertController(title: "New group", message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Manual group", style: .default) { [weak self] _ in
            self?.promptForGroup { [weak self] label in self?.createManualGroup(label: label, members: []) }
        })
        sheet.addAction(UIAlertAction(title: "Query group", style: .default) { [weak self] _ in self?.promptForQueryGroup() })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        configurePopover(sheet)
        present(sheet, animated: true)
    }

    private func showAddToGroup(for objectID: VaultObjectID) {
        do {
            guard let groups = try searchFacade?.index.groups(), !groups.isEmpty else {
                showContentStatus("Create a semantic or manual group before adding files.")
                return
            }
            let sheet = UIAlertController(title: "Add to group", message: nil, preferredStyle: .actionSheet)
            for group in groups {
                sheet.addAction(UIAlertAction(title: group.label, style: .default) { [weak self] _ in
                    self?.addMembership(objectID: objectID, to: group.id)
                })
            }
            sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            configurePopover(sheet)
            present(sheet, animated: true)
        } catch {
            showContentStatus("Groups could not be loaded. Try reopening the index.") { [weak self] in
                self?.searchFacade = nil; self?.updateReadyContent()
            }
        }
    }

    private func promptForQueryGroup() {
        let alert = UIAlertController(title: "New query group",
            message: "Files matching this query are saved as the group's initial membership.", preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "Search query"
            field.accessibilityIdentifier = "vault.group.query"
            field.accessibilityLabel = "Query group search"
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Create", style: .default) { [weak self, weak alert] _ in
            guard let self,
                  let query = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !query.isEmpty, let facade = self.searchFacade else { return }
            do {
                let members = try facade.search(query, limit: 30).map(\.canonicalObjectID)
                self.createQueryGroup(query: query, members: members)
            } catch { self.showContentStatus("The query group could not be created. Try again.") }
        })
        present(alert, animated: true)
    }

    public func createManualGroup(label: String, members: [VaultObjectID] = []) {
        do {
            if let onCreateManualGroup { try onCreateManualGroup(label, members) }
            else if let index = searchFacade?.index { _ = try index.createGroup(label: label, members: members) }
            else { throw VaultSearchError.sqlite("Index unavailable") }
            renderGroups()
        } catch { showContentStatus("The manual group could not be created. Try again.") }
    }

    public func createQueryGroup(query: String, members: [VaultObjectID] = []) {
        do {
            if let onCreateQueryGroup { try onCreateQueryGroup(query, members) }
            else if let index = searchFacade?.index { _ = try index.createQueryGroup(query: query, members: members) }
            else { throw VaultSearchError.sqlite("Index unavailable") }
            renderGroups()
        } catch { showContentStatus("The query group could not be created. Try again.") }
    }

    public func addMembership(objectID: VaultObjectID, to groupID: UUID) {
        do {
            guard let index = searchFacade?.index else { throw VaultSearchError.sqlite("Index unavailable") }
            let modelVersion: String
            if let membershipModelVersionProvider { modelVersion = try membershipModelVersionProvider() }
            else if let indexedVersion = try index.modelVersions(limit: 1).first { modelVersion = indexedVersion }
            else { throw VaultSearchError.mixedModelSpace }
            guard !modelVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw VaultSearchError.mixedModelSpace
            }
            if let onAddMembership { try onAddMembership(objectID, groupID, modelVersion) }
            else { _ = try index.addManualMembership(objectID: objectID, toGroup: groupID, modelVersion: modelVersion) }
            renderGroups()
        } catch {
            showContentStatus("This file could not be added. Its active index model is unavailable; rebuild the index and try again.")
        }
    }

    private func promptForGroup(completion: @escaping (String) -> Void) {
        let alert = UIAlertController(title: "New group", message: nil, preferredStyle: .alert)
        alert.addTextField {
            $0.placeholder = "Group name"
            $0.accessibilityLabel = "Group name"
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Create", style: .default) { [weak alert] _ in
            guard let value = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return }
            completion(value)
        })
        present(alert, animated: true)
    }

    private func showContentStatus(_ text: String, origin: ContentStatusOrigin = .other,
                                   retry: (() -> Void)? = nil) {
        contentStatusLabel.text = text
        contentStatusLabel.accessibilityLabel = text
        contentRetryAction = retry
        contentRetryButton.isHidden = retry == nil
        contentStatusPanel.isHidden = false
        contentStatusOrigin = origin
    }

    /// Clears the shared status panel, unless it is currently showing a
    /// status raised by one of `protectedOrigins` — a section's own
    /// completion (for example, search finishing) must not silently erase a
    /// sibling section's still-relevant error (for example, groups failing
    /// to load).
    private func hideContentStatus(unlessShownFor protectedOrigins: Set<ContentStatusOrigin> = []) {
        guard contentStatusPanel.isHidden || !protectedOrigins.contains(contentStatusOrigin) else { return }
        contentStatusPanel.isHidden = true
        contentRetryAction = nil
        contentStatusOrigin = .other
    }

    private func focusSearchIfReady() {
        guard !didAutofocus, !contentScroll.isHidden,
              setupCoordinator?.state.policy != nil || services?.isReady == true else { return }
        didAutofocus = true
        DispatchQueue.main.async { [weak self] in self?.searchField.becomeFirstResponder() }
    }

    private func makeMacCredentialStore() -> VaultMacKeychainCredentialStore? {
        guard let accessGroup = Bundle.main.object(forInfoDictionaryKey: "LunaVaultKeychainAccessGroup") as? String,
              !accessGroup.isEmpty else { return nil }
        return VaultMacKeychainCredentialStore(accessGroup: accessGroup,
            service: "\(Bundle.main.bundleIdentifier ?? "com.hsanabria.luna.vault").mac-pairing")
    }

    private func setupMessage(_ reason: VaultSetupUnavailableReason) -> String {
        switch reason {
        case .keychainUnavailable: return "Vault Keychain access is unavailable. Unlock this iPhone and try again."
        case .storageUnavailable: return "Vault storage is unavailable. Check device storage and try again."
        case .iCloudUnavailable: return "iCloud is unavailable. Check your Apple ID and iCloud Drive, then try again."
        case .macNotPaired: return "Your Mac is not paired. Pair it in Settings, then try again."
        }
    }

    private func storageLocationIndex(_ location: VaultStorageLocation) -> Int {
        switch location {
        case .device: return 0
        case .iCloud: return 1
        case .mac: return 2
        }
    }

    private func openCanonicalObject(_ objectID: VaultObjectID) {
        openHandler?(objectID)
    }

    private func emptyLabel(_ text: String) -> UILabel {
        let label = labeledText(text, style: .body)
        label.textColor = .secondaryLabel
        label.accessibilityLabel = text
        return label
    }

    private func labeledText(_ text: String, style: UIFont.TextStyle) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: style)
        label.numberOfLines = 0
        label.accessibilityLabel = text
        return label
    }

    private func removeArrangedSubviews(from stack: UIStackView) {
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
    }

    private func configurePopover(_ alert: UIAlertController) {
        if let popover = alert.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.safeAreaInsets.top + 44, width: 1, height: 1)
        }
    }
}

extension VaultRootViewController: UITextFieldDelegate {
    public func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        scheduleSearch(debounceNanoseconds: 0)
        textField.resignFirstResponder()
        return true
    }
}

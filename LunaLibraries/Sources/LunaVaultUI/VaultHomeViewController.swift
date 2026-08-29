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
    public static let recents = "vault.recents"
    public static let groups = "vault.groups"
    public static let results = "vault.results"
    public static let setup = "vault.setup"
    public static let setupPolicy = "vault.setup.policy"
    public static let setupContinue = "vault.setup.continue"
    public static let settings = "vault.settings"
    public static let macPairing = "vault.settings.mac"
}

/// Search-first Vault home. File import, extraction, rendering and backend
/// transport remain callbacks; this controller only presents indexed results.
public final class VaultRootViewController: UIViewController {
    private var services: VaultRuntimeServices?
    private let setupCoordinator: VaultSetupCoordinator?
    private var searchFacade: VaultSearchPresentationFacade?
    private let searchIndexProvider: (() -> VaultSearchIndex?)?
    private let servicesProvider: (() -> VaultRuntimeServices?)?
    private let importHandler: (() -> Void)?

    private let searchField = UITextField()
    private let statusLabel = UILabel()
    private let setupPanel = UIStackView()
    private let recentScroll = UIScrollView()
    private let recentStack = UIStackView()
    private let groupsStack = UIStackView()
    private let resultsStack = UIStackView()
    private let contentStack = UIStackView()
    private let policyControl = UISegmentedControl(items: ["iPhone", "iCloud", "Mac"])
    private let setupButton = UIButton(type: .system)
    private var didAutofocus = false
    private var setupPolicy = VaultStoragePolicy(location: .device)

    public var onCreateManualGroup: ((String, [VaultObjectID]) -> Void)?
    public var onCreateQueryGroup: ((String, [VaultObjectID]) -> Void)?
    public var onAddMembership: ((VaultObjectID, UUID) -> Void)?

    public init(services: VaultRuntimeServices? = nil,
                setupCoordinator: VaultSetupCoordinator? = nil,
                searchIndex: VaultSearchIndex? = nil,
                searchIndexProvider: (() -> VaultSearchIndex?)? = nil,
                servicesProvider: (() -> VaultRuntimeServices?)? = nil,
                importHandler: (() -> Void)? = nil) {
        self.services = services
        self.setupCoordinator = setupCoordinator
        self.searchFacade = searchIndex.map { VaultSearchPresentationFacade(index: $0) }
        self.searchIndexProvider = searchIndexProvider
        self.servicesProvider = servicesProvider
        self.importHandler = importHandler
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "Luna Vault"
        let settings = UIBarButtonItem(image: UIImage(systemName: "gearshape"), style: .plain,
                                       target: self, action: #selector(settingsTapped))
        settings.accessibilityIdentifier = VaultAccessibilityID.settings
        let importing = UIBarButtonItem(image: UIImage(systemName: "square.and.arrow.down"), style: .plain,
                                        target: self, action: #selector(importTapped))
        importing.accessibilityIdentifier = VaultAccessibilityID.importButton
        navigationItem.rightBarButtonItems = [settings, importing]

        configureSearchField()
        configureSetupPanel()
        configureContent()
        renderState()
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated); renderState()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated); focusSearchIfReady()
    }

    @objc private func importTapped() { importHandler?() }
    @objc private func settingsTapped() {
        navigationController?.pushViewController(VaultSettingsViewController(setupCoordinator: setupCoordinator), animated: true)
    }

    private func configureSearchField() {
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholder = "Search your vault"
        searchField.accessibilityLabel = "Vault search"
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

    private func configureSetupPanel() {
        setupPanel.axis = .vertical; setupPanel.spacing = 14; setupPanel.alignment = .fill
        setupPanel.isLayoutMarginsRelativeArrangement = true
        setupPanel.layoutMargins = UIEdgeInsets(top: 22, left: 22, bottom: 22, right: 22)
        setupPanel.backgroundColor = .secondarySystemBackground; setupPanel.layer.cornerRadius = 16
        setupPanel.accessibilityIdentifier = VaultAccessibilityID.setup
        let heading = UILabel(); heading.text = "Set up your encrypted Vault"; heading.font = .preferredFont(forTextStyle: .headline)
        let detail = UILabel(); detail.text = "Choose where the encrypted working copy lives. You can change this later in Settings."; detail.numberOfLines = 0; detail.textColor = .secondaryLabel
        policyControl.accessibilityLabel = "Vault storage location"; policyControl.accessibilityIdentifier = VaultAccessibilityID.setupPolicy
        policyControl.addTarget(self, action: #selector(policyChanged), for: .valueChanged)
        setupButton.setTitle("Create Vault", for: .normal); setupButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        setupButton.accessibilityIdentifier = VaultAccessibilityID.setupContinue; setupButton.addTarget(self, action: #selector(completeSetup), for: .touchUpInside)
        [heading, detail, policyControl, setupButton].forEach(setupPanel.addArrangedSubview)
        setupPanel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(setupPanel)
        NSLayoutConstraint.activate([
            setupPanel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            setupPanel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            setupPanel.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 18),
        ])
    }

    private func configureContent() {
        contentStack.axis = .vertical; contentStack.spacing = 22; contentStack.alignment = .fill; contentStack.translatesAutoresizingMaskIntoConstraints = false
        recentStack.axis = .horizontal; recentStack.spacing = 10
        recentScroll.showsHorizontalScrollIndicator = false; recentScroll.accessibilityIdentifier = VaultAccessibilityID.recents
        recentScroll.addSubview(recentStack); recentStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            recentStack.leadingAnchor.constraint(equalTo: recentScroll.contentLayoutGuide.leadingAnchor), recentStack.trailingAnchor.constraint(equalTo: recentScroll.contentLayoutGuide.trailingAnchor),
            recentStack.topAnchor.constraint(equalTo: recentScroll.contentLayoutGuide.topAnchor), recentStack.bottomAnchor.constraint(equalTo: recentScroll.contentLayoutGuide.bottomAnchor), recentStack.heightAnchor.constraint(equalToConstant: 84),
        ])
        groupsStack.axis = .vertical; groupsStack.spacing = 8; groupsStack.accessibilityIdentifier = VaultAccessibilityID.groups
        resultsStack.axis = .vertical; resultsStack.spacing = 8; resultsStack.accessibilityIdentifier = VaultAccessibilityID.results
        let scroll = UIScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false; scroll.alwaysBounceVertical = true; scroll.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20), contentStack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
            contentStack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor), contentStack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -28), contentStack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40),
            recentScroll.heightAnchor.constraint(equalToConstant: 84),
        ])
        contentStack.addArrangedSubview(statusLabel)
        contentStack.addArrangedSubview(sectionHeader("Recent")); contentStack.addArrangedSubview(recentScroll)
        contentStack.addArrangedSubview(sectionHeader("Groups", action: #selector(newManualGroupTapped))); contentStack.addArrangedSubview(groupsStack)
        contentStack.addArrangedSubview(sectionHeader("Results")); contentStack.addArrangedSubview(resultsStack)
        view.addSubview(scroll)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor), scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 18), scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
    }

    private func sectionHeader(_ text: String, action: Selector? = nil) -> UIView {
        let row = UIStackView(); row.axis = .horizontal; row.alignment = .center
        let label = UILabel(); label.text = text; label.font = .preferredFont(forTextStyle: .title3); row.addArrangedSubview(label); row.addArrangedSubview(UIView())
        if let action { let button = UIButton(type: .system); button.setTitle("New", for: .normal); button.addTarget(self, action: action, for: .touchUpInside); row.addArrangedSubview(button) }
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
            if searchFacade == nil, let index = searchIndexProvider?() { searchFacade = VaultSearchPresentationFacade(index: index) }
        }
        renderState(); focusSearchIfReady()
    }

    @objc private func retrySetup() { _ = setupCoordinator?.load(); renderState() }
    @objc private func queryChanged() { reloadResults() }

    private func renderState() {
        let state = setupCoordinator?.state
        let firstRun = state.map { if case .firstRun = $0 { return true }; return false } ?? false
        setupPanel.isHidden = !firstRun; contentStack.isHidden = firstRun
        if firstRun { statusLabel.isHidden = true; return }
        guard let state else { updateReadyContent(); return }
        switch state {
        case .firstRun: break
        case .ready(let policy):
            setupPolicy = policy; updateReadyContent()
            if services?.isReady != true {
                statusLabel.isHidden = false
                statusLabel.text = policy.location == .iCloud ? "iCloud is unavailable. Check your Apple ID and iCloud Drive." : policy.location == .mac ? "Pair your Mac in Settings to use Mac storage." : "Vault storage needs attention."
            } else { statusLabel.isHidden = true }
        case .unavailable(let reason): showStatus(setupMessage(reason), retry: true)
        case .error(let failure): showStatus("Vault setup could not finish (\(failure)). Try again.", retry: true)
        }
    }

    private func updateReadyContent() {
        guard let facade = searchFacade else { return }
        do { renderRecents(try facade.recent(limit: 12)); renderGroups(); if (searchField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { renderResults([]) } else { reloadResults() } }
        catch { showStatus("Vault index is unavailable. Try again later.", retry: false) }
    }

    private func reloadResults() {
        guard let facade = searchFacade, let text = searchField.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { renderResults([]); return }
        do { renderResults(try facade.search(text, limit: 30)) }
        catch { showStatus("Search is unavailable. Try again later.", retry: false) }
    }

    private func renderRecents(_ hits: [VaultSearchHit]) {
        recentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if hits.isEmpty { recentStack.addArrangedSubview(emptyLabel("No recent files yet")); return }
        for hit in hits {
            let button = UIButton(type: .system); button.contentHorizontalAlignment = .left; button.titleLabel?.numberOfLines = 2; button.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
            button.setTitle("  \(hit.filename)\n  \(hit.snippet)", for: .normal); button.backgroundColor = .secondarySystemBackground; button.layer.cornerRadius = 14; button.accessibilityLabel = hit.filename; button.accessibilityHint = "Open recent Vault item"; button.widthAnchor.constraint(equalToConstant: 190).isActive = true; button.heightAnchor.constraint(equalToConstant: 84).isActive = true; recentStack.addArrangedSubview(button)
        }
    }

    private func renderGroups() {
        groupsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let index = searchFacade?.index else { return }
        do {
            let groups = try index.groups(); if groups.isEmpty { groupsStack.addArrangedSubview(emptyLabel("Groups keep related files together.")) }
            for group in groups {
                let button = UIButton(type: .system); button.contentHorizontalAlignment = .left; button.setTitle("\(group.label)  ·  \(group.memberIDs.count) files", for: .normal); button.accessibilityLabel = "Group \(group.label)"; button.addAction(UIAction { [weak self] _ in self?.showGroup(group) }, for: .touchUpInside); groupsStack.addArrangedSubview(button)
            }
        } catch { groupsStack.addArrangedSubview(emptyLabel("Groups are unavailable.")) }
    }

    private func renderResults(_ hits: [VaultSearchHit]) {
        resultsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if hits.isEmpty { resultsStack.addArrangedSubview(emptyLabel("Search by name or extracted text")); return }
        for hit in hits {
            let row = UIStackView(); row.axis = .vertical; row.spacing = 3; row.isLayoutMarginsRelativeArrangement = true; row.layoutMargins = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12); row.backgroundColor = .secondarySystemBackground; row.layer.cornerRadius = 12
            let title = UILabel(); title.text = hit.filename; title.font = .preferredFont(forTextStyle: .headline)
            let detail = UILabel(); detail.text = hit.snippet; detail.numberOfLines = 2; detail.textColor = .secondaryLabel
            let fields = UILabel(); fields.text = hit.isSymbolicAlias ? "Group alias · \(hit.matchedFields.joined(separator: ", "))" : hit.matchedFields.joined(separator: ", "); fields.font = .preferredFont(forTextStyle: .caption1); fields.textColor = .tertiaryLabel
            [title, detail, fields].forEach(row.addArrangedSubview); row.accessibilityIdentifier = "vault.result.\(hit.canonicalObjectID.rawValue.uuidString)"; resultsStack.addArrangedSubview(row)
        }
    }

    private func showGroup(_ group: VaultGroup) { let alert = UIAlertController(title: group.label, message: "\(group.memberIDs.count) files · \(group.frozen ? "Manual" : "Live") group", preferredStyle: .alert); alert.addAction(UIAlertAction(title: "Done", style: .default)); present(alert, animated: true) }
    @objc private func newManualGroupTapped() { promptForGroup { [weak self] label in self?.createManualGroup(label: label, members: []) } }

    public func createManualGroup(label: String, members: [VaultObjectID] = []) { if let onCreateManualGroup { onCreateManualGroup(label, members) } else { _ = try? searchFacade?.index.createGroup(label: label, members: members) }; renderGroups() }
    public func createQueryGroup(query: String, members: [VaultObjectID] = []) { if let onCreateQueryGroup { onCreateQueryGroup(query, members) } else { _ = try? searchFacade?.index.createQueryGroup(query: query, members: members) }; renderGroups() }
    public func addMembership(objectID: VaultObjectID, to groupID: UUID) { onAddMembership?(objectID, groupID) }

    private func promptForGroup(completion: @escaping (String) -> Void) { let alert = UIAlertController(title: "New group", message: nil, preferredStyle: .alert); alert.addTextField { $0.placeholder = "Group name" }; alert.addAction(UIAlertAction(title: "Cancel", style: .cancel)); alert.addAction(UIAlertAction(title: "Create", style: .default) { _ in guard let value = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }; completion(value) }); present(alert, animated: true) }
    private func focusSearchIfReady() { guard !didAutofocus, setupCoordinator?.state.policy != nil else { return }; didAutofocus = true; DispatchQueue.main.async { [weak self] in self?.searchField.becomeFirstResponder() } }
    private func showStatus(_ text: String, retry: Bool) { statusLabel.text = text; statusLabel.textColor = .secondaryLabel; statusLabel.numberOfLines = 0; statusLabel.textAlignment = .center; statusLabel.isHidden = false; if retry { setupButton.setTitle("Try again", for: .normal); setupButton.removeTarget(nil, action: nil, for: .allEvents); setupButton.addTarget(self, action: #selector(retrySetup), for: .touchUpInside) } }
    private func setupMessage(_ reason: VaultSetupUnavailableReason) -> String { switch reason { case .keychainUnavailable: return "Vault Keychain access is unavailable. Unlock this iPhone and try again."; case .storageUnavailable: return "Vault storage is unavailable. Check device storage and try again."; case .iCloudUnavailable: return "iCloud is unavailable. Check your Apple ID and iCloud Drive."; case .macNotPaired: return "Your Mac is not paired yet. Pair it from Settings." } }
    private func emptyLabel(_ text: String) -> UILabel { let label = UILabel(); label.text = text; label.textColor = .secondaryLabel; label.numberOfLines = 0; return label }
}

extension VaultRootViewController: UITextFieldDelegate {
    public func textFieldShouldReturn(_ textField: UITextField) -> Bool { reloadResults(); textField.resignFirstResponder(); return true }
}

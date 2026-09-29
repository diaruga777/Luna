import UIKit
import LunaVaultStore

/// Connection setup and maintenance are distinct states, backed by the same verified runtime.
public final class VaultConnectedSettingsViewController: UITableViewController, UITextFieldDelegate {
    private let runtime: any VaultPresentationProviding
    private let pairingHandler: (String) async throws -> Void
    private let code = UITextField()
    private let connectButton = UIButton(type: .system)
    private var snapshot: VaultPairingSnapshot?
    private var connection: VaultConnectionStatus = .notPaired
    private var cache: VaultCachePresentation?
    private var imageFormat: VaultPhotoImageFormat = .jpeg
    private var videoFormat: VaultPhotoVideoFormat = .mp4
    private var message: String?
    private var messageIsError = false
    private var operation: Task<Void, Never>?
    private var loading = true
    private var needsNetworkSettings = false
    private var wantsPairing = false
    private var isPaired: Bool { snapshot?.isPaired == true && !wantsPairing }

    public convenience init(runtime: VaultConnectedRuntime, prefilledCode: String? = nil) {
        self.init(services: runtime, prefilledCode: prefilledCode, pairingHandler: { try await runtime.pair(code: $0) })
    }
    public init(services: any VaultPresentationProviding, prefilledCode: String? = nil,
                pairingHandler: @escaping (String) async throws -> Void) {
        self.runtime = services
        self.pairingHandler = pairingHandler
        super.init(style: .insetGrouped)
        code.text = prefilledCode
        wantsPairing = prefilledCode != nil
    }
    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        navigationItem.largeTitleDisplayMode = .never
        tableView.keyboardDismissMode = .interactive
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 56
        tableView.accessibilityIdentifier = "vault.settings.list"
        code.placeholder = "Paste pairing code"
        code.font = .preferredFont(forTextStyle: .body)
        code.adjustsFontForContentSizeCategory = true
        code.autocapitalizationType = .none
        code.autocorrectionType = .no
        code.spellCheckingType = .no
        code.clearButtonMode = .whileEditing
        code.returnKeyType = .go
        code.enablesReturnKeyAutomatically = true
        code.delegate = self
        code.accessibilityIdentifier = "vault.mac.pairing-code"
        code.accessibilityLabel = "Mac pairing code"
        code.addTarget(self, action: #selector(codeChanged), for: .editingChanged)
        let toolbar = UIToolbar(); toolbar.sizeToFit()
        toolbar.items = [UIBarButtonItem(systemItem: .flexibleSpace),
                         UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(dismissKeyboard))]
        code.inputAccessoryView = toolbar
        Task { [weak self] in await self?.loadStatus() }
    }
    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let header = tableView.tableHeaderView else { return }
        let size = header.systemLayoutSizeFitting(CGSize(width: tableView.bounds.width, height: 0),
                                                  withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        if abs(header.frame.height - size.height) > 1 {
            header.frame.size = CGSize(width: tableView.bounds.width, height: size.height)
            tableView.tableHeaderView = header
        }
    }
    private func loadStatus() async {
        do {
            snapshot = try await runtime.pairingSnapshot()
            connection = await runtime.connectionStatus()
            cache = try await runtime.cachePresentation()
            (imageFormat, videoFormat) = try await runtime.photoExportFormats()
        } catch { message = "Couldn’t load settings. Try reopening this screen."; messageIsError = true }
        loading = false
        render()
    }
    private func render() {
        title = isPaired ? "Settings" : "Connect Mac"
        code.isEnabled = operation == nil
        tableView.tableHeaderView = isPaired || loading ? nil : setupHeader()
        tableView.reloadData()
        view.setNeedsLayout()
    }
    private func setupHeader() -> UIView {
        let symbol = UIImageView(image: UIImage(systemName: "laptopcomputer.and.iphone"))
        symbol.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 52, weight: .light)
        symbol.tintColor = .tintColor
        symbol.contentMode = .scaleAspectFit
        symbol.isAccessibilityElement = false
        let title = label("A place for everything.", style: .title2, color: .label)
        title.font = .preferredFont(forTextStyle: .title2).withTraits(.traitBold)
        title.textAlignment = .center
        let subtitle = label("Your Mac keeps your files. Vault brings them with you.", style: .body, color: .secondaryLabel)
        subtitle.textAlignment = .center
        let intro = UIStackView(arrangedSubviews: [symbol, title, subtitle]); intro.axis = .vertical; intro.spacing = 12
        let steps = UIStackView(arrangedSubviews: [
            step("1", "Open Luna Vault on your Mac.", "Keep both devices on the same network."),
            step("2", "Copy the pairing code.", "Paste it below to connect this iPhone."),
            step("3", "Approve on your Mac.", "Browse your Mac read only. The Vault folder supports search and uploads.")
        ]); steps.axis = .vertical; steps.spacing = 20
        let stack = UIStackView(arrangedSubviews: [intro, steps]); stack.axis = .vertical; stack.spacing = 30
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = UIView(); container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
        ])
        return container
    }
    private func step(_ number: String, _ title: String, _ subtitle: String) -> UIView {
        let badge = label(number, style: .headline, color: .tintColor)
        badge.textAlignment = .center
        badge.widthAnchor.constraint(equalToConstant: 28).isActive = true
        let texts = UIStackView(arrangedSubviews: [label(title, style: .body, color: .label), label(subtitle, style: .subheadline, color: .secondaryLabel)])
        texts.axis = .vertical; texts.spacing = 3
        let row = UIStackView(arrangedSubviews: [badge, texts]); row.spacing = 12; row.alignment = .top
        row.isAccessibilityElement = true; row.accessibilityLabel = "Step \(number). \(title) \(subtitle)"
        return row
    }
    private func label(_ text: String, style: UIFont.TextStyle, color: UIColor) -> UILabel {
        let label = UILabel(); label.text = text; label.font = .preferredFont(forTextStyle: style)
        label.adjustsFontForContentSizeCategory = true; label.numberOfLines = 0; label.textColor = color
        return label
    }
    public func textFieldShouldReturn(_ textField: UITextField) -> Bool { pair(); return true }
    @objc private func dismissKeyboard() { view.endEditing(true) }
    @objc private func codeChanged() {
        guard !isPaired, let cell = tableView.cellForRow(at: IndexPath(row: 1, section: 0)) else { return }
        configurePairCell(cell)
    }
    public override func numberOfSections(in tableView: UITableView) -> Int { loading ? 0 : (isPaired ? 5 : (needsNetworkSettings ? 2 : 1)) }
    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if !isPaired { return section == 0 ? 2 : 1 }
        return section == 0 ? 3 : (section == 1 || section == 3 ? 2 : 1)
    }
    public override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if !isPaired { return section == 0 ? "Pairing Code" : nil }
        return ["Connection", "On This iPhone", "Search", "Photos Export", ""][section]
    }
    public override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if !isPaired { return section == 0 ? (message ?? "Transfers are encrypted between this iPhone and your paired Mac.") : "Enable Local Network access for Vault, then try again." }
        switch section {
        case 0: return message ?? (connection == .offline ? "Keep Luna Vault open on your Mac to connect. Downloaded files are still available offline." : "Files download when you open them.")
        case 1: return "Removing downloads frees space on this iPhone. Files on your Mac and pending uploads are kept."
        case 2: return "Search finds file names and text in downloaded files. Rebuild only if results seem incomplete."
        case 3: return "Choose the formats used when importing from Photos into Vault. Original keeps the library file unchanged."
        default: return nil
        }
    }
    public override func tableView(_ tableView: UITableView, willDisplayFooterView view: UIView, forSection section: Int) {
        guard section == 0, let footer = view as? UITableViewHeaderFooterView else { return }
        footer.textLabel?.textColor = messageIsError ? .systemRed : .secondaryLabel
        footer.accessibilityIdentifier = "vault.mac.status"
        if message != nil { footer.accessibilityTraits.insert(.updatesFrequently) }
    }
    public override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.textProperties.numberOfLines = 0
        content.secondaryTextProperties.numberOfLines = 0
        content.imageProperties.tintColor = .tintColor
        if !isPaired {
            if indexPath.section == 1 {
                content.text = "Open iPhone Settings"; content.image = UIImage(systemName: "gearshape")
            } else if indexPath.row == 0 {
                cell.contentView.addSubview(code); code.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    code.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
                    code.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
                    code.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 14),
                    code.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -14)
                ])
                cell.selectionStyle = .none
                return cell
            } else { configurePairCell(cell); return cell }
        } else {
            switch (indexPath.section, indexPath.row) {
            case (0, 0):
                content.text = snapshot?.remoteName ?? "My Mac"
                content.secondaryText = connection == .syncing ? "Syncing files…" : connection.rawValue
                content.image = UIImage(systemName: "desktopcomputer")
                cell.selectionStyle = .none
            case (0, 1): content.text = "Reconnect"; content.image = UIImage(systemName: "arrow.clockwise")
            case (0, 2): content.text = "Update Connection"; content.image = UIImage(systemName: "link"); cell.accessoryType = .disclosureIndicator
            case (1, 0):
                content.text = "Downloaded Files"
                content.secondaryText = cache.map { "\($0.fileCount) files · \(ByteCountFormatter.string(fromByteCount: $0.usedBytes, countStyle: .file))" }
                content.image = UIImage(systemName: "internaldrive")
                cell.selectionStyle = .none
            case (1, 1): content.text = "Remove Downloads"; content.image = UIImage(systemName: "arrow.down.circle")
            case (2, _): content.text = "Rebuild Search Index"; content.image = UIImage(systemName: "magnifyingglass")
            case (3, 0):
                content.text = "Images"; content.secondaryText = imageFormat.title
                content.image = UIImage(systemName: "photo"); cell.accessoryType = .disclosureIndicator
            case (3, 1):
                content.text = "Videos"; content.secondaryText = videoFormat.title
                content.image = UIImage(systemName: "video"); cell.accessoryType = .disclosureIndicator
            default:
                content.text = "Disconnect Mac"; content.textProperties.color = .systemRed
                content.image = UIImage(systemName: "eject"); content.imageProperties.tintColor = .systemRed
            }
        }
        if cell.selectionStyle != .none {
            cell.isUserInteractionEnabled = operation == nil
            if operation != nil { content.textProperties.color = .tertiaryLabel }
        }
        cell.contentConfiguration = content
        cell.isAccessibilityElement = true
        cell.accessibilityLabel = [content.text, content.secondaryText].compactMap { $0 }.joined(separator: ", ")
        if cell.selectionStyle != .none { cell.accessibilityTraits = .button }
        return cell
    }
    private func configurePairCell(_ cell: UITableViewCell) {
        let enabled = operation == nil && !(code.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        var configuration: UIButton.Configuration
        if #available(iOS 26.0, *) { configuration = .prominentGlass() }
        else { configuration = .filled() }
        configuration.title = operation == nil ? "Connect Mac" : "Connecting…"
        configuration.cornerStyle = .capsule
        configuration.showsActivityIndicator = operation != nil
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20)
        connectButton.configuration = configuration
        connectButton.isEnabled = enabled
        connectButton.accessibilityIdentifier = "vault.mac.pair"
        connectButton.accessibilityHint = "Approve this iPhone in Luna Vault on your Mac"
        if connectButton.superview !== cell.contentView {
            connectButton.removeFromSuperview()
            connectButton.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(connectButton)
            connectButton.addAction(UIAction(identifier: .init("vault.connect")) { [weak self] _ in self?.pair() }, for: .primaryActionTriggered)
            NSLayoutConstraint.activate([
                connectButton.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
                connectButton.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
                connectButton.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 12),
                connectButton.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -12),
                connectButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
            ])
        }
        cell.selectionStyle = .none
        cell.backgroundConfiguration = .clear()
        cell.isAccessibilityElement = false
    }

    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard operation == nil else { return }
        if !isPaired {
            if indexPath.section == 1, let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            else if indexPath.row == 1 { pair() }
            return
        }
        switch (indexPath.section, indexPath.row) {
        case (0, 1): run(message: "Connecting…") { [runtime] in
            await runtime.refresh()
            return await runtime.connectionStatus() == .connected ? "Your Mac is connected." : "Your Mac is still offline. Keep Luna Vault open on your Mac and check your network."
        }
        case (0, 2):
            navigationController?.pushViewController(VaultConnectedSettingsViewController(
                services: runtime, prefilledCode: "", pairingHandler: pairingHandler), animated: true)
        case (1, 1):
            confirm(title: "Remove Downloaded Files?", message: "Files on your Mac and pending uploads will be kept. You’ll need a connection to download other files again.", action: "Remove Downloads") { [weak self] in
                guard let self else { return }
                run(message: "Removing downloads…") { [runtime] in try await runtime.clearCache(); return "Downloads removed." }
            }
        case (2, _): run(message: "Rebuilding search index…") { [runtime] in try await runtime.rebuildIndex(); return "Search index is up to date." }
        case (3, 0): chooseImageFormat(from: indexPath)
        case (3, 1): chooseVideoFormat(from: indexPath)
        case (4, _):
            confirm(title: "Disconnect Your Mac?", message: "Your Mac’s files will stay on your Mac. You’ll need its pairing code to connect again.", action: "Disconnect") { [weak self] in
                guard let self else { return }
                run(message: "Disconnecting…") { [runtime] in try await runtime.removePairing(); return "Mac disconnected." }
            }
        default: break
        }
    }
    private func chooseImageFormat(from indexPath: IndexPath) {
        let sheet = UIAlertController(title: "Image Export Format", message: nil, preferredStyle: .actionSheet)
        for format in VaultPhotoImageFormat.allCases {
            sheet.addAction(UIAlertAction(title: format.title, style: .default) { [weak self, runtime] _ in
                self?.run(message: "Saving image format…") {
                    try await runtime.setPhotoImageFormat(format)
                    return "Images will export as \(format.title)."
                }
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = tableView
        sheet.popoverPresentationController?.sourceRect = tableView.rectForRow(at: indexPath)
        present(sheet, animated: true)
    }
    private func chooseVideoFormat(from indexPath: IndexPath) {
        let sheet = UIAlertController(title: "Video Export Format", message: nil, preferredStyle: .actionSheet)
        for format in VaultPhotoVideoFormat.allCases {
            sheet.addAction(UIAlertAction(title: format.title, style: .default) { [weak self, runtime] _ in
                self?.run(message: "Saving video format…") {
                    try await runtime.setPhotoVideoFormat(format)
                    return "Videos will export as \(format.title)."
                }
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = tableView
        sheet.popoverPresentationController?.sourceRect = tableView.rectForRow(at: indexPath)
        present(sheet, animated: true)
    }
    private func confirm(title: String, message: String, action: String, handler: @escaping () -> Void) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: action, style: .destructive) { _ in handler() })
        present(alert, animated: true)
    }
    private func pair() {
        let input = (code.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard operation == nil, !input.isEmpty else { return }
        dismissKeyboard()
        run(message: "Allow Local Network access if asked, then approve this iPhone on your Mac.", returnToFiles: true) { [pairingHandler] in
            try await pairingHandler(input)
            return "Your Mac is connected. Your files are ready in Vault."
        }
    }
    private func run(message: String, returnToFiles: Bool = false, work: @escaping () async throws -> String) {
        guard operation == nil else { return }
        self.message = message; messageIsError = false; needsNetworkSettings = false
        operation = Task { [weak self] in
            do {
                let result = try await work()
                guard let self else { return }
                self.message = result
                if returnToFiles { wantsPairing = false }
                code.text = nil
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                guard let self else { return }
                self.message = error.localizedDescription
                messageIsError = true
                // Only offer network settings for permission failures, not invalid codes.
                let description = error.localizedDescription.lowercased()
                needsNetworkSettings = description.contains("local network") || description.contains("permission")
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            guard let self else { return }
            operation = nil
            await loadStatus()
            UIAccessibility.post(notification: .announcement, argument: self.message)
            if returnToFiles && !messageIsError { navigationController?.popToRootViewController(animated: true) }
        }
        render()
    }
}

private extension UIFont {
    func withTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(traits) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}

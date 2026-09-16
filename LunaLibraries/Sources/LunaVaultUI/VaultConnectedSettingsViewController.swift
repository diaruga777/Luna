import UIKit

/// Pairing succeeds only when the shared runtime finishes a real index exchange.
public final class VaultConnectedSettingsViewController: UIViewController, UITextFieldDelegate {
    private let runtime: VaultConnectedRuntime
    private let code = UITextField()
    private let status = UILabel()
    private let pairButton = UIButton(type: .system)
    private let removeButton = UIButton(type: .system)
    private let networkSettingsButton = UIButton(type: .system)
    private var operation: Task<Void, Never>?

    public init(runtime: VaultConnectedRuntime, prefilledCode: String? = nil) {
        self.runtime = runtime
        super.init(nibName: nil, bundle: nil)
        title = "Vault Settings"
        code.text = prefilledCode
    }
    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError() }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let instructions = UILabel()
        instructions.text = "On your Mac, open Luna Vault and copy its pairing code. Paste it here, then accept the connection on the Mac. Keep both devices on the same network for setup."
        instructions.numberOfLines = 0
        code.placeholder = "Paste Mac pairing code"
        code.borderStyle = .roundedRect
        code.autocapitalizationType = .none; code.autocorrectionType = .no
        code.returnKeyType = .done; code.delegate = self
        code.accessibilityIdentifier = "vault.mac.pairing-code"
        let toolbar = UIToolbar(); toolbar.sizeToFit()
        toolbar.items = [UIBarButtonItem(systemItem: .flexibleSpace),
            UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(dismissKeyboard))]
        code.inputAccessoryView = toolbar
        pairButton.setTitle("Pair this Mac", for: .normal)
        pairButton.accessibilityIdentifier = "vault.mac.pair"
        pairButton.addTarget(self, action: #selector(pair), for: .touchUpInside)
        removeButton.setTitle("Unpair Mac", for: .normal)
        removeButton.setTitleColor(.systemRed, for: .normal)
        removeButton.addTarget(self, action: #selector(remove), for: .touchUpInside)
        removeButton.isHidden = true
        status.numberOfLines = 0; status.textColor = .secondaryLabel
        status.accessibilityIdentifier = "vault.mac.status"
        let cache = UIButton(type: .system)
        cache.setTitle("Clear downloaded cache", for: .normal)
        cache.addTarget(self, action: #selector(clearCache), for: .touchUpInside)
        let index = UIButton(type: .system)
        index.setTitle("Rebuild search index", for: .normal)
        index.addTarget(self, action: #selector(rebuild), for: .touchUpInside)
        networkSettingsButton.setTitle("Open iPhone Settings", for: .normal)
        networkSettingsButton.addTarget(self, action: #selector(openSettings), for: .touchUpInside)
        networkSettingsButton.isHidden = true
        let stack = UIStackView(arrangedSubviews: [instructions, code, pairButton, status, networkSettingsButton, removeButton, cache, index])
        stack.axis = .vertical; stack.spacing = 20; stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.keyboardDismissMode = .interactive
        view.addSubview(scroll); scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -20),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40),
        ])
        loadStatus()
    }

    public func textFieldShouldReturn(_ textField: UITextField) -> Bool { dismissKeyboard(); return true }
    @objc private func dismissKeyboard() { view.endEditing(true) }
    private func loadStatus() {
        Task {
            do {
                let snapshot = try await runtime.pairingSnapshot()
                let state = await runtime.connectionStatus()
                status.text = snapshot.isPaired ? "Paired with \(snapshot.remoteName ?? "Mac") · \(state.rawValue)" : "No verified Mac pairing yet."
                removeButton.isHidden = !snapshot.isPaired
            } catch { status.text = "Could not read pairing: \(error.localizedDescription)" }
        }
    }
    @objc private func pair() {
        guard operation == nil else { return }
        dismissKeyboard()
        let input = code.text ?? ""
        pairButton.isEnabled = false; removeButton.isEnabled = false
        status.text = "Connecting to your Mac… Allow Local Network access if asked, then accept the request on the Mac."
        networkSettingsButton.isHidden = true
        operation = Task {
            do {
                try await runtime.pair(code: input)
                status.text = "Paired and connected. The Mac's file index has been received."
                removeButton.isHidden = false
            } catch {
                status.text = error.localizedDescription
                networkSettingsButton.isHidden = false
            }
            pairButton.isEnabled = true; removeButton.isEnabled = true; operation = nil
        }
    }
    @objc private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
    @objc private func remove() {
        Task {
            do { try await runtime.removePairing(); loadStatus() }
            catch { status.text = "Could not unpair: \(error)" }
        }
    }
    @objc private func clearCache() {
        Task {
            do { try await runtime.clearCache(); status.text = "Downloaded cache cleared. Pending uploads are kept." }
            catch { status.text = "Could not clear cache: \(error)" }
        }
    }
    @objc private func rebuild() {
        Task {
            status.text = "Rebuilding search index…"
            do { try await runtime.rebuildIndex(); status.text = "Search index rebuilt for downloaded files." }
            catch { status.text = "Could not rebuild index: \(error)" }
        }
    }
}

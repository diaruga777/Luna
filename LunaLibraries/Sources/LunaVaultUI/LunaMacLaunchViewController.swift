import UIKit
import LunaVaultBEP

/// Every containing app gets the same first-launch connection states, including
/// a restored pairing before its own setup has ever run. Music can opt out.
public final class LunaMacLaunchViewController: UIViewController {
    private let runtime: VaultConnectedRuntime
    private let client: LunaMacClient
    private let makeContent: () -> UIViewController
    private var content: UIViewController?
    private let defaults: UserDefaults
    private var current: UIViewController?
    public var onShowContent: (() -> Void)?
    public var isShowingContent: Bool { content != nil && current === content }
    private var completionKey: String { "LunaMac.Setup." + client.rawValue }
    public convenience init(runtime: VaultConnectedRuntime, client: LunaMacClient, content: UIViewController,
                            defaults: UserDefaults = .standard) {
        self.init(runtime: runtime, client: client, makeContent: { content }, defaults: defaults)
    }
    public init(runtime: VaultConnectedRuntime, client: LunaMacClient, makeContent: @escaping () -> UIViewController,
                defaults: UserDefaults = .standard) {
        self.runtime = runtime; self.client = client; self.makeContent = makeContent; self.defaults = defaults
        super.init(nibName: nil, bundle: nil)
    }
    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    public override func viewDidLoad() {
        super.viewDidLoad()
        if defaults.bool(forKey: completionKey) { showContent(); return }
        let setup = LunaMacConnectionViewController(runtime: runtime, client: client)
        setup.onContinue = { [weak self] in self?.finish() }
        if client == .music {
            setup.navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Not Now", primaryAction: UIAction { [weak self] _ in self?.finish() })
        }
        show(UINavigationController(rootViewController: setup))
    }
    public func showConnection(_ controller: UIViewController) {
        loadViewIfNeeded()
        if let navigation = current as? UINavigationController { navigation.pushViewController(controller, animated: true) }
        else { current?.present(UINavigationController(rootViewController: controller), animated: true) }
    }
    private func finish() {
        defaults.set(true, forKey: completionKey)
        showContent()
        onShowContent?()
    }
    private func showContent() {
        let controller = content ?? makeContent()
        content = controller
        show(controller)
    }
    private func show(_ controller: UIViewController) {
        current?.willMove(toParent: nil); current?.view.removeFromSuperview(); current?.removeFromParent()
        current = controller; addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        controller.didMove(toParent: self)
    }
}

import UIKit
import LunaCodeCore
import LunaCodeUI
import LunaVaultUI
import LunaVaultStore
import LunaVaultTailscale

@main final class CodeAppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default", sessionRole: session.role); config.delegateClass = CodeSceneDelegate.self; return config
    }
}
final class CodeSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var runtime: VaultConnectedRuntime?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene); self.window = window
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--editor-preview") {
            window.rootViewController = try? CodeEditorPreview.make(reset: ProcessInfo.processInfo.arguments.contains("--reset-preview"), workspace: ProcessInfo.processInfo.arguments.contains("--workspace-preview"))
            window.makeKeyAndVisible(); return
        }
        #endif
        do {
            let store = try VaultFolderStore.production()
            let transport = LunaVaultGoTransport(configuration: .init(stateDirectory: store.identityDirectory, requestLocalNetworkAccess: true))
            let runtime = try VaultConnectedRuntime(store: store, dialer: transport, lookup: transport, localID: transport.identity())
            self.runtime = runtime
            let drafts = try CodeDraftStore(root: store.rootURL.deletingLastPathComponent().appendingPathComponent("Code/Drafts"))
            let environment = CodeEnvironment(client: CodeClient { try await runtime.codeRequest($0) }, drafts: drafts,
                browse: { path, offset, hidden in
                    let response = try await runtime.macDirectory(path: path, offset: offset, showHidden: hidden)
                    return CodeBrowserPage(items: response.entries.map { CodeBrowserItem(path: $0.path, name: $0.name, directory: $0.isDirectory) }, next: response.nextOffset)
                }, pairing: {
                    let settings = VaultConnectedSettingsViewController(services: runtime) { try await runtime.pair(code: $0) }
                    settings.title = "Luna Mac"; return settings
                }, peerID: { (try? store.peer()?.deviceID.description) ?? "unpaired" })
            window.rootViewController = CodeWorkspaceController(environment: environment)
        } catch {
            let controller = UIViewController(); controller.view.backgroundColor = .systemBackground
            let label = UILabel(); label.numberOfLines = 0; label.textAlignment = .center
            label.text = "Luna Code could not start.\n\n" + error.localizedDescription
            label.translatesAutoresizingMaskIntoConstraints = false; controller.view.addSubview(label)
            NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.leadingAnchor, constant: 24), label.trailingAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.trailingAnchor, constant: -24), label.centerYAnchor.constraint(equalTo: controller.view.centerYAnchor)])
            window.rootViewController = controller
        }
        window.makeKeyAndVisible()
    }
    func sceneDidEnterBackground(_ scene: UIScene) { if let runtime { Task { await runtime.stop() } } }
}

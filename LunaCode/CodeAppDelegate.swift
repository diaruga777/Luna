import LunaPremium
import UIKit
import LunaCodeCore
import LunaCodeUI
import LunaVaultUI
import LunaVaultStore
import LunaVaultTailscale

@main final class CodeAppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        PremiumAccess.shared.start()
        do {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Code/Overnight")
            let journal = try CodeOvernightStore(root: root)
            CodeNightlyScheduler.shared.register(journal: journal) { invocation, manual in
                let selectedPeer = UserDefaults.standard.string(forKey: "Code.nightlyPeer") ?? "unpaired"
                let policy = CodeNightlyScheduler.shared.policy(peer: selectedPeer)
                let connection = try await LunaMacConnection.makeOvernightCodeRuntime(policy: policy) { provider, outcome in
                    try? journal.event(CodeOvernightDiagnosticEvent(stage: "control." + provider.rawValue, correlationID: invocation.id, outcome: outcome))
                    if outcome == "authenticated", var current = journal.invocations().first(where: { $0.id == invocation.id }) {
                        current.controlProvider = provider; try? journal.save(current)
                    }
                }
                do {
                    guard selectedPeer == connection.peerID else { throw CodeFailure("The paired Mac changed. Review Overnight Builds before trying again.") }
                    let client = CodeClient { try await LunaMacConnection.overnightCodeRequest($0, runtime: connection.runtime) }
                    let runner = CodeOvernightCoordinator(catalog: CodeBuildCatalog(defaults: .standard), client: client, journal: journal)
                    let jobs = try await withTaskCancellationHandler {
                        try await runner.run(peer: connection.peerID, invocationID: invocation.id, policy: policy, manually: manual)
                    } onCancel: { Task { await connection.runtime.stop() } }
                    await connection.runtime.stop()
                    return jobs
                } catch {
                    await connection.runtime.stop()
                    throw error
                }
            }
        } catch { NSLog("Overnight attempt storage unavailable: %@", error.localizedDescription) }
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default", sessionRole: session.role); config.delegateClass = CodeSceneDelegate.self; return config
    }
}
final class CodeSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var runtime: VaultConnectedRuntime?
    private var builds: CodeBuildMonitor?
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
            let runtime = try LunaMacConnection.makeRuntime(client: .code, store: store)
            self.runtime = runtime
            let drafts = try CodeDraftStore(root: store.rootURL.deletingLastPathComponent().appendingPathComponent("Code/Drafts"))
            let environment = CodeEnvironment(client: CodeClient { try await runtime.codeRequest($0) }, drafts: drafts,
                browse: { path, offset, hidden in
                    let response = try await runtime.macDirectory(path: path, offset: offset, showHidden: hidden)
                    return CodeBrowserPage(items: response.entries.map { CodeBrowserItem(path: $0.path, name: $0.name, directory: $0.isDirectory) }, next: response.nextOffset)
                }, pairing: {
                    let settings = LunaMacConnectionViewController(services: runtime, client: .code) { try await runtime.pair(code: $0) }
                    settings.title = "Luna Mac"
                    settings.additionalSettings = [("Overnight Builds", {
                        CodeOvernightSettingsController(client: CodeClient { try await runtime.codeRequest($0) }, peerID: { (try? store.peer()?.deviceID.description) ?? "unpaired" })
                    })]
                    return settings
                }, peerID: { (try? store.peer()?.deviceID.description) ?? "unpaired" })
            builds = environment.builds
            environment.builds.becameIdle = { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, UIApplication.shared.applicationState == .background, self.builds?.needsConnection != true else { return }
                    await self.runtime?.stop()
                }
            }
            window.rootViewController = LunaMacLaunchViewController(runtime: runtime, client: .code, content: CodeTabsController(environment: environment))
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
    func sceneDidBecomeActive(_ scene: UIScene) {
        if let runtime { Task { @MainActor in
            await runtime.reconnect()
            guard let journal = CodeNightlyScheduler.shared.journal else { return }
            let client = CodeClient { try await runtime.codeRequest($0) }
            let runner = CodeOvernightCoordinator(catalog: CodeBuildCatalog(defaults: .standard), client: client, journal: journal)
            do { _ = try await runner.refresh() }
            catch { try? journal.event(CodeOvernightDiagnosticEvent(stage: "foregroundStatus", correlationID: UUID().uuidString, outcome: "unavailable")) }
        } }
    }
    func sceneDidEnterBackground(_ scene: UIScene) { if builds?.needsConnection != true, let runtime { Task { @MainActor [weak self] in
        guard UIApplication.shared.applicationState == .background, self?.builds?.needsConnection != true else { return }
        await runtime.stop()
    } } }
}

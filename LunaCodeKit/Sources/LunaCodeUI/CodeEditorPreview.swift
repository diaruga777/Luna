#if os(iOS) && DEBUG
import UIKit
import CryptoKit
import LunaCodeCore

/// Simulator-only fixture for layout and keyboard tests. It never connects to
/// a Mac, uses no shared pairing state, and cannot build or publish anything.
@MainActor public enum CodeEditorPreview {
    public static func make(reset: Bool, workspace: Bool = false) throws -> UIViewController {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LunaCodeEditorUITests")
        if reset { try? FileManager.default.removeItem(at: root) }
        let drafts = try CodeDraftStore(root: root)
        let defaults = UserDefaults(suiteName: "LunaCodeEditorUITests")!
        if reset { defaults.removePersistentDomain(forName: "LunaCodeEditorUITests") }
        if !workspace && reset { defaults.set("/Preview/Welcome.swift", forKey: "Code.lastFile.preview") }
        let files = PreviewFiles()
        let environment = CodeEnvironment(client: CodeClient { await files.handle($0) }, drafts: drafts, defaults: defaults,
            browse: { path, _, _ in
                if ProcessInfo.processInfo.arguments.contains("--browser-failure") { throw CodeFailure("Preview Mac is offline.") }
                let entries: [(String, Bool)]
                switch path {
                case nil: entries = [("/Preview/Sample.xcodeproj", true), ("/Other/Other.xcworkspace", true)]
                case "/Preview": entries = [("/Preview/Sample.xcodeproj", true), ("/Preview/Sources", true), ("/Preview/Welcome.swift", false)]
                case "/Preview/Sources": entries = [("/Preview/Sources/Detail.swift", false)]
                case "/Other": entries = [("/Other/Other.xcworkspace", true), ("/Other/Other.swift", false)]
                default: entries = []
                }
                return CodeBrowserPage(items: entries.map { CodeBrowserItem(path: $0.0, name: ($0.0 as NSString).lastPathComponent, directory: $0.1) }, next: nil)
            },
            pairing: { UIViewController() }, peerID: { "preview" })
        return CodeWorkspaceController(environment: environment)
    }
}
private actor PreviewFiles {
    private var injectConflict = ProcessInfo.processInfo.arguments.contains("--save-conflict")
    var text = """
    import UIKit

    // A small change, wherever you are.
    final class WelcomeViewController: UIViewController {
        private let titleLabel = UILabel()

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .systemBackground
            titleLabel.text = "Hello, Luna"
            titleLabel.font = .systemFont(ofSize: 28)
            titleLabel.textColor = .systemIndigo
            view.addSubview(titleLabel)
        }

        func greeting(for name: String) -> String {
            return "Welcome, \\(name)"
        }
    }
    """
    func handle(_ data: Data) -> Data {
        var response = CodeResponse()
        do {
            let request = try JSONDecoder().decode(CodeRequest.self, from: data)
            let version = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
            switch request.operation {
            case .schemes:
                response.schemes = ["Sample", "SampleTests"]
                return try JSONEncoder().encode(response)
            case .open: break
            case .save:
                if injectConflict { text += "\n// Changed on Mac"; injectConflict = false; response.conflict = true }
                else if request.version == version { text = request.text } else { response.conflict = true }
            default: throw CodeFailure("Editor preview: Mac commands are disabled.")
            }
            response.document = CodeDocument(path: request.path, text: text, version: SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined())
        } catch { response.error = error.localizedDescription }
        return try! JSONEncoder().encode(response)
    }
}
#endif

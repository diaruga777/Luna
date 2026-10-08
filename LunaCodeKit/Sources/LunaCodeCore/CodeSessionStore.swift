import Foundation

/// Keeps each Mac's selected project and each project's last file independent.
public final class CodeSessionStore {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults) { self.defaults = defaults }

    public func project(peer: String) -> CodeProject? {
        defaults.data(forKey: "Code.project." + peer).flatMap { try? JSONDecoder().decode(CodeProject.self, from: $0) }
    }

    public func setProject(_ project: CodeProject?, peer: String) {
        // Migrate the old per-Mac file before changing its project association.
        _ = lastFile(peer: peer)
        defaults.set(project.flatMap { try? JSONEncoder().encode($0) }, forKey: "Code.project." + peer)
    }

    public func lastFile(peer: String) -> String? {
        let key = fileKey(peer: peer)
        if defaults.object(forKey: key) == nil {
            let oldKey = "Code.lastFile." + peer
            if let legacy = defaults.string(forKey: oldKey) {
                let root = project(peer: peer)?.root
                if root == nil || legacy.hasPrefix(root! + "/") { defaults.set(legacy, forKey: key) }
                defaults.removeObject(forKey: oldKey)
            }
        }
        return defaults.string(forKey: key).flatMap { $0.isEmpty ? nil : $0 }
    }

    public func setLastFile(_ path: String?, peer: String) {
        // An explicit close must not resurrect a legacy last-file value.
        defaults.removeObject(forKey: "Code.lastFile." + peer)
        defaults.set(path ?? "", forKey: fileKey(peer: peer))
    }

    private func fileKey(peer: String) -> String {
        let projectKey = Data((project(peer: peer)?.path ?? "").utf8).base64EncodedString()
        return "Code.sessionFile." + peer + "." + projectKey
    }
}

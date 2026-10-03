import Foundation
import LunaCodeCore

public actor CodeService {
    private let files = CodeFiles()
    private let jobs: CodeJobs
    private let root: URL
    private var language: Task<CodeLanguageServer, Error>?
    private var projectKey: String?
    private var savedReplies: [String: (Data, Data)] = [:]
    public init(root: URL) throws { self.root = root; jobs = try CodeJobs(root: root.appendingPathComponent("Jobs")) }
    public func handle(_ data: Data) async -> Data {
        var response = CodeResponse()
        do {
            guard data.count <= CodeWire.maxPayloadBytes else { throw CodeFailure("Request too large.") }
            let request = try JSONDecoder().decode(CodeRequest.self, from: data)
            if let previous = savedReplies[request.id] {
                guard previous.0 == data else { throw CodeFailure("A request ID was reused with different content.") }
                return previous.1
            }
            switch request.operation {
            case .open:
                let document = try files.open(request.path)
                if document.version != request.version { response.document = document }
            case .save:
                let result = try files.save(path: request.path, text: request.text, expected: request.version)
                response.document = result.0; response.conflict = result.1
            case .schemes:
                let path = request.path
                guard path.hasPrefix("/"), ["xcworkspace", "xcodeproj"].contains(URL(fileURLWithPath: path).pathExtension) else { throw CodeFailure("Choose an Xcode project or workspace.") }
                let log = root.appendingPathComponent(UUID().uuidString + ".json")
                defer { try? FileManager.default.removeItem(at: log) }
                let status = try await CodeProcess().run("/usr/bin/xcodebuild", [path.hasSuffix(".xcworkspace") ? "-workspace" : "-project", path, "-list", "-json"], directory: (path as NSString).deletingLastPathComponent, log: log, timeout: 60)
                let output = try Data(contentsOf: log)
                // xcodebuild may prepend package-resolution progress before JSON.
                guard status == 0, let start = output.firstIndex(of: 123),
                    let object = try JSONSerialization.jsonObject(with: output.suffix(from: start)) as? [String: Any] else { throw CodeFailure("Xcode could not list schemes. Open the project on the Mac to resolve its packages.") }
                let project = object["workspace"] as? [String: Any] ?? object["project"] as? [String: Any]
                response.schemes = project?["schemes"] as? [String] ?? []
            case .prepare, .build, .deploy:
                response.job = try await jobs.start(request)
                if request.operation == .prepare { language?.cancel(); language = nil; projectKey = nil }
            case .job: response.job = try await jobs.status(request.jobID)
            case .cancel: response.job = try await jobs.cancel(request.jobID)
            case .analyze, .complete:
                guard let project = request.project, !project.scheme.isEmpty, request.text.utf8.count <= CodeWire.maxFileBytes else { throw CodeFailure("Select a project and scheme to enable Mac code intelligence.") }
                let key = project.path + "\u{0}" + project.scheme
                if language == nil || projectKey != key {
                    let derived = await jobs.derivedData(project)
                    projectKey = key
                    language = Task {
                        let server = try CodeLanguageServer(project: project, derivedData: derived, logs: root)
                        try await server.initialize(project: project)
                        return server
                    }
                }
                let server: CodeLanguageServer
                do { server = try await language!.value }
                catch { language = nil; throw error }
                try server.update(path: request.path, text: request.text, version: request.bufferVersion)
                if request.operation == .complete {
                    response.completions = try await server.complete(path: request.path, position: request.position ?? CodePosition(line: 0, character: 0))
                } else { response.diagnostics = try await server.diagnostics(path: request.path) }
            }
            let encoded = try JSONEncoder().encode(response)
            if request.operation == .save {
                if savedReplies.count > 64 { savedReplies.removeAll() }
                savedReplies[request.id] = (data, encoded)
            }
            return encoded
        } catch { response.error = error.localizedDescription }
        return (try? JSONEncoder().encode(response)) ?? Data()
    }
}

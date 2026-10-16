import Foundation
import LunaCodeCore

public actor CodeService {
    private let files = CodeFiles()
    private let jobs: CodeJobs
    private let root: URL
    private let checkAccess: @Sendable (String) async throws -> Void
    private var language: Task<CodeLanguageServer, Error>?
    private var projectKey: String?
    private var intelligenceTail: Task<Void, Never>?
    private var savedReplies: [String: (Data, Data)] = [:]
    public init(root: URL, checkAccess: @escaping @Sendable (String) async throws -> Void = { _ in }) throws {
        self.root = root; self.checkAccess = checkAccess; jobs = try CodeJobs(root: root.appendingPathComponent("Jobs"))
    }
    public func handle(_ data: Data) async -> Data {
        var response = CodeResponse()
        do {
            guard data.count <= CodeWire.maxPayloadBytes else { throw CodeFailure("Request too large.") }
            let request = try JSONDecoder().decode(CodeRequest.self, from: data)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let canonical = try encoder.encode(request)
            if let previous = savedReplies[request.id] {
                guard previous.0 == canonical else { throw CodeFailure("A request ID was reused with different content.") }
                return previous.1
            }
            switch request.operation {
            case .job, .cancel, .devices: break
            default:
                let path = request.project?.path ?? request.path
                if path.hasPrefix("/") { try await checkAccess(URL(fileURLWithPath: path).deletingLastPathComponent().path) }
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
                response.schemes = try await CodeDeviceSupport.schemes(path: path, root: root)
            case .apps:
                guard request.path.hasPrefix("/"), ["xcworkspace", "xcodeproj"].contains(URL(fileURLWithPath: request.path).pathExtension) else { throw CodeFailure("Choose an Xcode project or workspace.") }
                response.apps = try await CodeDeviceSupport.apps(path: request.path, scheme: request.project?.scheme, root: root)
            case .devices: response.devices = try await CodeDeviceSupport.devices(root: root)
            case .branches: response.branches = try await CodeDeviceSupport.branches(path: request.path, root: root)
            case .prepare, .build, .deploy, .runOnDevice:
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
                // Keep each buffer update and its response together. Actors may
                // reenter while awaiting LSP, including requests from both apps.
                let previous = intelligenceTail
                let operation = Task<CodeResponse, Error> {
                    await previous?.value
                    try server.update(path: request.path, text: request.text, version: request.bufferVersion)
                    var reply = CodeResponse()
                    if request.operation == .complete {
                        reply.completions = try await server.complete(path: request.path, position: request.position ?? CodePosition(line: 0, character: 0))
                    } else { reply.diagnostics = try await server.diagnostics(path: request.path) }
                    return reply
                }
                intelligenceTail = Task { _ = try? await operation.value }
                response = try await operation.value
            }
            let encoded = try JSONEncoder().encode(response)
            if request.operation == .save {
                if savedReplies.count > 64 { savedReplies.removeAll() }
                savedReplies[request.id] = (canonical, encoded)
            }
            return encoded
        } catch { response.error = error.localizedDescription }
        return (try? JSONEncoder().encode(response)) ?? Data()
    }
}

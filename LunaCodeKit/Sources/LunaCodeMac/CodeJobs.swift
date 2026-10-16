import Foundation
import CryptoKit
import LunaCodeCore

public actor CodeJobs {
    public let root: URL
    private var jobs: [String: CodeJob] = [:]
    private var processes: [String: CodeProcess] = [:]
    private var requests: [String: String] = [:]
    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for url in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "json" {
            if var job = try? JSONDecoder().decode(CodeJob.self, from: Data(contentsOf: url)) {
                if job.state == .running { job.state = .failed; job.log += "\nMac companion restarted before this job completed." }
                jobs[job.id] = job
            }
        }
    }
    public func derivedData(_ project: CodeProject) -> URL {
        let key = SHA256.hash(data: Data((project.path + project.scheme).utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent("DerivedData-" + key)
    }
    public func start(_ request: CodeRequest) throws -> CodeJob {
        if let id = requests[request.id], let existing = jobs[id] { return existing }
        guard processes.isEmpty else { throw CodeFailure("A Mac build is already running. Wait for it or cancel it first.") }
        guard let project = request.project, FileManager.default.fileExists(atPath: project.path),
              ["xcodeproj", "xcworkspace"].contains(URL(fileURLWithPath: project.path).pathExtension),
              !project.scheme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CodeFailure("Select an Xcode project or workspace and scheme first.")
        }
        if request.operation == .runOnDevice {
            guard request.deviceBuild != nil, !project.scheme.lowercased().contains("webdriveragent") else { throw CodeFailure("Select an app scheme and phone first.") }
        }
        let title = request.operation == .runOnDevice ? "Build & Run · " + project.scheme : request.operation == .deploy ? "Build & Deploy" : (request.operation == .prepare ? "Prepare Code Intelligence" : "Build")
        let job = CodeJob(id: UUID().uuidString, title: title)
        jobs[job.id] = job; requests[request.id] = job.id
        let process = CodeProcess(); processes[job.id] = process
        persist(job)
        Task { await execute(request, project: project, job: job, process: process) }
        return job
    }
    public func status(_ id: String) throws -> CodeJob {
        guard var job = jobs[id] else { throw CodeFailure("This build job is no longer available.") }
        let url = root.appendingPathComponent(id + ".log")
        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            if let length = try? handle.seekToEnd() {
                try? handle.seek(toOffset: length > 120_000 ? length - 120_000 : 0)
                let data = (try? handle.readToEnd()) ?? Data()
                job.log = (length > 120_000 ? "Earlier output remains in the Mac job log.\n" : "") + String(decoding: data, as: UTF8.self) + job.log
            }
        }
        return job
    }
    public func cancel(_ id: String) throws -> CodeJob {
        guard var job = jobs[id] else { throw CodeFailure("Unknown build job.") }
        if job.state == .running { processes[id]?.cancel(); job.state = .cancelled; jobs[id] = job; persist(job) }
        return try status(id)
    }
    private func persist(_ job: CodeJob) { try? JSONEncoder().encode(job).write(to: root.appendingPathComponent(job.id + ".json"), options: .atomic) }
    private func execute(_ request: CodeRequest, project: CodeProject, job: CodeJob, process: CodeProcess) async {
        var completed = job
        let log = root.appendingPathComponent(job.id + ".log")
        do {
            let exit: Int32
            if request.operation == .runOnDevice {
                try await runOnDevice(request, project: project, job: job, process: process, log: log)
                exit = 0
            } else if request.operation == .deploy {
                guard !project.appID.isEmpty, !project.groupID.isEmpty else { throw CodeFailure("Set the App Store Connect app ID and internal testing group ID in Project Settings.") }
                let asc = try Self.ascExecutable()
                // Verify the destination really is an internal group before uploading.
                let groupsLog = root.appendingPathComponent(job.id + "-groups.log")
                let result = try await process.run(asc, ["testflight", "groups", "list", "--app", project.appID, "--paginate", "--output", "json"], directory: project.root, log: groupsLog, timeout: 60)
                guard result == 0, let json = try JSONSerialization.jsonObject(with: Data(contentsOf: groupsLog)) as? [String: Any],
                    let groups = json["data"] as? [[String: Any]], groups.contains(where: {
                        $0["id"] as? String == project.groupID && ($0["attributes"] as? [String: Any])?["isInternalGroup"] as? Bool == true
                    }) else { throw CodeFailure("Could not verify this internal testing group. Check the app/group IDs and existing asc API-key authentication on the Mac.") }
                let export = root.appendingPathComponent(job.id + "-ExportOptions.plist")
                let options: [String: Any] = ["method": "app-store-connect", "signingStyle": "automatic", "destination": "export", "manageAppVersionAndBuildNumber": false]
                try PropertyListSerialization.data(fromPropertyList: options, format: .xml, options: 0).write(to: export)
                let target = project.path.hasSuffix(".xcworkspace") ? "--workspace" : "--project"
                exit = try await process.run(asc, ["publish", "testflight", "--app", project.appID,
                    target, project.path, "--scheme", project.scheme, "--configuration", "Release",
                    "--group", project.groupID, "--wait", "--timeout", "60m",
                    "--archive-path", root.appendingPathComponent(job.id + ".xcarchive").path,
                    "--ipa-path", root.appendingPathComponent(job.id + ".ipa").path,
                    "--export-options", export.path,
                    "--archive-xcodebuild-flag=-allowProvisioningUpdates", "--export-xcodebuild-flag=-allowProvisioningUpdates"],
                    directory: project.root, log: log, timeout: 7200)
            } else {
                exit = try await process.run("/usr/bin/xcodebuild", project.xcodeArguments + ["-configuration", "Debug",
                    "-destination", "generic/platform=iOS Simulator", "-derivedDataPath", derivedData(project).path, "-resultBundlePath", root.appendingPathComponent(job.id + ".xcresult").path, "build"],
                    directory: project.root, log: log)
            }
            completed.state = exit == 0 ? .succeeded : .failed
            if exit == 0, request.operation == .deploy { completed.log = "\nAvailable to the internal group after processing. Open TestFlight on your iPhone to install." }
        } catch is CancellationError { completed.state = .cancelled }
        catch { completed.state = .failed; completed.log = "\n" + error.localizedDescription }
        if jobs[job.id]?.state == .cancelled { completed.state = .cancelled }
        jobs[job.id] = completed; processes[job.id] = nil; persist(completed)
    }
    public static func ascExecutable() throws -> String {
        let paths = [ProcessInfo.processInfo.environment["LUNA_ASC_PATH"], NSHomeDirectory() + "/.blitz/bin/asc", "/opt/homebrew/bin/asc", "/usr/local/bin/asc"].compactMap { $0 }
        guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw CodeFailure("Install asc on the Mac and configure its existing App Store Connect API key. Luna also checks ~/.blitz/bin/asc and LUNA_ASC_PATH.")
        }
        return path
    }
}

import Foundation
import LunaMusicFiles
import Darwin

/// Shared across reconnects. Only an already paired Music RPC can reach this
/// service; callers receive opaque job IDs, never arbitrary filesystem paths.
public actor CompanionYouTubeAudio {
    public static let shared = CompanionYouTubeAudio()
    struct Toolchain: Sendable {
        var brew: URL
        var ytDLP: URL
        var bin: URL
    }
    struct Command: Sendable {
        var executable: URL
        var arguments: [String]
        var bin: URL
        var timeout: TimeInterval = 120
        var watchedFile: URL?
        var maximumBytes: Int64 = 0
    }
    private struct Job {
        var videoID: String
        var response = YouTubeAudioResponse(state: .resolving)
        var task: Task<Void, Never>?
        var touched = Date()
    }
    private let cacheDirectory: URL
    private let detector: @Sendable () async -> Toolchain?
    private let runner: @Sendable (Command) async throws -> Data
    private var checked = false
    private var toolchain: Toolchain?
    private var jobs: [String: Job] = [:]
    private var upgradeTask: Task<Void, Error>?
    private var lastUpgrade = Date.distantPast

    init(cacheDirectory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("LunaMac/YouTubeAudio"),
         detector: @escaping @Sendable () async -> Toolchain? = { await CompanionYouTubeAudio.detect() },
         runner: @escaping @Sendable (Command) async throws -> Data = { try await CompanionYouTubeAudio.run($0) }) {
        self.cacheDirectory = cacheDirectory; self.detector = detector; self.runner = runner
    }

    @discardableResult public func refreshCapability() async -> Bool {
        toolchain = await detector(); checked = true
        return toolchain != nil
    }
    public func handle(_ request: YouTubeAudioRequest) async -> YouTubeAudioResponse {
        do {
            cleanExpiredJobs()
            if request.action == .availability {
                if !checked { await refreshCapability() }
                return .init(available: toolchain != nil)
            }
            guard UUID(uuidString: request.id) != nil else { throw MusicFileError("Invalid audio request.") }
            switch request.action {
            case .availability: return .init(available: toolchain != nil)
            case .resolve:
                guard let video = YouTubeAudioURL.videoID(request.url) else { throw MusicFileError("Enter a YouTube video link.") }
                if let job = jobs[request.id] {
                    guard job.videoID == video else { throw MusicFileError("This audio request has changed.") }
                    return job.response
                }
                if !checked { await refreshCapability() }
                guard let tools = toolchain else { throw MusicFileError("YouTube audio is unavailable on this Mac.") }
                guard jobs.count < 8 else { throw MusicFileError("Wait for another audio download to finish.") }
                jobs[request.id] = Job(videoID: video)
                jobs[request.id]?.task = Task { await self.resolve(request.id, video: video, tools: tools) }
            case .status:
                guard jobs[request.id] != nil else { throw MusicFileError("This audio request expired. Try again.") }
            case .download:
                guard let job = jobs[request.id], let tools = toolchain else { throw MusicFileError("This audio request expired. Try again.") }
                guard request.maximumBytes > 0, request.maximumBytes <= 10_000_000_000 else { throw MusicFileError("Invalid audio download limit.") }
                if job.response.state == .resolved {
                    jobs[request.id]?.response.state = .downloading
                    jobs[request.id]?.task = Task { await self.download(request.id, video: job.videoID, tools: tools, maximumBytes: request.maximumBytes) }
                }
            case .read:
                guard let job = jobs[request.id], job.response.state == .ready, let size = job.response.size,
                      request.offset >= 0, request.offset < size, request.length > 0,
                      request.length <= MusicFileProtocol.chunkSize,
                      Int64(request.length) <= size - request.offset else { throw MusicFileError("Invalid audio range.") }
                let file = audioURL(request.id)
                guard try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isRegularFile == true,
                      try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
                      try file.resourceValues(forKeys: [.fileSizeKey]).fileSize == Int(size) else { throw MusicFileError("The audio file changed. Try again.") }
                let input = try FileHandle(forReadingFrom: file); defer { try? input.close() }
                try input.seek(toOffset: UInt64(request.offset))
                let bytes = try input.read(upToCount: request.length) ?? Data()
                guard bytes.count == request.length else { throw MusicFileError("The audio transfer was incomplete.") }
                jobs[request.id]?.touched = Date()
                return .init(state: .ready, size: size, data: bytes)
            case .release:
                jobs.removeValue(forKey: request.id)?.task?.cancel()
                try? FileManager.default.removeItem(at: directory(request.id))
                return .init()
            }
            jobs[request.id]?.touched = Date()
            return jobs[request.id]?.response ?? .init(error: "This audio request expired. Try again.")
        } catch { return .init(state: .failed, error: error.localizedDescription) }
    }
    private func resolve(_ id: String, video: String, tools: Toolchain) async {
        do {
            let command = Command(executable: tools.ytDLP,
                arguments: Self.arguments + ["--skip-download", "--dump-single-json", "--", YouTubeAudioURL.canonical(video).absoluteString], bin: tools.bin)
            let data = try await withUpgradeRetry(command, tools: tools)
            try Task.checkCancellation()
            let metadata = try Self.metadata(data, video: video)
            guard jobs[id] != nil else { return }
            jobs[id]?.response = .init(state: .resolved, metadata: metadata)
            jobs[id]?.task = nil
        } catch { fail(id, error) }
    }
    private func download(_ id: String, video: String, tools: Toolchain, maximumBytes: Int64) async {
        do {
            try FileManager.default.createDirectory(at: directory(id), withIntermediateDirectories: true)
            let command = Command(executable: tools.ytDLP,
                arguments: Self.arguments + ["--no-simulate", "--no-continue", "--no-part", "--fixup", "never",
                    "--max-filesize", String(maximumBytes), "--output", audioURL(id).path,
                    "--", YouTubeAudioURL.canonical(video).absoluteString],
                bin: tools.bin, timeout: 1800, watchedFile: audioURL(id), maximumBytes: maximumBytes)
            _ = try await withUpgradeRetry(command, tools: tools)
            try Task.checkCancellation()
            let size = (try FileManager.default.attributesOfItem(atPath: audioURL(id).path)[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 0, size <= maximumBytes else { throw MusicFileError("The audio exceeds your download limit.") }
            guard jobs[id] != nil else { return }
            jobs[id]?.response.state = .ready; jobs[id]?.response.size = size; jobs[id]?.task = nil
        } catch {
            try? FileManager.default.removeItem(at: directory(id))
            fail(id, error)
        }
    }
    private func fail(_ id: String, _ error: Error) {
        guard jobs[id] != nil else { return }
        jobs[id]?.response.state = .failed; jobs[id]?.response.error = error.localizedDescription; jobs[id]?.task = nil
    }
    private func withUpgradeRetry(_ command: Command, tools: Toolchain) async throws -> Data {
        do { return try await runner(command) }
        catch {
            try Task.checkCancellation()
            // Share a concurrent upgrade and rate-limit subsequent failures. No
            // install, unpin, sudo, or upgrade of unrelated requested packages.
            if let upgradeTask { try await upgradeTask.value }
            else if Date().timeIntervalSince(lastUpgrade) >= 900 {
                lastUpgrade = Date()
                let runner = self.runner
                let task = Task {
                    _ = try await runner(Command(executable: tools.brew, arguments: ["update"], bin: tools.bin, timeout: 300))
                    _ = try await runner(Command(executable: tools.brew, arguments: ["upgrade", "yt-dlp"], bin: tools.bin, timeout: 600))
                }
                upgradeTask = task
                defer { upgradeTask = nil }
                try await task.value
            }
            try Task.checkCancellation()
            if let file = command.watchedFile { try? FileManager.default.removeItem(at: file) }
            return try await runner(command)
        }
    }
    private static let arguments = ["--ignore-config", "--no-plugin-dirs", "--no-playlist", "--no-warnings",
        "--no-progress", "--no-colors", "--socket-timeout", "20", "--retries", "1", "--fragment-retries", "1",
        "--format", "bestaudio[ext=m4a][protocol=https]"]

    static func metadata(_ data: Data, video: String) throws -> YouTubeAudioMetadata {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["id"] as? String == video, json["vcodec"] as? String == "none",
              json["ext"] as? String == "m4a", json["is_live"] as? Bool != true,
              let address = json["url"] as? String, let url = URL(string: address),
              url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
              ["https", "http"].contains(json["protocol"] as? String ?? "") else {
            throw MusicFileError("YouTube didn’t provide a direct audio stream for this video.")
        }
        let headers = (json["http_headers"] as? [String: String] ?? [:]).filter {
            !$0.key.contains("\r") && !$0.key.contains("\n") && !$0.value.contains("\r") && !$0.value.contains("\n") &&
            !["host", "content-length", "connection"].contains($0.key.lowercased())
        }
        let duration = (json["duration"] as? NSNumber)?.doubleValue ?? 0
        return .init(videoID: video, title: String((json["title"] as? String ?? "YouTube Audio").prefix(500)),
            author: String((json["channel"] as? String ?? json["uploader"] as? String ?? "").prefix(300)),
            duration: duration.isFinite ? max(0, duration) : 0, downloadURL: url, headers: headers)
    }
    private func directory(_ id: String) -> URL { cacheDirectory.appendingPathComponent(id, isDirectory: true) }
    private func audioURL(_ id: String) -> URL { directory(id).appendingPathComponent("audio.m4a") }
    private func cleanExpiredJobs() {
        for (id, job) in jobs where Date().timeIntervalSince(job.touched) > 86400 {
            job.task?.cancel(); jobs[id] = nil; try? FileManager.default.removeItem(at: directory(id))
        }
        // Remove files abandoned by a previous app launch, but never an active job.
        for url in (try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            guard jobs[url.lastPathComponent] == nil,
                  let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  Date().timeIntervalSince(date) > 86400 else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }
    private static func detect() async -> Toolchain? {
        var candidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        candidates += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/brew" }
        for path in Array(NSOrderedSet(array: candidates)) as? [String] ?? candidates {
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }
            let brew = URL(fileURLWithPath: path), bin = brew.deletingLastPathComponent()
            do {
                let installed = try await run(Command(executable: brew, arguments: ["list", "--formula", "--versions", "yt-dlp"], bin: bin, timeout: 10))
                guard String(data: installed, encoding: .utf8)?.split(whereSeparator: \.isWhitespace).first == "yt-dlp" else { continue }
                let prefixData = try await run(Command(executable: brew, arguments: ["--prefix", "yt-dlp"], bin: bin, timeout: 10))
                guard let prefix = String(data: prefixData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), prefix.hasPrefix("/") else { continue }
                // Keep Homebrew's stable opt path: resolving into Cellar here
                // would retry the old executable after a successful upgrade.
                let executable = URL(fileURLWithPath: prefix).appendingPathComponent("bin/yt-dlp")
                guard FileManager.default.isExecutableFile(atPath: executable.path) else { continue }
                _ = try await run(Command(executable: executable, arguments: ["--ignore-config", "--version"], bin: bin, timeout: 10))
                return Toolchain(brew: brew, ytDLP: executable, bin: bin)
            } catch { continue }
        }
        return nil
    }
    static func run(_ command: Command) async throws -> Data {
        let worker = Task.detached(priority: .utility) { () async throws -> Data in
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent("luna-ytdlp-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            let output = staging.appendingPathComponent("stdout"), errors = staging.appendingPathComponent("stderr")
            FileManager.default.createFile(atPath: output.path, contents: nil)
            FileManager.default.createFile(atPath: errors.path, contents: nil)
            let out = try FileHandle(forWritingTo: output), err = try FileHandle(forWritingTo: errors)
            defer { try? out.close(); try? err.close() }
            let process = Process(); process.executableURL = command.executable; process.arguments = command.arguments
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = command.bin.path + ":/usr/bin:/bin:/usr/sbin:/sbin"
            environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"; environment["HOMEBREW_NO_ANALYTICS"] = "1"
            environment["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
            process.environment = environment; process.standardOutput = out; process.standardError = err
            process.standardInput = FileHandle.nullDevice
            try Task.checkCancellation(); try process.run()
            let deadline = Date().addingTimeInterval(command.timeout)
            var interrupted = false
            while process.isRunning {
                let size = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let errorSize = (try? errors.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let audioSize = command.watchedFile.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } ?? 0
                if Task.isCancelled || Date() > deadline || size > 4 * 1024 * 1024 || errorSize > 1024 * 1024 ||
                    (command.maximumBytes > 0 && Int64(audioSize) > command.maximumBytes) {
                    interrupted = true; process.terminate()
                    try? await Task.sleep(for: .milliseconds(200))
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    break
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            process.waitUntilExit(); try Task.checkCancellation()
            guard !interrupted, process.terminationStatus == 0 else {
                // Do not send signed media URLs, headers or tool diagnostics to
                // the phone/UI. yt-dlp output is diagnostic data, not copy.
                throw MusicFileError("YouTube audio couldn’t be fetched on the Mac. Try again later.")
            }
            return try Data(contentsOf: output)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}

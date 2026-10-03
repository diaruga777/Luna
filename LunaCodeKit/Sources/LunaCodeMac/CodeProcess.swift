import Foundation
import LunaCodeCore

/// No shell interpolation. Output goes to disk so a full pipe cannot stall a build.
public final class CodeProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    public init() {}
    public func cancel() {
        lock.lock(); cancelled = true; let p = process; lock.unlock()
        if let p, p.isRunning { p.interrupt(); p.terminate() }
    }
    public func run(_ executable: String, _ arguments: [String], directory: String,
                    log: URL, timeout: TimeInterval = 3600) async throws -> Int32 {
        try await withTaskCancellationHandler {
            try await Task.detached { [self] in
                FileManager.default.createFile(atPath: log.path, contents: nil)
                let output = try FileHandle(forWritingTo: log)
                defer { try? output.close() }
                try output.seekToEnd()
                let p = Process(); p.executableURL = URL(fileURLWithPath: executable)
                p.arguments = arguments; p.currentDirectoryURL = URL(fileURLWithPath: directory)
                var environment = ProcessInfo.processInfo.environment
                environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "")
                p.environment = environment; p.standardOutput = output; p.standardError = output
                try lock.withCriticalScope {
                    guard !cancelled else { throw CancellationError() }
                    try p.run(); process = p
                }
                let deadline = Date().addingTimeInterval(timeout)
                while p.isRunning {
                    if Date() > deadline { p.interrupt(); p.terminate(); throw CodeFailure("The command timed out. See the build log.") }
                    try await Task.sleep(for: .milliseconds(100))
                }
                p.waitUntilExit()
                lock.withCriticalScope { process = nil }
                if lock.withCriticalScope({ cancelled }) { throw CancellationError() }
                return p.terminationStatus
            }.value
        } onCancel: { self.cancel() }
    }
}
extension NSLock {
    func withCriticalScope<T>(_ operation: () throws -> T) rethrows -> T { lock(); defer { unlock() }; return try operation() }
}

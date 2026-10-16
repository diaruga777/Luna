import Foundation

/// macOS can block a filesystem call while its permission dialog is open.
/// Probe with a read only operation off the service actor, and bound how long
/// callers wait. Never time out a write that might subsequently complete.
public final class CompanionFileAccess: @unchecked Sendable {
    public static let shared = CompanionFileAccess()
    private struct Probe {
        let id = UUID()
        var waiters: [CheckedContinuation<[URL], Error>]
        var timedOut = false
    }
    private let lock = NSLock()
    private let deadlineQueue = DispatchQueue(label: "LunaMac.fileAccess.deadlines")
    private let timeout: TimeInterval
    private let readDirectory: @Sendable (URL) throws -> [URL]
    private var pending: [String: Probe] = [:]
    private var issues: [String: String] = [:]

    public init(timeout: TimeInterval = 8, readDirectory: @escaping @Sendable (URL) throws -> [URL] = {
        try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)
    }) {
        self.timeout = timeout; self.readDirectory = readDirectory
    }
    public var statusMessage: String? {
        lock.lock(); defer { lock.unlock() }
        return issues.sorted { $0.key < $1.key }.first?.value
    }
    public static func waitingMessage(_ path: String) -> String {
        "Folder access is taking too long: \(path). Luna Mac may be waiting for a macOS permission prompt. On your Mac, allow folder access in the prompt, or open System Settings → Privacy & Security → Files and Folders or Full Disk Access. Then retry in Luna."
    }
    public func checkDirectory(_ url: URL) async throws { _ = try await contents(of: url) }
    /// Check each directory before a recursive scanner descends into another
    /// protected location (for example Documents inside a shared Home folder).
    public func checkTree(_ root: URL) async throws {
        var directories = [root]
        while let directory = directories.popLast() {
            let entries = try await contents(of: directory)
            for url in entries where !url.lastPathComponent.hasPrefix(".") {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values.isDirectory == true, values.isSymbolicLink != true { directories.append(url) }
            }
        }
    }
    private func contents(of url: URL) async throws -> [URL] {
        let path = url.standardizedFileURL.path
        let result: [URL] = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[URL], Error>) in
            lock.lock()
            if var probe = pending[path] {
                if probe.timedOut {
                    lock.unlock(); continuation.resume(throwing: AccessError(Self.waitingMessage(path)))
                } else {
                    probe.waiters.append(continuation); pending[path] = probe; lock.unlock()
                }
                return
            }
            guard pending.count < 16 else {
                lock.unlock(); continuation.resume(throwing: AccessError("Luna Mac is waiting for folder access. Respond to any macOS permission prompts, then retry.")); return
            }
            let probe = Probe(waiters: [continuation]); let id = probe.id
            pending[path] = probe; lock.unlock()
            deadlineQueue.asyncAfter(deadline: .now() + timeout) { [self] in
                lock.lock()
                guard var probe = pending[path], probe.id == id, !probe.timedOut else { lock.unlock(); return }
                let waiters = probe.waiters; probe.waiters = []; probe.timedOut = true; pending[path] = probe
                let message = Self.waitingMessage(path); issues[path] = message
                lock.unlock()
                for waiter in waiters { waiter.resume(throwing: AccessError(message)) }
            }
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let result = Result { try readDirectory(url) }.mapError { error -> Error in
                    if Self.isPermissionError(error) {
                        return AccessError("macOS denied Luna Mac access to \(path). Allow access in System Settings → Privacy & Security → Files and Folders or Full Disk Access, then retry in Luna.")
                    }
                    return error
                }
                lock.lock()
                let waiters = pending.removeValue(forKey: path)?.waiters ?? []
                if case .failure(let error) = result, error is AccessError { issues[path] = error.localizedDescription }
                else { issues[path] = nil }
                lock.unlock()
                for waiter in waiters { waiter.resume(with: result) }
            }
        }
        try Task.checkCancellation()
        return result
    }
    private static func isPermissionError(_ error: Error) -> Bool {
        let value = error as NSError
        if value.domain == NSPOSIXErrorDomain, [1, 13].contains(value.code) { return true }
        if value.domain == NSCocoaErrorDomain, [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(value.code) { return true }
        if let underlying = value.userInfo[NSUnderlyingErrorKey] as? Error { return isPermissionError(underlying) }
        return false
    }
    private struct AccessError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

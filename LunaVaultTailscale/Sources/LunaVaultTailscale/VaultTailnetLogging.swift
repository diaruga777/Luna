import Foundation
import TailscaleKit
import os

/// One subsystem for every Tailscale-path log line, so a device capture is
/// one predicate:
///   log stream --level debug --predicate 'subsystem == "com.hsanabria.luna.vault"'
/// Categories: tailnet (node lifecycle), tailnet-channel (frames),
/// tailnet-listener (companion accepts), tsnet-go (the Go engine's own log),
/// mac-client (Vault's wire client), mac-server (companion serve loop).
enum VaultTailnetLog {
    static let subsystem = "com.hsanabria.luna.vault"
    static let node = os.Logger(subsystem: subsystem, category: "tailnet")
    static let channel = os.Logger(subsystem: subsystem, category: "tailnet-channel")
    static let listener = os.Logger(subsystem: subsystem, category: "tailnet-listener")
    static let go = os.Logger(subsystem: subsystem, category: "tsnet-go")
}

/// Forwards the Go engine's log stream into the unified log line by line.
/// tsnet writes to a plain file descriptor; this pump owns a pipe, hands the
/// write end to the node, and relays the read end at debug level.
final class VaultTailnetGoLogPump: @unchecked Sendable {
    private let pipe = Pipe()
    private var buffer = Data()
    private let lock = NSLock()

    var writeFileDescriptor: Int32 { pipe.fileHandleForWriting.fileDescriptor }

    func start() {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.lock.lock()
            self.buffer.append(data)
            var lines: [String] = []
            while let newline = self.buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = self.buffer[self.buffer.startIndex..<newline]
                self.buffer.removeSubrange(self.buffer.startIndex...newline)
                if let text = String(data: Data(line), encoding: .utf8), !text.isEmpty {
                    lines.append(text)
                }
            }
            // Bound the partial-line buffer so a writer that never sends a
            // newline cannot grow it without limit.
            if self.buffer.count > 65_536 { self.buffer.removeAll(keepingCapacity: false) }
            self.lock.unlock()
            for line in lines {
                VaultTailnetLog.go.debug("\(line, privacy: .public)")
            }
        }
    }

    func stop() {
        pipe.fileHandleForReading.readabilityHandler = nil
        try? pipe.fileHandleForWriting.close()
        try? pipe.fileHandleForReading.close()
    }

    deinit { stop() }
}

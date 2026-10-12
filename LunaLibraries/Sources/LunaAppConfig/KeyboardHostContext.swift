import Foundation

/// A cooperative foreground lease. No document contents or app identifiers are recorded.
/// Writer renews it while active; a crash or missing shared-container access expires safely.
public enum KeyboardHostContext {
    public static let leaseDuration: TimeInterval = 6
    public static func publishWriter(active: Bool, container: URL? = AppConfig.sharedContainerURL(), now: Date = Date()) {
        guard let container else { return }
        let file = container.appendingPathComponent("writer-keyboard-host")
        if active {
            try? Data(String(now.timeIntervalSinceReferenceDate).utf8).write(to: file, options: .atomic)
        } else { try? FileManager.default.removeItem(at: file) }
    }
    public static func writerIsActive(container: URL? = AppConfig.sharedContainerURL(), now: Date = Date()) -> Bool {
        guard let container, let data = try? Data(contentsOf: container.appendingPathComponent("writer-keyboard-host")),
            data.count < 64, let text = String(data: data, encoding: .utf8), let timestamp = Double(text) else { return false }
        let age = now.timeIntervalSinceReferenceDate - timestamp
        return age >= 0 && age < leaseDuration
    }
}

#if os(iOS)
import UIKit
import BackgroundTasks
import LunaCodeCore

@MainActor public final class CodeNightlyScheduler {
    public static let shared = CodeNightlyScheduler()
    private let defaults = UserDefaults.standard
    private var perform: (() async throws -> Void)?
    private var identifier: String { (Bundle.main.bundleIdentifier ?? "com.hsanabria.luna.code") + ".overnight-builds" }
    public func register(perform: @escaping () async throws -> Void) {
        self.perform = perform
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            Task { @MainActor in
                guard let self, let task = task as? BGProcessingTask else { task.setTaskCompleted(success: false); return }
                // Re-enqueue before doing any work: expiration or a self-update
                // must not lose the next night's request.
                let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())) ?? Date().addingTimeInterval(86400)
                self.schedule(after: tomorrow)
                let work = Task { @MainActor in
                    do {
                        try await self.perform?()
                        try Task.checkCancellation()
                        task.setTaskCompleted(success: true)
                    } catch {
                        NSLog("Overnight build request failed: %@", error.localizedDescription)
                        task.setTaskCompleted(success: false)
                    }
                }
                task.expirationHandler = { work.cancel() }
            }
        }
        schedule()
    }
    public func schedule(peer: String? = nil, after date: Date = Date()) {
        if let peer { defaults.set(peer, forKey: "Code.nightlyPeer") }
        guard let peer = defaults.string(forKey: "Code.nightlyPeer"),
              CodeBuildCatalog(defaults: defaults).apps(peer: peer).contains(where: { $0.nightlyEnabled == true }) else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier); return
        }
        let request = BGProcessingTaskRequest(identifier: identifier)
        // The Mac does the expensive work. Allow battery operation and LANs
        // without Internet; the RPC path enforces local Wi-Fi itself.
        request.requiresExternalPower = false
        request.requiresNetworkConnectivity = false
        request.earliestBeginDate = CodeNightlySchedule.nextStart(after: date)
        do { try BGTaskScheduler.shared.submit(request) }
        catch { NSLog("Overnight build scheduling failed: %@", error.localizedDescription) }
    }
}
#endif

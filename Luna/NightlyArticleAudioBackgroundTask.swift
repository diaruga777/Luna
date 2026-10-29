import BackgroundTasks
import Foundation
import LunaAudioPlayback
import LunaStorage

/// iOS chooses the actual launch time. An eligibility date is not a deadline;
/// every launch and every network chunk must independently enforce the window.
@MainActor
enum NightlyArticleAudioBackgroundTask {
    static let taskID = "com.hsanabria.luna.nightlyArticleAudio"
    private static var scheduling = false

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: .main) { task in
            MainActor.assumeIsolated { handle(task) }
        }
    }

    static func schedule(skipCurrentWindow: Bool = false) {
        guard !LunaStage.isActive, !scheduling else { return }
        scheduling = true
        BGTaskScheduler.shared.getPendingTaskRequests { pending in
            Task { @MainActor in
                defer { scheduling = false }
                // Preserve a queued request rather than repeatedly postponing it.
                guard !pending.contains(where: { $0.identifier == taskID }) else { return }
                let request = BGProcessingTaskRequest(identifier: taskID)
                request.earliestBeginDate = NightlyArticleAudioWindow.nextStart(after: Date(), skipCurrentWindow: skipCurrentWindow)
                request.requiresNetworkConnectivity = true
                request.requiresExternalPower = false
                do {
                    try BGTaskScheduler.shared.submit(request)
                } catch {
                    DiagnosticLog.shared.record("nightly audio scheduling failed code=\((error as NSError).code)", category: "gemini-tts")
                }
            }
        }
    }

    private static func handle(_ task: BGTask) {
        // Chain first, including early/late launches, failures and expiration.
        schedule(skipCurrentWindow: true)
        guard let deadline = NightlyArticleAudioWindow.deadline(at: Date()), !LunaStage.isActive else {
            DiagnosticLog.shared.record("nightly audio skipped outside PST window", category: "gemini-tts")
            task.setTaskCompleted(success: true)
            return
        }
        // A deadline watchdog also cancels cache-lock waits and non-network work.
        // URLSession requests have the same absolute limit inside the renderer.
        let work = Task.detached(priority: .utility) {
            do {
                try Task.checkCancellation()
                try await GeminiArticleSpeech.shared.pruneAudio(for: SavesStore.shared.items())
                try await NightlyArticleAudio.run()
                return true
            } catch {
                DiagnosticLog.shared.record("nightly audio stopped error=\(String(describing: type(of: error))) code=\((error as NSError).code)", category: "gemini-tts")
                return false
            }
        }
        let deadlineWatch = Task {
            do {
                try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
                work.cancel()
            } catch { }
        }
        task.expirationHandler = {
            work.cancel()
            deadlineWatch.cancel()
        }
        Task {
            let success = await work.value
            deadlineWatch.cancel()
            task.setTaskCompleted(success: success && !work.isCancelled)
        }
    }
}

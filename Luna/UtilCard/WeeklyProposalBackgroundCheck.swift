//
//  WeeklyProposalBackgroundCheck.swift
//  Luna
//

import BackgroundTasks
import LunaStorage
import LunaWeekly
import UIKit

/// The curator's inbox poll, off-app.
///
/// Registered by every app unconditionally (a `BGTaskScheduler` identifier must
/// be claimed before `didFinishLaunching` returns, and whether this device
/// holds the key can change afterwards), but both the scheduler and the
/// handler no-op unless it actually does. Nothing here can fail loudly: with no
/// container provisioned the fetch simply errors and the task completes.
enum WeeklyProposalBackgroundCheck {
    static let taskID = "com.hsanabria.luna.weeklyProposalCheck"
    /// Proposals are not urgent; four hours is plenty, and iOS will stretch it.
    static let interval: TimeInterval = 4 * 60 * 60

    static func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskID, using: nil
        ) { task in
            handle(task as? BGAppRefreshTask)
        }
    }

    /// Idempotent, like `schedulePriceRefresh`: repeatedly cancelling and
    /// resubmitting a BGTask churns it so iOS never lets it mature.
    static func schedule(reason: String) {
        guard WeeklyPromotionKeyStore.isKeyHolder else { return }
        BGTaskScheduler.shared.getPendingTaskRequests { pending in
            guard !pending.contains(where: { $0.identifier == taskID }) else { return }
            let request = BGAppRefreshTaskRequest(identifier: taskID)
            request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
            do {
                try BGTaskScheduler.shared.submit(request)
                DiagnosticLog.shared.record(
                    "weekly proposal check scheduled (\(reason))", category: "weekly")
            } catch {
                DiagnosticLog.shared.record(
                    "weekly proposal check schedule FAILED (\(reason)): \(error)",
                    category: "weekly")
            }
        }
    }

    private static func handle(_ task: BGAppRefreshTask?) {
        guard let task else { return }
        schedule(reason: "background chain")
        // Expiration handler first, before any work can start.
        var work: Task<Void, Never>?
        task.expirationHandler = { work?.cancel() }
        work = Task { @MainActor in
            await WeeklySaveRefresher.shared.checkProposalsIfKeyHolder()
            task.setTaskCompleted(success: !Task.isCancelled)
        }
    }
}

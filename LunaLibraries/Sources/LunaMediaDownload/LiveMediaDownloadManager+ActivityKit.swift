//
//  LiveMediaDownloadManager+ActivityKit.swift
//  Luna
//

import Foundation
import LunaModels
import LunaStorage
import LunaURLClassification

#if canImport(ActivityKit)
import ActivityKit
#endif

#if canImport(ActivityKit)
@available(iOS 16.1, *)
private extension LiveMediaDownloadAttributes.ContentState.Phase {
    init(jobPhase: LiveMediaDownloadJob.Phase) {
        switch jobPhase {
        case .resolving: self = .resolving
        case .downloading: self = .downloading
        case .waiting: self = .waiting
        case .suspended: self = .suspended
        case .saving: self = .saving
        case .finished: self = .finished
        case .failed: self = .failed
        }
    }
}
#endif

extension LiveMediaDownloadManager {
    /// `announce` fires a system alert (banner + sound) the moment the Live
    /// Activity appears, so a download starting reads as more than a silent
    /// Dynamic Island update. Suppressed for `startFailedActivity`, which
    /// never actually starts a download — only its (single) end-of-life alert
    /// should fire there, and while alerts are suspended altogether
    /// (`areActivityAlertsSuspended` — a bulk import).
    func startActivity(for job: LiveMediaDownloadJob, announce: Bool = true) async {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *), ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // The system is already showing progress for this work (an App Intent
        // running under `LongRunningIntent`) — prefer it and don't stack a second
        // activity on top. Scoped to the intent's awaited leg only.
        guard !Self.systemProvidesProgressUI else {
            SharedDiagnosticLog.record(
                "live activity suppressed: system intent progress UI owns \(job.sourceURLString)",
                category: "media-download")
            return
        }
        let attributes = LiveMediaDownloadAttributes(
            jobID: job.id,
            sourceURLString: job.sourceURLString,
            title: job.title)
        let state = activityState(for: job)
        do {
            let activity = try Activity.request(attributes: attributes, contentState: state, pushType: nil)
            if announce, !Self.areActivityAlertsSuspended {
                await activity.update(
                    using: state,
                    alertConfiguration: AlertConfiguration(
                        title: L10n.resource("Downloader_liveActivity_alert_downloadStartedTitle"),
                        body: "\(job.title)",
                        sound: .default))
            }
        } catch {
            SharedDiagnosticLog.record(
                "live activity request failed: \(error)", category: "media-download")
        }
        #endif
    }

    func startFailedActivity(
        urlString: String,
        title: String?,
        message: String,
        errorKind: LiveMediaDownloadJob.ErrorKind = .download
    ) async {
        var job = LiveMediaDownloadJob(
            id: UUID().uuidString,
            sourceURLString: urlString,
            assetURLString: nil,
            mediaKind: nil,
            title: title ?? L10n.string("Downloader_liveActivity_defaultTitle"),
            resolveKind: nil,
            phase: .failed,
            progress: 0,
            thumbnailFileName: nil,
            fileExtension: nil,
            expectedByteCount: nil,
            receivedByteCount: nil,
            resumeDataFileName: nil,
            timeRange: nil,
            resolvedVideoID: nil,
            youtubeVisitorData: nil,
            errorMessage: message,
            errorKind: errorKind,
            resolveAttempts: 0,
            mediaAttempts: 0,
            suspendDeadline: nil,
            ownership: MediaAutoDownloader.isRunningInDownloader ? .downloader : .invokingApp
        )
        job.fail(message: message, kind: errorKind)
        await startActivity(for: job, announce: false)
        await endActivity(for: job, dismissalDelay: Self.failureDismissalDelay)
    }

    /// `alerting` fires the end-of-life system alert (banner + sound) with this
    /// update instead of leaving it to `endActivity` — which is how the FINISHED
    /// state can alert and still stay live afterwards (see `finishedLiveHold`).
    func updateActivity(for job: LiveMediaDownloadJob, alerting: Bool = false) async {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *) else { return }
        let state = activityState(for: job)
        let alert = alerting ? Self.endOfLifeAlert(for: job) : nil
        for activity in Activity<LiveMediaDownloadAttributes>.activities
            where activity.attributes.jobID == job.id {
            if let alert {
                await activity.update(using: state, alertConfiguration: alert)
            } else {
                await activity.update(using: state)
            }
        }
        #endif
    }

    func endActivity(for job: LiveMediaDownloadJob, dismissalDelay: TimeInterval = 20) async {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *) else { return }
        let state = activityState(for: job)
        let alert = Self.endOfLifeAlert(for: job)
        for activity in Activity<LiveMediaDownloadAttributes>.activities
            where activity.attributes.jobID == job.id {
            if let alert {
                await activity.update(using: state, alertConfiguration: alert)
            }
            await activity.end(using: state, dismissalPolicy: .after(Date(timeIntervalSinceNow: dismissalDelay)))
        }
        #endif
    }

    /// Ends every activity for `jobID` right now — no alert, and no lingering
    /// lock-screen tail. The second half of the finished flow (the live hold has
    /// already shown the completed card and its alert already fired with the
    /// `.finished` update), and the orphan reaper's one tool.
    func endActivitiesImmediately(jobID: String) async {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *) else { return }
        for activity in Activity<LiveMediaDownloadAttributes>.activities
            where activity.attributes.jobID == jobID {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        #endif
    }

    /// Ends any activity whose job is gone from `keepingJobIDs` — a card
    /// stranded by a process death inside the finished live hold, or by any
    /// other termination between `store.remove` and `end`. Nothing else can
    /// clear it: an activity outlives the process that requested it, and a job
    /// that no longer exists will never reach an end call of its own. Cards
    /// mid-hold in THIS process are in `keepingJobIDs` too, so a foreground
    /// while one is on screen doesn't cut its five seconds short.
    ///
    /// Only `.active` activities are reaped. An already-ENDED one is a failure
    /// card living out its `failureDismissalDelay` on the Lock Screen with its
    /// job already removed — deliberate, and not this sweep's business.
    func reapOrphanedActivities(keepingJobIDs: Set<String>) async {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *) else { return }
        for activity in Activity<LiveMediaDownloadAttributes>.activities
            where activity.activityState == .active
                && !keepingJobIDs.contains(activity.attributes.jobID) {
            SharedDiagnosticLog.record(
                "reaped orphaned live activity for job \(activity.attributes.jobID)",
                category: "media-download")
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        #endif
    }

    #if canImport(ActivityKit)
    /// The one end-of-life alert definition, shared by the finished update and
    /// `endActivity`. A silent Dynamic Island collapse is easy to miss, so both
    /// a successful finish and a failure surface as a system alert (banner +
    /// sound), matching the one at start. Not for a user-canceled (still
    /// `.suspended` when torn down) job — that's an intentional dismissal, not
    /// a result worth alerting about — and not while alerts are suspended (a
    /// bulk import, where every transfer's start and finish would buzz over the
    /// import's own progress bar).
    @available(iOS 16.1, *)
    static func endOfLifeAlert(for job: LiveMediaDownloadJob) -> AlertConfiguration? {
        switch job.phase {
        case .finished, .failed:
            guard !areActivityAlertsSuspended else { return nil }
            return AlertConfiguration(
                title: job.phase == .failed
                    ? L10n.resource("Downloader_liveActivity_status_downloadFailed")
                    : L10n.resource("Downloader_liveActivity_alert_downloadFinishedTitle"),
                body: "\(job.title)",
                sound: .default)
        default:
            return nil
        }
    }
    #endif

    /// Tears every Live Activity down at once, immediately and without an alert
    /// — the factory reset's media leg, installed on `FactoryReset` by the media
    /// composition roots. An activity outlives the process that started it, so a
    /// wiped install would otherwise leave a lock-screen card describing a
    /// download whose job file is gone.
    public func endAllActivities() async {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *) else { return }
        for activity in Activity<LiveMediaDownloadAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        #endif
    }

    #if canImport(ActivityKit)
    @available(iOS 16.1, *)
    func activityState(for job: LiveMediaDownloadJob) -> LiveMediaDownloadAttributes.ContentState {
        LiveMediaDownloadAttributes.ContentState(
            phase: .init(jobPhase: job.phase),
            progress: job.progress,
            mediaKind: .init(job.mediaKind),
            message: job.statusMessage,
            thumbnailFileName: job.thumbnailFileName,
            // Reopen the app this download is running in — each app registers
            // only its own scheme now, so this can't hardcode Reader's.
            actionURLString: job.errorKind == .photosPermission
                ? "\(LunaDeepLink.ownScheme)://settings/photos" : nil,
            suspendDeadline: job.suspendDeadline,
            // Tap-anywhere-on-the-activity, every phase including `.finished`
            // — opening the app on the downloading/downloaded card is correct
            // and harmless even mid-transfer. Built here (not in the widget)
            // because this file already imports LunaDeepLink; the widget
            // target links only LunaMediaDownload + LunaDesignSystem.
            viewURLString: LunaDeepLink.mediaViewLink(
                scheme: LunaDeepLink.ownScheme, sourceURLString: job.sourceURLString
            )?.absoluteString,
            // The finished card's Share button: the same `media` route plus
            // `&share=1`, which asks the app to hand the downloaded file to the
            // system share sheet rather than just centering on its card. Built
            // here for the same reason `viewURLString` is.
            shareURLString: LunaDeepLink.mediaShareLink(
                scheme: LunaDeepLink.ownScheme, sourceURLString: job.sourceURLString
            )?.absoluteString
        )
    }
    #endif
}

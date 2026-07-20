//
//  LiveMediaDownloadManager+ActivityKit.swift
//  Luna
//

import Foundation
import LunaStorage
import LunaURLClassification

#if canImport(ActivityKit)
import ActivityKit
#endif

#if canImport(ActivityKit)
@available(iOS 16.1, *)
private extension LiveMediaDownloadAttributes.MediaKind {
    init(rawJobValue: String) {
        self = LiveMediaDownloadAttributes.MediaKind(rawValue: rawJobValue) ?? .unknown
    }
}

@available(iOS 16.1, *)
private extension LiveMediaDownloadAttributes.ContentState.Phase {
    init(jobPhase: LiveMediaDownloadJob.Phase) {
        switch jobPhase {
        case .resolving: self = .resolving
        case .downloading: self = .downloading
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
    /// should fire there.
    func startActivity(for job: LiveMediaDownloadJob, announce: Bool = true) async {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *), ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = LiveMediaDownloadAttributes(
            jobID: job.id,
            sourceURLString: job.sourceURLString,
            title: job.title)
        let state = activityState(for: job)
        do {
            let activity = try Activity.request(attributes: attributes, contentState: state, pushType: nil)
            if announce {
                await activity.update(
                    using: state,
                    alertConfiguration: AlertConfiguration(
                        title: "Download started", body: "\(job.title)", sound: .default))
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
            mediaKind: "unknown",
            title: title ?? "Media download",
            creator: nil,
            resolveKind: nil,
            phase: .failed,
            progress: 0,
            thumbnailFileName: nil,
            fileExtension: nil,
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

    func updateActivity(for job: LiveMediaDownloadJob) async {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *) else { return }
        let state = activityState(for: job)
        for activity in Activity<LiveMediaDownloadAttributes>.activities
            where activity.attributes.jobID == job.id {
            await activity.update(using: state)
        }
        #endif
    }

    func endActivity(for job: LiveMediaDownloadJob, dismissalDelay: TimeInterval = 20) async {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *) else { return }
        let state = activityState(for: job)
        // A final alert right before ending — a silent Dynamic Island collapse
        // is easy to miss, so both a successful finish and a failure surface
        // as a system alert (banner + sound), matching the one at start. Not
        // for a user-canceled (still `.suspended` when torn down) job — that's
        // an intentional dismissal, not a result worth alerting about.
        var alert: AlertConfiguration?
        switch job.phase {
        case .finished, .failed:
            alert = AlertConfiguration(
                title: job.phase == .failed ? "Download failed" : "Download finished",
                body: "\(job.title)",
                sound: .default)
        default:
            alert = nil
        }
        for activity in Activity<LiveMediaDownloadAttributes>.activities
            where activity.attributes.jobID == job.id {
            if let alert {
                await activity.update(using: state, alertConfiguration: alert)
            }
            await activity.end(using: state, dismissalPolicy: .after(Date(timeIntervalSinceNow: dismissalDelay)))
        }
        #endif
    }

    #if canImport(ActivityKit)
    @available(iOS 16.1, *)
    func activityState(for job: LiveMediaDownloadJob) -> LiveMediaDownloadAttributes.ContentState {
        LiveMediaDownloadAttributes.ContentState(
            phase: .init(jobPhase: job.phase),
            progress: job.progress,
            mediaKind: .init(rawJobValue: job.mediaKind),
            message: job.statusMessage,
            thumbnailFileName: job.thumbnailFileName,
            // Reopen the app this download is running in — each app registers
            // only its own scheme now, so this can't hardcode Reader's.
            actionURLString: job.errorKind == .photosPermission
                ? "\(LunaDeepLink.ownScheme)://settings/photos" : nil,
            suspendDeadline: job.suspendDeadline
        )
    }
    #endif
}

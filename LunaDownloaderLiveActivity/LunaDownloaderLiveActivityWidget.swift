//
//  LunaDownloaderLiveActivityWidget.swift
//  LunaDownloaderLiveActivity
//

import ActivityKit
import AppIntents
import LunaDesignSystem
import LunaMediaDownload
import LunaModels
import SwiftUI
import UIKit
import WidgetKit

struct SuspendLiveMediaDownloadIntent: AppIntent {
    static var title: LocalizedStringResource = "Intents_cancelLiveDownload_title_Luna"
    static var description = IntentDescription("Intents_cancelLiveDownload_description_Luna")

    @Parameter(title: "Intents_cancelLiveDownload_jobIDParam_title_Luna")
    var jobID: String

    init() {}

    init(jobID: String) {
        self.jobID = jobID
    }

    func perform() async throws -> some IntentResult {
        await LiveMediaDownloadManager.shared.suspend(jobID: jobID)
        return .result()
    }
}

struct ResumeLiveMediaDownloadIntent: AppIntent {
    static var title: LocalizedStringResource = "Intents_resumeLiveDownload_title_Luna"
    static var description = IntentDescription("Intents_resumeLiveDownload_description_Luna")

    @Parameter(title: "Intents_resumeLiveDownload_jobIDParam_title_Luna")
    var jobID: String

    init() {}

    init(jobID: String) {
        self.jobID = jobID
    }

    func perform() async throws -> some IntentResult {
        await LiveMediaDownloadManager.shared.resume(jobID: jobID)
        return .result()
    }
}

/// Tap-anywhere-on-the-activity target, every phase including `.finished` —
/// opening the app on the downloading/downloaded card is correct and
/// harmless regardless of where the transfer is. Built once by
/// `LiveMediaDownloadManager.activityState(for:)` (which can import
/// `LunaDeepLink`; this target links only `LunaMediaDownload` +
/// `LunaDesignSystem`) rather than assembled here.
private func viewURL(for state: LiveMediaDownloadAttributes.ContentState) -> URL? {
    state.viewURLString.flatMap(URL.init(string:))
}

/// The finished card's Share target — the same `media` route plus `&share=1`,
/// prebuilt by `activityState(for:)` for the same reason `viewURLString` is.
private func shareURL(for state: LiveMediaDownloadAttributes.ContentState) -> URL? {
    state.shareURLString.flatMap(URL.init(string:))
}

struct LunaDownloaderLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LiveMediaDownloadAttributes.self) { context in
            DownloadActivityView(context: context)
                .activityBackgroundTint(Color(.systemBackground))
                .activitySystemActionForegroundColor(.primary)
                .widgetURL(viewURL(for: context.state))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ThumbnailView(state: context.state)
                        .frame(width: 48, height: 48)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(context.attributes.title)
                            .font(.headline)
                            .lineLimit(1)
                        if context.state.phase == .failed {
                            Text(context.state.message)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .lineLimit(2)
                        }
                    }
                    .widgetURL(viewURL(for: context.state))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        // A finished card reads as done: no progress track, and
                        // the two things there are left to do with the file.
                        if context.state.phase != .failed, context.state.phase != .finished {
                            MoonHorizonProgressView(progress: context.state.progress)
                                .frame(height: 20)
                        }
                        HStack(spacing: 10) {
                            Text(context.state.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            ActivityControlButton(context: context)
                        }
                        if context.state.phase == .finished {
                            FinishedActionsView(state: context.state)
                        }
                    }
                }
            } compactLeading: {
                ThumbnailView(state: context.state)
            } compactTrailing: {
                if context.state.phase == .failed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                } else if context.state.phase == .finished {
                    // A percentage that has nowhere left to go reads as a stalled
                    // transfer; the completed card says so instead.
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel(
                            L10n.string("LiveActivity_downloader_finishedAccessibilityLabel"))
                } else if context.state.phase == .suspended {
                    Image(systemName: "arrow.clockwise.circle.fill")
                } else {
                    Text("\(Int(context.state.progress * 100))%")
                        .font(.caption2.monospacedDigit())
                }
            } minimal: {
                Image(systemName: context.state.phase == .failed ? "exclamationmark.triangle.fill" : "arrow.down.circle")
                    .foregroundStyle(context.state.phase == .failed ? .red : .primary)
            }
        }
    }
}

private struct DownloadActivityView: View {
    let context: ActivityViewContext<LiveMediaDownloadAttributes>

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 12) {
                ThumbnailView(state: context.state)
                    .frame(width: 64, height: 64)

                VStack(alignment: .leading, spacing: 8) {
                    Text(context.attributes.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(context.state.message)
                        .font(.subheadline)
                        .foregroundStyle(context.state.phase == .failed ? .red : .secondary)
                        .lineLimit(2)
                    if context.state.phase == .failed,
                       let actionURL = context.state.actionURLString.flatMap(URL.init(string:)) {
                        Link(destination: actionURL) {
                            Label(L10n.string("LiveActivity_downloader_openPhotosSettingsLabel"), systemImage: "gearshape")
                                .font(.caption.weight(.semibold))
                        }
                    }
                }

                if context.state.phase != .failed {
                    Spacer(minLength: 0)
                    ActivityControlButton(context: context)
                }
            }
            // The moon horizon spans the full width of the activity, below the
            // row — except once the transfer is done, where a full track would
            // read as a stalled progress bar rather than a result. The finished
            // card puts its two actions in that space instead.
            if context.state.phase == .finished {
                FinishedActionsView(state: context.state)
            } else if context.state.phase != .failed {
                MoonHorizonProgressView(progress: context.state.progress)
                    .frame(height: 24)
            }
        }
        .padding(.vertical, 4)
    }
}

/// The finished card's two affordances. `Link`s rather than buttons: a widget
/// cannot present anything itself, so each one opens the app on a route that
/// does — Play on the tap-to-view link (the same one the whole card carries),
/// Share on that route plus `&share=1`, which raises the system share sheet
/// over the downloaded file (`SceneDelegate.openMediaDeepLink`).
private struct FinishedActionsView: View {
    let state: LiveMediaDownloadAttributes.ContentState

    var body: some View {
        HStack(spacing: 10) {
            if let playURL = viewURL(for: state) {
                Link(destination: playURL) {
                    Label(
                        L10n.string("LiveActivity_downloader_playButtonLabel"),
                        systemImage: "play.fill")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .accessibilityLabel(
                    L10n.string("LiveActivity_downloader_playButtonAccessibilityLabel"))
            }
            if let shareURL = shareURL(for: state) {
                Link(destination: shareURL) {
                    Label(
                        L10n.string("LiveActivity_downloader_shareButtonLabel"),
                        systemImage: "square.and.arrow.up")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .accessibilityLabel(
                    L10n.string("LiveActivity_downloader_shareButtonAccessibilityLabel"))
            }
        }
    }
}

private struct ActivityControlButton: View {
    let context: ActivityViewContext<LiveMediaDownloadAttributes>

    var body: some View {
        switch context.state.phase {
        case .resolving, .downloading:
            Button(intent: SuspendLiveMediaDownloadIntent(jobID: context.attributes.jobID)) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.string("LiveActivity_downloader_cancelButtonAccessibilityLabel"))
        case .suspended, .waiting:
            Button(intent: ResumeLiveMediaDownloadIntent(jobID: context.attributes.jobID)) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.string("LiveActivity_downloader_resumeButtonAccessibilityLabel"))
        default:
            EmptyView()
        }
    }
}

private struct ThumbnailView: View {
    let state: LiveMediaDownloadAttributes.ContentState

    var body: some View {
        ZStack {
            if let image = thumbnailImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(state.phase == .failed ? .red.opacity(0.12) : .secondary.opacity(0.18))
                Image(systemName: state.phase == .failed ? "exclamationmark.triangle.fill" : "photo")
                    .foregroundStyle(state.phase == .failed ? .red : .secondary)
            }
            Badge(kind: state.mediaKind)
                .padding(5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var thumbnailImage: UIImage? {
        guard let fileName = state.thumbnailFileName else { return nil }
        return UIImage(contentsOfFile: LiveMediaDownloadAssets.thumbnailURL(fileName: fileName).path)
    }
}

private struct Badge: View {
    let kind: LiveMediaDownloadAttributes.MediaKind

    var body: some View {
        switch kind {
        case .video:
            Image(systemName: "play.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .padding(8)
                .background(.black.opacity(0.55), in: Circle())
        case .animatedImage:
            Image(systemName: "rectangle.on.rectangle")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .padding(7)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
        default:
            EmptyView()
        }
    }
}

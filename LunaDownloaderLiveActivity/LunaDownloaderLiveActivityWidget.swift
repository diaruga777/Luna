//
//  LunaDownloaderLiveActivityWidget.swift
//  LunaDownloaderLiveActivity
//

import ActivityKit
import LunaMediaDownload
import SwiftUI
import UIKit
import WidgetKit

struct LunaDownloaderLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LiveMediaDownloadAttributes.self) { context in
            DownloadActivityView(context: context)
                .activityBackgroundTint(Color(.systemBackground))
                .activitySystemActionForegroundColor(.primary)
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
                        } else {
                            ProgressView(value: context.state.progress)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                ThumbnailView(state: context.state)
            } compactTrailing: {
                if context.state.phase == .failed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
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
                if context.state.phase == .failed {
                    if let actionURL = context.state.actionURLString.flatMap(URL.init(string:)) {
                        Link(destination: actionURL) {
                            Label("Open Photos Settings", systemImage: "gearshape")
                                .font(.caption.weight(.semibold))
                        }
                    }
                } else {
                    ProgressView(value: context.state.progress)
                        .tint(.accentColor)
                }
            }
        }
        .padding(.vertical, 4)
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

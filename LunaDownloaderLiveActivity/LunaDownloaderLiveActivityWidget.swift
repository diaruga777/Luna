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
                        ProgressView(value: context.state.progress)
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
                Text("\(Int(context.state.progress * 100))%")
                    .font(.caption2.monospacedDigit())
            } minimal: {
                Image(systemName: "arrow.down.circle")
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
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                ProgressView(value: context.state.progress)
                    .tint(.accentColor)
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
                    .fill(.secondary.opacity(0.18))
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
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

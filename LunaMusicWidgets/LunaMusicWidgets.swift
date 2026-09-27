import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main struct LunaMusicWidgetBundle: WidgetBundle {
    var body: some Widget {
        LunaMusicLibraryWidget()
        LunaMusicQueueActivity()
        LunaMusicPlaybackControl()
        LunaMusicNextControl()
    }
}

private struct MusicTransport: View {
    let isPlaying: Bool
    var body: some View {
        HStack(spacing: 30) {
            Button(intent: PreviousMusicTrackIntent()) { Image(systemName: "backward.fill") }
                .accessibilityLabel("Previous Song")
            Button(intent: ToggleMusicPlaybackIntent()) { Image(systemName: isPlaying ? "pause.fill" : "play.fill") }
                .accessibilityLabel(isPlaying ? "Pause" : "Play")
            Button(intent: NextMusicTrackIntent()) { Image(systemName: "forward.fill") }
                .accessibilityLabel("Next Song")
        }
        .font(.title2).buttonStyle(.plain)
    }
}

private struct MusicProgress: View {
    let state: MusicActivityAttributes.ContentState
    var body: some View {
        if state.duration > 0 {
            if state.isPlaying {
                ProgressView(timerInterval: state.playbackStart...state.playbackStart.addingTimeInterval(state.duration), countsDown: false)
                    .tint(.white)
            } else {
                ProgressView(value: min(state.elapsed, state.duration), total: state.duration).tint(.white)
            }
        }
    }
}

struct LunaMusicQueueActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MusicActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "music.note").font(.largeTitle).foregroundStyle(.pink)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(context.isStale ? "Playback Queue" : context.state.title).font(.headline).lineLimit(1)
                        Text(context.isStale ? "Open Luna Music to refresh" : context.state.artist).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "list.bullet").accessibilityLabel("Playback Queue")
                }
                if !context.isStale, let next = context.state.nextTitle {
                    Text("Next: \(next)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if !context.isStale {
                    MusicProgress(state: context.state)
                    HStack { Spacer(); MusicTransport(isPlaying: context.state.isPlaying); Spacer() }
                } else {
                    Text("Open your queue to refresh playback").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding().activityBackgroundTint(.black.opacity(0.8)).activitySystemActionForegroundColor(.white)
            .widgetURL(URL(string: "lunamusic://queue"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "music.note").foregroundStyle(.pink).font(.title2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Image(systemName: "list.bullet").accessibilityLabel("Playback Queue")
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 3) {
                        Text(context.isStale ? "Playback Queue" : context.state.title).font(.headline).lineLimit(1)
                        Text(context.isStale ? "Open Luna Music to refresh" : context.state.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 12) {
                        if !context.isStale, let next = context.state.nextTitle {
                            Text("Next: \(next)").font(.caption).lineLimit(1)
                        }
                        if !context.isStale {
                            MusicProgress(state: context.state)
                            MusicTransport(isPlaying: context.state.isPlaying)
                        }
                    }.padding(.top, 8)
                }
            } compactLeading: {
                Image(systemName: "music.note").foregroundStyle(.pink)
            } compactTrailing: {
                Image(systemName: context.isStale ? "list.bullet" : (context.state.isPlaying ? "waveform" : "pause.fill")).foregroundStyle(.pink)
            } minimal: {
                Image(systemName: "music.note").foregroundStyle(.pink)
            }
            .widgetURL(URL(string: "lunamusic://queue"))
        }
    }
}

private struct MusicEntry: TimelineEntry {
    var date: Date
    var snapshot: MusicWidgetSnapshot?
}

private struct MusicTimeline: TimelineProvider {
    func placeholder(in context: Context) -> MusicEntry { MusicEntry(date: Date(), snapshot: nil) }
    func getSnapshot(in context: Context, completion: @escaping (MusicEntry) -> Void) {
        completion(MusicEntry(date: Date(), snapshot: MusicWidgetSnapshot.read()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<MusicEntry>) -> Void) {
        let snapshot = MusicWidgetSnapshot.read()
        var entries = [MusicEntry(date: Date(), snapshot: snapshot)]
        if let snapshot { entries.append(MusicEntry(date: snapshot.expiresAt, snapshot: nil)) }
        completion(Timeline(entries: entries, policy: .after(Date().addingTimeInterval(900))))
    }
}

struct LunaMusicLibraryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: MusicWidgetSnapshot.kind, provider: MusicTimeline()) { entry in
            MusicWidgetView(entry: entry).containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Luna Music")
        .description("Your playback queue and library search.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular])
    }
}

private struct MusicWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: MusicEntry
    var body: some View {
        Group {
            if family == .accessoryCircular {
                Image(systemName: "music.note").widgetAccentable()
            } else if family == .accessoryRectangular {
                VStack(alignment: .leading) {
                    Text(entry.snapshot?.state.title ?? "Luna Music").font(.headline).lineLimit(1)
                    Text(entry.snapshot?.state.artist ?? "Search your library").font(.caption).lineLimit(1)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "music.note").foregroundStyle(.pink)
                        Text("Luna Music").font(.caption.weight(.semibold))
                        Spacer()
                        Link(destination: URL(string: "lunamusic://search")!) { Image(systemName: "magnifyingglass") }
                            .accessibilityLabel("Search Library")
                    }
                    Spacer(minLength: 0)
                    Text(entry.snapshot?.state.title ?? "Your Library").font(.headline).lineLimit(2)
                    Text(entry.snapshot?.state.artist ?? "Find a song, album, artist, or playlist")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer(minLength: 0)
                    if let snapshot = entry.snapshot {
                        MusicTransport(isPlaying: snapshot.state.isPlaying)
                    } else {
                        Link("Search Library", destination: URL(string: "lunamusic://search")!).font(.caption.bold())
                    }
                }
            }
        }
        .widgetURL(URL(string: entry.snapshot == nil ? "lunamusic://search" : "lunamusic://queue"))
    }
}

struct LunaMusicPlaybackControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "LunaMusicPlaybackControl") {
            ControlWidgetButton(action: ToggleMusicPlaybackIntent()) {
                Label("Play / Pause", systemImage: "playpause.fill")
            }
        }
        .displayName("Luna Music Playback").description("Play or pause your current queue.")
    }
}

struct LunaMusicNextControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "LunaMusicNextControl") {
            ControlWidgetButton(action: NextMusicTrackIntent()) {
                Label("Next Song", systemImage: "forward.fill")
            }
        }
        .displayName("Next in Luna Music").description("Skip to the next song in your queue.")
    }
}

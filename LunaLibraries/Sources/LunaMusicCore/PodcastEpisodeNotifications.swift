import Foundation
import ImageIO
import UserNotifications
import LunaPodcastCore

/// Local episode alerts. Delivery IDs are stable across an interrupted outbox drain.
@MainActor public final class PodcastEpisodeNotifications {
    public static let shared = PodcastEpisodeNotifications()
    public static let categoryID = "podcast.new-episode"
    public static let addToQueueID = "podcast.add-to-queue"
    public static let playNextID = "podcast.play-next"
    private let center = UNUserNotificationCenter.current()
    private var delivering = false

    public enum Action: Equatable { case open, addToQueue, playNext, ignore }
    public static func action(for identifier: String) -> Action {
        switch identifier {
        case UNNotificationDefaultActionIdentifier: return .open
        case addToQueueID: return .addToQueue
        case playNextID: return .playNext
        default: return .ignore
        }
    }
    public func register() {
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.categoryID, actions: [
            UNNotificationAction(identifier: Self.addToQueueID, title: "Add to Queue", options: [], icon: UNNotificationActionIcon(systemImageName: "text.line.last.and.arrowtriangle.forward")),
            UNNotificationAction(identifier: Self.playNextID, title: "Play Next", options: [], icon: UNNotificationActionIcon(systemImageName: "text.line.first.and.arrowtriangle.forward"))
        ], intentIdentifiers: [], options: [])])
    }
    /// Following succeeds even if the listener declines system notification permission.
    public func requestPermissionIfNeeded() async {
        guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }
    public static func content(show: PodcastShow, episode: PodcastEpisode) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "New \(show.title)"
        content.body = episode.title
        content.sound = .default
        content.categoryIdentifier = categoryID
        content.threadIdentifier = "podcast.\(show.id)"
        content.userInfo = ["podcastEpisodeID": episode.id]
        return content
    }
    public func deliverPending(in library: PodcastLibraryController) async {
        guard !delivering, !(library.state.pendingNotificationEpisodeIDs ?? []).isEmpty else { return }
        delivering = true
        defer { delivering = false }
        let status = await center.notificationSettings().authorizationStatus
        let allowed = status == .authorized || status == .provisional || status == .ephemeral
        let delivered = Set(await center.deliveredNotifications().map { $0.request.identifier })
        for id in library.state.pendingNotificationEpisodeIDs ?? [] {
            guard !Task.isCancelled else { return }
            do {
                if allowed, let episode = library.state.episodes[id],
                   let show = library.state.shows[episode.showID], show.followed, show.settings.notifications {
                    let identifier = "podcast.\(show.id).\(id)"
                    if !delivered.contains(identifier) {
                        let content = Self.content(show: show, episode: episode)
                        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("podcast-alert-\(UUID().uuidString)", isDirectory: true)
                        defer { try? FileManager.default.removeItem(at: directory) }
                        if let url = show.artworkURL,
                           let attachment = try? await Self.artwork(url, directory: directory) { content.attachments = [attachment] }
                        try Task.checkCancellation()
                        // Settings can change while fetching artwork.
                        if let current = library.state.shows[episode.showID], current.followed, current.settings.notifications {
                            try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
                        }
                    }
                }
                // Disabled/denied alerts are discarded, never replayed as a backlog.
                try library.edit { $0.pendingNotificationEpisodeIDs?.removeAll { $0 == id } }
            } catch {
                library.report(error)
                return // Retain the outbox entry for the next refresh/launch.
            }
        }
    }
    public func removeAlerts(for showID: String) async {
        let prefix = "podcast.\(showID)."
        let delivered = await center.deliveredNotifications().map { $0.request.identifier }.filter { $0.hasPrefix(prefix) }
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
        center.removeDeliveredNotifications(withIdentifiers: delivered)
        center.removePendingNotificationRequests(withIdentifiers: pending)
    }
    /// Uses exactly the same store operation as the episode menu; never starts playback.
    public func enqueue(_ episodeID: String, next: Bool, in library: PodcastLibraryController) throws {
        try library.requireStore().enqueue(episodeID, next: next)
        library.reloadState()
    }
    nonisolated private static func artwork(_ url: URL, directory: URL) async throws -> UNNotificationAttachment? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let (file, response) = try await PodcastNetwork.session.download(for: request)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 10 * 1_024 * 1_024 else { return nil }
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 512
              ] as CFDictionary) else { return nil }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent("podcast.jpg")
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return try UNNotificationAttachment(identifier: "podcast-artwork", url: output, options: [UNNotificationAttachmentOptionsThumbnailHiddenKey: false])
    }
}

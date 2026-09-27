import Foundation

enum MusicLaunchRoute: Equatable {
    case search, queue

    init?(url: URL) {
        guard url.scheme?.lowercased() == "lunamusic" else { return nil }
        switch url.host?.lowercased() {
        case "queue": self = .queue
        case "search", "library": self = .search
        default: return nil
        }
    }
}

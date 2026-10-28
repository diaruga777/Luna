import Foundation

enum MusicLaunchRoute: Equatable {
    case search, queue
    case reader(UUID?)

    init?(url: URL) {
        guard url.scheme?.lowercased() == "lunamusic" else { return nil }
        switch url.host?.lowercased() {
        case "reader":
            let values = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.filter { $0.name == "save" } ?? []
            if values.isEmpty { self = .reader(nil) }
            else {
                guard values.count == 1, let value = values.first?.value, let id = UUID(uuidString: value) else { return nil }
                self = .reader(id)
            }
        case "queue": self = .queue
        case "search", "library": self = .search
        default: return nil
        }
    }
}

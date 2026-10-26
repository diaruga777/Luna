import Foundation
import UniformTypeIdentifiers
import LunaVaultBEP
import LunaVaultStore

public struct VaultVideoProgress: Codable, Equatable, Sendable {
    public let seconds: Double
    public let duration: Double
    public let completed: Bool
    public init(seconds: Double, duration: Double, completed: Bool = false) {
        self.seconds = seconds; self.duration = duration; self.completed = completed
    }
    public var resumeSeconds: Double {
        guard !completed, seconds.isFinite, duration.isFinite, seconds >= 0, duration > 0,
              seconds < duration else { return 0 }
        return seconds
    }
}

/// Stored only in the iPhone's metadata database, never in the source files or BEP index.
public struct VaultVideoHistory: Sendable {
    private let store: VaultFolderStore
    public init(store: VaultFolderStore) { self.store = store }
    private func key(_ identity: String) -> String {
        "video.progress." + SHA256Digest.hash(Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public func progress(for identity: String) throws -> VaultVideoProgress? {
        guard let value = try store.value(forKey: key(identity)), let data = value.data(using: .utf8) else { return nil }
        return try JSONDecoder().decode(VaultVideoProgress.self, from: data)
    }
    public func save(_ progress: VaultVideoProgress, for identity: String) throws {
        guard progress.seconds.isFinite, progress.seconds >= 0,
              progress.duration.isFinite, progress.duration > 0 else { return }
        let value = String(decoding: try JSONEncoder().encode(progress), as: UTF8.self)
        try store.setValue(value, forKey: key(identity))
    }
}

public enum VaultVideoEpisodes {
    public static func isVideo(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension
        return UTType(filenameExtension: ext)?.conforms(to: .movie) == true || ["m4v", "mkv", "avi", "webm"].contains(ext.lowercased())
    }

    /// True only in the last three minutes while paused, or the last minute
    /// during playback. Unknown/indefinite durations never show a suggestion.
    public static func showsNext(seconds: Double, duration: Double, paused: Bool) -> Bool {
        guard seconds.isFinite, duration.isFinite, seconds >= 0, duration > 0, seconds <= duration else { return false }
        return duration - seconds <= (paused ? 180 : 60)
    }

    private struct Episode {
        let season: Int?
        let number: Int
        let title: [String]
        let titleBeforeNumber: Bool
    }
    private static func episode(_ path: String) -> Episode? {
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
        let patterns = [
            #"s(?:eason)?[ ._-]*(\d{1,3})[ ._-]*e(?:p(?:isode)?)?[ ._-]*(\d{1,4})(?!\d)"#,
            #"(?<!\d)(\d{1,3})x(\d{1,4})(?!\d)"#,
            #"(?:episode|ep|e)[ ._-]*(\d{1,4})(?!\d)"#,
            #"(?<!\d)(\d{1,4})(?!\d|p\b)"#
        ]
        for (kind, pattern) in patterns.enumerated() {
            let regex = try! NSRegularExpression(pattern: pattern)
            for match in regex.matches(in: stem, range: NSRange(stem.startIndex..., in: stem)) {
                let string = stem as NSString
                let number = Int(string.substring(with: match.range(at: kind < 2 ? 2 : 1))) ?? 0
                guard number > 0, !(kind == 3 && (number >= 1900 || [264, 265, 480, 576, 720, 1080].contains(number))) else { continue }
                let prefix = string.substring(to: match.range.location)
                let suffix = string.substring(from: NSMaxRange(match.range))
                let ignored: Set<String> = ["the", "a", "an", "of", "and", "episode", "ep", "season", "s", "e", "1080p", "720p", "2160p", "4k", "web", "dl", "webrip", "bluray", "x264", "x265", "h264", "h265"]
                func words(_ text: String) -> [String] {
                    text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty && !ignored.contains($0) }
                }
                let before = words(prefix)
                let title = before.isEmpty ? words(suffix) : before
                guard title.contains(where: { $0.count >= 3 && $0.rangeOfCharacter(from: .letters) != nil }) else { continue }
                return Episode(season: kind < 2 ? Int(string.substring(with: match.range(at: 1))) : nil, number: number, title: title, titleBeforeNumber: !before.isEmpty)
            }
        }
        return nil
    }
    public static func next(after path: String, siblings: [String]) -> String? {
        guard let current = episode(path) else { return nil }
        let parent = (path as NSString).deletingLastPathComponent
        return siblings.compactMap { candidate -> (String, Episode, Int)? in
            guard candidate != path, isVideo(candidate), (candidate as NSString).deletingLastPathComponent == parent,
                  let value = episode(candidate), (current.season == nil) == (value.season == nil) else { return nil }
            let season = current.season ?? 0, nextSeason = value.season ?? 0
            guard (nextSeason == season && value.number > current.number) || (nextSeason == season + 1 && value.number == 1) else { return nil }
            // Match meaningful title words in order, allowing episode titles and
            // release suffixes to differ, without matching on codec/resolution.
            let common = Set(current.title).intersection(value.title).filter { $0.count >= 3 }
            guard !common.isEmpty else { return nil }
            let shorter = min(current.title.count, value.title.count)
            if current.titleBeforeNumber && value.titleBeforeNumber {
                guard current.title.starts(with: value.title) || value.title.starts(with: current.title) else { return nil }
            } else {
                guard common.count >= min(2, shorter) || (current.title.first == value.title.first && shorter <= 2) else { return nil }
            }
            return (candidate, value, common.count)
        }.sorted {
            if $0.1.season != $1.1.season { return ($0.1.season ?? 0) < ($1.1.season ?? 0) }
            if $0.1.number != $1.1.number { return $0.1.number < $1.1.number }
            if $0.2 != $1.2 { return $0.2 > $1.2 }
            return $0.0.localizedStandardCompare($1.0) == .orderedAscending
        }.first?.0
    }
}

import Foundation
import UniformTypeIdentifiers

/// File-family matching for automation. Extensions are metadata hints, not a
/// content sniff; use system type conformance plus common unregistered formats.
public enum VaultFileFilter {
    public static func matches(path: String, isFolder: Bool, extension fileExtension: String?, category: String?) -> Bool {
        let requested = (fileExtension ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        guard !requested.isEmpty || category != nil else { return true }
        guard !isFolder else { return false }
        let ext = (path as NSString).pathExtension.lowercased()
        guard requested.isEmpty || ext == requested else { return false }
        guard let category else { return true }
        let type = UTType(filenameExtension: ext)
        switch category {
        case "video": return type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true
            || ["mkv", "webm", "avi", "m4v", "mpg", "mpeg", "mts", "m2ts", "ts", "flv", "wmv", "ogv"].contains(ext)
        case "audio": return type?.conforms(to: .audio) == true || ["ogg", "opus", "flac", "mka"].contains(ext)
        case "image": return type?.conforms(to: .image) == true
        case "pdf": return type?.conforms(to: .pdf) == true
        case "text": return type?.conforms(to: .text) == true || ["md", "markdown", "log", "srt", "vtt"].contains(ext)
        case "archive": return type?.conforms(to: .archive) == true || ["7z", "rar", "gz", "bz2", "xz", "tgz"].contains(ext)
        default: return false
        }
    }
}

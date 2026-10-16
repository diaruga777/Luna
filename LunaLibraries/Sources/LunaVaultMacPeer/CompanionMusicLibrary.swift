import Foundation
import AVFoundation
import LunaMusicFiles
#if os(macOS)
import AppKit
#endif

/// One catalog per paired connection. Reuses metadata across scans and launches;
/// only Music is walked and no file is ever modified by this service.
public actor CompanionMusicLibrary {
    private var root: URL
    private let cacheURL: URL?
    private let scanInterval: TimeInterval
    private var files: [MusicFile] = []
    private var metadata: [String: MusicFile] = [:]
    private var generation = UUID().uuidString
    private var scannedAt = Date.distantPast
    public init(vaultRoot: URL, cacheURL: URL? = nil, scanInterval: TimeInterval = 15) {
        root = vaultRoot.appendingPathComponent("Music", isDirectory: true).standardizedFileURL
        self.cacheURL = cacheURL; self.scanInterval = scanInterval
    }
    private var loadedCache = false
    public func handle(_ payload: Data) async -> Data {
        let response: MusicFileResponse
        do {
            let request = try JSONDecoder().decode(MusicFileRequest.self, from: payload)
            try await CompanionFileAccess.shared.checkDirectory(root.deletingLastPathComponent())
            if !loadedCache {
                root = root.resolvingSymlinksInPath()
                loadedCache = true
                if let cacheURL, let data = try? Data(contentsOf: cacheURL),
                   let cached = try? JSONDecoder().decode([MusicFile].self, from: data) {
                    metadata = Dictionary(cached.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
                }
            }
            response = try await perform(request)
        } catch { response = MusicFileResponse(error: error.localizedDescription) }
        return (try? JSONEncoder().encode(response)) ?? Data()
    }
    public func perform(_ request: MusicFileRequest) async throws -> MusicFileResponse {
        switch request.operation {
        case .catalog:
            guard request.offset >= 0, request.offset <= Int64(Int.max) else { throw MusicFileError("Invalid music page.") }
            if request.offset == 0, Date().timeIntervalSince(scannedAt) > scanInterval { try await scan() }
            if request.offset > 0, request.generation != generation { throw MusicFileError("The music library changed. Refresh it again.") }
            let start = min(Int(request.offset), files.count)
            // Artwork is bounded to 12 KiB per track, so 100 rows fit the RPC cap.
            let end = min(start + MusicFileProtocol.pageSize, files.count)
            return MusicFileResponse(files: Array(files[start..<end]), nextOffset: end < files.count ? Int64(end) : nil, generation: generation)
        case .read:
            let url = try safeURL(request.path)
            try await CompanionFileAccess.shared.checkDirectory(url.deletingLastPathComponent())
            guard request.length > 0, request.length <= MusicFileProtocol.chunkSize else { throw MusicFileError("Invalid music range.") }
            let result = try CompanionMacBrowser().perform(.init(.read, path: url.path, offset: request.offset,
                length: request.length, version: request.version))
            return MusicFileResponse(data: result.data)
        }
    }
    private func safeURL(_ path: String) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !path.utf8.contains(0), MusicFileProtocol.extensions.contains((path as NSString).pathExtension.lowercased()) else {
            throw MusicFileError("Invalid music file path.")
        }
        var url = root
        for part in parts {
            url.appendPathComponent(String(part))
            guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw MusicFileError("Music files must be inside the Music folder, without symbolic links.")
            }
        }
        guard try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw MusicFileError("Music must be a real folder inside Vault.") }
        return url
    }
    private func scan() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await CompanionFileAccess.shared.checkTree(root)
        guard try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw MusicFileError("Music must be a real folder inside Vault.") }
        var failure: Error?
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles], errorHandler: { _, error in failure = error; return false }) else { throw MusicFileError("Cannot read the Music folder.") }
        var next: [MusicFile] = []
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            guard values.isRegularFile == true, MusicFileProtocol.extensions.contains(url.pathExtension.lowercased()) else { continue }
            let canonicalPath = url.standardizedFileURL.path
            guard canonicalPath.hasPrefix(root.path + "/") else { continue }
            let path = String(canonicalPath.dropFirst(root.path.count + 1))
            guard path.split(separator: "/").count >= 3 else { continue }
            guard let info = try CompanionMacBrowser().perform(.init(.stat, path: url.path)).entries.first else { continue }
            if let old = metadata[path], old.version == info.version { next.append(old); continue }
            let asset = AVURLAsset(url: url)
            guard (try? await asset.load(.isPlayable)) == true,
                  !((try? await asset.loadTracks(withMediaType: .audio)) ?? []).isEmpty else { continue }
            let tags = (try? await asset.load(.commonMetadata)) ?? []
            func value(_ key: AVMetadataKey) async -> String? {
                guard let tag = tags.first(where: { $0.commonKey == key }), let text = try? await tag.load(.stringValue),
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return String(text.prefix(300))
            }
            let parts = path.split(separator: "/").map(String.init)
            let artist = await value(.commonKeyArtist) ?? parts[0]
            let album = await value(.commonKeyAlbumName) ?? parts[1]
            let title = await value(.commonKeyTitle) ?? url.deletingPathExtension().lastPathComponent
            let duration = (try? await asset.load(.duration).seconds) ?? 0
            var cover: Data?
            #if os(macOS)
            if let tag = tags.first(where: { $0.commonKey == .commonKeyArtwork }),
               let data = try? await tag.load(.dataValue), data.count < 20 * 1024 * 1024,
               let image = NSImage(data: data) {
                let thumbnail = NSImage(size: NSSize(width: 160, height: 160), flipped: false) { rect in
                    image.draw(in: rect); return true
                }
                if let tiff = thumbnail.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                   let jpg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.55]), jpg.count <= 12 * 1024 { cover = jpg }
            }
            #endif
            let allTags = (try? await asset.load(.metadata)) ?? []
            var albumArtist = artist
            var track = Int(title.split(separator: " ").first ?? "") ?? 0
            var disc = 0
            for tag in allTags {
                let identifier = tag.identifier?.rawValue ?? ""
                if identifier == "itsk/aART", let text = try? await tag.load(.stringValue), !text.isEmpty { albumArtist = text }
                if identifier == "id3/TRCK", let text = try? await tag.load(.stringValue) { track = Int(text.split(separator: "/").first ?? "") ?? track }
                if identifier == "id3/TPOS", let text = try? await tag.load(.stringValue) { disc = Int(text.split(separator: "/").first ?? "") ?? 0 }
                if ["itsk/trkn", "itsk/disk"].contains(identifier), let data = try? await tag.load(.dataValue), data.count >= 4 {
                    let number = Int(data[2]) * 256 + Int(data[3])
                    if identifier == "itsk/trkn" { track = number } else { disc = number }
                }
            }
            // Don't install metadata extracted across an in-place file replacement.
            guard try CompanionMacBrowser().perform(.init(.stat, path: url.path)).entries.first?.version == info.version else { continue }
            next.append(MusicFile(path: path, version: info.version, size: info.size, title: title,
                artist: artist, album: album, albumArtist: albumArtist, duration: duration.isFinite ? duration : 0,
                track: track, disc: disc, modifiedAt: info.modifiedAt, artwork: cover))
        }
        if let failure { throw failure }
        next.sort { $0.path < $1.path }
        files = next; metadata = Dictionary(next.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        generation = UUID().uuidString; scannedAt = Date()
        if let cacheURL { try JSONEncoder().encode(next).write(to: cacheURL, options: .atomic) }
    }
}

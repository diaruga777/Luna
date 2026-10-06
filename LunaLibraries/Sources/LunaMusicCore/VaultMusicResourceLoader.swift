import AVFoundation
import UniformTypeIdentifiers
import Foundation

/// AVFoundation requests arbitrary ranges (including the MP4 moov atom at EOF).
/// Each request is satisfied incrementally; seeking cancels the old request and
/// never requires downloading the entire song. The cache bounds shared buffers.
@MainActor
final class VaultMusicResourceLoader: NSObject, @preconcurrency AVAssetResourceLoaderDelegate {
    let asset: AVURLAsset
    private let song: MusicSong
    private let cache: VaultMusicCache
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    init(song: MusicSong, cache: VaultMusicCache) {
        self.song = song; self.cache = cache
        let ext = (song.file!.path as NSString).pathExtension
        asset = AVURLAsset(url: URL(string: "luna-music-file://audio/\(MusicFileProtocol.key(song.persistentID.rawValue)).\(ext)")!)
        super.init()
        asset.resourceLoader.setDelegate(self, queue: .main)
    }
    func cancel() {
        tasks.values.forEach { $0.cancel() }; tasks.removeAll()
        asset.cancelLoading()
    }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        guard let file = song.file else { return false }
        if let info = request.contentInformationRequest {
            info.contentType = UTType(filenameExtension: (file.path as NSString).pathExtension)?.identifier ?? UTType.audio.identifier
            info.contentLength = file.size; info.isByteRangeAccessSupported = true
        }
        let key = ObjectIdentifier(request)
        tasks[key] = Task { [weak self, song, cache] in
            defer { self?.tasks[key] = nil }
            do {
                if let dataRequest = request.dataRequest {
                    var offset = max(dataRequest.requestedOffset, dataRequest.currentOffset)
                    let end = dataRequest.requestsAllDataToEndOfResource ? file.size : min(file.size, dataRequest.requestedOffset + Int64(dataRequest.requestedLength))
                    guard offset >= 0, offset <= end else { throw MusicFileError("Invalid playback range.") }
                    while offset < end {
                        try Task.checkCancellation()
                        let data = try await cache.range(song: song, offset: offset, length: Int(min(Int64(MusicFileProtocol.chunkSize), end - offset)))
                        try Task.checkCancellation()
                        guard !request.isCancelled else { return }
                        dataRequest.respond(with: data); offset += Int64(data.count)
                    }
                }
                if !request.isCancelled { request.finishLoading() }
            } catch {
                if !request.isCancelled { request.finishLoading(with: error) }
            }
        }
        return true
    }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        tasks.removeValue(forKey: ObjectIdentifier(request))?.cancel()
    }
}

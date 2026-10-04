//
//  RedditAudioFetcher.swift
//  Luna
//

import Foundation
import LunaModels

/// Resolves and downloads a Reddit video's audio track. Reddit doesn't hand
/// back the audio URL directly for a post with sound: `RedditMediaParser`'s
/// `primaryAudioURL` is the `/{videoID}/audio` path Reddit consistently uses
/// (confirmed against real `DASHPlaylist.mpd` manifests), tried first as a
/// fast path; if that download fails for some post, this falls back to
/// fetching and parsing the DASH manifest itself (authoritative, but a
/// second network round trip) to find the real audio URL. Shared by both
/// download engines (the foreground `MediaFileDownloader` and the
/// Downloader's background `LiveMediaDownloadManager`) rather than
/// duplicated in each.
public enum RedditAudioFetcher {
    public static func fetch(
        primaryAudioURL: URL, dashManifestURL: URL?, referer: String
    ) async -> URL? {
        if let file = await download(primaryAudioURL, referer: referer) { return file }

        guard !URLBehaviorPolicy.pluginsOnly, let dashManifestURL,
              let (data, response) = try? await URLSession.shared.data(
                for: request(for: dashManifestURL, referer: referer)),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let xml = String(data: data, encoding: .utf8),
              let resolvedURL = RedditMediaParser.audioURL(fromDASHManifest: xml, manifestURL: dashManifestURL)
        else { return nil }
        return await download(resolvedURL, referer: referer)
    }

    private static func download(_ url: URL, referer: String) async -> URL? {
        guard let (location, response) = try? await URLSession.shared.download(
            for: request(for: url, referer: referer)),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return nil }
        let destination = MediaDownloadStorage.newFileURL(extension: "mp4")
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    private static func request(for url: URL, referer: String) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(MediaDownloadHTTP.browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        return request
    }
}

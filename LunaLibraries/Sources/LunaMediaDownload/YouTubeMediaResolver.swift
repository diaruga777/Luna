//
//  YouTubeMediaResolver.swift
//  Luna
//

import Foundation
import LunaURLClassification

/// Pure normalization for the common YouTube URL family. Network-only clip
/// expansion is handled separately because `/clip/<id>` doesn't contain its
/// underlying video id or range in the URL.
public struct YouTubeLink: Equatable {
    public let sourceURL: URL
    public let videoID: String?
    public let timeRange: MediaTimeRange?
    public let isClip: Bool

    public init?(url: URL) {
        guard let recognized = PlatformRecognizer.recognize(url.absoluteString),
              recognized.platform == .youtube
        else { return nil }
        sourceURL = url
        videoID = recognized.itemID
        isClip = url.pathComponents.dropFirst().first == "clip"

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = components?.queryItems ?? []
        let explicitStart = query.first(where: { $0.name == "start" })?.value
            .flatMap(Self.seconds)
        let sharedStart = query.first(where: { $0.name == "t" })?.value
            .flatMap(Self.seconds)
        let fragmentStart: Double? = {
            guard let fragment = components?.fragment else { return nil }
            let raw = fragment.hasPrefix("t=") ? String(fragment.dropFirst(2)) : fragment
            return Self.seconds(raw)
        }()
        let start = explicitStart ?? sharedStart ?? fragmentStart ?? 0
        let end = query.first(where: { $0.name == "end" })?.value.flatMap(Self.seconds)
        let range = MediaTimeRange(startSeconds: start, endSeconds: end)
        timeRange = range.isEffective ? range : nil
    }

    public var canonicalWatchURL: URL? {
        guard let videoID else { return nil }
        return Self.watchURL(videoID: videoID)
    }

    public var embedURL: URL? {
        videoID.flatMap(Self.embedURL(videoID:))
    }

    public var thumbnailURL: URL? {
        videoID.flatMap(Self.thumbnailURL(videoID:))
    }

    static func watchURL(videoID: String) -> URL? {
        guard var components = URLComponents(string: "https://www.youtube.com/watch")
        else { return nil }
        components.queryItems = [URLQueryItem(name: "v", value: videoID)]
        return components.url
    }

    static func embedURL(videoID: String) -> URL? {
        URL(string: "https://www.youtube.com/embed/\(videoID)?html5=1")
    }

    static func thumbnailURL(videoID: String) -> URL? {
        URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg")
    }

    /// Accepts plain seconds plus YouTube's `1h2m3s`, `2m10s`, and `90s` forms.
    public static func seconds(_ raw: String) -> Double? {
        let value = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = Double(value), seconds >= 0 { return seconds }
        let pattern = #"^(?:(\d+(?:\.\d+)?)h)?(?:(\d+(?:\.\d+)?)m)?(?:(\d+(?:\.\d+)?)s)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: value, range: NSRange(value.startIndex..., in: value)),
              match.range.length == value.utf16.count
        else { return nil }
        func component(_ index: Int) -> Double {
            guard match.range(at: index).location != NSNotFound,
                  let range = Range(match.range(at: index), in: value)
            else { return 0 }
            return Double(value[range]) ?? 0
        }
        let result = component(1) * 3600 + component(2) * 60 + component(3)
        return result > 0 ? result : nil
    }
}

struct YouTubeClipDescriptor: Equatable {
    let videoID: String
    let timeRange: MediaTimeRange
}

enum YouTubeClipParser {
    static func descriptor(fromHTML html: String) -> YouTubeClipDescriptor? {
        let search: String
        if let marker = html.range(of: "clipConfig") {
            search = String(html[marker.lowerBound..<html.index(
                marker.lowerBound, offsetBy: min(8_000, html.distance(
                    from: marker.lowerBound, to: html.endIndex)))])
        } else {
            search = html
        }
        let normalized = search.replacingOccurrences(of: #"\""#, with: #"""#)
        guard let videoID = firstGroup(
            in: normalized, pattern: #"\"videoId\"\s*:\s*\"([A-Za-z0-9_-]{11})\""#),
              let startRaw = firstGroup(
                in: normalized, pattern: #"\"startTimeMs\"\s*:\s*\"?(\d+)\"?"#),
              let endRaw = firstGroup(
                in: normalized, pattern: #"\"endTimeMs\"\s*:\s*\"?(\d+)\"?"#),
              let start = Double(startRaw), let end = Double(endRaw), end > start
        else { return nil }
        return YouTubeClipDescriptor(
            videoID: videoID,
            timeRange: MediaTimeRange(
                startSeconds: start / 1_000, endSeconds: end / 1_000))
    }
}

/// Selects the best direct progressive MP4 from YouTube's player response.
/// Adaptive-only video/audio pairs are intentionally excluded: Luna's durable
/// background engine is single-file/resumable, and returning a video-only stream
/// would silently lose sound.
enum YouTubePlayerResponseParser {
    static func asset(
        from data: Data,
        videoID: String,
        timeRange: MediaTimeRange?
    ) -> MediaAsset? {
        guard let response = responseObject(from: data) else { return nil }
        return asset(from: response, videoID: videoID, timeRange: timeRange)
    }

    private static func responseObject(from data: Data) -> [String: Any]? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           object["streamingData"] != nil {
            return object
        }
        guard let html = String(data: data, encoding: .utf8) else { return nil }
        // YouTube commonly emits `var ytInitialPlayerResponse = null` before the
        // real assignment. Walk every occurrence and only accept a value whose
        // first non-whitespace character is `{`; never jump from `null` to an
        // unrelated script object's opening brace.
        var cursor = html.startIndex
        while let name = html[cursor...].range(of: "ytInitialPlayerResponse") {
            defer { cursor = name.upperBound }
            guard let equals = html[name.upperBound...].firstIndex(of: "=") else { continue }
            var valueStart = html.index(after: equals)
            while valueStart < html.endIndex,
                  html[valueStart].isWhitespace {
                valueStart = html.index(after: valueStart)
            }
            guard valueStart < html.endIndex, html[valueStart] == "{",
                  let json = balancedJSONObject(in: html, startingAt: valueStart),
                  let object = try? JSONSerialization.jsonObject(
                    with: Data(json.utf8)) as? [String: Any],
                  object["streamingData"] != nil
            else { continue }
            return object
        }
        return nil
    }

    private static func asset(
        from response: [String: Any],
        videoID: String,
        timeRange: MediaTimeRange?
    ) -> MediaAsset? {
        guard let streaming = response["streamingData"] as? [String: Any],
              let formats = streaming["formats"] as? [[String: Any]]
        else { return nil }
        let duration = ((response["videoDetails"] as? [String: Any])?["lengthSeconds"] as? String)
            .flatMap(Double.init)
        let thumbnail = bestThumbnail(response: response)
            ?? URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg")

        let candidates: [(asset: MediaAsset, height: Int, bitrate: Int)] = formats.compactMap { format in
            guard let mime = format["mimeType"] as? String,
                  mime.lowercased().contains("video/mp4"),
                  (format["audioQuality"] != nil || mime.contains(",")),
                  let urlString = format["url"] as? String,
                  let url = URL(string: urlString)
            else { return nil }
            let contentLength = int64(format["contentLength"])
                ?? approximateSize(format: format, duration: duration)
            let asset = MediaAsset(
                url: url,
                kind: .video,
                thumbnailURL: thumbnail,
                estimatedByteCount: contentLength,
                timeRange: timeRange)
            return (
                asset,
                (format["height"] as? NSNumber)?.intValue ?? 0,
                (format["bitrate"] as? NSNumber)?.intValue ?? 0)
        }
        return candidates.max {
            ($0.height, $0.bitrate) < ($1.height, $1.bitrate)
        }?.asset
    }

    private static func bestThumbnail(response: [String: Any]) -> URL? {
        guard let details = response["videoDetails"] as? [String: Any],
              let thumbnail = details["thumbnail"] as? [String: Any],
              let thumbnails = thumbnail["thumbnails"] as? [[String: Any]]
        else { return nil }
        return thumbnails.compactMap { ($0["url"] as? String).flatMap(URL.init(string:)) }.last
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let value = value as? String { return Int64(value) }
        return (value as? NSNumber)?.int64Value
    }

    private static func approximateSize(
        format: [String: Any], duration: Double?
    ) -> Int64? {
        guard let duration, duration > 0,
              let bitrate = (format["bitrate"] as? NSNumber)?.doubleValue,
              bitrate > 0
        else { return nil }
        return Int64((bitrate / 8) * duration)
    }

    private static func balancedJSONObject(
        in text: String, startingAt start: String.Index
    ) -> String? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return String(text[start...index]) }
            }
            index = text.index(after: index)
        }
        return nil
    }
}

struct YouTubeMediaResolver {
    typealias Fetch = SocialMediaResolver.Fetch
    let fetch: Fetch

    init(fetch: @escaping Fetch = SocialMediaResolver.defaultFetch) {
        self.fetch = fetch
    }

    func resolveAssets(for sourceURL: URL) async -> [MediaAsset] {
        guard let link = YouTubeLink(url: sourceURL) else { return [] }
        var videoID = link.videoID
        var range = link.timeRange

        if link.isClip {
            guard let data = await fetch(Self.htmlRequest(sourceURL)),
                  let html = String(data: data, encoding: .utf8),
                  let clip = YouTubeClipParser.descriptor(fromHTML: html)
            else { return [] }
            videoID = clip.videoID
            range = clip.timeRange
        }
        guard let videoID else { return [] }

        guard let watchURL = YouTubeLink.watchURL(videoID: videoID) else { return [] }
        let watchData = await fetch(Self.htmlRequest(watchURL))
        if let watchData,
           let asset = YouTubePlayerResponseParser.asset(
            from: watchData, videoID: videoID, timeRange: range) {
            return [asset]
        }

        if let embedURL = URL(string: "https://www.youtube.com/embed/\(videoID)?html5=1"),
           let data = await fetch(Self.htmlRequest(embedURL)),
           let asset = YouTubePlayerResponseParser.asset(
            from: data, videoID: videoID, timeRange: range) {
            return [asset]
        }

        // Final keyless attempt: use the public Innertube configuration exposed
        // by the watch page with the embedded-player client. Responses that only
        // contain ciphered/PO-token formats remain unsupported and fail clearly.
        guard let watchData,
              let request = Self.playerRequest(
                fromWatchData: watchData, videoID: videoID)
        else { return [] }
        guard let data = await fetch(request),
              let asset = YouTubePlayerResponseParser.asset(
                from: data, videoID: videoID, timeRange: range)
        else { return [] }
        return [asset]
    }

    static func htmlRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(
            url: url, cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30)
        request.httpShouldHandleCookies = false
        request.setValue(MediaDownloadHTTP.browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        return request
    }

    static func playerRequest(fromWatchData data: Data, videoID: String) -> URLRequest? {
        guard let html = String(data: data, encoding: .utf8),
              let apiKey = firstGroup(
                in: html, pattern: #"\"INNERTUBE_API_KEY\"\s*:\s*\"([^\"]+)\""#)
        else { return nil }
        guard let version = firstGroup(
            in: html,
            pattern: #"\"INNERTUBE_CLIENT_VERSION\"\s*:\s*\"([^\"]+)\""#)
        else { return nil }
        var endpoint = URLComponents(string: "https://www.youtube.com/youtubei/v1/player")
        endpoint?.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let endpointURL = endpoint?.url else { return nil }
        var request = URLRequest(url: endpointURL, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(MediaDownloadHTTP.browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "videoId": videoID,
            "contentCheckOk": true,
            "racyCheckOk": true,
            "context": ["client": [
                "clientName": "WEB_EMBEDDED_PLAYER",
                "clientVersion": version,
                "hl": "en",
                "gl": "US",
            ]],
        ])
        return request.httpBody == nil ? nil : request
    }
}

private func firstGroup(in text: String, pattern: String) -> String? {
    guard let regex = try? NSRegularExpression(
        pattern: pattern, options: [.dotMatchesLineSeparators]),
          let match = regex.firstMatch(
            in: text, range: NSRange(text.startIndex..., in: text)),
          match.numberOfRanges > 1,
          let range = Range(match.range(at: 1), in: text)
    else { return nil }
    return String(text[range])
}
